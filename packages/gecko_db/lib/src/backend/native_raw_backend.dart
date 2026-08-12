/// FRB-backed native RawBackend adapter.
///
/// The adapter keeps Dart transaction handles out of FFI. Each mutation batch
/// is encoded once with the existing versioned `Op` contract and sent to the
/// Rust `NativeWorker`, which applies it in one redb write transaction.
library;

import 'dart:typed_data';

import '../errors/native_error.dart';
import '../namespaces.dart';
import '../native/generated/counters.dart' show WorkCounters;
import '../native/generated/worker.dart' show StorageStats;
import '../native/generated/api.dart' show PreparedChange;
import '../wire/compatibility.dart';
import '../wire/op.dart';
import '../worker/native_worker_client.dart';
import 'byte_key.dart';
import 'raw_backend.dart';

/// A file-backed backend using the generated flutter_rust_bridge worker.
class NativeRawBackend
    implements
        RawBackend,
        DurableIndexRegistrar,
        PreparedBatchBackend,
        DirectReadBackend {
  NativeRawBackend._(
    this._worker,
    this._readOnly, {
    int changeLogMaxEntries = 0,
  }) : _changeLogMaxEntries = changeLogMaxEntries;

  final NativeWorkerClient _worker;
  final bool _readOnly;

  /// pending-sync change-log retention (0 = disabled); pruned in the
  /// Rust commit path when a batch grows the log beyond this bound.
  final int _changeLogMaxEntries;
  final Map<String, List<String>> _durableIndexes = <String, List<String>>{};

  @override
  void registerDurableIndex(String table, List<String> fields) {
    _durableIndexes[table] = List<String>.unmodifiable(fields);
  }

  /// Snapshot ids handed out by the worker that have not been released yet.
  /// Dropped on [close] so a closed backend never leaks MVCC read
  /// transactions; individual snapshots are also released by
  /// `_NativeSnapshot.dispose` (and by a `Finalizer` for GC safety).
  final Set<int> _openSnapshots = <int>{};

  @override
  bool get isReadOnly => _readOnly;

  /// Whether the worker isolate is alive and has completed its startup
  /// handshake. Test/qualification surface
  bool get workerAlive => _worker.isWorkerAlive;

  /// The worker isolate's own name, proving reads/writes execute off the
  /// caller's isolate. Test/qualification surface
  String? get workerIsolateName => _worker.workerIsolateName;

  /// Test/qualification surface runs the [`Finalizer`] teardown
  /// path deterministically (instead of waiting for garbage collection),
  /// after which the worker isolate is shut down and [workerAlive] is false.
  Future<void> disposeForTest() => _worker.debugFinalize();

  /// Number of MVCC snapshots currently held in the worker (open snapshot-
  /// bound cursors/transactions). Compaction refuses to run while this is
  /// non-zero.
  int get openSnapshotCount => _openSnapshots.length;

  /// Returns the current commit LSN (sequence number) via a single
  /// worker-isolate round trip with trivial Rust work. A perf-instrumentation
  /// probe (boundary benchmark): measures the isolate/port + FRB
  /// marshalling cost in isolation, not a storage operation.
  Future<int> commitSequenceProbe() async {
    try {
      return await _worker.commitSequence();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Compacts the database file in place Returns true when
  /// space was reclaimed. Requires no open snapshots and a writable database.
  Future<bool> compact() async {
    try {
      return await _worker.compact();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Reports physical/logical size and health counters from the worker.
  Future<StorageStats> storageStats() async {
    try {
      return await _worker.storageStats();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Starts recording physical-work counters in the worker (zero-cost when
  /// off by default). Drain with [takeCounters].
  Future<void> enableCounters() async {
    try {
      return await _worker.enableCounters();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Stops recording and resets all physical-work counters to zero.
  Future<void> disableCounters() async {
    try {
      return await _worker.disableCounters();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Snapshots and resets the physical-work counters accumulated since the
  /// last drain. Returns a zeroed snapshot when counters are disabled.
  Future<WorkCounters> takeCounters() async {
    try {
      return await _worker.takeCounters();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Opens a file-backed worker after `RustLib.init()` has loaded the native
  /// artifact through the generated FRB loader.
  ///
  /// When [encryptionKey] is supplied (32 raw bytes), the file is opened with
  /// Rust AES-256-GCM physical page encryption;
  /// [encryptionKeyGeneration] selects the key generation for interrupted
  /// rotation recovery.
  static Future<NativeRawBackend> open(
    String path, {
    bool readOnly = false,
    String? nativeLibraryPath,
    List<int>? encryptionKey,
    int encryptionKeyGeneration = 1,
    int changeLogMaxEntries = 0,
  }) async {
    try {
      final backend = NativeRawBackend._(
        await NativeWorkerClient.open(
          path: path,
          readOnly: readOnly,
          nativeLibraryPath: nativeLibraryPath,
          encryptionKey: encryptionKey,
          encryptionKeyGeneration: encryptionKeyGeneration,
        ),
        readOnly,
        changeLogMaxEntries: changeLogMaxEntries,
      );
      try {
        final handshake = CompatibilityHandshake.decode(
          await backend._worker.compatibilityHandshake(),
        );
        handshake.validateCompatibility();
        return backend;
      } catch (error) {
        await backend.close();
        rethrow;
      }
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<ApplyBatchResult> applyBatch(RawBatch ops) async {
    final wireOps = <Op>[for (final op in ops) _toWireOp(op)];
    try {
      final result = await _worker.applyBatch(
        Op.encodeBatch(wireOps),
        indexDefinitions: [
          for (final entry in _durableIndexes.entries) (entry.key, entry.value),
        ],
        changeLogMaxEntries: _changeLogMaxEntries,
      );
      return _rawApplyResult(result, ops);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<void> registerCompositeIndexes(
    String table,
    List<List<String>> indexes,
  ) async {
    try {
      await _worker.setCompositeIndexes(table, indexes);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<ApplyBatchResult> applyPreparedBatch(RawBatchPlan plan) async {
    final wireOps = <Op>[for (final op in plan.ops) _toWireOp(op)];
    final preparedChanges = [
      for (final template in plan.changeTemplates)
        PreparedChange(
          operationIndex: BigInt.from(template.operationIndex),
          ordinal: BigInt.from(template.ordinal),
          syncStateKey: template.syncStateKey.bytes,
          recordTemplate: Uint8List.fromList(template.recordTemplate),
          fillPreviousVersion: template.fillPreviousVersion,
        ),
    ];
    try {
      final result = await _worker.applyPreparedBatch(
        Op.encodeBatch(wireOps),
        indexDefinitions: [
          for (final entry in _durableIndexes.entries) (entry.key, entry.value),
        ],
        changeLogMaxEntries: _changeLogMaxEntries,
        previousOperationIndexes: [
          for (final index in plan.previousOperationIndexes) index.toString(),
        ],
        putModes: [
          for (final entry in plan.putModes.entries)
            (BigInt.from(entry.key), _putMode(entry.value)),
        ],
        changes: preparedChanges,
      );
      return _rawApplyResult(result, plan.ops);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  ApplyBatchResult _rawApplyResult(ApplyBatchResult result, RawBatch ops) {
    final affected = <(String, ByteKey)>{
      for (final op in ops)
        switch (op) {
          RawPut(:final table, :final key) => (table, key),
          RawDelete(:final table, :final key) => (table, key),
          RawDeleteRange(:final table, :final start) => (table, start),
          RawClear(:final table) => (table, ByteKey(const [])),
        },
      ...result.removedKeys,
    };
    return ApplyBatchResult(
      affected: affected,
      deltas: result.deltas,
      sequence: result.sequence,
      previousValues: result.previousValues,
      removedKeys: result.removedKeys,
    );
  }

  static int _putMode(RawPutMode mode) => switch (mode) {
    RawPutMode.upsert => 0,
    RawPutMode.insertOnly => 1,
    RawPutMode.updateOnly => 2,
  };

  @override
  Future<List<int>?> directRead(String table, ByteKey key) async {
    try {
      return await _worker.get(table: table, key: key.bytes);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<List<RawEntry>> directScan(
    String table, {
    ByteKey? start,
    ByteKey? end,
  }) async {
    try {
      final pairs = await _worker.rangeScan(
        table: table,
        start: start?.bytes,
        end: end?.bytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// registers a live query with the worker's reactive registry.
  @override
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  }) async {
    try {
      return await _worker.registerLiveQuery(
        table: table,
        predicateBytes: predicateBytes,
        sortBytes: sortBytes,
        kind: kind,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// removes a live-query registration (idempotent).
  @override
  Future<void> unregisterLiveQuery(int id) async {
    try {
      await _worker.unregisterLiveQuery(id);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// Number of active live-query registrations (diagnostics).
  @override
  Future<int> liveQueryCount() async {
    try {
      return await _worker.liveQueryCount();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// aggregates pending local changes in Rust; Dart only decodes the
  /// returned records.
  @override
  Future<List<RawEntry>> pendingChanges() async {
    try {
      return await _worker.pendingChanges();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<RawSnapshot> snapshot() async {
    final id = await _worker.createSnapshot();
    _openSnapshots.add(id);
    return NativeRawSnapshot(
      _worker,
      id,
      onDispose: () => _openSnapshots.remove(id),
    );
  }

  /// single-hop batched point-read — all [keys] are read under ONE Rust
  /// read transaction (consistent batch read) with a single FRB boundary
  /// crossing and no snapshot create/drop. See [RawBackend.getMany].
  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) async {
    if (keys.isEmpty) return const [];
    try {
      final pairs = await _worker.getMany(
        table: table,
        keys: [for (final k in keys) k.bytes],
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// verifies and atomically repairs the durable index entries for [table]
  /// from the primary rows in Rust. Native queries do not rebuild a Dart index.
  Future<void> repairIndex({
    required String table,
    required List<String> fields,
  }) async {
    try {
      await _worker.repairIndex(table: table, fields: fields);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// native query fast path: range-scans the durable `__gecko_index`
  /// table for keys in `[start..=end]`, joins each entry's value (the
  /// user-table row key) back to its row in [table], and returns the
  /// `(recordId → row)` pairs in ONE boundary crossing. [start]/[end] are the
  /// already codec-encoded `[table, field, value, ...]` key bounds.
  ///
  /// This opens its own short-lived read transaction (not consistent with a
  /// caller snapshot). For a consistent view, snapshot first and use
  /// [_NativeSnapshot.queryIndexed].
  Future<List<RawEntry>> queryIndexed({
    required String table,
    required ByteKey start,
    required ByteKey end,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.queryIndexed(
        table: table,
        indexTable: indexTable,
        start: start.bytes,
        end: end.bytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<RawEntry>> queryFilteredLimited({
    required String table,
    required List<int> predicateBytes,
    int? limit,
    int offset = 0,
  }) async {
    try {
      final pairs = await _worker.queryFilteredLimited(
        table: table,
        predicateBytes: predicateBytes,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<RawEntry>> querySorted({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortSpecBytes,
    int? limit,
    int offset = 0,
  }) async {
    try {
      final pairs = await _worker.querySorted(
        table: table,
        predicateBytes: predicateBytes,
        sortSpecBytes: sortSpecBytes,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<RawEntry>> queryIndexedLimited({
    required String table,
    required ByteKey start,
    required ByteKey end,
    required List<int> predicateBytes,
    bool covered = false,
    int? limit,
    int offset = 0,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.queryIndexedLimited(
        table: table,
        indexTable: indexTable,
        start: start.bytes,
        end: end.bytes,
        predicateBytes: predicateBytes,
        covered: covered,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<RawEntry>> queryIndexedOrdered({
    required String table,
    required ByteKey start,
    required ByteKey end,
    required List<int> predicateBytes,
    required String sortField,
    required bool eqBounded,
    bool descending = false,
    bool covered = false,
    int? limit,
    int offset = 0,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.queryIndexedOrdered(
        table: table,
        indexTable: indexTable,
        start: start.bytes,
        end: end.bytes,
        predicateBytes: predicateBytes,
        sortField: sortField,
        eqBounded: eqBounded,
        descending: descending,
        covered: covered,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<RawEntry>> queryIndexedMulti({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    bool covered = false,
    int? limit,
    int offset = 0,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.queryIndexedMulti(
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
        covered: covered,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<List<int>>> queryIndexedDistinct({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    required String field,
    bool covered = false,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      return await _worker.queryIndexedDistinct(
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
        field: field,
        covered: covered,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<int> queryIndexedCount({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    bool covered = false,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      return await _worker.queryIndexedCount(
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
        covered: covered,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<int> queryFilteredCount({
    required String table,
    required List<int> predicateBytes,
  }) async {
    try {
      return await _worker.queryFilteredCount(
        table: table,
        predicateBytes: predicateBytes,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  Future<List<List<int>>> queryFilteredDistinct({
    required String table,
    required List<int> predicateBytes,
    required String field,
  }) async {
    try {
      return await _worker.queryFilteredDistinct(
        table: table,
        predicateBytes: predicateBytes,
        field: field,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// step 2: full-scan with a pushed predicate (no snapshot). Scans
  /// every row in [table], evaluates [predicateBytes] against each row's
  /// encoded bytes IN RUST (decoding only the referenced fields), and returns
  /// only the matching `(recordId → row)` pairs in one boundary crossing.
  /// Non-matching rows are never decoded in Dart.
  Future<List<RawEntry>> queryFiltered({
    required String table,
    required List<int> predicateBytes,
  }) async {
    try {
      final pairs = await _worker.queryFiltered(
        table: table,
        predicateBytes: predicateBytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<bool> tableExists(String table) async =>
      (await tables()).contains(table);

  @override
  Future<List<String>> tables() async {
    try {
      return await _worker.tables();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<int> lastCommitSeq() async {
    try {
      return (await _worker.commitSequence()).toInt();
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  @override
  Future<void> close() async {
    for (final id in List<int>.of(_openSnapshots)) {
      try {
        await _worker.dropSnapshot(id);
      } catch (_) {
        // Best effort: the worker may already be gone; the redb database is
        // torn down with the worker regardless.
      }
    }
    _openSnapshots.clear();
    await _worker.close();
  }

  static Op _toWireOp(RawOp op) => switch (op) {
    RawPut(:final table, :final key, :final value) => Op(
      op: OpKind.put,
      table: table,
      key: key.bytes,
      value: value is Uint8List ? value : Uint8List.fromList(value),
    ),
    RawDelete(:final table, :final key) => Op(
      op: OpKind.delete,
      table: table,
      key: key.bytes,
    ),
    RawDeleteRange(:final table, :final start, :final end) => Op(
      op: OpKind.deleteRange,
      table: table,
      start: start.bytes,
      end: end.bytes,
    ),
    RawClear(:final table) => Op(op: OpKind.clear, table: table),
  };
}

class NativeRawSnapshot implements RawSnapshot {
  NativeRawSnapshot(this._worker, this._snapshotId, {required this.onDispose})
    : _token = _SnapshotToken(_worker, _snapshotId) {
    _finalizer.attach(this, _token, detach: this);
  }

  /// Releases the worker-side MVCC read transaction when the snapshot object
  /// is garbage collected, so a long-lived database that creates many short
  /// snapshots never accumulates held redb read transactions.
  static final Finalizer<_SnapshotToken> _finalizer = Finalizer<_SnapshotToken>(
    (token) {
      token.worker.dropSnapshotUnawaited(token.id);
    },
  );

  final NativeWorkerClient _worker;
  final int _snapshotId;
  final void Function() onDispose;
  final _SnapshotToken _token;
  bool _disposed = false;

  /// Deterministically releases the worker-side snapshot. Idempotent.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    onDispose();
    try {
      await _worker.dropSnapshot(_snapshotId);
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  @override
  Future<List<int>?> read(String table, ByteKey key) async {
    try {
      return await _worker.snapshotGet(
        snapshot: _snapshotId,
        table: table,
        key: key.bytes,
      );
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  @override
  Future<List<RawEntry>> scan(
    String table, {
    ByteKey? start,
    ByteKey? end,
    bool startInclusive = true,
    bool endInclusive = true,
  }) async {
    if (!startInclusive || !endInclusive) {
      final entries = await scanAll(table);
      return entries.where((entry) {
        final afterStart =
            start == null ||
            entry.key.compareTo(start) > 0 ||
            (startInclusive && entry.key == start);
        final beforeEnd =
            end == null ||
            entry.key.compareTo(end) < 0 ||
            (endInclusive && entry.key == end);
        return afterStart && beforeEnd;
      }).toList();
    }
    try {
      final pairs = await _worker.snapshotRangeScan(
        snapshot: _snapshotId,
        table: table,
        start: start?.bytes,
        end: end?.bytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  @override
  Future<List<RawEntry>> scanAll(String table) async {
    try {
      final pairs = await _worker.snapshotRangeScan(
        snapshot: _snapshotId,
        table: table,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// native query fast path, snapshot-bound: the index→row join
  /// observes the same consistent committed state as the snapshot's other
  /// reads. See [NativeRawBackend.queryIndexed] for the semantics.
  Future<List<RawEntry>> queryIndexed({
    required String table,
    required ByteKey start,
    required ByteKey end,
    String indexTable = geckoIndexTable,
  }) async {
    // coverage:ignore-start no longer called kept as public API surface
    try {
      final pairs = await _worker.snapshotQueryIndexed(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        start: start.bytes,
        end: end.bytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(error);
    }
    // coverage:ignore-end
  }

  /// step 2, snapshot-bound: the full scan + predicate evaluation
  /// observe the snapshot's consistent committed state. See
  /// [NativeRawBackend.queryFiltered] for the semantics.
  Future<List<RawEntry>> queryFiltered({
    required String table,
    required List<int> predicateBytes,
  }) async {
    try {
      final pairs = await _worker.snapshotQueryFiltered(
        snapshot: _snapshotId,
        table: table,
        predicateBytes: predicateBytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// batched point-read, snapshot-bound — all reads observe one
  /// consistent committed state. See [NativeRawBackend.getMany].
  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) async {
    try {
      final pairs = await _worker.snapshotGetMany(
        snapshot: _snapshotId,
        table: table,
        keys: [for (final k in keys) k.bytes],
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// aggregate pushdown, snapshot-bound. See
  /// [NativeRawBackend.queryFilteredCount].
  Future<int> queryFilteredCount({
    required String table,
    required List<int> predicateBytes,
  }) async {
    try {
      return await _worker.snapshotQueryFilteredCount(
        snapshot: _snapshotId,
        table: table,
        predicateBytes: predicateBytes,
      );
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// aggregate pushdown, snapshot-bound. See
  /// [NativeRawBackend.queryFilteredDistinct].
  Future<List<List<int>>> queryFilteredDistinct({
    required String table,
    required List<int> predicateBytes,
    required String field,
  }) async {
    try {
      return await _worker.snapshotQueryFilteredDistinct(
        snapshot: _snapshotId,
        table: table,
        predicateBytes: predicateBytes,
        field: field,
      );
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// snapshot-bound parent lookup with Rust-side FK extraction.
  Future<RawEntry?> relationshipParent({
    required String childTable,
    required ByteKey childKey,
    required String parentTable,
    required String foreignKeyField,
  }) async {
    try {
      final pair = await _worker.snapshotRelationshipParent(
        snapshot: _snapshotId,
        childTable: childTable,
        childKey: childKey.bytes,
        parentTable: parentTable,
        foreignKeyField: foreignKeyField,
      );
      return pair == null ? null : RawEntry(ByteKey(pair.$1), pair.$2);
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// /snapshot-bound child retrieval using Rust FK matching. The
  /// worker classifies matching rows by FK and returns them grouped by parent
  /// id, so Dart never re-decodes every candidate row to bucket it.
  Future<List<GroupedChildren>> relationshipChildren({
    required String childTable,
    required String foreignKeyField,
    required List<ByteKey> parentIds,
    required List<(ByteKey, ByteKey)> indexRanges,
    List<int> predicateBytes = const [1, 0],
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final groups = await _worker.snapshotRelationshipChildren(
        snapshot: _snapshotId,
        childTable: childTable,
        foreignKeyField: foreignKeyField,
        parentIds: [for (final id in parentIds) id.bytes],
        indexTable: indexTable,
        indexRanges: [
          for (final range in indexRanges) (range.$1.bytes, range.$2.bytes),
        ],
        predicateBytes: predicateBytes,
      );
      return [
        for (final group in groups)
          GroupedChildren(
            parentId: ByteKey(group.$1),
            entries: [
              for (final pair in group.$2) RawEntry(ByteKey(pair.$1), pair.$2),
            ],
          ),
      ];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// snapshot-bound many-to-many join ID retrieval.
  Future<List<List<int>>> relationshipJoinIds({
    required String joinTable,
    required String field,
    required ByteKey wantedId,
  }) async {
    try {
      return await _worker.snapshotRelationshipJoinIds(
        snapshot: _snapshotId,
        joinTable: joinTable,
        field: field,
        wantedId: wantedId.bytes,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// full-scan + predicate with an early LIMIT/OFFSET, snapshot-bound.
  /// Returns at most [limit] matching rows after skipping [offset], stopping
  /// the scan as soon as the window fills.
  Future<List<RawEntry>> queryFilteredLimited({
    required String table,
    required List<int> predicateBytes,
    int? limit,
    int offset = 0,
  }) async {
    try {
      final pairs = await _worker.snapshotQueryFilteredLimited(
        snapshot: _snapshotId,
        table: table,
        predicateBytes: predicateBytes,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// counts matching rows from durable-index candidates without
  /// transferring primary rows to Dart.
  Future<int> queryIndexedCount({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    bool covered = false,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      return await _worker.snapshotQueryIndexedCount(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
        covered: covered,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// extracts only the requested field bytes from durable-index
  /// candidates. Dart performs the final decode and insertion-order dedup.
  Future<List<List<int>>> queryIndexedDistinct({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    required String field,
    bool covered = false,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      return await _worker.snapshotQueryIndexedDistinct(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
        field: field,
        covered: covered,
      );
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// intersects multiple durable-index candidate ranges in Rust and
  /// rechecks the complete predicate in the same MVCC snapshot.
  Future<List<RawEntry>> queryIndexedMulti({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    bool covered = false,
    int? limit,
    int offset = 0,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.snapshotQueryIndexedMulti(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
        covered: covered,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// index-served query with an early LIMIT/OFFSET, snapshot-bound.
  Future<List<RawEntry>> queryIndexedLimited({
    required String table,
    required ByteKey start,
    required ByteKey end,
    required List<int> predicateBytes,
    bool covered = false,
    int? limit,
    int offset = 0,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.snapshotQueryIndexedLimited(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        start: start.bytes,
        end: end.bytes,
        predicateBytes: predicateBytes,
        covered: covered,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// full-scan + top-K sort, snapshot-bound. Returns the
  /// `[offset, offset+limit)` window ordered by [sortSpecBytes] (a Rust port
  /// of Dart `compareRows`); the full candidate set is never materialized.
  Future<List<RawEntry>> querySorted({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortSpecBytes,
    int? limit,
    int offset = 0,
  }) async {
    try {
      final pairs = await _worker.snapshotQuerySorted(
        snapshot: _snapshotId,
        table: table,
        predicateBytes: predicateBytes,
        sortSpecBytes: sortSpecBytes,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }

  /// index-ordered early-stop sort, snapshot-bound. Streams the durable
  /// index range `[start..=end]` in index-key order, applies [predicateBytes],
  /// and stops once `offset + limit` matches are collected. [eqBounded] marks
  /// an equality bound on [sortField] (index-key order is correct for either
  /// direction); when false the range covers all values of [sortField]
  /// (ascending only; missing-field rows are appended if the window is not
  /// filled).
  Future<List<RawEntry>> queryIndexedOrdered({
    required String table,
    required ByteKey start,
    required ByteKey end,
    required List<int> predicateBytes,
    required String sortField,
    required bool eqBounded,
    bool descending = false,
    bool covered = false,
    int? limit,
    int offset = 0,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.snapshotQueryIndexedOrdered(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        start: start.bytes,
        end: end.bytes,
        predicateBytes: predicateBytes,
        sortField: sortField,
        eqBounded: eqBounded,
        descending: descending,
        covered: covered,
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(
        error,
      ); // coverage:ignore-line defensive error translation
    }
  }
}

class _SnapshotToken {
  _SnapshotToken(this.worker, this.id);
  final NativeWorkerClient worker;
  final int id;
}
