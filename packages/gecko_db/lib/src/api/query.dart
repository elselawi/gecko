/// Query contract — Tier 2 query builder.
library;

import 'dart:async';

/// Sort direction.
enum SortOrder { ascending, descending }

/// Which plan a query execution used (index diagnostics).
enum IndexPlan { fullScan, secondaryIndex }

/// A single sort specification (field + direction).
class SortSpec {
  const SortSpec(this.field, [this.order = SortOrder.ascending]);

  final String field;
  final SortOrder order;
}

/// A lazily-evaluated query against a collection (Tier 2).
///
/// Queries never materialize the full collection in memory; they evaluate
/// against indexes where available and fall back to scans otherwise.
abstract class Query<T> {
  /// Diagnostics: which plan the last execution used, or null if the query has
  /// not run yet.
  IndexPlan get lastPlan;

  /// Reactive filtered query (Tier 2): re-emits the matching list whenever a
  /// change in this collection might affect membership.
  Stream<List<T>> watch();

  /// Adds a filter on [field] == [value].
  Query<T> filter(String field, Object? value);

  /// Adds a range filter: min <= field (or <= max) on [field].
  Query<T> range(String field, {Object? min, Object? max});

  /// Adds a prefix filter: [field] is a String starting with [prefix].
  Query<T> prefix(String field, String prefix);

  /// Applies a sort specification.
  Query<T> sort(List<SortSpec> specs);

  /// Limits the result set.
  Query<T> limit(int n);

  /// Skips the first [n] results (offset pagination).
  Query<T> offset(int n);

  /// Returns all matching records (empty list when none).
  Future<List<T>> findAll();

  /// Lazily streams matching records without materializing the full result
  /// set. For sorted queries the engine must materialize ordering, so this is
  /// documented as equivalent to [findAll] in that case; for unsorted queries
  /// it genuinely streams.
  Stream<T> iterate();

  /// Returns the first matching record, or null.
  Future<T?> first();

  /// Counts the matching records.
  Future<int> count();

  /// Returns distinct values of [field] among matches.
  Future<List<Object?>> distinct(String field);

  /// Cursor-based pagination. Resumes after [afterKey], returning a page plus
  /// the next cursor.
  Future<(List<T>, Object? nextCursor)> findPage({
    Object? afterKey,
    int? pageSize,
  });

  /// Opens a **snapshot-bound cursor** over this query's result.
  ///
  /// The cursor captures one MVCC snapshot at creation and paginates that
  /// frozen view, so concurrent inserts/updates/deletes never duplicate or
  /// drop records across pages (WS3 cursor contract). Call [QueryCursor.dispose]
  /// to release the snapshot.
  QueryCursor<T> cursor({int? pageSize});
}

/// A snapshot-bound pagination cursor over a query result (WS3).
///
/// Pages follow the query's documented order, are disjoint, and together
/// exhaust the result exactly once. The underlying snapshot is released by
/// [dispose] (and by the backend on close).
abstract class QueryCursor<T> {
  /// Returns the next page of at most [pageSize] results (default 50) plus an
  /// opaque cursor for the following call, or `([], null)` when exhausted.
  Future<(List<T>, Object? nextCursor)> next({int? pageSize});

  /// Releases the underlying snapshot. Idempotent.
  Future<void> dispose();
}
