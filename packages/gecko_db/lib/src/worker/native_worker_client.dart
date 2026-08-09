/// Dedicated Dart-isolate client for the native FRB worker.
///
/// The `NativeWorker` opaque handle is created and used only inside the
/// spawned isolate. The caller isolate exchanges plain, sendable values over
/// a small request/response protocol and never owns an FFI transaction handle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../errors/errors.dart';
import '../errors/native_error.dart';
import '../native/generated/api.dart';
import '../native/generated/worker.dart' show StorageStats;
import '../native/native_resolver.dart' show bundledArtifactPath;
import '../wire/compatibility.dart';
import '../native/generated/frb_generated.dart';

class NativeWorkerClient {
  NativeWorkerClient._(this._isolate, this._receivePort)
    : _subscription = _receivePort.listen(null) {
    _subscription.onData(_handleMessage);
  }

  final Isolate _isolate;
  final ReceivePort _receivePort;
  late final StreamSubscription<Object?> _subscription;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextRequest = 0;
  SendPort? _commandPort;
  bool _closed = false;
  bool _workerAlive = false;
  String? _workerIsolateName;
  final Completer<void> _workerExited = Completer<void>();

  static final Finalizer<_FinalizerToken> _finalizer =
      Finalizer<_FinalizerToken>(_finalizerCallback);

  /// Sends the teardown request to the worker isolate. Kept as a static
  /// callback so the deterministic test seam ([debugFinalize]) exercises
  /// exactly the same path a real GC-driven finalization would take.
  static void _finalizerCallback(_FinalizerToken token) {
    token.commandPort.send(const <Object?>['finalize']);
  }

  static Future<NativeWorkerClient> open({
    required String path,
    required bool readOnly,
    String? nativeLibraryPath,
    List<int>? physicalKey,
    int physicalKeyGeneration = 1,
  }) async {
    final receivePort = ReceivePort();
    final isolate =
        await Isolate.spawn<List<Object?>>(_nativeWorkerMain, <Object?>[
          receivePort.sendPort,
          path,
          readOnly,
          nativeLibraryPath,
          physicalKey,
          physicalKeyGeneration,
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
    _closed = true;
    _finalizer.detach(this);
    final commandPort = _commandPort;
    if (commandPort != null) {
      _finalizerCallback(_FinalizerToken(commandPort));
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
    await _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  Future<int> applyBatch(List<int> encodedOps) async =>
      _asInt(await _request('applyBatch', <Object?>[encodedOps]));

  Future<List<int>?> get({
    required String table,
    required List<int> key,
  }) async {
    final result = await _request('get', <Object?>[table, key]);
    return result == null ? null : List<int>.from(result as List);
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

  /// Releases [snapshot] in the worker (idempotent).
  Future<void> dropSnapshot(int snapshot) async {
    await _request('dropSnapshot', <Object?>[snapshot]);
  }

  /// Fire-and-forget snapshot release used by the `Finalizer` path: sends the
  /// request without registering a pending completer, so a finalizer can
  /// release a snapshot even after the worker is unreachable without leaking.
  void dropSnapshotUnawaited(int snapshot) {
    final commandPort = _commandPort;
    if (_closed || commandPort == null) return;
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
    await _subscription.cancel();
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  Future<Object?> _request(String operation, List<Object?> arguments) {
    final commandPort = _commandPort;
    if (_closed || commandPort == null) {
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
          _finalizer.attach(this, _FinalizerToken(_commandPort!), detach: this);
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
  const _FinalizerToken(this.commandPort);
  final SendPort commandPort;
}

Future<void> _nativeWorkerMain(List<Object?> args) async {
  final parent = args[0] as SendPort;
  final path = args[1] as String;
  final readOnly = args[2] as bool;
  final nativeLibraryPath = args[3] as String?;
  final physicalKey = args[4] as List<int>?;
  final physicalKeyGeneration = args[5] as int;
  final isolateName = Isolate.current.debugName ?? 'gecko-native-worker';
  try {
    // No-build-steps fallback: when no explicit library path is given, use the
    // artifact bundled in the package (built by `tool/build_artifacts.dart
    // bundle`) before falling back to the FRB default loader.
    final effectiveLibraryPath =
        nativeLibraryPath ?? await bundledArtifactPath();
    await RustLib.init(
      externalLibrary: effectiveLibraryPath == null
          ? null
          : ExternalLibrary.open(effectiveLibraryPath),
    );
    final worker = physicalKey == null
        ? await NativeWorker.open(path: path, readOnly: readOnly)
        : await NativeWorker.openEncrypted(
            path: path,
            key: physicalKey,
            keyGen: physicalKeyGeneration,
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
          final result = await _dispatch(worker, operation, arguments);
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

BigInt _asBigInt(Object? value) {
  if (value is BigInt) return value;
  return BigInt.from(value as int);
}

Future<Object?> _dispatch(
  NativeWorker worker,
  String operation,
  List<Object?> arguments,
) async {
  switch (operation) {
    case 'applyBatch':
      return (await worker.applyBatch(
        encodedOps: List<int>.from(arguments[0] as List),
      )).toString();
    case 'get':
      final value = await worker.get_(
        table: arguments[0] as String,
        key: List<int>.from(arguments[1] as List),
      );
      return value?.toList();
    case 'rangeScan':
      final pairs = await worker.rangeScan(
        table: arguments[0] as String,
        start: arguments[1] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[1] as List)),
        end: arguments[2] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[2] as List)),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'tables':
      return await worker.tables();
    case 'createSnapshot':
      return (await worker.createSnapshot()).toString();
    case 'snapshotGet':
      final value = await worker.snapshotGet(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        key: Uint8List.fromList(List<int>.from(arguments[2] as List)),
      );
      return value?.toList();
    case 'snapshotRangeScan':
      final pairs = await worker.snapshotRangeScan(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        start: arguments[2] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[2] as List)),
        end: arguments[3] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[3] as List)),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'dropSnapshot':
      await worker.dropSnapshot(snapshot: _asBigInt(arguments[0]));
      return null;
    case 'commitSequence':
      return (await worker.commitSequence()).toString();
    case 'compact':
      return await worker.compact();
    case 'storageStats':
      return await worker.storageStats();
    case 'compatibilityHandshake':
      return await worker.compatibilityHandshake();
    case 'close':
      await worker.close();
      return null;
    default:
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Unknown native worker operation',
      );
  }
}
