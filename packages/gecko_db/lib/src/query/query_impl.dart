/// Phase 5 query engine over the byte-level engine.
///
/// Queries decode each stored row into a plain map, evaluate [`FilterGroup`]s,
/// apply the documented sort ordering, and support pagination, count, distinct,
/// lazy iteration, and cursor pagination. A secondary-index layer is layered on
/// top for efficiency (indexed vs fallback-scan is observable via `usedIndex`).
library;

import 'dart:async';

import '../api/change.dart';
import '../api/maintenance.dart';
import '../api/query.dart';
import '../backend/byte_key.dart';
import '../backend/native_raw_backend.dart' show NativeRawSnapshot;
import '../backend/raw_backend.dart';
import '../errors/errors.dart';
import '../raw/raw_engine.dart';
import '../wire/wire_codec.dart';
import 'durable_index_bounds.dart';
import 'filter.dart';
import 'predicate_codec.dart';
import 'secondary_index.dart';
import 'sorting.dart';

/// A decoded row plus its raw key, carried during query evaluation.
class _Decoded {
  _Decoded(this.key, this.row);
  final ByteKey key;
  final Map<Object?, Object?> row;
}

/// Immutable secondary index metadata used by the engine.
class IndexDefinition {
  const IndexDefinition({required this.name, required this.fields});
  final String name;
  final List<String> fields;

  bool get isCompound => fields.length > 1;
}

/// A single in-memory secondary index bound to a collection, used by queries
/// on that collection plus the write path that keeps it in sync.
class CollectionIndex {
  CollectionIndex({
    required List<String> fields,
    Iterable<String>? prefixFields,
  }) : secondary = SecondaryIndex(
         fields: fields,
         prefixFields: prefixFields ?? const [],
       );

  final SecondaryIndex secondary;
  final Completer<void> _ready = Completer<void>();

  /// Completes once the index has been populated from the primary table at
  /// collection-open. Queries await this before consulting the index so a
  /// freshly-opened collection can never read a partially-built index.
  Future<void> get ready => _ready.future;

  /// Marks the index fully populated.
  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// True if the index is ready for queries.
  bool get isReady => _ready.isCompleted;

  /// The primary decoded row key (the typed collection's record id).
  void onPut(Object? id, Object? previous, Object? row) {
    final oldMap = previous is Map
        ? Map<Object?, Object?>.from(previous)
        : <Object?, Object?>{};
    final newMap = row is Map
        ? Map<Object?, Object?>.from(row)
        : <Object?, Object?>{};
    if (oldMap.isNotEmpty) secondary.remove(id, oldMap);
    secondary.insert(id, newMap);
  }

  /// Removes [row] under [id] when a record is deleted.
  void onDelete(Object? id, Object? previous) {
    final oldMap = previous is Map
        ? Map<Object?, Object?>.from(previous)
        : <Object?, Object?>{};
    secondary.remove(id, oldMap);
  }
}

/// The concrete [`Query`] implementation.
class QueryImpl<T> implements Query<T> {
  QueryImpl(
    this._engine,
    this._table, {
    required this.toRow,
    required this.fromRow,
    Map<String, Object?>? initialEq,
    CollectionIndex? secondary,
  }) : _filters = <Filter>[
         for (final entry in (initialEq ?? const {}).entries)
           Filter.eq(entry.key.toString(), entry.value),
       ],
       _secondary = secondary;

  final RawEngine _engine;
  final String _table;
  final Object? Function(T) toRow;
  final T Function(Object?) fromRow;
  final CollectionIndex? _secondary;

  final List<Filter> _filters;
  List<SortSpec> _sort = const [];
  int? _limit;
  int? _offset;
  final DefaultWireCodec _codec = const DefaultWireCodec();

  /// Diagnostics: which plan the last execution used.
  @override
  IndexPlan lastPlan = IndexPlan.fullScan;

  @override
  Query<T> filter(String field, Object? value) {
    final q = _copy();
    q._filters.add(Filter.eq(field, value));
    return q;
  }

  @override
  Query<T> range(String field, {Object? min, Object? max}) {
    final q = _copy();
    q._filters.add(Filter.between(field, min: min, max: max));
    return q;
  }

  @override
  Query<T> prefix(String field, String prefix) {
    final q = _copy();
    q._filters.add(Filter.prefix(field, prefix));
    return q;
  }

  @override
  Query<T> sort(List<SortSpec> specs) {
    final q = _copy();
    q._sort = List<SortSpec>.from(specs);
    return q;
  }

  @override
  Query<T> limit(int n) {
    final q = _copy();
    q._limit = n;
    return q;
  }

  @override
  Query<T> offset(int n) {
    final q = _copy();
    q._offset = n;
    return q;
  }

  QueryImpl<T> _copy() =>
      QueryImpl<T>(
          _engine,
          _table,
          toRow: toRow,
          fromRow: fromRow,
          secondary: _secondary,
        )
        .._filters.addAll(_filters)
        .._sort = List<SortSpec>.from(_sort)
        .._limit = _limit
        .._offset = _offset;

  FilterGroup get _group => FilterGroup(_filters);

  /// Lazy iteration over matching decoded rows in sort order, consulting the
  /// optional secondary index when the equality filters are covered.
  Stream<_Decoded> _scan() async* {
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot();
    try {
      yield* _scanWith(snap, secondary?.secondary, null);
    } finally {
      await snap.dispose();
    }
  }

  /// When [idx] is non-null and the query has exactly one equality filter
  /// covered by the index, returns `(field, value)` for a durable-index
  /// range scan. Returns null for multi-eq, range, prefix, or uncovered
  /// queries (those stay on the Dart per-id path until the corresponding
  /// bound helpers land).
  (String, Object?)? _nativeEqProbe(SecondaryIndex? idx) {
    if (idx == null) return null;
    final eqs = <String, Object?>{
      for (final f in _filters)
        if (f.isIndexUsable) f.field: f.value,
    };
    if (eqs.length != 1 || !idx.coversEq(eqs)) return null;
    // Range/prefix filters mixed with the eq would also need primitive
    // intersection in Rust; defer those to the Dart path.
    final hasRangeOrPrefix = _filters.any(
      (f) => f.isRangeFilter || f.isPrefixFilter,
    );
    if (hasRangeOrPrefix) return null;
    final entry = eqs.entries.single;
    return (entry.key, entry.value);
  }

  /// Computes the candidate-id set from any index-usable filters (equality,
  /// range, prefix), intersecting all of them. Returns null when no filter is
  /// index-served (full scan required).
  Set<Object?>? _indexCandidates(SecondaryIndex? idx) {
    if (idx == null) return null;
    Set<Object?>? candidates;
    final eqs = <String, Object?>{
      for (final f in _filters)
        if (f.isIndexUsable) f.field: f.value,
    };
    if (eqs.isNotEmpty && idx.coversEq(eqs)) {
      candidates = idx.lookupEq(eqs);
    }
    for (final f in _filters) {
      if (f.isRangeFilter && idx.isRangeIndexed(f.field)) {
        final rangeIds = idx.lookupRange(f.field, min: f.min, max: f.max)!;
        candidates = candidates == null
            ? rangeIds
            : candidates.intersection(rangeIds);
      }
    }
    for (final f in _filters) {
      if (f.isPrefixFilter && idx.isPrefixed(f.field)) {
        final prefixIds = idx.lookupPrefix(f.field, f.prefix!)!;
        candidates = candidates == null
            ? prefixIds
            : candidates.intersection(prefixIds);
      }
    }
    return candidates;
  }

  Stream<_Decoded> _scanWith(
    RawSnapshot snap,
    SecondaryIndex? idx,
    _QueryTimings? t,
  ) async* {
    if (t != null) t.start(_QueryStage.plan);
    if (t != null && idx != null) t.start(_QueryStage.indexLookup);
    final candidateIds = _indexCandidates(idx);
    if (t != null) {
      if (idx != null) t.stop(_QueryStage.indexLookup);
      t.stop(_QueryStage.plan);
    }
    if (candidateIds != null) {
      lastPlan = IndexPlan.secondaryIndex;
      // Phase 2 native fast path: when the snapshot is a NativeRawSnapshot
      // (redb file backend) and the query is a single equality filter
      // covered by the index, traverse the durable `__gecko_index` table in
      // one FRB hop and join back to the rows — eliminating the Dart-side
      // N+1 point reads (88% of indexed eq per the Phase 1 profile).
      // Multi-eq/range/prefix stay on the Dart per-id path for now.
      final nativeEq = _nativeEqProbe(idx);
      if (nativeEq != null && snap is NativeRawSnapshot) {
        final (field, value) = nativeEq;
        final (start, end) = eqBounds(_table, field, value, codec: _codec);
        if (t != null) t.start(_QueryStage.backendRead);
        final entries = await snap.queryIndexed(
          table: _table,
          start: ByteKey(start),
          end: ByteKey(end),
        );
        if (t != null) t.stop(_QueryStage.backendRead);
        final decoded = <_Decoded>[];
        for (final entry in entries) {
          if (t != null) {
            t.scanned++;
            t.start(_QueryStage.decode);
          }
          final decodedValue = _codec.decode(entry.value ?? const []);
          if (t != null) {
            t.stop(_QueryStage.decode);
            t.start(_QueryStage.mapCopy);
          }
          final row = _mapOf(decodedValue);
          if (t != null) t.stop(_QueryStage.mapCopy);
          decoded.add(_Decoded(entry.key, row));
        }
        if (_sort.isNotEmpty) {
          if (t != null) t.start(_QueryStage.sort);
          decoded.sort((a, b) => compareRows(a.row, b.row, _sort));
          if (t != null) t.stop(_QueryStage.sort);
        }
        if (t != null) t.start(_QueryStage.predicate);
        for (final item in decoded) {
          if (_group.test(item.row)) {
            if (t != null) t.matched++;
            yield item;
          }
        }
        if (t != null) t.stopAccum(_QueryStage.predicate);
        return;
      }
      final decoded = <_Decoded>[];
      for (final id in candidateIds) {
        if (t != null) t.start(_QueryStage.backendRead);
        final raw = await snap.read(_table, ByteKey(_codec.encode(id)));
        if (raw == null) continue;
        if (t != null) {
          t.scanned++;
          t.stop(_QueryStage.backendRead);
          t.start(_QueryStage.decode);
        }
        final decodedValue = _codec.decode(raw);
        if (t != null) {
          t.stop(_QueryStage.decode);
          t.start(_QueryStage.mapCopy);
        }
        final row = _mapOf(decodedValue);
        if (t != null) t.stop(_QueryStage.mapCopy);
        decoded.add(_Decoded(ByteKey(_codec.encode(id)), row));
      }
      if (_sort.isNotEmpty) {
        if (t != null) t.start(_QueryStage.sort);
        decoded.sort((a, b) => compareRows(a.row, b.row, _sort));
        if (t != null) t.stop(_QueryStage.sort);
      }
      if (t != null) t.start(_QueryStage.predicate);
      for (final item in decoded) {
        if (_group.test(item.row)) {
          if (t != null) t.matched++;
          yield item;
        }
      }
      if (t != null) t.stopAccum(_QueryStage.predicate);
      return;
    }
    lastPlan = IndexPlan.nativeFilteredScan;
    // Phase 2 step 2: when the snapshot is a NativeRawSnapshot (redb file
    // backend), push the predicate to Rust. The scan evaluates the predicate
    // against each row's bytes IN RUST (decoding only the referenced fields)
    // and returns only matches in one boundary crossing — non-matching rows
    // are never decoded in Dart (the Phase 1 profile showed `scanAll`
    // transferring the whole table dominated 70% of a 100k-row full scan).
    // An empty predicate matches everything (matches Dart's FilterGroup).
    if (snap is NativeRawSnapshot) {
      final predicateBytes = encodePredicate(_filters, codec: _codec);
      if (t != null) t.start(_QueryStage.backendRead);
      final entries = await snap.queryFiltered(
        table: _table,
        predicateBytes: predicateBytes,
      );
      if (t != null) t.stop(_QueryStage.backendRead);
      final decoded = <_Decoded>[];
      for (final entry in entries) {
        if (t != null) {
          t.scanned++;
          t.start(_QueryStage.decode);
        }
        final decodedValue = _codec.decode(entry.value ?? const []);
        if (t != null) {
          t.stop(_QueryStage.decode);
          t.start(_QueryStage.mapCopy);
        }
        final row = _mapOf(decodedValue);
        if (t != null) t.stop(_QueryStage.mapCopy);
        decoded.add(_Decoded(entry.key, row));
      }
      if (_sort.isNotEmpty) {
        if (t != null) t.start(_QueryStage.sort);
        decoded.sort((a, b) => compareRows(a.row, b.row, _sort));
        if (t != null) t.stop(_QueryStage.sort);
      }
      // The predicate was already evaluated in Rust; re-test in Dart only when
      // timing is armed (to populate the `predicate` stage for the breakdown).
      if (t != null) t.start(_QueryStage.predicate);
      for (final item in decoded) {
        if (t != null) t.matched++;
        // Rust already filtered; no Dart re-test needed for correctness.
        yield item;
      }
      if (t != null) t.stopAccum(_QueryStage.predicate);
      return;
    }
    // In-memory backend (or non-native snapshot): the original Dart full scan.
    lastPlan = IndexPlan.fullScan;
    if (t != null) t.start(_QueryStage.backendRead);
    final entries = await snap.scanAll(_table);
    if (t != null) t.stop(_QueryStage.backendRead);
    final decoded = <_Decoded>[];
    for (final entry in entries) {
      if (t != null) {
        t.scanned++;
        t.start(_QueryStage.decode);
      }
      final decodedValue = _codec.decode(entry.value ?? const []);
      if (t != null) {
        t.stop(_QueryStage.decode);
        t.start(_QueryStage.mapCopy);
      }
      final row = _mapOf(decodedValue);
      if (t != null) t.stop(_QueryStage.mapCopy);
      decoded.add(_Decoded(entry.key, row));
    }
    if (_sort.isNotEmpty) {
      if (t != null) t.start(_QueryStage.sort);
      decoded.sort((a, b) => compareRows(a.row, b.row, _sort));
      if (t != null) t.stop(_QueryStage.sort);
    }
    if (t != null) t.start(_QueryStage.predicate);
    for (final item in decoded) {
      if (_group.test(item.row)) {
        if (t != null) t.matched++;
        yield item;
      }
    }
    if (t != null) t.stopAccum(_QueryStage.predicate);
  }

  Map<Object?, Object?> _mapOf(Object? value) =>
      value is Map ? Map<Object?, Object?>.from(value) : <Object?, Object?>{};

  /// Applies limit/offset after an already-ordered stream.
  Future<List<_Decoded>> _collectOrdered({_QueryTimings? t}) async {
    final matching = <_Decoded>[];
    await for (final item in _scanTimed(t)) {
      matching.add(item);
    }
    var start = _offset ?? 0;
    var end = matching.length;
    if (_limit != null) end = start + _limit!;
    if (start > matching.length) start = matching.length;
    if (end > matching.length) end = matching.length;
    return matching.sublist(start, end);
  }

  /// [Iterable] timed scan: wraps [_scan] so the per-stage accumulator [t]
  /// (when non-null) is threaded into [_scanWith]. When null, behaves exactly
  /// like [_scan] and pays no timing overhead.
  Stream<_Decoded> _scanTimed(_QueryTimings? t) async* {
    if (t == null) {
      yield* _scan();
      return;
    }
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot();
    try {
      yield* _scanWith(snap, secondary?.secondary, t);
    } finally {
      await snap.dispose();
    }
  }

  /// Applies limit/offset to an unordered (scan) result.
  Future<List<_Decoded>> _collect({_QueryTimings? t}) async {
    final all = await _collectOrdered(t: t);
    return all;
  }

  @override
  Future<List<T>> findAll() async {
    final armed = _engine.slowQueryThresholdMicros > 0;
    final stopwatch = armed ? (Stopwatch()..start()) : null;
    final t = armed ? _QueryTimings() : null;
    final items = await _collect(t: t);
    if (t != null) t.start(_QueryStage.model);
    final out = [for (final item in items) fromRow(item.row)];
    if (t != null) t.stop(_QueryStage.model);
    if (stopwatch != null) {
      _engine.reportSlowQuery(
        SlowQueryRecord(
          durationMicros: stopwatch.elapsedMicroseconds,
          table: _table,
          indexed: lastPlan == IndexPlan.secondaryIndex,
          filters: [for (final f in _filters) f.toString()],
          sort: [for (final s in _sort) s.toString()],
          timings: t?.toRecord(),
        ),
      );
    }
    return out;
  }

  /// Lazily streams matching rows without materializing the full result
  /// set. Unsorted queries stream directly from the backend; sorted queries
  /// must materialize order and are therefore equivalent to [findAll], which
  /// is documented.
  @override
  Stream<T> iterate() {
    // M3: route through `_scan()` (which delegates to `_scanWith`) so the
    // native fast path (indexed eq + predicate push) applies. Previously
    // this bypassed it via a per-id `snap.read` loop in `_streamUnsorted`,
    // which silently fell back to the Dart scan + `_group.test` on native
    // and missed the M2 predicate-push win (the relationship N+1 pattern).
    // `_scan` handles snapshot lifecycle + sort materialization uniformly.
    return _scan().map((d) => fromRow(d.row));
  }

  @override
  Future<T?> first() async {
    final limited = _copy().._limit = 1;
    final items = await limited._collect();
    return items.isEmpty ? null : fromRow(items.first.row);
  }

  @override
  Future<int> count() async {
    // M3: aggregate pushdown — on native, an unindexed query counts matching
    // rows IN RUST without transferring them (no decode + map-copy + Dart
    // increment loop). Indexed-eq queries keep the existing `queryIndexed`
    // path (the result set is already small and joined in one hop).
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot();
    try {
      if (_nativeEqProbe(secondary?.secondary) == null &&
          snap is NativeRawSnapshot) {
        final predicateBytes = encodePredicate(_filters, codec: _codec);
        lastPlan = IndexPlan.nativeFilteredScan;
        return snap.queryFilteredCount(
          table: _table,
          predicateBytes: predicateBytes,
        );
      }
      var n = 0;
      await for (final _ in _scanWith(snap, secondary?.secondary, null)) {
        n++;
      }
      return n;
    } finally {
      await snap.dispose();
    }
  }

  @override
  Future<List<Object?>> distinct(String field) async {
    // M3: aggregate pushdown — on native, an unindexed query emits only the
    // requested field's bytes per matching row (one value per row, not the
    // whole row). Dart decodes + dedups. Indexed-eq queries keep the
    // `queryIndexed` path (small result set, already joined).
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot();
    try {
      if (_nativeEqProbe(secondary?.secondary) == null &&
          snap is NativeRawSnapshot) {
        final predicateBytes = encodePredicate(_filters, codec: _codec);
        lastPlan = IndexPlan.nativeFilteredScan;
        final fieldBytes = await snap.queryFilteredDistinct(
          table: _table,
          predicateBytes: predicateBytes,
          field: field,
        );
        final seen = <Object?>{};
        for (final bytes in fieldBytes) {
          if (bytes.isEmpty) continue;
          seen.add(_codec.decode(bytes));
        }
        return seen.toList();
      }
      final seen = <Object?>{};
      await for (final item in _scanWith(snap, secondary?.secondary, null)) {
        if (item.row.containsKey(field)) {
          seen.add(item.row[field]);
        }
      }
      return seen.toList();
    } finally {
      await snap.dispose();
    }
  }

  /// Cursor-based pagination.
  ///
  /// [afterKey] (when provided) is the encoded key bytes returned by a previous
  /// page's `nextCursor`. The next cursor is likewise opaque key bytes; resume
  /// by passing it straight back. Pages are disjoint, order-preserving, and
  /// together exhaust the query.
  @override
  Future<(List<T>, Object? nextCursor)> findPage({
    Object? afterKey,
    int? pageSize,
  }) async {
    final limit = pageSize ?? _limit ?? 50;
    final rawCursor = afterKey == null ? null : ByteKey(afterKey as List<int>);
    final page = <_Decoded>[];
    var sawAfter = afterKey == null;
    await for (final item in _scan()) {
      if (!sawAfter) {
        if (rawCursor != null && item.key.compareTo(rawCursor) <= 0) continue;
        sawAfter = true;
      }
      page.add(item);
      if (page.length >= limit) break;
    }
    final nextCursor = page.isEmpty ? null : page.last.key.bytes;
    return ([for (final item in page) fromRow(item.row)], nextCursor);
  }

  /// Opens a snapshot-bound cursor (WS3). The cursor materializes the ordered
  /// matching set once from a frozen MVCC snapshot and pages through it, so
  /// concurrent writes cannot duplicate or drop records across pages.
  @override
  QueryCursor<T> cursor({int? pageSize}) {
    final secondary = _secondary;
    final snapFuture = () async {
      if (secondary != null) await secondary.ready;
      return _engine.backend.snapshot();
    }();
    return _QueryCursorImpl<T>(this, snapFuture, pageSize ?? _limit);
  }

  /// Reactive filtered query: re-emits the matching list whenever a change in
  /// this collection might affect membership.
  @override
  Stream<List<T>> watch() {
    late StreamController<List<T>> controller;
    late StreamSubscription<ChangeSet> sub;
    controller = StreamController<List<T>>(
      onListen: () async {
        // Emit current snapshot immediately.
        unawaited(findAll().then(controller.add));
        sub = _engine.changes.stream.listen((ChangeSet changeSet) {
          if (changeSet.changes.any((Change c) => c.table == _table)) {
            unawaited(_decodeSnapshot().then(controller.add));
          }
        });
      },
      onCancel: () => sub.cancel(),
    );
    return controller.stream;
  }

  Future<List<T>> _decodeSnapshot() async {
    return findAll();
  }

  /// Materializes the ordered matching set against [snap] (used by the
  /// snapshot-bound cursor).
  Future<List<_Decoded>> _materialize(RawSnapshot snap) async {
    final result = <_Decoded>[];
    await for (final item in _scanWith(snap, _secondary?.secondary, null)) {
      result.add(item);
    }
    return result;
  }
}

/// Snapshot-bound cursor implementation (WS3).
///
/// The ordered matching set is materialized once from the captured snapshot on
/// the first page, then paged by offset. This is O(result) memory but
/// guarantees the documented contract: pages are disjoint, order-preserving,
/// exhaustive, and stable under concurrent mutation because the snapshot is
/// frozen at cursor creation.
class _QueryCursorImpl<T> implements QueryCursor<T> {
  _QueryCursorImpl(this._query, this._snapFuture, this._pageSize);

  final QueryImpl<T> _query;
  final Future<RawSnapshot> _snapFuture;
  final int? _pageSize;
  RawSnapshot? _snap;
  List<_Decoded>? _rows;
  int _offset = 0;
  bool _disposed = false;

  @override
  Future<(List<T>, Object? nextCursor)> next({int? pageSize}) async {
    if (_disposed) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Cursor has been disposed',
      );
    }
    final snap = _snap ??= await _snapFuture;
    _rows ??= await _query._materialize(snap);
    final limit = pageSize ?? _pageSize ?? 50;
    if (_offset >= _rows!.length) return (<T>[], null);
    final end = (_offset + limit > _rows!.length)
        ? _rows!.length
        : _offset + limit;
    final page = _rows!.sublist(_offset, end);
    _offset = end;
    final lastKey = page.last.key.bytes;
    return ([for (final item in page) _query.fromRow(item.row)], lastKey);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final snap = _snap;
    _snap = null;
    if (snap != null) {
      await snap.dispose();
      return;
    }
    // The snapshot future created the worker snapshot at cursor creation even
    // if `next()` was never called; release it so a created-but-unused cursor
    // can never block compaction or leak an MVCC read transaction.
    try {
      final pending = await _snapFuture;
      await pending.dispose();
    } catch (_) {
      // The snapshot may already be gone (backend closed); release is
      // best-effort.
    }
  }
}

/// Per-stage query timers (Phase 1 instrumentation).
/// A single accumulator is only allocated when slow-query logging is armed
/// ([RawEngine.slowQueryThresholdMicros] > 0); queries that run with timing
/// disabled pass `null` and pay no overhead.
enum _QueryStage {
  plan,
  indexLookup,
  backendRead,
  decode,
  mapCopy,
  predicate,
  model,
  sort,
}

/// Accumulates per-stage microseconds + row counts for one query execution.
/// Stages are timed with a single reused [Stopwatch]; [start] / [stop]
/// bracket a stage, [stopAccum] stops a stage that was accumulating across
/// interleaved yields (e.g. the predicate loop yields matches).
class _QueryTimings {
  final Stopwatch _watch = Stopwatch();
  final Map<_QueryStage, int> _micros = {
    for (final s in _QueryStage.values) s: 0,
  };
  int scanned = 0;
  int matched = 0;

  void start(_QueryStage stage) {
    _watch.reset();
    _watch.start();
  }

  void stop(_QueryStage stage) {
    _watch.stop();
    _micros[stage] = (_micros[stage] ?? 0) + _watch.elapsedMicroseconds;
  }

  /// Stops a stage whose [start] ran across a yield/await boundary; the
  /// elapsed time is the accumulated total since the last [start].
  void stopAccum(_QueryStage stage) => stop(stage);

  QueryStageTimings toRecord() => QueryStageTimings(
    plan: _micros[_QueryStage.plan]!,
    indexLookup: _micros[_QueryStage.indexLookup]!,
    backendRead: _micros[_QueryStage.backendRead]!,
    decode: _micros[_QueryStage.decode]!,
    mapCopy: _micros[_QueryStage.mapCopy]!,
    predicate: _micros[_QueryStage.predicate]!,
    model: _micros[_QueryStage.model]!,
    sort: _micros[_QueryStage.sort]!,
    rowsScanned: scanned,
    rowsMatched: matched,
  );
}
