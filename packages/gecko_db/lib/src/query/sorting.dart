/// sorting comparators.
///
/// Rows are sorted by a list of [`SortSpec`]. Missing field values place those
/// rows at a documented position: last for ascending, first for descending
/// (consistent with the index ordering). [`compareRows`] returns 0 for ties;
/// the query engine then breaks ties deterministically by record key bytes
///, which matches the durable index's `(value, recordId)` order so the
/// native fast paths and the Dart sort agree exactly.
library;

import '../api/query.dart';

/// Compares two rows by the given sort specs.
///
/// `missingFirst` controls where rows lacking the sort field sort: for
/// ascending we want missing values last, for descending missing first.
/// Returns 0 for ties; the query engine breaks ties by record key.
int compareRows(
  Map<Object?, Object?> a,
  Map<Object?, Object?> b,
  List<SortSpec> specs,
) {
  for (final spec in specs) {
    final hasA = a.containsKey(spec.field);
    final hasB = b.containsKey(spec.field);
    if (hasA != hasB) {
      // Missing sort placement: ascending → missing last; descending → missing first.
      if (spec.order == SortOrder.ascending) {
        return hasA ? -1 : 1; // a present → a first
      } else {
        return hasA ? 1 : -1; // a present → a last
      }
    }
    if (!hasA) continue;
    final cmp = _compare(a[spec.field], b[spec.field]);
    if (cmp != 0) {
      return spec.order == SortOrder.ascending ? cmp : -cmp;
    }
  }
  return 0; // stable: keep input order for ties
}

int _compare(Object? x, Object? y) => compareFieldValues(x, y);

/// Compares two decoded field values under the documented sort-order contract
/// (nulls sort last, numerics by value, then strings, then other comparable
/// types, with a deterministic fallback by string representation).
int compareFieldValues(Object? x, Object? y) {
  if (x is num && y is num) return x.compareTo(y);
  if (x is String && y is String) return x.compareTo(y);
  if (x is bool && y is bool) return (x ? 1 : 0).compareTo(y ? 1 : 0);
  if (x is Comparable && y is Comparable && x.runtimeType == y.runtimeType) {
    return Comparable.compare(x, y);
  }
  if (x == null || y == null) {
    return (x ?? '').toString().compareTo((y ?? '').toString());
  }
  return x.toString().compareTo(y.toString());
}
