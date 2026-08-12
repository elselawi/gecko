/// Web implementation of the web-worker client.
///
/// Spawns a Dedicated Worker (`new Worker(workerUrl)`) and speaks the JSON
/// protocol from `web_worker_protocol.dart`. Byte arrays travel as base64
/// (`{"b64": ...}`); `StorageStats` as a tagged map.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../backend/byte_key.dart';
import '../backend/raw_backend.dart';
import '../native/generated/api.dart' show PreparedChange;
import '../native/generated/worker.dart' show StorageStats;
import 'web_worker_protocol.dart';

/// Interop constructor for the JS `Worker` global.
@JS('Worker')
extension type _WorkerCtor._(JSObject _) implements JSObject {
  external factory _WorkerCtor(String url);
}

/// Builds a JS `Uint8Array` from [bytes] (the transport's transferable
/// byte-leaf representation).
JSObject _newUint8Array(Uint8List bytes) {
  final ctor = globalContext.getProperty('Uint8Array'.toJS) as JSFunction;
  final arr = ctor.callAsFunction(null, bytes.length.toJS) as JSObject;
  for (var i = 0; i < bytes.length; i++) {
    arr.setProperty(i.toString().toJS, bytes[i].toJS);
  }
  return arr;
}

/// Converts [message] (a map whose byte leaves are `{"bytes": Uint8List}`)
/// into a JS object, replacing byte leaves with JS `Uint8Array`s, and returns
/// the transfer list (their underlying `ArrayBuffer`s) for zero-copy
/// `postMessage`.
(JSObject, JSArray<JSAny?>) _jsifyBinary(Map<String, Object?> message) {
  final transferables = <JSAny?>[];
  JSAny? walk(Object? v) {
    if (v == null) return null;
    if (v is Map && v[bytesTag] is List<int>) {
      final arr = _newUint8Array(
        v[bytesTag] is Uint8List
            ? v[bytesTag] as Uint8List
            : Uint8List.fromList(v[bytesTag] as List<int>),
      );
      transferables.add(arr.getProperty('buffer'.toJS));
      return arr;
    }
    if (v is Map) {
      final obj = JSObject();
      for (final entry in v.entries) {
        obj.setProperty(entry.key.toString().toJS, walk(entry.value));
      }
      return obj;
    }
    if (v is List) {
      return <JSAny?>[for (final e in v) walk(e)].toJS;
    }
    if (v is String) return v.toJS;
    if (v is int) return v.toJS;
    if (v is bool) return v.toJS;
    if (v is double) return v.toJS;
    return v as JSAny?;
  }

  final root = JSObject();
  for (final entry in message.entries) {
    root.setProperty(entry.key.toJS, walk(entry.value));
  }
  return (root, transferables.toJS);
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
  /// inside it (persisting via OPFS), and waits for the `ready` handshake.
  static Future<WebWorkerClient> open({
    required String workerUrl,
    required String path,
    bool readOnly = false,
    List<int>? encryptionKey,
    int encryptionKeyGeneration = 1,
  }) async {
    final worker = _WorkerCtor(workerUrl);
    final client = WebWorkerClient._(worker, '');

    // Wire the worker's onmessage/onerror to the stream. Binary (structured)
    // messages arrive as JS objects and are delivered as maps; JSON
    // fallback messages arrive as strings.
    worker.setProperty(
      'onmessage'.toJS,
      ((JSAny? event) {
        final data = (event as JSObject).getProperty('data'.toJS);
        final decoded = data.dartify();
        if (decoded is String || decoded is Map) {
          client._messages.add(decoded);
        }
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
    // Binary channel (preferred): byte leaves travel as transferable
    // ArrayBuffers. Falls back to the JSON/base64 channel when the
    // environment cannot post binary messages.
    final binary = encodeRequestBinary(request);
    try {
      final (jsMessage, transferables) = _jsifyBinary(binary);
      _worker.callMethod('postMessage'.toJS, jsMessage, transferables);
    } catch (_) {
      _worker.callMethod('postMessage'.toJS, encodeRequest(request).toJS);
    }
  }

  int _nextId() => ++_nextRequestId;

  void _handleMessage(Object? message) {
    final decoded = decodeMessageBinary(message);
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
      'args': <Object?>[for (final arg in arguments) encodeValueBinary(arg)],
    });
    final response = await completer.future;
    if (response['ok'] == true) {
      return decodeValueBinary(response['value']);
    }
    throw StateError(response['error'] as String? ?? 'operation failed');
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is BigInt) return value.toInt();
    return int.parse(value.toString());
  }

  /// applies a batch and returns the reactive-registry deltas
  /// the worker produced for it. [changeLogMaxEntries] (0 = disabled) prunes
  /// the pending-sync change log in the same write transaction
  Future<ApplyBatchResult> applyBatch(
    List<int> encodedOps, {
    List<List<Object?>> indexDefinitions = const [],
    int changeLogMaxEntries = 0,
  }) async {
    final result =
        await _request('applyBatch', <Object?>[
              encodedOps,
              indexDefinitions,
              changeLogMaxEntries,
            ])
            as Map;
    return _decodeApplyBatchResult(result);
  }

  Future<ApplyBatchResult> applyPreparedBatch(
    List<int> encodedOps, {
    List<List<Object?>> indexDefinitions = const [],
    int changeLogMaxEntries = 0,
    List<String> previousOperationIndexes = const [],
    List<(BigInt, int)> putModes = const [],
    List<PreparedChange> changes = const [],
  }) async {
    final result =
        await _request('applyPreparedBatch', <Object?>[
              encodedOps,
              indexDefinitions,
              changeLogMaxEntries,
              previousOperationIndexes,
              [
                for (final (index, mode) in putModes)
                  <Object?>[index.toString(), mode],
              ],
              [
                for (final change in changes)
                  <String, Object?>{
                    'operationIndex': change.operationIndex.toString(),
                    'ordinal': change.ordinal.toString(),
                    'syncStateKey': change.syncStateKey,
                    'recordTemplate': change.recordTemplate,
                    'fillPreviousVersion': change.fillPreviousVersion,
                  },
              ],
            ])
            as Map;
    return _decodeApplyBatchResult(result);
  }

  ApplyBatchResult _decodeApplyBatchResult(Map<Object?, Object?> result) =>
      ApplyBatchResult(
        affected: const <(String, ByteKey)>{},
        sequence: int.parse(result['sequence'] as String),
        previousValues: [
          for (final value in result['previousValues'] as List)
            value == null ? null : List<int>.from(value as List),
        ],
        removedKeys: [
          for (final entry in result['removedKeys'] as List)
            (
              (entry as List)[0] as String,
              ByteKey(List<int>.from(entry[1] as List)),
            ),
        ],
        deltas: [
          for (final delta in result['deltas'] as List)
            RegistryDelta(
              id: int.parse((delta as Map)['id'] as String),
              added: _decodeEntries(delta['added'] as List),
              updated: _decodeEntries(delta['updated'] as List),
              removed: _decodeEntries(delta['removed'] as List),
              snapshot: _decodeEntries(delta['snapshot'] as List),
              unchanged: delta['unchanged'] as bool,
            ),
        ],
      );

  /// registers a live query with the worker's reactive
  /// registry, returning the registration id and initial result set.
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  }) async {
    final result =
        await _request('registerLiveQuery', <Object?>[
              table,
              predicateBytes,
              sortBytes,
              kind,
            ])
            as Map;
    return LiveQueryRegistration(
      id: int.parse(result['id'] as String),
      initial: _decodeEntries(result['initial'] as List),
    );
  }

  /// removes a live-query registration (idempotent).
  Future<void> unregisterLiveQuery(int id) async {
    await _request('unregisterLiveQuery', <Object?>[id.toString()]);
  }

  /// Number of active live-query registrations (diagnostics).
  Future<int> liveQueryCount() async {
    final result = await _request('liveQueryCount', const <Object?>[]);
    return int.parse(result as String);
  }

  /// aggregates pending local changes (dirty, non-remote, sorted by
  /// localMutationId) in Rust; returns (key, record) pairs for Dart to decode.
  Future<List<RawEntry>> pendingChanges() async {
    final result = await _request('pendingChanges', const <Object?>[]);
    return _decodeEntries(result);
  }

  /// Filters the sync-state table in Rust to the matching records.
  Future<List<RawEntry>> syncStateMatching(List<List<int>> matchers) async {
    final result = await _request('syncStateMatching', <Object?>[
      [for (final m in matchers) m],
    ]);
    return _decodeEntries(result);
  }

  /// Range-filtered `changesSince(lastSeq)` in Rust.
  Future<List<RawEntry>> changesSince(int seq) async {
    final result = await _request('changesSince', <Object?>[seq]);
    return _decodeEntries(result);
  }

  /// Attachment metadata whose parent row is missing (scan in Rust).
  Future<List<RawEntry>> orphanedAttachments() async {
    final result = await _request('orphanedAttachments', const <Object?>[]);
    return _decodeEntries(result);
  }

  /// Decodes a wire `[[keyBytes, valueBytes], ...]` list into [RawEntry]s.
  List<RawEntry> _decodeEntries(Object? raw) => [
    for (final pair in (raw as List))
      RawEntry(
        ByteKey(List<int>.from((pair as List)[0] as List)),
        List<int>.from(pair[1] as List),
      ),
  ];

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
