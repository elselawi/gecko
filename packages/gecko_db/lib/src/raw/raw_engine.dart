/// The raw byte-level API surface for
///
/// Provides [`rawGet`], [`rawPut`], [`rawDelete`], [`rawRangeScan`] over any
/// [`RawBackend`], fronted by an optional LRU cache for hot point reads, and
/// gated by a bounded in-flight write gate (backpressure). Tier 3
/// (typed models/queries) builds on top of this.
library;

import 'dart:async';
import '../backend/byte_key.dart';
import '../backend/native_raw_backend.dart' show NativeRawBackend;
import '../backend/raw_backend.dart';
import '../cache/lru_cache.dart';
import '../errors/errors.dart';
import '../reactive/change_bus.dart';
import '../api/change.dart';
import '../api/maintenance.dart';
import '../wire/wire_codec.dart';
import '../worker/native_worker_client.dart' show WorkerContention;

/// Strategy for a put when a key already exists.
enum RawWriteMode {
  /// Insert-or-overwrite (upsert). The default.
  upsert,

  /// Succeed only if the key does not already exist.
  insertOnly,

  /// Succeed only if the key already exists (overwrite).
  updateOnly,
}

/// The raw Read/Write controller over a [`RawBackend`].
///
/// This class owns the LRU cache and the write gate, so it is the natural home
/// for the bounded-memory guarantees and backpressure the plan mandates.
class RawEngine {
  RawEngine(
    this._backend, {
    int? lruCapacity,
    int? inFlightBatchLimit,
    int? lruMaxWeight,
    ChangeBus? changeBus,
    this.slowQueryThresholdMicros = 0,
  }) : _lru = LruCache<_CacheKey, List<int>?>(
         capacity: lruCapacity ?? _defaultLruCapacity,
         maxWeight: lruMaxWeight,
         weightOf: lruMaxWeight == null ? null : (value) => value?.length ?? 0,
       ),
       // Negative (missing-key) lookups live in their OWN bounded cache so a
       // burst of absent-key reads never evicts real row data.
       _negativeLru = LruCache<_CacheKey, bool>(
         capacity: _defaultNegativeLruCapacity,
       ),
       _writeGate = _WriteGate(inFlightBatchLimit ?? _defaultInFlight),
       _changeBus = changeBus ?? ChangeBus();

  static const int _defaultLruCapacity = 1024;
  static const int _defaultNegativeLruCapacity = 256;
  static const int _defaultInFlight = 8;

  final RawBackend _backend;
  final LruCache<_CacheKey, List<int>?> _lru;

  /// Cached absent keys: a repeated read of a missing key returns null without
  /// crossing the boundary, and never evicts a real cached row.
  final LruCache<_CacheKey, bool> _negativeLru;
  bool _disposed = false;
  final _WriteGate _writeGate;
  final ChangeBus _changeBus;

  /// per-registration deltas produced by the worker for each
  /// committed batch, in commit order (same delivery order as [_changeBus]).
  final StreamController<RegistryDelta> _liveDeltas =
      StreamController<RegistryDelta>.broadcast(sync: true);
  bool _diagnosticsEnabled = false;
  int _scannedRows = 0;
  int _totalReads = 0;
  int _totalWrites = 0;
  int _failedWrites = 0;
  int _totalWriteDurationMicros = 0;
  int _slowQueryCount = 0;
  final List<SlowQueryRecord> _recentSlowQueries = [];

  /// Upper bound on retained recent slow-query records.
  static const int _maxSlowQueryRecords = 32;

  /// Slow-query threshold in microseconds; 0 disables slow-query logging.
  int slowQueryThresholdMicros;

  /// The change hub for this engine ().
  ChangeBus get changes => _changeBus;

  /// stream of per-registration deltas for committed batches,
  /// in commit order. Each delta carries the registration id it belongs to.
  Stream<RegistryDelta> get liveDeltas => _liveDeltas.stream;

  /// registers a live query with the worker's reactive registry. A windowed
  /// query ([limit] is non-null) receives only the ordered slice
  /// `[offset, offset + limit)` while the registry maintains the full matching
  /// set incrementally.
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
    int? limit,
    int offset = 0,
  }) {
    _assertUsable();
    return _backend.registerLiveQuery(
      table: table,
      predicateBytes: predicateBytes,
      sortBytes: sortBytes,
      kind: kind,
      limit: limit,
      offset: offset,
    );
  }

  /// removes a live-query registration (idempotent).
  Future<void> unregisterLiveQuery(int id) {
    _assertUsable();
    return _backend.unregisterLiveQuery(id);
  }

  /// Number of active live-query registrations (diagnostics).
  Future<int> liveQueryCount() {
    _assertUsable();
    return _backend.liveQueryCount();
  }

  /// aggregates pending local changes in Rust (scan/filter/sort executed
  /// there); Dart only decodes the returned records.
  Future<List<RawEntry>> pendingChanges() {
    _assertUsable();
    return _backend.pendingChanges();
  }

  /// Worker-contention measurement (serial-queue depth + service latency);
  /// empty/default when the backend does not expose a serial worker queue.
  WorkerContention get workerContention {
    final backend = _backend;
    return backend is NativeRawBackend
        ? backend.workerContention
        : const WorkerContention(
            requestCount: 0,
            queueDepthHighWater: 0,
            avgServiceMicros: 0,
            maxServiceMicros: 0,
          );
  }

  /// Filters the sync-state table in Rust to the records matching [matchers];
  /// Dart transforms only the matching records.
  Future<List<RawEntry>> syncStateMatching(List<List<int>> matchers) {
    _assertUsable();
    final backend = _backend;
    if (backend is NativeRawBackend) {
      return backend.syncStateMatching(matchers);
    }
    throw const GeckoError(
      GeckoErrorType.invalidOperation,
      'syncStateMatching requires the native backend',
    );
  }

  /// Range-filtered `changesSince(lastSeq)` in Rust.
  Future<List<RawEntry>> changesSince(int seq) {
    _assertUsable();
    final backend = _backend;
    if (backend is NativeRawBackend) {
      return backend.changesSince(seq);
    }
    throw const GeckoError(
      GeckoErrorType.invalidOperation,
      'changesSince requires the native backend',
    );
  }

  /// Attachment metadata whose parent row is missing (Rust-side scan).
  Future<List<RawEntry>> orphanedAttachments() {
    _assertUsable();
    final backend = _backend;
    if (backend is NativeRawBackend) {
      return backend.orphanedAttachments();
    }
    throw const GeckoError(
      GeckoErrorType.invalidOperation,
      'orphanedAttachments requires the native backend',
    );
  }

  /// Applies [ops] atomically and forwards any reactive-registry deltas the
  /// worker produced to [liveDeltas] (one delta per touched registration).
  Future<ApplyBatchResult> _applyBatchWithDeltas(RawBatchPlan plan) async {
    final result = _backend is PreparedBatchBackend
        ? await (_backend as PreparedBatchBackend).applyPreparedBatch(plan)
        : await _backend.applyBatch(plan.ops);
    for (final delta in result.deltas) {
      _liveDeltas.add(delta);
    }
    return result;
  }

  /// The backend this engine wraps (exposed for the shared parametrized tests).
  RawBackend get backend => _backend;

  /// Whether the underlying backend is read-only.
  bool get isReadOnly => _backend.isReadOnly;

  void _assertUsable() {
    if (_disposed) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Raw engine is closed',
      );
    }
  }

  void _assertWritable() {
    _assertUsable();
    if (isReadOnly) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Database is read-only; write operations are not allowed',
      );
    }
  }

  /// Total rows materialized by full-scan calls since this engine was created.
  /// Used by the query engine's index diagnostics: an indexed query performs
  /// point reads and does not contribute rows here.
  int get scannedRows => _scannedRows;
  int get totalReads => _totalReads;
  int get totalWrites => _totalWrites;
  int get failedWrites => _failedWrites;
  int get totalWriteDurationMicros => _totalWriteDurationMicros;
  bool get diagnosticsEnabled => _diagnosticsEnabled;

  /// Number of slow queries recorded since open (or since [reset]).
  int get slowQueryCount => _slowQueryCount;

  /// The most recent slow-query records (bounded, oldest-dropped).
  List<SlowQueryRecord> get recentSlowQueries =>
      List<SlowQueryRecord>.unmodifiable(_recentSlowQueries);

  /// Number of write batches that had to wait for the in-flight write gate
  /// (lock-contention counter).
  int get lockContentionCount => _writeGate.contentionCount;

  /// Currently-active change-feed subscriptions.
  int get activeSubscriberCount => _changeBus.activeSubscriberCount;

  /// Records a slow query when diagnostics logging is armed.
  void reportSlowQuery(SlowQueryRecord record) {
    if (slowQueryThresholdMicros <= 0) return;
    if (record.durationMicros < slowQueryThresholdMicros) return;
    _slowQueryCount++;
    _recentSlowQueries.add(record);
    if (_recentSlowQueries.length > _maxSlowQueryRecords) {
      _recentSlowQueries.removeAt(0);
    }
  }

  void setDiagnosticsEnabled(bool enabled) => _diagnosticsEnabled = enabled;
  void resetDiagnosticsCounters() {
    _scannedRows = 0;
    _totalReads = 0;
    _totalWrites = 0;
    _failedWrites = 0;
    _totalWriteDurationMicros = 0;
    _slowQueryCount = 0;
    _recentSlowQueries.clear();
  }

  /// Strongly-typed friendly name for table absence errors.
  static const String _missingTablePrefix = '__gecko_';

  /// Reads the raw value at [key] in [table], or null if absent.
  ///
  /// On a cache hit the value is returned without touching the backend; a
  /// cached MISSING key is also served from the bounded negative cache (no
  /// boundary crossing on repeated absent reads). On a write the affected
  /// cache entries are invalidated so results are never stale.
  Future<List<int>?> rawGet(String table, ByteKey key) async {
    _assertUsable();
    if (_diagnosticsEnabled) _totalReads++;
    final cacheKey = _CacheKey(table, key);
    if (_negativeLru.containsKey(cacheKey)) {
      // Cached missing sentinel: the key was absent on a previous read and no
      // write has touched it since.
      return null;
    }
    if (_lru.containsKey(cacheKey)) {
      // Cache hit (the value is never null in [_lru]). Return a defensive
      // copy so a caller mutating the returned list cannot corrupt the cache
      // (the cache stores the shared encoding of the value).
      return List<int>.from(_lru.get(cacheKey)!);
    }
    final value = _backend is DirectReadBackend
        ? await (_backend as DirectReadBackend).directRead(table, key)
        : await _readThroughSnapshot(table, key);
    if (value == null) {
      _negativeLru.put(cacheKey, true);
    } else {
      _lru.put(cacheKey, value);
    }
    return value == null ? null : List<int>.from(value);
  }

  /// Invalidates both the value cache and the negative (missing-key) cache for
  /// [table]/[key] — a write to a previously-missing key must clear its
  /// negative entry, and vice versa.
  void _invalidate(String table, ByteKey key) {
    final cacheKey = _CacheKey(table, key);
    _lru.invalidate(cacheKey);
    _negativeLru.invalidate(cacheKey);
  }

  void _invalidateAll(Iterable<(String, ByteKey)> keys) {
    for (final (table, key) in keys) {
      _invalidate(table, key);
    }
  }

  /// Table-generation invalidation: evicts every cached entry (positive and
  /// negative) for [table] without enumerating its keys. Used after a
  /// wholesale clear in no-report mode, where the worker deliberately does not
  /// return every removed key.
  void _invalidateTable(String table) {
    _lru.removeWhere((key) => key.table == table);
    _negativeLru.removeWhere((key) => key.table == table);
  }

  /// Selectively invalidates the keys touched by [ops] (put/delete carry the
  /// key; delete-range/clear keys come from [result].removedKeys) instead of
  /// clearing the whole LRU after every batch. Whole-table clears reported via
  /// [ApplyBatchResult.cleared] invalidate the table generation in one pass.
  void _invalidateForOps(RawBatch ops, ApplyBatchResult result) {
    for (final op in ops) {
      switch (op) {
        case RawPut(:final table, :final key):
          _invalidate(table, key);
        case RawDelete(:final table, :final key):
          _invalidate(table, key);
        default:
          break; // delete-range/clear keys arrive via removedKeys/cleared
      }
    }
    for (final table in result.cleared) {
      _invalidateTable(table);
    }
    _invalidateAll(result.removedKeys);
  }

  Future<List<int>?> _readThroughSnapshot(String table, ByteKey key) async {
    final snap = await _backend.snapshot();
    try {
      return await snap.read(table, key);
    } finally {
      await snap.dispose();
    }
  }

  /// Inserts or updates [key] → [value] in [table] per [mode].
  ///
  /// Returns the previous value (or null if there was none).
  Future<List<int>?> rawPut(
    String table,
    ByteKey key,
    List<int> value, {
    RawWriteMode mode = RawWriteMode.upsert,
  }) async {
    _assertWritable();
    return _writeGate.run(() async {
      final started = _diagnosticsEnabled ? (Stopwatch()..start()) : null;
      try {
        final result = await _applyBatchWithDeltas(
          RawBatchPlan(
            ops: [RawPut(table, key, value)],
            previousOperationIndexes: const [0],
            putModes: {
              0: switch (mode) {
                RawWriteMode.upsert => RawPutMode.upsert,
                RawWriteMode.insertOnly => RawPutMode.insertOnly,
                RawWriteMode.updateOnly => RawPutMode.updateOnly,
              },
            },
          ),
        );
        final previous = result.previousValues.isEmpty
            ? null
            : result.previousValues.single;
        _invalidate(table, key);
        _publishAt(result.sequence, [(table, key, ChangeKind.put)]);
        return previous;
      } catch (_) {
        _failedWrites++;
        rethrow;
      } finally {
        if (_diagnosticsEnabled) {
          _totalWrites++;
          _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
        }
      }
    });
  }

  /// Deletes [key] from [table] (no-op if absent). Returns whether it existed.
  Future<bool> rawDelete(String table, ByteKey key) async {
    _assertWritable();
    return _writeGate.run(() async {
      try {
        final result = await _applyBatchWithDeltas(
          RawBatchPlan(
            ops: [RawDelete(table, key)],
            previousOperationIndexes: const [0],
          ),
        );
        final previous = result.previousValues.isEmpty
            ? null
            : result.previousValues.single;
        _invalidate(table, key);
        _publishAt(result.sequence, [(table, key, ChangeKind.delete)]);
        return previous != null;
      } catch (_) {
        if (_diagnosticsEnabled) _failedWrites++;
        rethrow;
      } finally {
        if (_diagnosticsEnabled) _totalWrites++;
      }
    });
  }

  /// Deletes every key in [table].
  Future<void> rawClear(String table) async {
    _assertWritable();
    return _writeGate.run(() async {
      try {
        final result = await _applyBatchWithDeltas(
          // Internal no-report mode: the worker does not collect every removed
          // key (memory proportional to deleted rows is avoided); the whole
          // table is invalidated below as one cache generation.
          RawBatchPlan(ops: [RawClear(table)], reportRemovedKeys: false),
        );
        for (final cleared in result.cleared) {
          _invalidateTable(cleared);
        }
        _publishAt(result.sequence, [
          (table, ByteKey(const []), ChangeKind.delete),
        ]);
      } catch (_) {
        if (_diagnosticsEnabled) _failedWrites++;
        rethrow;
      } finally {
        if (_diagnosticsEnabled) _totalWrites++;
      }
    });
  }

  /// Scans [table] over [[start], [end]] bounds (both inclusive), returning
  /// entries in ascending byte-wise order.
  Future<List<RawEntry>> rawRangeScan(
    String table, {
    ByteKey? start,
    ByteKey? end,
  }) async {
    _assertUsable();
    final entries = _backend is DirectReadBackend
        ? await (_backend as DirectReadBackend).directScan(
            table,
            start: start,
            end: end,
          )
        : await _scanThroughSnapshot(table, start: start, end: end);
    _scannedRows += entries.length;
    return entries;
  }

  /// Scans the whole [table] (empty iterable, never null).
  Future<List<RawEntry>> rawScanAll(String table) async {
    return rawRangeScan(table);
  }

  Future<List<RawEntry>> _scanThroughSnapshot(
    String table, {
    ByteKey? start,
    ByteKey? end,
  }) async {
    final snap = await _backend.snapshot();
    try {
      return await snap.scan(table, start: start, end: end);
    } finally {
      await snap.dispose();
    }
  }

  /// The engine's current in-flight write count (for backpressure tests).
  int get inFlightCount => _writeGate.inFlight;

  /// The configured in-flight write bound.
  int get inFlightLimit => _writeGate.limit;

  /// Current resident cache entries.
  int get cacheLength => _lru.length;

  /// Current resident cache weight (bytes) when a weight bound is configured.
  int get cacheWeight => _lru.weight;

  /// Completes after all writes that were already admitted to the gate finish.
  Future<void> drain() => _writeGate.drain();

  /// Drains writes, closes the backend and completes the change feed.
  Future<void> dispose() async {
    if (_disposed) return;
    await drain();
    await _backend.close();
    await _changeBus.close();
    await _liveDeltas.close();
    _disposed = true;
  }

  /// Reserved-table helper for internal callers (metadata tables).
  bool isReservedTable(String table) => table.startsWith(_missingTablePrefix);

  /// Commits one atomic batch under the engine's single-writer gate.
  ///
  /// The callback still receives the last assigned sequence for API
  /// compatibility, but sequence allocation and persistence now happen in
  /// Rust. New callers should use [commitPreparedBatch] when they need
  /// storage-derived previous values in change records.
  Future<int> commitBatch(
    FutureOr<List<RawOp>> Function(int lsn, RawSnapshot snapshot) buildOps, {
    List<Change> Function(int lsn)? buildChanges,
  }) async {
    _assertWritable();
    return _writeGate.run(() async {
      final started = _diagnosticsEnabled ? (Stopwatch()..start()) : null;
      final snapshot = await _backend.snapshot();
      try {
        final lsn = _changeBus.lastSequence + 1;
        final ops = await buildOps(lsn, snapshot);
        if (ops.isEmpty) return lsn - 1;
        try {
          final result = await _applyBatchWithDeltas(RawBatchPlan(ops: ops));
          _invalidateForOps(ops, result);
          final changes =
              buildChanges?.call(result.sequence) ?? const <Change>[];
          if (changes.isNotEmpty) {
            _publishAt(result.sequence, const [], supplied: changes);
          }
          return result.sequence;
        } catch (_) {
          if (_diagnosticsEnabled) _failedWrites++;
          rethrow;
        } finally {
          if (_diagnosticsEnabled) {
            _totalWrites++;
            _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
          }
        }
      } finally {
        await snapshot.dispose();
      }
    });
  }

  Future<ApplyBatchResult> applyPreparedPlan(RawBatchPlan plan) async {
    _assertWritable();
    return _writeGate.run(() async {
      final started = _diagnosticsEnabled ? (Stopwatch()..start()) : null;
      try {
        final result = await _applyBatchWithDeltas(plan);
        _invalidateForOps(plan.ops, result);
        return result;
      } catch (_) {
        if (_diagnosticsEnabled) _failedWrites++;
        rethrow;
      } finally {
        if (_diagnosticsEnabled) {
          _totalWrites++;
          _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
        }
      }
    });
  }

  /// Commits a batch that does not need a Dart snapshot while preparing its
  /// operations. Rust assigns and persists the sequence in the same write
  /// transaction; this path avoids the historical create/read/drop snapshot
  /// round trip used by simple metadata and join writes.
  Future<int> commitBatchNoSnapshot(
    FutureOr<List<RawOp>> Function(int lsn) buildOps, {
    List<Change> Function(int sequence)? buildChanges,
  }) async {
    _assertWritable();
    return _writeGate.run(() async {
      final started = _diagnosticsEnabled ? (Stopwatch()..start()) : null;
      try {
        final predicted = _changeBus.lastSequence + 1;
        final ops = await buildOps(predicted);
        if (ops.isEmpty) return _changeBus.lastSequence;
        final result = await _applyBatchWithDeltas(RawBatchPlan(ops: ops));
        _invalidateForOps(ops, result);
        final changes = buildChanges?.call(result.sequence) ?? const <Change>[];
        if (changes.isNotEmpty) {
          _publishAt(result.sequence, const [], supplied: changes);
        }
        return result.sequence;
      } catch (_) {
        if (_diagnosticsEnabled) _failedWrites++;
        rethrow;
      } finally {
        if (_diagnosticsEnabled) {
          _totalWrites++;
          _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
        }
      }
    });
  }

  Future<int> commitPreparedBatch(
    FutureOr<RawBatchPlan> Function() buildPlan, {
    List<Change> Function(int sequence)? buildChanges,
  }) async {
    _assertWritable();
    return _writeGate.run(() async {
      final started = _diagnosticsEnabled ? (Stopwatch()..start()) : null;
      try {
        final plan = await buildPlan();
        if (plan.ops.isEmpty) return _changeBus.lastSequence;
        final result = await _applyBatchWithDeltas(plan);
        _invalidateForOps(plan.ops, result);
        final changes = buildChanges?.call(result.sequence) ?? const <Change>[];
        if (changes.isNotEmpty) {
          _publishAt(result.sequence, const [], supplied: changes);
        }
        return result.sequence;
      } catch (_) {
        if (_diagnosticsEnabled) _failedWrites++;
        rethrow;
      } finally {
        if (_diagnosticsEnabled) {
          _totalWrites++;
          _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
        }
      }
    });
  }

  void publishPreparedChanges(int lsn, List<Change> changes) {
    _publishAt(lsn, const [], supplied: changes);
  }

  void _publishAt(
    int lsn,
    List<(String, ByteKey, ChangeKind)> rawChanges, {
    List<Change>? supplied,
  }) {
    final changes =
        supplied ??
        [
          for (final (table, key, kind) in rawChanges)
            if (!isReservedTable(table))
              Change(table: table, key: _decodeKey(key), kind: kind),
        ];
    if (changes.isEmpty) return;
    final seq = _changeBus.publishAt(lsn, changes);
    _changeBus.notifySequence(seq);
  }

  Object? _decodeKey(ByteKey key) {
    if (key.isEmpty) return null;
    try {
      return const DefaultWireCodec().decode(key.bytes);
    } catch (_) {
      return key.bytes;
    }
  }
}

class _CacheKey {
  const _CacheKey(this.table, this.key);

  final String table;
  final ByteKey key;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey && other.table == table && other.key == key;

  @override
  int get hashCode => Object.hash(table, key);
}

/// A bounded write gate implementing natural async backpressure.
///
/// When the number of in-flight write batches reaches [limit], new callers
/// await a signal before proceeding, so memory stays bounded rather than
/// growing an unbounded queue.
class _WriteGate {
  _WriteGate(this.limit) : assert(limit > 0);

  final int limit;
  int _inFlight = 0;
  int _waits = 0;
  final List<Completer<void>> _waiters = [];
  final List<Completer<void>> _drainWaiters = [];

  int get inFlight => _inFlight;

  /// Number of times a caller had to wait for the gate (lock contention).
  int get contentionCount => _waits;

  Future<void> drain() {
    if (_inFlight == 0) return Future<void>.value();
    final completer = Completer<void>();
    _drainWaiters.add(completer);
    return completer.future;
  }

  Future<T> run<T>(Future<T> Function() action) async {
    while (_inFlight >= limit) {
      _waits++;
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
    _inFlight++;
    try {
      return await action();
    } finally {
      _inFlight--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
      if (_inFlight == 0) {
        for (final waiter in _drainWaiters) {
          if (!waiter.isCompleted) waiter.complete();
        }
        _drainWaiters.clear();
      }
    }
  }
}
