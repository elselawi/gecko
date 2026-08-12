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
import '../backend/native_raw_backend.dart'
    show NativeRawBackend, NativeRawSnapshot;
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

/// Lifecycle of a declared durable index within one session.
enum CollectionIndexState { idle, preparing, ready, failed }

/// Metadata for the declared durable indexes of a collection.
///
/// The declared fields are registered with the native worker so Rust owns
/// durable index maintenance. Preparation runs one coalesced Rust repair per
/// declaration fingerprint: concurrent `collection()` calls for the same
/// table share one in-flight repair instead of queueing several full repairs.
/// Queries await [ready] (which settles on success AND failure) and then
/// consult [state]: only `ready` indexes may route through the durable index;
/// a `failed` or `preparing` index falls back to the pushed-predicate
/// full-scan path, never a potentially incomplete durable index.
class CollectionIndex {
  CollectionIndex({
    required List<String> fields,
    Iterable<String>? prefixFields,
  }) : fields = List<String>.unmodifiable(fields),
       prefixFields = List<String>.unmodifiable(prefixFields ?? const []);

  List<String> fields;
  List<String> prefixFields;

  CollectionIndexState _state = CollectionIndexState.idle;
  Future<void>? _inflight;
  String? _fingerprint;
  Object? _lastError;

  CollectionIndexState get state => _state;
  bool get isReady => _state == CollectionIndexState.ready;
  bool get isFailed => _state == CollectionIndexState.failed;

  /// The last preparation error, when [isFailed]. Used by tests to prove a
  /// failed repair leaves the index unusable (never silently ready).
  Object? get lastError => _lastError;

  /// Resolves when the current preparation settles. Queries await this before
  /// deciding whether to use the durable index; the decision is made from
  /// [state], never from whether this future threw (it never throws).
  Future<void> get ready => _inflight ?? Future<void>.value();

  /// Replaces the declared fields (single + prefix) when a later declaration
  /// for the same table changes the plan. Incompatible declarations are never
  /// silently treated as equivalent; the next [prepare] rebuilds with the new
  /// definition.
  void replaceFields(List<String> newFields, List<String> newPrefixFields) {
    fields = List<String>.unmodifiable(newFields);
    prefixFields = List<String>.unmodifiable(newPrefixFields);
  }

  /// Starts (or joins) the coalesced preparation for [fingerprint].
  ///
  /// The first declaration starts the repair and stores the in-flight future;
  /// concurrent declarations with the same fingerprint await the same future
  /// (one repair, never N). A declaration with a different fingerprint
  /// replaces the plan: a new preparation begins with the new definition.
  /// A failed preparation completes waiters but leaves [state] as
  /// [CollectionIndexState.failed] so queries fall back to the full-scan path
  /// and a later declaration may retry.
  Future<void> prepare({
    required String fingerprint,
    required Future<void> Function() work,
  }) {
    final existing = _inflight;
    if (_state == CollectionIndexState.preparing && _fingerprint == fingerprint) {
      return existing!;
    }
    if (_state == CollectionIndexState.ready && _fingerprint == fingerprint) {
      return existing!;
    }
    // idle, failed, or a different fingerprint: start a new preparation.
    _state = CollectionIndexState.preparing;
    _fingerprint = fingerprint;
    _lastError = null;
    final completer = Completer<void>();
    _inflight = completer.future;
    Future<void>.sync(work)
        .then((_) {
          _state = CollectionIndexState.ready;
        })
        .catchError((Object error) {
          _state = CollectionIndexState.failed;
          _lastError = error;
        })
        .whenComplete(() {
          if (!completer.isCompleted) completer.complete();
        });
    return completer.future;
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
    List<List<String>>? compositeIndexes,
  }) : _filters = <Filter>[
         for (final entry in (initialEq ?? const {}).entries)
           Filter.eq(entry.key.toString(), entry.value),
       ],
       _secondary = secondary,
       _compositeIndexes =
           compositeIndexes == null
               ? const <List<String>>[]
               : List<List<String>>.unmodifiable(compositeIndexes);

  final RawEngine _engine;
  final String _table;
  final Object? Function(T) toRow;
  final T Function(Object? row) fromRow;
  final CollectionIndex? _secondary;
  final List<List<String>> _compositeIndexes;

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
          compositeIndexes: _compositeIndexes,
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
    final backend = _engine.backend;
    if (backend is NativeRawBackend) {
      yield* _scanDirect(
        backend,
        secondary,
        nativeLimit: nativeLimit,
        nativeOffset: nativeOffset,
      );
      return;
    }
    final snap = await backend.snapshot() as NativeRawSnapshot;
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

  Stream<_Decoded> _scanDirect(
    NativeRawBackend backend,
    CollectionIndex? idx, {
    int? nativeLimit,
    int nativeOffset = 0,
  }) async* {
    final nativeRanges = _nativeIndexedRanges(idx);
    final compositeRoute = _compositeRoute();
    final predicateBytes = encodePredicate(_filters, codec: _codec);
    final List<RawEntry> entries;
    final nativeEq = nativeRanges != null ? _nativeEqProbe(idx) : null;
    if (nativeEq != null) {
      lastPlan = IndexPlan.secondaryIndex;
      final (field, value) = nativeEq;
      final (start, end) = eqBounds(_table, field, value, codec: _codec);
      entries = await backend.queryIndexedLimited(
        table: _table,
        start: ByteKey(start),
        end: ByteKey(end),
        predicateBytes: predicateBytes,
        covered: _indexCoversFilters(idx),
        limit: nativeLimit,
        offset: nativeOffset,
      );
    } else if (compositeRoute != null) {
      // A declared composite index serves the compound predicate as one
      // ordered scan (eq prefix + optional trailing range).
      lastPlan = IndexPlan.secondaryIndex;
      final (_, (start, end), covered) = compositeRoute;
      entries = await backend.queryIndexedLimited(
        table: _table,
        start: ByteKey(start),
        end: ByteKey(end),
        predicateBytes: predicateBytes,
        covered: covered,
        limit: nativeLimit,
        offset: nativeOffset,
      );
    } else if (nativeRanges != null && nativeRanges.length == 1) {
      // A single range/prefix: stream the exact bounds with an early window
      // (Priority 5 limit/offset pushdown) instead of materializing the whole
      // candidate span and windowing it afterwards.
      lastPlan = IndexPlan.secondaryIndex;
      final (start, end) = nativeRanges.single;
      entries = await backend.queryIndexedLimited(
        table: _table,
        start: ByteKey(start),
        end: ByteKey(end),
        predicateBytes: predicateBytes,
        covered: _indexCoversFilters(idx),
        limit: nativeLimit,
        offset: nativeOffset,
      );
    } else if (nativeRanges != null) {
      lastPlan = IndexPlan.secondaryIndex;
      entries = await backend.queryIndexedMulti(
        table: _table,
        ranges: [
          for (final range in nativeRanges)
            (ByteKey(range.$1), ByteKey(range.$2)),
        ],
        predicateBytes: predicateBytes,
        covered: _indexCoversFilters(idx),
        limit: nativeLimit,
        offset: nativeOffset,
      );
    } else {
      lastPlan = IndexPlan.nativeFilteredScan;
      final windowed = nativeLimit != null || nativeOffset > 0;
      entries = windowed
          ? await backend.queryFilteredLimited(
              table: _table,
              predicateBytes: predicateBytes,
              limit: nativeLimit,
              offset: nativeOffset,
            )
          : await backend.queryFiltered(
              table: _table,
              predicateBytes: predicateBytes,
            );
    }
    for (final entry in entries) {
      yield _Decoded(entry.key, _mapOf(_codec.decode(entry.value ?? const [])));
    }
  }

  /// When [idx] is non-null and the query has exactly one equality filter
  /// covered by the durable declaration, returns `(field, value)` for the
  /// exact Rust index range scan.
  (String, Object?)? _nativeEqProbe(CollectionIndex? idx) {
    // Only a `ready` index may route through the durable index: a failed or
    // still-preparing index must fall back to the pushed-predicate full scan
    // rather than using a potentially incomplete durable index.
    if (idx == null || !idx.isReady) return null;
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

  /// Returns exact durable-index bounds for every filter that can narrow a
  /// native candidate set. Equality uses an exact value bound; range and
  /// prefix use the order-preserving element bounds from
  /// `durable_index_bounds.dart` (Priority 5), so a range/prefix scan visits
  /// only rows that can match. Rust always rechecks the complete predicate,
  /// so even these tight bounds remain correct.
  List<(List<int>, List<int>)>? _nativeIndexedRanges(CollectionIndex? idx) {
    if (idx == null || !idx.isReady) return null;
    final ranges = <(List<int>, List<int>)>[];
    for (final f in _filters) {
      if (f.isIndexUsable && idx.fields.contains(f.field)) {
        ranges.add(eqBounds(_table, f.field, f.value, codec: _codec));
      } else if (f.isRangeFilter &&
          (idx.fields.contains(f.field) ||
              idx.prefixFields.contains(f.field))) {
        ranges.add(rangeBounds(_table, f.field, f.min, f.max, codec: _codec));
      } else if (f.isPrefixFilter && idx.prefixFields.contains(f.field)) {
        ranges.add(prefixBounds(_table, f.field, f.prefix!, codec: _codec));
      }
    }
    return ranges.isEmpty ? null : ranges;
  }

  /// True when the durable single-field index [idx] covers every filter:
  /// each filter's field is in the index's declared fields (for a
  /// single-field index, all on that one field), so the exact eq/range/prefix
  /// bounds prove the whole predicate and Rust may skip the per-row recheck
  /// (Priority 5). Mirrors `Predicate::covers` in Rust.
  bool _indexCoversFilters(CollectionIndex? idx) {
    if (idx == null || !idx.isReady || _filters.isEmpty) return false;
    return _filters.every((f) => idx.fields.contains(f.field));
  }

  /// Picks a declared composite index that can serve this query's compound
  /// predicate as ONE ordered scan (Priority 5): the composite fields'
  /// leading prefix must be equality-bounded, optionally followed by a single
  /// range/prefix on the trailing field. Returns `(fields, (start, end),
  /// covered)`; [covered] is true only when the composite bounds prove every
  /// filter (all filters are eq on the bounded prefix, plus at most the
  /// trailing range/prefix). Otherwise Rust rechecks the complete predicate.
  (List<String>, (List<int>, List<int>), bool)? _compositeRoute() {
    if (_compositeIndexes.isEmpty || _filters.isEmpty) return null;
    // Composite durable entries are built by the same one-time repair as the
    // single-field entries: a failed/preparing index must not serve a
    // composite route with a possibly incomplete durable index.
    final secondary = _secondary;
    if (secondary == null || !secondary.isReady) return null;
    final eqs = <String, Object?>{
      for (final f in _filters)
        if (f.isIndexUsable) f.field: f.value,
    };
    for (final fields in _compositeIndexes) {
      if (fields.isEmpty) continue;
      var k = 0;
      while (k < fields.length && eqs.containsKey(fields[k])) {
        k++;
      }
      if (k == 0) continue; // the first field must be eq-bounded to narrow
      // A single range/prefix filter on the next field becomes the trailing
      // bound; anything else (or a filter on a deeper field) falls back to
      // eq-prefix-only bounds with Rust recheck.
      Filter? trailing;
      if (k < fields.length) {
        final candidates = <Filter>[
          for (final f in _filters)
            if ((f.isRangeFilter || f.isPrefixFilter) && f.field == fields[k])
              f,
        ];
        if (candidates.length == 1) trailing = candidates.single;
      }
      // covered: every filter is proven by the composite bounds (eq on the
      // bounded prefix, plus at most the single trailing range/prefix).
      final proven = <String>{for (var i = 0; i < k; i++) fields[i]};
      if (trailing != null) proven.add(trailing.field);
      final covered = _filters.every((f) {
        if (f.isIndexUsable) return proven.contains(f.field);
        return (f.isRangeFilter || f.isPrefixFilter) && identical(f, trailing);
      });
      final eqFields = fields.sublist(0, k);
      final eqValues = [for (final field in eqFields) eqs[field]];
      final (start, end) = trailing == null
          ? compositeEqBounds(
              _table, fields, eqFields, eqValues, codec: _codec,
            )
          : trailing.isRangeFilter
          ? compositeRangeBounds(
              _table,
              fields,
              eqFields,
              eqValues,
              min: trailing.min,
              max: trailing.max,
              codec: _codec,
            )
          : compositePrefixBounds(
              _table,
              fields,
              eqFields,
              eqValues,
              trailing.field,
              trailing.prefix!,
              codec: _codec,
            );
      return (fields, (start, end), covered);
    }
    return null;
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
    final compositeRoute = _compositeRoute();
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
          covered: _indexCoversFilters(idx),
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
    }
    if (compositeRoute != null) {
      // A declared composite index serves the compound predicate as one
      // ordered scan (eq prefix + optional trailing range); the complete
      // predicate is rechecked in Rust unless the bounds prove every filter.
      lastPlan = IndexPlan.secondaryIndex;
      final (_, (start, end), covered) = compositeRoute;
      if (t != null) t.start(_QueryStage.backendRead);
      final entries = await snap.queryIndexedLimited(
        table: _table,
        start: ByteKey(start),
        end: ByteKey(end),
        predicateBytes: encodePredicate(_filters, codec: _codec),
        covered: covered,
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
    if (nativeRanges != null && nativeRanges.length == 1) {
      // A single range/prefix: stream the exact bounds with an early window
      // (Priority 5 limit/offset pushdown) instead of materializing the whole
      // candidate span and windowing it afterwards.
      lastPlan = IndexPlan.secondaryIndex;
      final (start, end) = nativeRanges.single;
      if (t != null) t.start(_QueryStage.backendRead);
      final entries = await snap.queryIndexedLimited(
        table: _table,
        start: ByteKey(start),
        end: ByteKey(end),
        predicateBytes: encodePredicate(_filters, codec: _codec),
        covered: _indexCoversFilters(idx),
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
    if (nativeRanges != null) {
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
        covered: _indexCoversFilters(idx),
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
    final backend = _engine.backend;
    final ownsSnapshot = snapshot == null;
    final directBackend = snapshot == null && backend is NativeRawBackend
        ? backend
        : null;
    final snap =
        snapshot ??
        (directBackend == null
            ? await backend.snapshot() as NativeRawSnapshot
            : null);
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
        final (field, (start, end), eqBounded, descending, covered) = route;
        if (t != null) t.start(_QueryStage.backendRead);
        entries = directBackend != null
            ? await directBackend.queryIndexedOrdered(
                table: _table,
                start: ByteKey(start),
                end: ByteKey(end),
                predicateBytes: predicateBytes,
                sortField: field,
                eqBounded: eqBounded,
                descending: descending,
                covered: covered,
                limit: limit,
                offset: offset,
              )
            : await snap!.queryIndexedOrdered(
                table: _table,
                start: ByteKey(start),
                end: ByteKey(end),
                predicateBytes: predicateBytes,
                sortField: field,
                eqBounded: eqBounded,
                descending: descending,
                covered: covered,
                limit: limit,
                offset: offset,
              );
        if (t != null) t.stop(_QueryStage.backendRead);
      } else {
        // Non-index-covered sort: Rust top-K (never materializes the full set).
        lastPlan = IndexPlan.nativeFilteredScan;
        if (t != null) t.start(_QueryStage.backendRead);
        entries = directBackend != null
            ? await directBackend.querySorted(
                table: _table,
                predicateBytes: predicateBytes,
                sortSpecBytes: sortBytes,
                limit: limit,
                offset: offset,
              )
            : await snap!.querySorted(
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
      if (ownsSnapshot && snap != null) {
        await snap.dispose();
      }
    }
  }

  /// returns `(sortField, (start, end), eqBounded, descending, covered)` when
  /// the query's single sort spec can be served by streaming a durable index
  /// in key order (Priority 5): a single-field index on the sort field, or a
  /// composite whose LAST field is the sort field with every preceding field
  /// eq-bounded. Rust streams the index (reverse for descending) with an early
  /// stop; non-eq routes keep [covered] false so the Rust missing-field
  /// fallback rechecks the predicate. Returns null for multi-spec or
  /// non-indexed sorts (those use the Rust top-K path).
  (String, (List<int>, List<int>), bool, bool, bool)? _indexCoveredSortRoute(
    CollectionIndex? idx,
  ) {
    if (_sort.length != 1) return null;
    final spec = _sort.single;
    final descending = spec.order == SortOrder.descending;
    // Single-field durable index on the sort field.
    if (idx != null && idx.fields.contains(spec.field)) {
      final eqOnField = _filters.any(
        (f) => f.isIndexUsable && f.field == spec.field,
      );
      if (eqOnField) {
        // Every matching row has the same value, so index-key (recordId)
        // order is exactly the stable order for either direction; the exact
        // bounds prove every filter on the field.
        final value = _filters
            .firstWhere((f) => f.isIndexUsable && f.field == spec.field)
            .value;
        final (start, end) = eqBounds(_table, spec.field, value, codec: _codec);
        return (
          spec.field,
          (start, end),
          true,
          descending,
          _indexCoversFilters(idx),
        );
      }
      final (start, end) = fieldBounds(_table, spec.field, codec: _codec);
      // Non-eq: missing-field rows need the Rust fallback scan (rechecked),
      // so the covered skip stays off.
      return (spec.field, (start, end), false, descending, false);
    }
    // Composite whose LAST field is the sort field with all preceding fields
    // eq-bounded: index-key order equals sort order within the eq prefix.
    for (final fields in _compositeIndexes) {
      if (fields.isEmpty || fields.last != spec.field) continue;
      final prefix = fields.sublist(0, fields.length - 1);
      final eqs = <String, Object?>{
        for (final f in _filters)
          if (f.isIndexUsable) f.field: f.value,
      };
      if (!prefix.every(eqs.containsKey)) continue;
      final eqValues = [for (final field in prefix) eqs[field]];
      final (start, end) = compositeEqBounds(
        _table, fields, prefix, eqValues, codec: _codec,
      );
      // Non-eq on the sort field: Rust handles missing-field placement and
      // rechecks the predicate (covered stays false).
      return (spec.field, (start, end), false, descending, false);
    }
    return null;
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
    // Aggregate pushdown stays in Rust. Ordinary native reads use the direct
    // worker operation; compound indexed ranges retain the snapshot fallback
    // until a direct multi-range API is added.
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final backend = _engine.backend;
    final nativeRanges = _nativeIndexedRanges(secondary);
    final predicateBytes = encodePredicate(_filters, codec: _codec);
    if (backend case final NativeRawBackend nativeBackend
        when nativeRanges == null) {
      lastPlan = IndexPlan.nativeFilteredScan;
      return nativeBackend.queryFilteredCount(
        table: _table,
        predicateBytes: predicateBytes,
      );
    }
    if (backend case final NativeRawBackend nativeBackend) {
      if (nativeRanges != null) {
        lastPlan = IndexPlan.secondaryIndex;
        return nativeBackend.queryIndexedCount(
          table: _table,
          ranges: [
            for (final range in nativeRanges)
              (ByteKey(range.$1), ByteKey(range.$2)),
          ],
          predicateBytes: predicateBytes,
          covered: _indexCoversFilters(secondary),
        );
      }
      lastPlan = IndexPlan.nativeFilteredScan;
      return nativeBackend.queryFilteredCount(
        table: _table,
        predicateBytes: predicateBytes,
      );
    }
    final snap = await backend.snapshot() as NativeRawSnapshot;
    try {
      if (nativeRanges != null) {
        lastPlan = IndexPlan.secondaryIndex;
        return snap.queryIndexedCount(
          table: _table,
          ranges: [
            for (final range in nativeRanges)
              (ByteKey(range.$1), ByteKey(range.$2)),
          ],
          predicateBytes: predicateBytes,
          covered: _indexCoversFilters(secondary),
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
    // Aggregate pushdown emits only the requested field bytes. Unindexed
    // native queries use the direct operation; compound index routes retain a
    // snapshot for consistent multi-range evaluation.
    final secondary = _secondary;
    if (secondary != null) await secondary.ready;
    final backend = _engine.backend;
    final nativeRanges = _nativeIndexedRanges(secondary);
    final predicateBytes = encodePredicate(_filters, codec: _codec);
    final List<List<int>> fieldBytes;
    if (backend case final NativeRawBackend nativeBackend) {
      if (nativeRanges == null) {
        lastPlan = IndexPlan.nativeFilteredScan;
        fieldBytes = await nativeBackend.queryFilteredDistinct(
          table: _table,
          predicateBytes: predicateBytes,
          field: field,
        );
      } else {
        lastPlan = IndexPlan.secondaryIndex;
        fieldBytes = await nativeBackend.queryIndexedDistinct(
          table: _table,
          ranges: [
            for (final range in nativeRanges)
              (ByteKey(range.$1), ByteKey(range.$2)),
          ],
          predicateBytes: predicateBytes,
          field: field,
          covered: _indexCoversFilters(secondary),
        );
      }
    } else {
      final snap = await backend.snapshot() as NativeRawSnapshot;
      try {
        fieldBytes = nativeRanges == null
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
                covered: _indexCoversFilters(secondary),
              );
      } finally {
        await snap.dispose();
      }
      lastPlan = nativeRanges == null
          ? IndexPlan.nativeFilteredScan
          : IndexPlan.secondaryIndex;
    }
    final seen = <Object?>{};
    for (final bytes in fieldBytes) {
      if (bytes.isEmpty) continue;
      seen.add(_codec.decode(bytes));
    }
    return seen.toList();
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
