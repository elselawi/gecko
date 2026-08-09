/// In-memory secondary index for the query engine (Phase 5 Dart half).
///
/// The durable `redb` `MultimapTable` variant is native work; this pure-Dart
/// index is maintained by the typed collection and consulted by [`QueryImpl`]
/// so indexed equality/prefix queries avoid a full table scan (observable via
/// `IndexPlan.secondaryIndex` and the engine's scan counter). It is
/// single-writer consistent: updates happen under the same write gate that
/// commits the primary record.
library;

import 'dart:collection';

import 'sorting.dart';

/// A decoded row plus its stable record id, used to maintain an index.
typedef IndexedRow = ({Object? id, Map<Object?, Object?> row});

/// An in-memory equality + optional-prefix secondary index over one or more
/// fields of a collection. Equality-indexed fields are also range-capable
/// (a sorted value map is maintained per field), so `range()` queries on an
/// indexed field avoid a full table scan.
class SecondaryIndex {
  SecondaryIndex({required this.fields, Iterable<String>? prefixFields})
    : prefixFields = List<String>.unmodifiable(prefixFields ?? const []) {
    for (final field in fields) {
      _byField[field] = <Object?, Set<Object?>>{};
      _sorted[field] = SplayTreeMap<Object?, Set<Object?>>(compareFieldValues);
      _byKey[field] = <Object?, Object?>{};
    }
    for (final field in prefixFields ?? const <String>[]) {
      _byPrefix[field] = <String, Set<Object?>>{};
      _sorted[field] = SplayTreeMap<Object?, Set<Object?>>(compareFieldValues);
      _byKey[field] = <Object?, Object?>{};
    }
  }

  /// Fields indexed for equality lookups, in declaration order.
  final List<String> fields;

  /// Fields supporting prefix ("search-as-you-type") lookups.
  final List<String> prefixFields;

  final Map<String, Map<Object?, Set<Object?>>> _byField = {};
  final Map<String, Map<Object?, Object?>> _byKey = {};
  final Map<String, Map<String, Set<Object?>>> _byPrefix = {};

  /// Sorted value → ids, for range-capable (equality and prefix) fields.
  final Map<String, SplayTreeMap<Object?, Set<Object?>>> _sorted = {};

  /// True if [field] is indexed for equality.
  bool isIndexed(String field) => fields.contains(field);

  /// True if [field] supports prefix lookups.
  bool isPrefixed(String field) => prefixFields.contains(field);

  /// True if [field] is range-capable (equality or prefix indexed).
  bool isRangeIndexed(String field) =>
      fields.contains(field) || prefixFields.contains(field);

  /// All equality filters in [eqs] must be on indexed fields.
  bool coversEq(Map<String, Object?> eqs) {
    if (eqs.isEmpty) return false;
    return eqs.keys.every(isIndexed);
  }

  /// Inserts [row] under [id]. All prior entries for [id] must be removed
  /// first via [remove] (or [replace]).
  void insert(Object? id, Map<Object?, Object?> row) {
    for (final field in fields) {
      if (row.containsKey(field)) {
        final value = row[field];
        _byField[field]!.putIfAbsent(value, () => <Object?>{}).add(id);
        _sorted[field]!.putIfAbsent(value, () => <Object?>{}).add(id);
      }
    }
    for (final field in prefixFields) {
      final value = row[field];
      if (value is String) {
        for (var end = 1; end <= value.length; end++) {
          _byPrefix[field]!
              .putIfAbsent(value.substring(0, end), () => <Object?>{})
              .add(id);
        }
      }
    }
    _byKeyValue(id, row);
  }

  /// Removes [row] under [id].
  void remove(Object? id, Map<Object?, Object?> row) {
    for (final field in fields) {
      if (row.containsKey(field)) {
        final set = _byField[field]![row[field]];
        set?.remove(id);
        if (set != null && set.isEmpty) _byField[field]!.remove(row[field]);
        final sorted = _sorted[field]![row[field]];
        sorted?.remove(id);
        if (sorted != null && sorted.isEmpty) {
          _sorted[field]!.remove(row[field]);
        }
      }
    }
    for (final field in prefixFields) {
      final value = row[field];
      if (value is String) {
        for (var end = 1; end <= value.length; end++) {
          final key = value.substring(0, end);
          final set = _byPrefix[field]![key];
          set?.remove(id);
          if (set != null && set.isEmpty) _byPrefix[field]!.remove(key);
        }
      }
    }
    for (final field in fields) {
      _byKey[field]!.remove(id);
    }
    for (final field in prefixFields) {
      _byKey[field]!.remove(id);
    }
  }

  /// Replaces the old value of [id] with [row].
  void replace(
    Object? id,
    Map<Object?, Object?> oldRow,
    Map<Object?, Object?> row,
  ) {
    if (oldRow.isEmpty && !_has(id)) {
      insert(id, row);
      return;
    }
    remove(id, oldRow);
    insert(id, row);
  }

  bool _has(Object? id) =>
      _byKey[fields.isEmpty
              ? (fields.isNotEmpty ? fields.first : '')
              : fields.first]
          ?.containsKey(id) ??
      false;

  void _byKeyValue(Object? id, Map<Object?, Object?> row) {
    for (final field in fields) {
      if (row.containsKey(field)) _byKey[field]![id] = row[field];
    }
    for (final field in prefixFields) {
      if (row.containsKey(field)) _byKey[field]![id] = row[field];
    }
  }

  /// Returns the set of ids matching every equality filter, or null when the
  /// equality set is not covered by this index.
  Set<Object?>? lookupEq(Map<String, Object?> eqs) {
    if (!coversEq(eqs)) return null;
    Set<Object?>? result;
    for (final entry in eqs.entries) {
      final ids = _byField[entry.key]?[entry.value] ?? const <Object?>{};
      result = result == null
          ? Set<Object?>.from(ids)
          : result.intersection(ids);
      if (result.isEmpty) break;
    }
    return result ?? <Object?>{};
  }

  /// Returns ids whose [field] value has [prefix], or null when the field is
  /// not prefix-indexed.
  Set<Object?>? lookupPrefix(String field, String prefix) {
    if (!isPrefixed(field)) return null;
    return _byPrefix[field]?[prefix] ?? <Object?>{};
  }

  /// Returns ids whose [field] value is within [min]..[max] (both inclusive;
  /// either bound optional), or null when [field] is not range-capable. The
  /// sorted structure makes this O(log n + k), not a full scan.
  Set<Object?>? lookupRange(String field, {Object? min, Object? max}) {
    if (!isRangeIndexed(field)) return null;
    final sorted = _sorted[field];
    if (sorted == null || sorted.isEmpty) return <Object?>{};
    final result = <Object?>{};
    for (final value in sorted.keys) {
      if (min != null && compareFieldValues(value, min) < 0) continue;
      if (max != null && compareFieldValues(value, max) > 0) break;
      result.addAll(sorted[value]!);
    }
    return result;
  }

  /// Diagnostics: the field→value distribution (for index-usage assertions).
  Map<String, int> get sizeByField => {
    for (final e in _byField.entries) e.key: e.value.length,
  };

  /// Clears all index entries (used when rebuilding the index from the primary
  /// table at open to eliminate drift).
  void clearForRebuild() {
    for (final map in _byField.values) {
      map.clear();
    }
    for (final map in _byKey.values) {
      map.clear();
    }
    for (final map in _byPrefix.values) {
      map.clear();
    }
    for (final map in _sorted.values) {
      map.clear();
    }
  }
}
