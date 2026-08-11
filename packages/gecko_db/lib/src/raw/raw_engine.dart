/// The raw byte-level API surface for 
///
/// Provides [`rawGet`], [`rawPut`], [`rawDelete`], [`rawRangeScan`] over any
/// [`RawBackend`], fronted by an optional LRU cache for hot point reads, and
/// gated by a bounded in-flight write gate (backpressure). Tier 3
/// (typed models/queries) builds on top of this.
library;

import 'dart:async';
import 'dart:math' as math;

import '../backend/byte_key.dart';
import '../backend/raw_backend.dart';
import '../cache/lru_cache.dart';
import '../errors/errors.dart';
import '../reactive/change_bus.dart';
import '../api/change.dart';
import '../api/maintenance.dart';
import '../namespaces.dart';
import '../wire/wire_codec.dart';

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
       _writeGate = _WriteGate(inFlightBatchLimit ?? _defaultInFlight),
       _changeBus = changeBus ?? ChangeBus();

  static const int _defaultLruCapacity = 1024;
  static const int _defaultInFlight = 8;

  final RawBackend _backend;
  final LruCache<_CacheKey, List<int>?> _lru;
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

  /// registers a live query with the worker's reactive registry.
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  }) {
    _assertUsable();
    return _backend.registerLiveQuery(
      table: table,
      predicateBytes: predicateBytes,
      sortBytes: sortBytes,
      kind: kind,
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

  /// Applies [ops] atomically and forwards any reactive-registry deltas the
  /// worker produced to [liveDeltas] (one delta per touched registration).
  Future<void> _applyBatchWithDeltas(List<RawOp> ops) async {
    final result = await _backend.applyBatch(ops);
    for (final delta in result.deltas) {
      _liveDeltas.add(delta);
    }
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
  /// On a cache hit the value is returned without touching the backend; on a
  /// write the cache is invalidated so results are never stale.
  Future<List<int>?> rawGet(String table, ByteKey key) async {
    _assertUsable();
    if (_diagnosticsEnabled) _totalReads++;
    final cacheKey = _CacheKey(table, key);
    final cached = _lru.get(cacheKey);
    if (cached != null) {
      // Cache hit (including a cached "missing" sentinel).
      return cached;
    }
    final snap = await _backend.snapshot();
    try {
      final value = await snap.read(table, key);
      _lru.put(cacheKey, value);
      return value;
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
      final snapshot = await _backend.snapshot();
      try {
        final prev = await snapshot.read(table, key);
        switch (mode) {
          case RawWriteMode.upsert:
            break;
          case RawWriteMode.insertOnly:
            if (prev != null) {
              throw GeckoError(
                GeckoErrorType.invalidOperation,
                'rawPut insertOnly: key already exists in "$table"',
              );
            }
          case RawWriteMode.updateOnly:
            if (prev == null) {
              throw GeckoError(
                GeckoErrorType.keyNotFound,
                'rawPut updateOnly: key does not exist in "$table"',
              );
            }
        }
        final lsn = await _nextLsn(snapshot);
        try {
          await _applyBatchWithDeltas([RawPut(table, key, value), _lsnOp(lsn)]);
        } catch (_) {
          _failedWrites++;
          rethrow;
        } finally {
          if (_diagnosticsEnabled) {
            _totalWrites++;
            _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
          }
        }
        _lru.invalidate(_CacheKey(table, key));
        _publishAt(lsn, [(table, key, ChangeKind.put)]);
        return prev;
      } finally {
        await snapshot.dispose();
      }
    });
  }

  /// Deletes [key] from [table] (no-op if absent). Returns whether it existed.
  Future<bool> rawDelete(String table, ByteKey key) async {
    _assertWritable();
    return _writeGate.run(() async {
      final snapshot = await _backend.snapshot();
      try {
        final existed = await snapshot.read(table, key) != null;
        final lsn = await _nextLsn(snapshot);
        try {
          await _applyBatchWithDeltas([RawDelete(table, key), _lsnOp(lsn)]);
        } catch (_) {
          if (_diagnosticsEnabled) _failedWrites++;
          rethrow;
        } finally {
          if (_diagnosticsEnabled) _totalWrites++;
        }
        _lru.invalidate(_CacheKey(table, key));
        _publishAt(lsn, [(table, key, ChangeKind.delete)]);
        return existed;
      } finally {
        await snapshot.dispose();
      }
    });
  }

  /// Deletes every key in [table].
  Future<void> rawClear(String table) async {
    _assertWritable();
    return _writeGate.run(() async {
      final snapshot = await _backend.snapshot();
      try {
        final lsn = await _nextLsn(snapshot);
        try {
          await _applyBatchWithDeltas([RawClear(table), _lsnOp(lsn)]);
        } catch (_) {
          if (_diagnosticsEnabled) _failedWrites++;
          rethrow;
        } finally {
          if (_diagnosticsEnabled) _totalWrites++;
        }
        _lru.clear();
        _publishAt(lsn, [(table, ByteKey(const []), ChangeKind.delete)]);
      } finally {
        await snapshot.dispose();
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
    final snap = await _backend.snapshot();
    try {
      final entries = await snap.scan(table, start: start, end: end);
      _scannedRows += entries.length;
      return entries;
    } finally {
      await snap.dispose();
    }
  }

  /// Scans the whole [table] (empty iterable, never null).
  Future<List<RawEntry>> rawScanAll(String table) async {
    _assertUsable();
    final snap = await _backend.snapshot();
    try {
      final entries = await snap.scanAll(table);
      _scannedRows += entries.length;
      return entries;
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
  /// [buildOps] runs after the persisted clock has been read and receives the
  /// LSN that will be written in the same backend batch. This is the seam used
  /// by transactions to append change metadata without a second persistence
  /// system.
  Future<int> commitBatch(
    FutureOr<List<RawOp>> Function(int lsn, RawSnapshot snapshot) buildOps, {
    List<Change> Function(int lsn)? buildChanges,
  }) async {
    _assertWritable();
    return _writeGate.run(() async {
      final started = _diagnosticsEnabled ? (Stopwatch()..start()) : null;
      final snapshot = await _backend.snapshot();
      try {
        final lsn = await _nextLsn(snapshot);
        final ops = await buildOps(lsn, snapshot);
        if (ops.isEmpty) return lsn - 1;
        try {
          await _applyBatchWithDeltas([...ops, _lsnOp(lsn)]);
        } catch (_) {
          if (_diagnosticsEnabled) _failedWrites++;
          rethrow;
        } finally {
          if (_diagnosticsEnabled) {
            _totalWrites++;
            _totalWriteDurationMicros += started?.elapsedMicroseconds ?? 0;
          }
        }
        _lru.clear();
        final changes = buildChanges?.call(lsn) ?? const <Change>[];
        if (changes.isNotEmpty) {
          _publishAt(lsn, const [], supplied: changes);
        }
        return lsn;
      } finally {
        await snapshot.dispose();
      }
    });
  }

  Future<int> _nextLsn(RawSnapshot snapshot) async {
    final raw = await snapshot.read(
      geckoSyncMetaTable,
      ByteKey(_codec.encode(geckoLsnKey)),
    );
    final persisted = raw == null ? 0 : (_codec.decode(raw) as int? ?? 0);
    return math.max(persisted, _changeBus.lastSequence) + 1;
  }

  RawPut _lsnOp(int lsn) => RawPut(
    geckoSyncMetaTable,
    ByteKey(_codec.encode(geckoLsnKey)),
    _codec.encode(lsn),
  );

  static const _codec = DefaultWireCodec();

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
