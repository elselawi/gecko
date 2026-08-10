/// Dedicated Dart-isolate client for the native FRB worker.
///
/// The `NativeWorker` opaque handle is created and used only inside the
/// spawned isolate. The caller isolate exchanges plain, sendable values over
/// a small request/response protocol and never owns an FFI transaction handle.
///
/// On the web there are no isolates/ports (`Isolate.spawn` with ports is
/// unsupported), and the wasm engine is single-threaded anyway, so the client
/// runs in *direct mode*: the same `NativeWorker` FRB handle is created and
/// serviced in the calling isolate, with requests dispatched straight to the
/// generated API. The request/response surface is identical.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import '../errors/errors.dart';
import '../errors/native_error.dart';
import '../native/generated/api.dart';
import '../native/generated/worker.dart' show StorageStats;
import '../native/native_resolver.dart' show isWeb;
import '../wire/compatibility.dart';
import '../native/generated/frb_generated.dart';
import '../native/external_library_loader.dart' show resolveExternalLibrary;
import '../native/opfs.dart' show registerOpfsHandle;
import 'native_dispatch.dart' show dispatchNativeWorker;

class NativeWorkerClient {
  NativeWorkerClient._(this._isolate, this._receivePort)
    : _subscription = _receivePort!.listen(null) {
    _subscription!.onData(_handleMessage);
  }

  // coverage:ignore-start web only validated live by the browser smoke suites
  // tool web smoke, not the VM test runner. isWeb is a compile time constant
  // false on the VM, so these branches never execute in dart test.

  /// Web direct-mode constructor: no isolate, no ports. The worker is adopted
  /// via [_adoptWebWorker] after the FRB handle is created and verified.
  NativeWorkerClient._webDirect() : _isolate = null, _receivePort = null {
    _subscription = null;
  }

  // coverage:ignore-end

  final Isolate? _isolate;
  final ReceivePort? _receivePort;
  StreamSubscription<Object?>? _subscription;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextRequest = 0;
  SendPort? _commandPort;
  bool _closed = false;
  bool _workerAlive = false;
  String? _workerIsolateName;
  final Completer<void> _workerExited = Completer<void>();

  /// The FRB worker handle. On native this lives inside the spawned isolate;
  /// on the web it is held here and serviced directly.
  NativeWorker? _worker;

  static final Finalizer<_FinalizerToken> _finalizer =
      Finalizer<_FinalizerToken>(_finalizerCallback);

  /// Sends the teardown request to the worker isolate (native) or closes the
  /// FRB worker (web). Kept as a static callback so the deterministic test
  /// seam ([debugFinalize]) exercises exactly the same path a real GC-driven
  /// finalization would take.
  static void _finalizerCallback(_FinalizerToken token) {
    // coverage:ignore-start web
    final worker = token.worker;
    if (worker != null) {
      // Web: best-effort close of the in-isolate FRB worker.
      try {
        unawaited(worker.close());
      } catch (_) {}
      return;
    }
    // coverage:ignore-end web
    final commandPort = token.commandPort;
    if (commandPort != null) {
      commandPort.send(const <Object?>['finalize']);
    }
  }

  static Future<NativeWorkerClient> open({
    required String path,
    required bool readOnly,
    String? nativeLibraryPath,
    List<int>? encryptionKey,
    int encryptionKeyGeneration = 1,
  }) async {
    // coverage:ignore-start web
    if (isWeb) {
      return _openWeb(
        path: path,
        readOnly: readOnly,
        nativeLibraryPath: nativeLibraryPath,
        encryptionKey: encryptionKey,
        encryptionKeyGeneration: encryptionKeyGeneration,
      );
    }
    // coverage:ignore-end web
    final receivePort = ReceivePort();
    final isolate =
        await Isolate.spawn<List<Object?>>(_nativeWorkerMain, <Object?>[
          receivePort.sendPort,
          path,
          readOnly,
          nativeLibraryPath,
          encryptionKey,
          encryptionKeyGeneration,
        ], errorsAreFatal: false);
    final client = NativeWorkerClient._(isolate, receivePort);
    try {
      await client._ready.future.timeout(const Duration(seconds: 30));
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  /// Web direct-mode open: initializes the FRB wasm engine and creates the
  /// `NativeWorker` in the calling isolate (the wasm build is single-threaded,
  /// so a spawned isolate would add nothing). The compatibility handshake is
  /// validated exactly like the native worker path.
  // coverage:ignore-start web
  static Future<NativeWorkerClient> _openWeb({
    required String path,
    required bool readOnly,
    String? nativeLibraryPath,
    List<int>? encryptionKey,
    int encryptionKeyGeneration = 1,
  }) async {
    final client = NativeWorkerClient._webDirect();
    try {
      await RustLib.init(
        externalLibrary: await resolveExternalLibrary(
          nativeLibraryPath: nativeLibraryPath,
        ),
      );
      // File-backed web databases persist in the Origin Private File System.
      // Sync access handles are worker-only, so outside a Worker (or in a
      // non-secure context) this fails with a typed error before touching
      // anything.
      if (encryptionKey != null) {
        throw const GeckoError(
          GeckoErrorType.invalidOperation,
          'Physical encryption is not supported on Web',
        );
      }
      final opfsError = await registerOpfsHandle(path);
      if (opfsError != null) {
        throw GeckoError(
          GeckoErrorType.invalidOperation,
          opfsError,
          details: <String, Object?>{'path': path},
        );
      }
      final worker = encryptionKey == null
          ? await NativeWorker.open(path: path, readOnly: readOnly)
          : await NativeWorker.openEncrypted(
              path: path,
              key: encryptionKey,
              keyGen: encryptionKeyGeneration,
            );
      final handshake = CompatibilityHandshake.decode(
        await worker.compatibilityHandshake(),
      );
      handshake.validateCompatibility();
      client._adoptWebWorker(worker);
      return client;
    } catch (error) {
      await client._closeWeb();
      rethrow;
    }
  }

  void _adoptWebWorker(NativeWorker worker) {
    _worker = worker;
    _workerIsolateName = 'gecko-native-worker (web, same isolate)';
    _workerAlive = true;
    if (!_ready.isCompleted) {
      _finalizer.attach(this, _FinalizerToken(null, worker), detach: this);
      _ready.complete();
    }
  }

  Future<void> _closeWeb() async {
    _closed = true;
    _finalizer.detach(this);
    final worker = _worker;
    _worker = null;
    if (worker != null) {
      try {
        await worker.close();
      } catch (_) {
        // Best effort teardown.
      }
    }
    _workerAlive = false;
    if (!_workerExited.isCompleted) _workerExited.complete();
  }

  // coverage:ignore-end web

  /// Whether the worker isolate completed its startup handshake and has not
  /// yet reported termination. Test/qualification surface.
  bool get isWorkerAlive => _workerAlive;

  /// The worker isolate's own name as seen from inside the isolate, proving
  /// reads and writes execute on a separate isolate rather than the caller's.
  /// Test/qualification surface.
  String? get workerIsolateName => _workerIsolateName;

  /// Test/qualification surface (ADR-0005): runs the [`Finalizer`] teardown
  /// path deterministically instead of waiting for an actual garbage
  /// collection (which is inherently non-deterministic). The worker isolate
  /// is asked to shut down and its termination is observed before this
  /// returns. After this call the client is closed; subsequent requests fail
  /// with a typed error.
  Future<void> debugFinalize() async {
    if (_closed) return;
    // coverage:ignore-start web
    if (isWeb) {
      await _closeWeb();
      return;
    }
    // coverage:ignore-end web
    _closed = true;
    _finalizer.detach(this);
    final commandPort = _commandPort;
    if (commandPort != null) {
      _finalizerCallback(_FinalizerToken(commandPort, null));
    }
    await _workerExited.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
    _workerAlive = false;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const GeckoError(
            GeckoErrorType.invalidOperation,
            'Native worker finalized before completing the request',
          ),
        );
      }
    }
    _pending.clear();
    await _subscription?.cancel();
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  Future<int> applyBatch(
    List<int> encodedOps, {
    List<(String, List<String>)> indexDefinitions = const [],
  }) async => _asInt(
    await _request('applyBatch', <Object?>[encodedOps, indexDefinitions]),
  );

  /// M7: verifies and atomically repairs durable index entries for [table].
  Future<void> repairIndex({
    required String table,
    required List<String> fields,
  }) async {
    await _request('repairIndex', <Object?>[table, fields]);
  }

  Future<List<int>?> get({
    required String table,
    required List<int> key,
  }) async {
    final result = await _request('get', <Object?>[table, key]);
    return result == null ? null : List<int>.from(result as List);
  }

  /// M3: batched point-read, snapshot-bound — fetches N keys in ONE read
  /// transaction, returning `(key, row)` pairs for keys that exist. Absent
  /// keys are omitted; a missing table is an empty result, never an error.
  /// Kills the relationship N+1 (one boundary crossing instead of one per id).
  Future<List<(List<int>, List<int>)>> snapshotGetMany({
    required int snapshot,
    required String table,
    required List<List<int>> keys,
  }) async {
    final result = await _request('snapshotGetMany', <Object?>[
      snapshot,
      table,
      keys,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  Future<List<(List<int>, List<int>)>> rangeScan({
    required String table,
    List<int>? start,
    List<int>? end,
  }) async {
    final result = await _request('rangeScan', <Object?>[table, start, end]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  Future<List<String>> tables() async {
    final result = await _request('tables', const <Object?>[]);
    return [for (final table in (result as List)) table as String];
  }

  /// Creates a point-in-time MVCC snapshot in the worker, returning its id.
  Future<int> createSnapshot() async =>
      _asInt(await _request('createSnapshot', const <Object?>[]));

  /// Reads a key through [snapshot] (a point-in-time MVCC view).
  Future<List<int>?> snapshotGet({
    required int snapshot,
    required String table,
    required List<int> key,
  }) async {
    final result = await _request('snapshotGet', <Object?>[
      snapshot,
      table,
      key,
    ]);
    return result == null ? null : List<int>.from(result as List);
  }

  /// Scans a range through [snapshot] (a point-in-time MVCC view).
  Future<List<(List<int>, List<int>)>> snapshotRangeScan({
    required int snapshot,
    required String table,
    List<int>? start,
    List<int>? end,
  }) async {
    final result = await _request('snapshotRangeScan', <Object?>[
      snapshot,
      table,
      start,
      end,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// Phase 2 native query fast path (no snapshot): range-scans the durable
  /// index table [indexTable] for keys in `[start..=end]`, joins each entry's
  /// value (the user-table row key) back to its row in [table], and returns
  /// the `(recordId, row)` pairs in one boundary crossing. Eliminates the
  /// Dart-side N+1 point reads. [start]/[end] are the already codec-encoded
  /// `[table, field, value, ...]` key bounds.
  Future<List<(List<int>, List<int>)>> queryIndexed({
    required String table,
    required String indexTable,
    required List<int> start,
    required List<int> end,
  }) async {
    final result = await _request('queryIndexed', <Object?>[
      table,
      indexTable,
      start,
      end,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// Snapshot-bound variant of [queryIndexed]: the index→row join observes
  /// one consistent committed state.
  Future<List<(List<int>, List<int>)>> snapshotQueryIndexed({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<int> start,
    required List<int> end,
  }) async {
    final result = await _request('snapshotQueryIndexed', <Object?>[
      snapshot,
      table,
      indexTable,
      start,
      end,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// Phase 2 step 2: full-scan with a pushed predicate (no snapshot). Scans
  /// every row in [table], evaluates [predicateBytes] against each row's
  /// encoded bytes IN RUST (decoding only the referenced fields), and returns
  /// only the matching `(recordId, row)` pairs in one boundary crossing.
  /// Non-matching rows are never decoded in Dart. [predicateBytes] is the
  /// serialized `Predicate` payload (see `predicate_codec.dart`).
  Future<List<(List<int>, List<int>)>> queryFiltered({
    required String table,
    required List<int> predicateBytes,
  }) async {
    final result = await _request('queryFiltered', <Object?>[
      table,
      predicateBytes,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// Snapshot-bound variant of [queryFiltered]: the scan + predicate
  /// evaluation observe one consistent committed state.
  Future<List<(List<int>, List<int>)>> snapshotQueryFiltered({
    required int snapshot,
    required String table,
    required List<int> predicateBytes,
  }) async {
    final result = await _request('snapshotQueryFiltered', <Object?>[
      snapshot,
      table,
      predicateBytes,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// M3: aggregate pushdown, snapshot-bound — counts matching rows WITHOUT
  /// transferring them. Scans [table], evaluates [predicateBytes] against each
  /// row's bytes IN RUST, and returns only the count. A `count()` query no
  /// longer pays the decode + transfer cost of every matching row.
  Future<int> snapshotQueryFilteredCount({
    required int snapshot,
    required String table,
    required List<int> predicateBytes,
  }) async {
    return _asInt(
      await _request('snapshotQueryFilteredCount', <Object?>[
        snapshot,
        table,
        predicateBytes,
      ]),
    );
  }

  /// M3: aggregate pushdown, snapshot-bound — emits only the bytes of [field]
  /// for each matching row, so a `distinct(field)` query transfers one value
  /// per row instead of the whole row. Returns a list of raw encoded
  /// `RowValue` bytes (self-delimiting); the caller decodes and dedups them.
  /// Rows where [field] is absent are omitted (matches Dart `distinct()`).
  Future<List<List<int>>> snapshotQueryFilteredDistinct({
    required int snapshot,
    required String table,
    required List<int> predicateBytes,
    required String field,
  }) async {
    final result = await _request('snapshotQueryFilteredDistinct', <Object?>[
      snapshot,
      table,
      predicateBytes,
      field,
    ]);
    return [for (final b in (result as List)) List<int>.from(b as List)];
  }

  /// M7.1: snapshot-bound parent lookup with Rust-side FK extraction.
  Future<(List<int>, List<int>)?> snapshotRelationshipParent({
    required int snapshot,
    required String childTable,
    required List<int> childKey,
    required String parentTable,
    required String foreignKeyField,
  }) async {
    final result = await _request('snapshotRelationshipParent', <Object?>[
      snapshot,
      childTable,
      childKey,
      parentTable,
      foreignKeyField,
    ]);
    if (result == null) return null;
    final pair = result as List;
    return (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List));
  }

  /// M7.1: snapshot-bound child retrieval with Rust-side FK matching.
  Future<List<(List<int>, List<int>)>> snapshotRelationshipChildren({
    required int snapshot,
    required String childTable,
    required String foreignKeyField,
    required List<List<int>> parentIds,
    required String indexTable,
    required List<(List<int>, List<int>)> indexRanges,
    required List<int> predicateBytes,
  }) async {
    final result = await _request('snapshotRelationshipChildren', <Object?>[
      snapshot,
      childTable,
      foreignKeyField,
      parentIds,
      indexTable,
      [
        for (final range in indexRanges) <Object?>[range.$1, range.$2],
      ],
      predicateBytes,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// M7.1: snapshot-bound many-to-many join ID retrieval.
  Future<List<List<int>>> snapshotRelationshipJoinIds({
    required int snapshot,
    required String joinTable,
    required String field,
    required List<int> wantedId,
  }) async {
    final result = await _request('snapshotRelationshipJoinIds', <Object?>[
      snapshot,
      joinTable,
      field,
      wantedId,
    ]);
    return [
      for (final bytes in (result as List)) List<int>.from(bytes as List),
    ];
  }

  /// M4: full-scan + predicate with an early LIMIT/OFFSET (snapshot-bound).
  /// Returns at most [limit] matching rows after skipping [offset], stopping
  /// the scan as soon as the window fills.
  Future<List<(List<int>, List<int>)>> snapshotQueryFilteredLimited({
    required int snapshot,
    required String table,
    required List<int> predicateBytes,
    int? limit,
    int offset = 0,
  }) async {
    final result = await _request('snapshotQueryFilteredLimited', <Object?>[
      snapshot,
      table,
      predicateBytes,
      limit,
      offset,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// M5: snapshot-bound intersection of multiple durable-index candidate
  /// ranges. Rust rechecks the complete predicate before returning rows.
  Future<List<(List<int>, List<int>)>> snapshotQueryIndexedMulti({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<(List<int>, List<int>)> ranges,
    required List<int> predicateBytes,
  }) async {
    final result = await _request('snapshotQueryIndexedMulti', <Object?>[
      snapshot,
      table,
      indexTable,
      [
        for (final range in ranges) <Object?>[range.$1, range.$2],
      ],
      predicateBytes,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// M7.1: snapshot-bound count over durable-index candidates.
  Future<int> snapshotQueryIndexedCount({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<(List<int>, List<int>)> ranges,
    required List<int> predicateBytes,
  }) async {
    return _asInt(
      await _request('snapshotQueryIndexedCount', <Object?>[
        snapshot,
        table,
        indexTable,
        [
          for (final range in ranges) <Object?>[range.$1, range.$2],
        ],
        predicateBytes,
      ]),
    );
  }

  /// M7.1: snapshot-bound distinct field extraction over durable-index
  /// candidates. Returns encoded field values; Dart performs final dedup.
  Future<List<List<int>>> snapshotQueryIndexedDistinct({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<(List<int>, List<int>)> ranges,
    required List<int> predicateBytes,
    required String field,
  }) async {
    final result = await _request('snapshotQueryIndexedDistinct', <Object?>[
      snapshot,
      table,
      indexTable,
      [
        for (final range in ranges) <Object?>[range.$1, range.$2],
      ],
      predicateBytes,
      field,
    ]);
    return [
      for (final bytes in (result as List)) List<int>.from(bytes as List),
    ];
  }

  /// M4: index-served query with an early LIMIT/OFFSET (snapshot-bound).
  Future<List<(List<int>, List<int>)>> snapshotQueryIndexedLimited({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<int> start,
    required List<int> end,
    required List<int> predicateBytes,
    int? limit,
    int offset = 0,
  }) async {
    final result = await _request('snapshotQueryIndexedLimited', <Object?>[
      snapshot,
      table,
      indexTable,
      start,
      end,
      predicateBytes,
      limit,
      offset,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// M4: full-scan + top-K sort (snapshot-bound). Returns the
  /// `[offset, offset+limit)` window ordered by [sortSpecBytes].
  Future<List<(List<int>, List<int>)>> snapshotQuerySorted({
    required int snapshot,
    required String table,
    required List<int> predicateBytes,
    required List<int> sortSpecBytes,
    int? limit,
    int offset = 0,
  }) async {
    final result = await _request('snapshotQuerySorted', <Object?>[
      snapshot,
      table,
      predicateBytes,
      sortSpecBytes,
      limit,
      offset,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// M4: index-ordered early-stop sort (snapshot-bound). Streams the durable
  /// index range in index-key order and stops once `offset + limit` matches
  /// are collected.
  Future<List<(List<int>, List<int>)>> snapshotQueryIndexedOrdered({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<int> start,
    required List<int> end,
    required List<int> predicateBytes,
    required String sortField,
    required bool eqBounded,
    int? limit,
    int offset = 0,
  }) async {
    final result = await _request('snapshotQueryIndexedOrdered', <Object?>[
      snapshot,
      table,
      indexTable,
      start,
      end,
      predicateBytes,
      sortField,
      eqBounded,
      limit,
      offset,
    ]);
    return [
      for (final pair in (result as List))
        (List<int>.from(pair[0] as List), List<int>.from(pair[1] as List)),
    ];
  }

  /// Releases [snapshot] in the worker (idempotent).
  Future<void> dropSnapshot(int snapshot) async {
    await _request('dropSnapshot', <Object?>[snapshot]);
  }

  /// Fire-and-forget snapshot release used by the `Finalizer` path: sends the
  /// request without registering a pending completer, so a finalizer can
  /// release a snapshot even after the worker is unreachable without leaking.
  void dropSnapshotUnawaited(int snapshot) {
    if (_closed) return;
    // coverage:ignore-start web
    if (isWeb) {
      final worker = _worker;
      if (worker == null) return;
      unawaited(
        dispatchNativeWorker(worker, 'dropSnapshot', <Object?>[
          snapshot,
        ]).catchError((Object _) => null),
      );
      return;
    }
    // coverage:ignore-end web
    final commandPort = _commandPort;
    if (commandPort == null) return;
    commandPort.send(<Object?>[
      'request',
      ++_nextRequest,
      'dropSnapshot',
      <Object?>[snapshot],
    ]);
  }

  Future<int> commitSequence() async =>
      _asInt(await _request('commitSequence', const <Object?>[]));

  /// Compacts the database file in place (Workstream 5). Returns true when
  /// space was reclaimed, false when already fully compacted. The worker
  /// rejects the request with a typed error if any MVCC snapshot is open.
  Future<bool> compact() async =>
      await _request('compact', const <Object?>[]) as bool;

  /// Reports physical/logical size and health counters (Workstream 5).
  Future<StorageStats> storageStats() async =>
      await _request('storageStats', const <Object?>[]) as StorageStats;

  Future<String> compatibilityHandshake() async =>
      await _request('compatibilityHandshake', const <Object?>[]) as String;

  Future<void> close() async {
    if (_closed) return;
    // coverage:ignore-start web
    if (isWeb) {
      await _closeWeb();
      return;
    }
    // coverage:ignore-end web
    _closed = true;
    _finalizer.detach(this);
    final commandPort = _commandPort;
    if (commandPort != null) {
      try {
        await _requestOnPort(
          commandPort,
          'close',
          const <Object?>[],
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        // The isolate may already have terminated; cleanup remains best effort.
      }
    }
    // Wait for the worker to acknowledge termination so `isWorkerAlive`
    // reports a deterministic false after `close()`. The timeout guards
    // against a crashed worker that can no longer respond.
    await _workerExited.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    _workerAlive = false;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const GeckoError(
            GeckoErrorType.invalidOperation,
            'Native worker closed before completing the request',
          ),
        );
      }
    }
    _pending.clear();
    await _subscription?.cancel();
    _receivePort?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  Future<Object?> _request(String operation, List<Object?> arguments) {
    if (_closed) {
      return Future<Object?>.error(
        const GeckoError(
          GeckoErrorType.invalidOperation,
          'Native worker is not available',
        ),
      );
    }
    // coverage:ignore-start web
    if (isWeb) {
      final worker = _worker;
      if (worker == null) {
        return Future<Object?>.error(
          const GeckoError(
            GeckoErrorType.invalidOperation,
            'Native worker is not available',
          ),
        );
      }
      // Direct mode: dispatch straight to the FRB worker in this isolate.
      // Errors propagate as futures so callers treat them uniformly.
      try {
        return Future<Object?>(
          () => dispatchNativeWorker(worker, operation, arguments),
        );
      } catch (error) {
        return Future<Object?>.error(error);
      }
    }
    // coverage:ignore-end web
    final commandPort = _commandPort;
    if (commandPort == null) {
      return Future<Object?>.error(
        const GeckoError(
          GeckoErrorType.invalidOperation,
          'Native worker is not available',
        ),
      );
    }
    return _requestOnPort(commandPort, operation, arguments);
  }

  Future<Object?> _requestOnPort(
    SendPort commandPort,
    String operation,
    List<Object?> arguments,
  ) {
    final id = ++_nextRequest;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    commandPort.send(<Object?>['request', id, operation, arguments]);
    return completer.future;
  }

  void _handleMessage(Object? message) {
    if (message is! List || message.isEmpty) return;
    switch (message[0]) {
      case 'ready':
        _commandPort = message[1] as SendPort;
        _workerIsolateName = message[2] as String?;
        _workerAlive = true;
        if (!_ready.isCompleted) {
          _finalizer.attach(
            this,
            _FinalizerToken(_commandPort!, null),
            detach: this,
          );
          _ready.complete();
        }
        break;
      case 'startupError':
        if (!_ready.isCompleted) {
          _ready.completeError(mapNativeError(message[1] as Object));
        }
        break;
      case 'workerExit':
        _workerAlive = false;
        if (!_workerExited.isCompleted) _workerExited.complete();
        break;
      case 'response':
        final id = message[1] as int;
        final completer = _pending.remove(id);
        if (completer == null || completer.isCompleted) return;
        if (message[2] == true) {
          completer.complete(message[3]);
        } else {
          completer.completeError(mapNativeError(message[3] as Object));
        }
        break;
    }
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    return int.parse(value.toString());
  }
}

class _FinalizerToken {
  const _FinalizerToken(this.commandPort, this.worker);
  final SendPort? commandPort;
  final NativeWorker? worker;
}

Future<void> _nativeWorkerMain(List<Object?> args) async {
  final parent = args[0] as SendPort;
  final path = args[1] as String;
  final readOnly = args[2] as bool;
  final nativeLibraryPath = args[3] as String?;
  final encryptionKey = args[4] as List<int>?;
  final encryptionKeyGeneration = args[5] as int;
  final isolateName = Isolate.current.debugName ?? 'gecko-native-worker';
  try {
    // Platform-specific library resolution: FFI dynamic library on native,
    // wasm-bindgen glue over HTTP on the web (see native_library_loader*).
    await RustLib.init(
      externalLibrary: await resolveExternalLibrary(
        nativeLibraryPath: nativeLibraryPath,
      ),
    );
    final worker = encryptionKey == null
        ? await NativeWorker.open(path: path, readOnly: readOnly)
        : await NativeWorker.openEncrypted(
            path: path,
            key: encryptionKey,
            keyGen: encryptionKeyGeneration,
          );
    final handshake = CompatibilityHandshake.decode(
      await worker.compatibilityHandshake(),
    );
    handshake.validateCompatibility();

    final commands = ReceivePort();
    parent.send(<Object?>['ready', commands.sendPort, isolateName]);
    try {
      await for (final raw in commands) {
        if (raw is List && raw.length == 1 && raw[0] == 'finalize') {
          await worker.close();
          commands.close();
          break;
        }
        if (raw is! List || raw.length < 4 || raw[0] != 'request') continue;
        final id = raw[1] as int;
        final operation = raw[2] as String;
        final arguments = List<Object?>.from(raw[3] as List);
        try {
          final result = await dispatchNativeWorker(
            worker,
            operation,
            arguments,
          );
          parent.send(<Object?>['response', id, true, result]);
          if (operation == 'close') {
            commands.close();
            break;
          }
        } catch (error) {
          parent.send(<Object?>[
            'response',
            id,
            false,
            jsonEncode(mapNativeError(error).toJson()),
          ]);
        }
      }
    } finally {
      _sendWorkerExit(parent);
    }
  } catch (error) {
    parent.send(<Object?>[
      'startupError',
      jsonEncode(mapNativeError(error).toJson()),
    ]);
    _sendWorkerExit(parent);
  }
}

void _sendWorkerExit(SendPort parent) {
  try {
    parent.send(const <Object?>['workerExit']);
  } catch (_) {
    // The parent may already have closed its port; teardown is best effort.
  }
}
