/// Phase 5 filter building blocks.
///
/// A filter is a pure function from a row map to whether it matches. Filters
/// compose (AND) and support equality, range, and prefix matching. They are
/// evaluated against the decoded row map.
library;

/// A pure row predicate: returns true if [row] matches.
typedef RowPredicate = bool Function(Map<Object?, Object?> row);

/// The field type for a filter — comparisons use Dart ordering semantics
/// compatible with the sort ordering contract.
enum _Op { equals, range, prefix }

/// A declarative filter the query engine can also use to decide
/// index-usability.
class Filter {
  Filter._(this.field, this._op, {this.value, this.min, this.max, this.prefix});

  /// Equality filter: field == [value].
  factory Filter.eq(String field, Object? value) =>
      Filter._(field, _Op.equals, value: value);

  /// Range filter: [min] <= field <= [max] (bounds optional).
  factory Filter.between(String field, {Object? min, Object? max}) =>
      Filter._(field, _Op.range, min: min, max: max);

  /// Prefix filter: field is a String starting with [prefix].
  factory Filter.prefix(String field, String prefix) =>
      Filter._(field, _Op.prefix, prefix: prefix);

  final String field;
  final Object? value;
  final Object? min;
  final Object? max;
  final String? prefix;
  final _Op _op;

  /// Whether this filter is satisfiable solely by looking up a value for
  /// [field] (an index on [field] can serve it).
  bool get isIndexUsable => _op == _Op.equals;

  /// Whether this is a range (`min <= field <= max`) filter.
  bool get isRangeFilter => _op == _Op.range;

  /// Whether this is a string-prefix filter.
  bool get isPrefixFilter => _op == _Op.prefix;

  /// Whether this filter matches the row's [fieldValue].
  bool matchesValue(Object? fieldValue) {
    switch (_op) {
      case _Op.equals:
        return _deepEquals(fieldValue, value);
      case _Op.range:
        if (min != null && _compare(fieldValue, min) < 0) return false;
        if (max != null && _compare(fieldValue, max) > 0) return false;
        return true;
      case _Op.prefix:
        if (fieldValue is! String || prefix == null) return false;
        return fieldValue.startsWith(prefix!);
    }
  }

  /// Evaluates the filter against a full row.
  bool test(Map<Object?, Object?> row) => matchesValue(row[field]);

  @override
  String toString() => switch (_op) {
    _Op.equals => '$field == $value',
    _Op.range => '$field in [$min, $max]',
    _Op.prefix => '$field startsWith $prefix',
  };

  static bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
      }
      return true;
    }
    return a == b;
  }

  static int _compare(Object? a, Object? b) {
    if (a is Comparable && b is Comparable && a.runtimeType == b.runtimeType) {
      return Comparable.compare(a, b);
    }
    if (a == b) return 0;
    // Deterministic fallback ordering by string representation.
    final sa = a.toString();
    final sb = b.toString();
    if (sa == sb) return 0;
    return sa.compareTo(sb);
  }
}

/// An AND-composed filter built from a list of primitives.
class FilterGroup {
  FilterGroup(this.filters);
  final List<Filter> filters;

  bool get isEmpty => filters.isEmpty;

  bool test(Map<Object?, Object?> row) => filters.every((f) => f.test(row));

  /// All fields referenced by equality filters (candidate index fields).
  List<String> get equalityFields => [
    for (final f in filters.where((f) => f._op == _Op.equals)) f.field,
  ];
}
