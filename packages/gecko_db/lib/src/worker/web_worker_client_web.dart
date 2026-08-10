/// Web implementation of the web-worker client.
///
/// Spawns a Dedicated Worker (`new Worker(workerUrl)`) and speaks the JSON
/// protocol from `web_worker_protocol.dart`. Byte arrays travel as base64
/// (`{"b64": ...}`); `StorageStats` as a tagged map.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../native/generated/worker.dart' show StorageStats;
import 'web_worker_protocol.dart';

/// Interop constructor for the JS `Worker` global.
@JS('Worker')
extension type _WorkerCtor._(JSObject _) implements JSObject {
  external factory _WorkerCtor(String url);
}

class WebWorkerClient {
  WebWorkerClient._(this._worker, this._handshake) {
    _subscription = _messages.stream.listen(_handleMessage);
  }

  /// The JS `Worker` object.
  final JSObject _worker;

  /// The compatibility handshake returned by the `open` response (populated on
  /// ready).
  String _handshake;

  final StreamController<Object?> _messages = StreamController<Object?>();
  late final StreamSubscription<Object?> _subscription;
  final Map<Object?, Completer<Map<String, Object?>>> _pending = {};
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _booted = Completer<void>();
  int _nextRequestId = 0;
  bool _closed = false;

  /// Spawns [workerUrl] as a Dedicated Worker, opens the database at [path]
  /// inside it (persisting via OPFS unless the path is `:memory:`), and waits
  /// for the `ready` handshake.
  static Future<WebWorkerClient> open({
    required String workerUrl,
    required String path,
    bool readOnly = false,
    List<int>? encryptionKey,
    int encryptionKeyGeneration = 1,
  }) async {
    final worker = _WorkerCtor(workerUrl);
    final client = WebWorkerClient._(worker, '');

    // Wire the worker's onmessage/onerror to the stream.
    worker.setProperty(
      'onmessage'.toJS,
      ((JSAny? event) {
        final data = (event as JSObject).getProperty('data'.toJS);
        final text = data.dartify();
        if (text is String) client._messages.add(text);
      }).toJS,
    );
    worker.setProperty(
      'onerror'.toJS,
      ((JSAny? error) {
        final message = (error as JSObject).getProperty('message'.toJS);
        final text = message.dartify();
        client._messages.add(<String, Object?>{
          'type': 'startupError',
          'error': text is String ? text : 'worker error',
        });
      }).toJS,
    );

    // The worker signals boot only after its onmessage handler is installed;
    // sending `open` earlier would drop the message (the worker loads glue +
    // wasm + FRB before it can receive anything).
    await client._booted.future.timeout(const Duration(seconds: 30));

    final requestId = client._nextId();
    final completer = Completer<Map<String, Object?>>();
    client._pending[requestId] = completer;
    client._send(<String, Object?>{
      'cmd': 'open',
      'id': requestId,
      'path': path,
      'readOnly': readOnly,
      if (encryptionKey != null) 'encryptionKey': encryptionKey,
      'encryptionKeyGeneration': encryptionKeyGeneration,
    });

    final response = await completer.future.timeout(
      const Duration(seconds: 30),
    );
    if (response['type'] == 'ready') {
      // Return the SAME client: the onmessage callback still feeds this
      // instance's message stream, so a second instance would never see
      // responses.
      client._handshake = response['handshake'] as String? ?? '';
      return client;
    }
    throw StateError(response['error'] as String? ?? 'open failed');
  }

  void _send(Map<String, Object?> request) {
    _worker.callMethod('postMessage'.toJS, encodeRequest(request).toJS);
  }

  int _nextId() => ++_nextRequestId;

  void _handleMessage(Object? message) {
    if (message is! String) return;
    final decoded = decodeMessage(message);
    final id = decoded['id'];
    final type = decoded['type'] as String?;

    if (type == 'booted') {
      if (!_booted.isCompleted) _booted.complete();
      return;
    }

    if (type == 'startupError') {
      // Fail every pending request (including an in-flight open) with the
      // worker's startup error so callers don't hang until a timeout.
      final error = decoded['error'] as String? ?? 'worker startup error';
      for (final completer in _pending.values) {
        completer.complete(<String, Object?>{
          'type': 'response',
          'ok': false,
          'error': error,
        });
      }
      _pending.clear();
      if (!_ready.isCompleted) _ready.completeError(StateError(error));
      return;
    }

    final completer = id == null ? null : _pending.remove(id);
    if (completer != null) {
      completer.complete(decoded);
      return;
    }
    if (type == 'closed') {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<Object?> _request(String operation, List<Object?> arguments) async {
    if (_closed) {
      throw StateError('Web worker client is closed');
    }
    final id = _nextId();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send(<String, Object?>{
      'cmd': 'request',
      'id': id,
      'op': operation,
      'args': <Object?>[for (final arg in arguments) encodeValue(arg)],
    });
    final response = await completer.future;
    if (response['ok'] == true) {
      return decodeValue(response['value']);
    }
    throw StateError(response['error'] as String? ?? 'operation failed');
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    return int.parse(value.toString());
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

  Future<int> createSnapshot() async =>
      _asInt(await _request('createSnapshot', const <Object?>[]));

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

  Future<void> dropSnapshot(int snapshot) async {
    await _request('dropSnapshot', <Object?>[snapshot]);
  }

  Future<int> commitSequence() async =>
      _asInt(await _request('commitSequence', const <Object?>[]));

  Future<bool> compact() async =>
      await _request('compact', const <Object?>[]) as bool;

  Future<StorageStats> storageStats() async =>
      await _request('storageStats', const <Object?>[]) as StorageStats;

  Future<String> compatibilityHandshake() async =>
      await _request('compatibilityHandshake', const <Object?>[]) as String;

  /// The handshake received at open (empty if the worker did not include one).
  String get handshake => _handshake;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _send(<String, Object?>{'cmd': 'close'});
    } catch (_) {
      // The worker may already be gone; teardown is best effort.
    }
    await _subscription.cancel();
    await _messages.close();
  }
}
