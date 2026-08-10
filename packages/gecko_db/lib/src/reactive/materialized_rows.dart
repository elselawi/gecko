/// M8: incremental materialized result cache for reactive streams.
///
/// A live watch keeps a cached materialized view of the rows it reports and,
/// on each coalesced batch, applies only the affected rows via point reads —
/// never a full re-scan of the watched table. This keeps the per-write update
/// cost independent of the watched collection size (the M8 done-when).
///
/// Rows are stored as decoded wire maps keyed by their raw [`ByteKey`] and
/// kept in ascending byte-key order — the documented order of
/// `Collection.getAll()` and unsorted `Query.findAll()`. A `SplayTreeMap`
/// gives O(log n) point insert/remove/update; the ordered list is rebuilt only
/// when emitting.
library;

import 'dart:collection';

import '../backend/byte_key.dart';

/// An ordered, incrementally-maintained set of decoded rows.
class MaterializedRows {
  final SplayTreeMap<ByteKey, Object?> _rows = SplayTreeMap<ByteKey, Object?>();

  bool get isEmpty => _rows.isEmpty;

  int get length => _rows.length;

  /// Whether [key] is currently materialized.
  bool contains(ByteKey key) => _rows.containsKey(key);

  /// The decoded row at [key], or null when absent.
  Object? operator [](ByteKey key) => _rows[key];

  /// Upserts [row] at [key] (order is maintained by the tree).
  void put(ByteKey key, Object? row) => _rows[key] = row;

  /// Removes [key] (a no-op when absent).
  void remove(ByteKey key) => _rows.remove(key);

  /// Drops every row (whole-table clear).
  void clear() => _rows.clear();

  /// The materialized rows in ascending byte-key order.
  List<Object?> toList() => [for (final row in _rows.values) row];

  Iterable<ByteKey> get keys => _rows.keys;
}
