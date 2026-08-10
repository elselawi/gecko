/// FRB-backed native RawBackend adapter.
///
/// The adapter keeps Dart transaction handles out of FFI. Each mutation batch
/// is encoded once with the existing versioned `Op` contract and sent to the
/// Rust `NativeWorker`, which applies it in one redb write transaction.
library;

import 'dart:typed_data';

import '../errors/native_error.dart';
import '../namespaces.dart';
import '../native/generated/worker.dart' show StorageStats;
import '../wire/compatibility.dart';
import '../wire/op.dart';
import '../wire/wire_codec.dart';
import '../worker/native_worker_client.dart';
import 'byte_key.dart';
import 'raw_backend.dart';

/// A file-backed backend using the generated flutter_rust_bridge worker.
class NativeRawBackend implements RawBackend, DurableIndexRegistrar {
  NativeRawBackend._(this._worker, this._readOnly);

  final NativeWorkerClient _worker;
  final bool _readOnly;
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
  /// handshake. Test/qualification surface (ADR-0005).
  bool get workerAlive => _worker.isWorkerAlive;

  /// The worker isolate's own name, proving reads/writes execute off the
  /// caller's isolate. Test/qualification surface (ADR-0005).
  String? get workerIsolateName => _worker.workerIsolateName;

  /// Test/qualification surface (ADR-0005): runs the [`Finalizer`] teardown
  /// path deterministically (instead of waiting for garbage collection),
  /// after which the worker isolate is shut down and [workerAlive] is false.
  Future<void> disposeForTest() => _worker.debugFinalize();

  /// Number of MVCC snapshots currently held in the worker (open snapshot-
  /// bound cursors/transactions). Compaction refuses to run while this is
  /// non-zero.
  int get openSnapshotCount => _openSnapshots.length;

  /// Returns the current commit LSN (sequence number) via a single
  /// worker-isolate round trip with trivial Rust work. A perf-instrumentation
  /// probe (Phase 1 boundary benchmark): measures the isolate/port + FRB
  /// marshalling cost in isolation, not a storage operation.
  Future<int> commitSequenceProbe() async {
    try {
      return await _worker.commitSequence();
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// Compacts the database file in place (Workstream 5). Returns true when
  /// space was reclaimed. Requires no open snapshots and a writable database.
  Future<bool> compact() async {
    try {
      return await _worker.compact();
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// Reports physical/logical size and health counters from the worker.
  Future<StorageStats> storageStats() async {
    try {
      return await _worker.storageStats();
    } catch (error) {
      throw mapNativeError(error);
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
      throw mapNativeError(error);
    }
  }

  @override
  Future<Set<(String, ByteKey)>> applyBatch(RawBatch ops) async {
    final wireOps = <Op>[for (final op in ops) _toWireOp(op)];
    // Delete-range ops must report every key they actually remove so the
    // affected-set contract matches the in-memory backend exactly. The engine
    // is single-writer, so the pre-scan sees precisely the keys the batch is
    // about to delete (nothing can interleave between scan and apply).
    final preRemoved = <(String, ByteKey)>{};
    final deleteRanges = [
      for (final op in ops)
        if (op is RawDeleteRange) op,
    ];
    if (deleteRanges.isNotEmpty) {
      final snap = await snapshot();
      for (final range in deleteRanges) {
        for (final entry in await snap.scan(
          range.table,
          start: range.start,
          end: range.end,
        )) {
          preRemoved.add((range.table, entry.key));
        }
      }
    }
    try {
      await _worker.applyBatch(
        Op.encodeBatch(wireOps),
        indexDefinitions: [
          for (final entry in _durableIndexes.entries)
            (entry.key, entry.value),
        ],
      );
    } catch (error) {
      throw mapNativeError(error);
    }
    return {
      for (final op in ops)
        switch (op) {
          RawPut(:final table, :final key) => (table, key),
          RawDelete(:final table, :final key) => (table, key),
          RawDeleteRange(:final table, :final start) => (table, start),
          RawClear(:final table) => (table, ByteKey(const [])),
        },
      ...preRemoved,
    };
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

  /// M7: verifies and atomically repairs the durable index entries for [table]
  /// from the primary rows in Rust. Native queries do not rebuild a Dart index.
  Future<void> repairIndex({
    required String table,
    required List<String> fields,
  }) async {
    try {
      await _worker.repairIndex(table: table, fields: fields);
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// Phase 2 native query fast path: range-scans the durable `__gecko_index`
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
      throw mapNativeError(error);
    }
  }

  /// Phase 2 step 2: full-scan with a pushed predicate (no snapshot). Scans
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
      throw mapNativeError(error);
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
      throw mapNativeError(error);
    }
  }

  @override
  Future<int> lastCommitSeq() async {
    try {
      final snapshot = await this.snapshot();
      final raw = await snapshot.read(
        geckoSyncMetaTable,
        ByteKey(const DefaultWireCodec().encode(geckoLsnKey)),
      );
      if (raw == null) return 0;
      return (const DefaultWireCodec().decode(raw) as int?) ?? 0;
    } catch (error) {
      throw mapNativeError(error);
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
      key: Uint8List.fromList(key.bytes),
      value: Uint8List.fromList(value),
    ),
    RawDelete(:final table, :final key) => Op(
      op: OpKind.delete,
      table: table,
      key: Uint8List.fromList(key.bytes),
    ),
    RawDeleteRange(:final table, :final start, :final end) => Op(
      op: OpKind.deleteRange,
      table: table,
      start: Uint8List.fromList(start.bytes),
      end: Uint8List.fromList(end.bytes),
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

  /// Phase 2 native query fast path, snapshot-bound: the index→row join
  /// observes the same consistent committed state as the snapshot's other
  /// reads. See [NativeRawBackend.queryIndexed] for the semantics.
  Future<List<RawEntry>> queryIndexed({
    required String table,
    required ByteKey start,
    required ByteKey end,
    String indexTable = geckoIndexTable,
  }) async {
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
  }

  /// Phase 2 step 2, snapshot-bound: the full scan + predicate evaluation
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
      throw mapNativeError(error);
    }
  }

  /// M3: batched point-read, snapshot-bound — all reads observe one
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
      throw mapNativeError(error);
    }
  }

  /// M3: aggregate pushdown, snapshot-bound. See
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

  /// M3: aggregate pushdown, snapshot-bound. See
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

  /// M4: full-scan + predicate with an early LIMIT/OFFSET, snapshot-bound.
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
      throw mapNativeError(error);
    }
  }

  /// M5: intersects multiple durable-index candidate ranges in Rust and
  /// rechecks the complete predicate in the same MVCC snapshot.
  Future<List<RawEntry>> queryIndexedMulti({
    required String table,
    required List<(ByteKey, ByteKey)> ranges,
    required List<int> predicateBytes,
    String indexTable = geckoIndexTable,
  }) async {
    try {
      final pairs = await _worker.snapshotQueryIndexedMulti(
        snapshot: _snapshotId,
        table: table,
        indexTable: indexTable,
        ranges: [for (final range in ranges) (range.$1.bytes, range.$2.bytes)],
        predicateBytes: predicateBytes,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// M4: index-served query with an early LIMIT/OFFSET, snapshot-bound.
  Future<List<RawEntry>> queryIndexedLimited({
    required String table,
    required ByteKey start,
    required ByteKey end,
    required List<int> predicateBytes,
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
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(error);
    }
  }

  /// M4: full-scan + top-K sort, snapshot-bound. Returns the
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
      throw mapNativeError(error);
    }
  }

  /// M4: index-ordered early-stop sort, snapshot-bound. Streams the durable
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
        limit: limit,
        offset: offset,
      );
      return [for (final pair in pairs) RawEntry(ByteKey(pair.$1), pair.$2)];
    } catch (error) {
      throw mapNativeError(error);
    }
  }
}

class _SnapshotToken {
  _SnapshotToken(this.worker, this.id);
  final NativeWorkerClient worker;
  final int id;
}
