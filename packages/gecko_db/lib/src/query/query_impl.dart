/// query engine over the byte-level engine.
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
import 'sort_spec_codec.dart';

/// A decoded row plus its raw key, carried during query evaluation.
class _Decoded {
  _Decoded(this.key, this.row);
  final ByteKey key;
  final Map<Object?, Object?> row;
}

/// Metadata for the declared durable indexes of a collection.
///
/// The declared fields are registered with the native worker so Rust owns
/// durable index maintenance. [ready] resolves once the one-time per-session
/// Rust repair has run (so rows written before the index was declared are
/// covered); queries await it before routing through the durable index.
class CollectionIndex {
  CollectionIndex({
    required List<String> fields,
    Iterable<String>? prefixFields,
  }) : fields = List<String>.unmodifiable(fields),
       prefixFields = List<String>.unmodifiable(prefixFields ?? const []);

  final List<String> fields;
  final List<String> prefixFields;
  final Completer<void> _ready = Completer<void>();

  /// Completes once the durable index has been repaired ( Rust is the
  /// sole authority; there is no Dart index to build).
  Future<void> get ready => _ready.future;

  /// Whether the one-time repair for this session has completed.
  bool get isReady => _ready.isCompleted;

  /// Marks the index prepared for queries. Idempotent.
  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
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
  final T Function(Object? row) fromRow;
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

  /// Lazy iteration over matching decoded rows in sort order. Native queries
  /// use durable Rust indexes directly.
  Stream<_Decoded> _scan({int? nativeLimit, int nativeOffset = 0}) async* {
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    // the engine is always native, so the snapshot is a
    // NativeRawSnapshot (the RawEngine exposes the RawSnapshot interface).
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      yield* _scanWith(
        snap,
        secondary,
        null,
        nativeLimit: nativeLimit,
        nativeOffset: nativeOffset,
      );
    } finally {
      await snap.dispose();
    }
  }

  /// When [idx] is non-null and the query has exactly one equality filter
  /// covered by the durable declaration, returns `(field, value)` for the
  /// exact Rust index range scan.
  (String, Object?)? _nativeEqProbe(CollectionIndex? idx) {
    if (idx == null) return null;
    final eqs = <String, Object?>{
      for (final f in _filters)
        if (f.isIndexUsable) f.field: f.value,
    };
    if (eqs.length != 1 || !eqs.keys.every(idx.fields.contains)) return null;
    // Range/prefix filters mixed with the eq would also need primitive
    // intersection in Rust; the multi-index route handles those queries.
    final hasRangeOrPrefix = _filters.any(
      (f) => f.isRangeFilter || f.isPrefixFilter,
    );
    if (hasRangeOrPrefix) return null;
    final entry = eqs.entries.single;
    return (entry.key, entry.value);
  }

  /// Returns broad durable-index bounds for every filter that can narrow a
  /// native candidate set. Equality uses an exact value bound; range and
  /// prefix use the whole `(table, field)` span because DefaultWireCodec v1
  /// is not semantic-order-preserving for all supported values. Rust always
  /// rechecks the complete predicate, so broad bounds remain correct.
  List<(List<int>, List<int>)>? _nativeIndexedRanges(CollectionIndex? idx) {
    if (idx == null) return null;
    final ranges = <(List<int>, List<int>)>[];
    for (final f in _filters) {
      if (f.isIndexUsable && idx.fields.contains(f.field)) {
        ranges.add(eqBounds(_table, f.field, f.value, codec: _codec));
      } else if (f.isRangeFilter &&
          (idx.fields.contains(f.field) ||
              idx.prefixFields.contains(f.field))) {
        ranges.add(fieldBounds(_table, f.field, codec: _codec));
      } else if (f.isPrefixFilter && idx.prefixFields.contains(f.field)) {
        ranges.add(fieldBounds(_table, f.field, codec: _codec));
      }
    }
    return ranges.isEmpty ? null : ranges;
  }

  Stream<_Decoded> _scanWith(
    NativeRawSnapshot snap,
    CollectionIndex? idx,
    _QueryTimings? t, {
    int? nativeLimit,
    int nativeOffset = 0,
  }) async* {
    if (t != null) t.start(_QueryStage.plan);
    if (t != null && idx != null) t.start(_QueryStage.indexLookup);
    // Native routing uses collection metadata to produce durable Rust
    // bounds; the transitional Dart index remains authoritative only for
    // the in-memory reference backend.
    final nativeRanges = _nativeIndexedRanges(idx);
    if (t != null) {
      if (idx != null) t.stop(_QueryStage.indexLookup);
      t.stop(_QueryStage.plan);
    }
    if (nativeRanges != null) {
      lastPlan = IndexPlan.secondaryIndex;
      // native fast path: when the snapshot is a NativeRawSnapshot
      // (redb file backend) and the query is a single equality filter
      // covered by the index, traverse the durable `__gecko_index` table in
      // one FRB hop and join back to the rows — eliminating the Dart-side
      // N+1 point reads (88% of indexed eq per the profile).
      // handles multi-eq/range/prefix below through Rust candidate
      // intersection and complete predicate recheck.
      final nativeEq = _nativeEqProbe(idx);
      if (nativeEq != null) {
        final (field, value) = nativeEq;
        final (start, end) = eqBounds(_table, field, value, codec: _codec);
        if (t != null) t.start(_QueryStage.backendRead);
        // the index scan always applies the complete predicate in Rust
        // (and stops early when a window is requested), so Dart never
        // re-tests rows or orders them.
        final entries = await snap.queryIndexedLimited(
          table: _table,
          start: ByteKey(start),
          end: ByteKey(end),
          predicateBytes: encodePredicate(_filters, codec: _codec),
          limit: nativeLimit,
          offset: nativeOffset,
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
        if (t != null) t.start(_QueryStage.predicate);
        for (final item in decoded) {
          if (t != null) t.matched++;
          yield item;
        }
        if (t != null) t.stopAccum(_QueryStage.predicate);
        return;
      }

      // range, prefix, and multi-equality filters use durable-index
      // candidate intersection in Rust. The broad field ranges are followed
      // by a complete Rust predicate recheck, preserving semantic range and
      // prefix behavior despite the v1 codec's non-sortable value bytes.
      if (t != null) t.start(_QueryStage.backendRead);
      final entries = await snap.queryIndexedMulti(
        table: _table,
        ranges: [
          for (final range in nativeRanges)
            (ByteKey(range.$1), ByteKey(range.$2)),
        ],
        predicateBytes: encodePredicate(_filters, codec: _codec),
      );
      if (t != null) t.stop(_QueryStage.backendRead);
      final decoded = <_Decoded>[];
      for (final entry in entries) {
        if (t != null) {
          t.scanned++;
          t.start(_QueryStage.decode);
        }
        final row = _mapOf(_codec.decode(entry.value ?? const []));
        if (t != null) {
          t.stop(_QueryStage.decode);
          t.start(_QueryStage.mapCopy);
        }
        if (t != null) t.stop(_QueryStage.mapCopy);
        decoded.add(_Decoded(entry.key, row));
      }
      if (t != null) t.start(_QueryStage.predicate);
      for (final item in decoded) {
        if (t != null) t.matched++;
        yield item;
      }
      if (t != null) t.stopAccum(_QueryStage.predicate);
      return;
    }
    lastPlan = IndexPlan.nativeFilteredScan;
    // step 2: push the predicate to Rust. The scan evaluates the
    // predicate against each row's bytes IN RUST (decoding only the referenced
    // fields) and returns only matches in one boundary crossing — non-matching
    // rows are never decoded in Dart (the profile showed `scanAll`
    // transferring the whole table dominated 70% of a 100k-row full scan).
    // An empty predicate matches everything (matches Dart's FilterGroup).
    final predicateBytes = encodePredicate(_filters, codec: _codec);
    if (t != null) t.start(_QueryStage.backendRead);
    // when the caller wants a window, the scan stops in Rust as soon as
    // the window fills (matching rows beyond it are never transferred).
    final windowed = nativeLimit != null || nativeOffset > 0;
    final entries = windowed
        ? await snap.queryFilteredLimited(
            table: _table,
            predicateBytes: predicateBytes,
            limit: nativeLimit,
            offset: nativeOffset,
          )
        : await snap.queryFiltered(
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
    // The predicate was already evaluated in Rust; the timing predicate stage
    // below only counts matched rows for the breakdown.
    if (t != null) t.start(_QueryStage.predicate);
    for (final item in decoded) {
      if (t != null) t.matched++;
      // Rust already filtered; no Dart re-test needed for correctness.
      yield item;
    }
    if (t != null) t.stopAccum(_QueryStage.predicate);
    return;
  }

  Map<Object?, Object?> _mapOf(Object? value) =>
      value is Map ? Map<Object?, Object?>.from(value) : <Object?, Object?>{};

  /// Applies limit/offset after an already-ordered stream.
  Future<List<_Decoded>> _collectOrdered({_QueryTimings? t}) async {
    // EVERY sorted query routes through Rust — the worker applies the
    // predicate + sort + window (top-K or index-ordered). Dart never orders
    // rows; it only materializes the returned entries.
    if (_sort.isNotEmpty) {
      return _nativeOrderedCollect(t);
    }
    final matching = <_Decoded>[];
    // Pass the window (offset + limit) to the native early-stop so only the
    // rows that can appear in the result cross the boundary; the Dart slice
    // below applies the offset uniformly (in-memory ignores the window).
    final start = _offset ?? 0;
    final windowEnd = _limit == null ? null : start + _limit!;
    await for (final item in _scanTimed(
      t,
      nativeLimit: windowEnd,
      nativeOffset: 0,
    )) {
      matching.add(item);
    }
    var sliceStart = start;
    var end = matching.length;
    if (_limit != null) end = sliceStart + _limit!;
    if (sliceStart > matching.length) sliceStart = matching.length;
    if (end > matching.length) end = matching.length;
    return matching.sublist(sliceStart, end);
  }

  /// /routes a sorted query through the Rust top-K or index-ordered
  /// path, returning the fully-ordered result (predicate + sort + window all
  /// applied in Rust). [snapshot] may be supplied by a caller that already
  /// holds one (e.g. the snapshot-bound cursor); otherwise one is opened and
  /// disposed here.
  Future<List<_Decoded>> _nativeOrderedCollect(
    _QueryTimings? t, {
    NativeRawSnapshot? snapshot,
  }) async {
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final ownsSnapshot = snapshot == null;
    final snap =
        snapshot ?? (await _engine.backend.snapshot() as NativeRawSnapshot);
    try {
      final idx = secondary;
      final predicateBytes = encodePredicate(_filters, codec: _codec);
      final sortBytes = encodeSortSpecs(_sort);
      final limit = _limit;
      final offset = _offset ?? 0;
      final route = _indexCoveredSortRoute(idx);
      final List<RawEntry> entries;
      if (route != null) {
        // Index-covered: stream the durable index in order and stop early.
        lastPlan = IndexPlan.secondaryIndex;
        final (field, (start, end), eqBounded) = route;
        if (t != null) t.start(_QueryStage.backendRead);
        entries = await snap.queryIndexedOrdered(
          table: _table,
          start: ByteKey(start),
          end: ByteKey(end),
          predicateBytes: predicateBytes,
          sortField: field,
          eqBounded: eqBounded,
          limit: limit,
          offset: offset,
        );
        if (t != null) t.stop(_QueryStage.backendRead);
      } else {
        // Non-index-covered sort: Rust top-K (never materializes the full set).
        lastPlan = IndexPlan.nativeFilteredScan;
        if (t != null) t.start(_QueryStage.backendRead);
        entries = await snap.querySorted(
          table: _table,
          predicateBytes: predicateBytes,
          sortSpecBytes: sortBytes,
          limit: limit,
          offset: offset,
        );
        if (t != null) t.stop(_QueryStage.backendRead);
      }
      final decoded = <_Decoded>[];
      for (final entry in entries) {
        if (t != null) {
          t.scanned++;
          t.start(_QueryStage.decode);
        }
        final row = _mapOf(_codec.decode(entry.value ?? const []));
        if (t != null) {
          t.stop(_QueryStage.decode);
          t.start(_QueryStage.mapCopy);
        }
        if (t != null) t.stop(_QueryStage.mapCopy);
        decoded.add(_Decoded(entry.key, row));
      }
      // Rust already filtered + sorted; only the timing predicate stage runs.
      if (t != null) t.start(_QueryStage.predicate);
      for (final _ in decoded) {
        if (t != null) t.matched++;
      }
      if (t != null) t.stopAccum(_QueryStage.predicate);
      return decoded;
    } finally {
      if (ownsSnapshot) {
        await snap.dispose();
      }
    }
  }

  /// returns `(sortField, (start, end), eqBounded)` when the query's
  /// single sort spec is covered by a single-field durable index, so index-key
  /// order matches the sort and Rust can stream the index with an early stop.
  /// Returns null for multi-spec, non-indexed, or descending-without-eq sorts
  /// (those use the Rust top-K path, which handles missing-field placement).
  (String, (List<int>, List<int>), bool)? _indexCoveredSortRoute(
    CollectionIndex? idx,
  ) {
    if (idx == null || _sort.length != 1) return null;
    final spec = _sort.single;
    if (!idx.fields.contains(spec.field)) return null;
    final eqOnField = _filters.any(
      (f) => f.isIndexUsable && f.field == spec.field,
    );
    if (eqOnField) {
      // Every matching row has the same value, so index-key (recordId) order
      // is exactly the stable Dart order for either direction.
      final value = _filters
          .firstWhere((f) => f.isIndexUsable && f.field == spec.field)
          .value;
      final (start, end) = eqBounds(_table, spec.field, value, codec: _codec);
      return (spec.field, (start, end), true);
    }
    // Descending without an eq on the field sorts missing rows FIRST; that
    // needs the top-K path (which handles missing-first correctly).
    if (spec.order == SortOrder.descending) return null;
    final (start, end) = fieldBounds(_table, spec.field, codec: _codec);
    return (spec.field, (start, end), false);
  }

  /// [Iterable] timed scan: wraps [_scan] so the per-stage accumulator [t]
  /// (when non-null) is threaded into [_scanWith]. When null, behaves exactly
  /// like [_scan] and pays no timing overhead. [nativeLimit]/[nativeOffset]
  /// forward the query window to the native early-stop (ignored in-memory).
  Stream<_Decoded> _scanTimed(
    _QueryTimings? t, {
    int? nativeLimit,
    int nativeOffset = 0,
  }) async* {
    if (t == null) {
      yield* _scan(nativeLimit: nativeLimit, nativeOffset: nativeOffset);
      return;
    }
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      yield* _scanWith(
        snap,
        secondary,
        t,
        nativeLimit: nativeLimit,
        nativeOffset: nativeOffset,
      );
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
  /// must materialize order ( the sort executes in Rust) and are therefore
  /// equivalent to [findAll], which is documented.
  @override
  Stream<T> iterate() {
    if (_sort.isNotEmpty) {
      return () async* {
        final items = await _nativeOrderedCollect(null);
        for (final d in items) {
          yield fromRow(d.row);
        }
      }();
    }
    // route through `_scan()` (which delegates to `_scanWith`) so the
    // native fast path (indexed eq + predicate push) applies.
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
    // aggregate pushdown — an unindexed query counts matching rows IN
    // RUST without transferring them (no decode + map-copy + Dart increment
    // loop). Indexed-eq queries keep the existing `queryIndexed` path (the
    // result set is already small and joined in one hop).
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      final nativeRanges = _nativeIndexedRanges(secondary);
      final predicateBytes = encodePredicate(_filters, codec: _codec);
      if (nativeRanges != null) {
        lastPlan = IndexPlan.secondaryIndex;
        return snap.queryIndexedCount(
          table: _table,
          ranges: [
            for (final range in nativeRanges)
              (ByteKey(range.$1), ByteKey(range.$2)),
          ],
          predicateBytes: predicateBytes,
        );
      }
      lastPlan = IndexPlan.nativeFilteredScan;
      return snap.queryFilteredCount(
        table: _table,
        predicateBytes: predicateBytes,
      );
    } finally {
      await snap.dispose();
    }
  }

  @override
  Future<List<Object?>> distinct(String field) async {
    // aggregate pushdown — an unindexed query emits only the requested
    // field's bytes per matching row (one value per row, not the whole row).
    // Dart decodes + dedups. Indexed-eq queries keep the `queryIndexed` path
    // (small result set, already joined).
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      final nativeRanges = _nativeIndexedRanges(secondary);
      final predicateBytes = encodePredicate(_filters, codec: _codec);
      final fieldBytes = nativeRanges == null
          ? await snap.queryFilteredDistinct(
              table: _table,
              predicateBytes: predicateBytes,
              field: field,
            )
          : await snap.queryIndexedDistinct(
              table: _table,
              ranges: [
                for (final range in nativeRanges)
                  (ByteKey(range.$1), ByteKey(range.$2)),
              ],
              predicateBytes: predicateBytes,
              field: field,
            );
      lastPlan = nativeRanges == null
          ? IndexPlan.nativeFilteredScan
          : IndexPlan.secondaryIndex;
      final seen = <Object?>{};
      for (final bytes in fieldBytes) {
        if (bytes.isEmpty) continue;
        seen.add(_codec.decode(bytes));
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
    // Sorted queries materialize their ordered set in Rust and page over
    // it; unsorted queries stream directly from the backend.
    if (_sort.isNotEmpty) {
      final ordered = await _nativeOrderedCollect(null);
      for (final item in ordered) {
        if (!sawAfter) {
          if (rawCursor != null && item.key.compareTo(rawCursor) <= 0) {
            continue;
          }
          sawAfter = true;
        }
        page.add(item);
        if (page.length >= limit) break;
      }
      final nextCursor = page.isEmpty ? null : page.last.key.bytes;
      return ([for (final item in page) fromRow(item.row)], nextCursor);
    }
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

  /// Opens a snapshot-bound cursor The cursor materializes the ordered
  /// matching set once from a frozen MVCC snapshot and pages through it, so
  /// concurrent writes cannot duplicate or drop records across pages.
  @override
  QueryCursor<T> cursor({int? pageSize}) {
    final snapFuture = () async {
      final secondary = _secondary;
      if (secondary != null) await secondary.ready;
      return _engine.backend.snapshot();
    }();
    return _QueryCursorImpl<T>(this, snapFuture, pageSize ?? _limit);
  }

  /// Reactive filtered query: re-emits the matching list whenever a change in
  /// this collection might affect membership.
  ///
  /// unbounded queries register with the worker's reactive
  /// registry — Rust maintains the matching result set (predicate + sort), and
  /// Dart forwards worker deltas. Windowed queries (limit/offset) keep full
  /// re-evaluation because a window can reorder under a write.
  @override
  Stream<List<T>> watch() {
    late StreamController<List<T>> controller;
    late StreamSubscription<Object?> sub;
    var registrationId = -1;
    final incremental = _limit == null && (_offset ?? 0) == 0;
    controller = StreamController<List<T>>(
      onListen: () {
        if (!incremental) {
          // Emit current snapshot immediately (full re-evaluation per change).
          unawaited(findAll().then(controller.add));
          sub = _engine.changes.stream.listen((ChangeSet changeSet) {
            if (changeSet.changes.any((Change c) => c.table == _table)) {
              unawaited(_decodeSnapshot().then(controller.add));
            }
          });
          return;
        }
        // Subscribe to deltas BEFORE registering so no delta produced after
        // registration completes can be missed (registration is async).
        sub = _engine.liveDeltas.listen((delta) {
          if (delta.id != registrationId) return;
          controller.add([
            for (final entry in delta.snapshot)
              fromRow(_codec.decode(entry.value ?? const [])),
          ]);
        });
        unawaited(() async {
          final registration = await _engine.registerLiveQuery(
            table: _table,
            predicateBytes: encodePredicate(_filters, codec: _codec),
            sortBytes: encodeSortSpecs(_sort),
            kind: LiveQueryKind.query.value,
          );
          if (controller.isClosed) {
            // Best-effort cleanup: the engine may already be closed (a
            // cancel/close race), in which case the worker died with the
            // registration and there is nothing to release.
            try {
              await _engine.unregisterLiveQuery(registration.id);
            } catch (_) {}
            return;
          }
          registrationId = registration.id;
          controller.add([
            for (final entry in registration.initial)
              fromRow(_codec.decode(entry.value ?? const [])),
          ]);
        }());
      },
      onCancel: () async {
        await sub.cancel();
        if (registrationId >= 0) {
          try {
            await _engine.unregisterLiveQuery(registrationId);
          } catch (_) {
            // Best-effort: the engine may already be closed.
          }
        }
      },
    );
    return controller.stream;
  }

  Future<List<T>> _decodeSnapshot() async {
    return findAll();
  }

  /// Materializes the ordered matching set against [snap] (used by the
  /// snapshot-bound cursor). Sorted materialization executes in Rust 
  Future<List<_Decoded>> _materialize(NativeRawSnapshot snap) async {
    if (_sort.isNotEmpty) {
      return _nativeOrderedCollect(null, snapshot: snap);
    }
    final result = <_Decoded>[];
    await for (final item in _scanWith(snap, _secondary, null)) {
      result.add(item);
    }
    return result;
  }
}

/// Snapshot-bound cursor implementation 
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
    _rows ??= await _query._materialize(snap as NativeRawSnapshot);
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

/// Per-stage query timers (instrumentation).
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
