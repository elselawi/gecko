/// VM stub for the web-worker client: Web Workers only exist on the web.
library;

import '../native/generated/worker.dart' show StorageStats;

/// Throws on the VM — the web-worker client is web-only (see the web
/// implementation in `web_worker_client_web.dart`).
Never _unsupported() => throw UnsupportedError(
  'WebWorkerClient requires the web platform (dart:js_interop). On the VM, '
  'use the isolate-based native worker client instead.',
);

class WebWorkerClient {
  WebWorkerClient._();

  static Future<WebWorkerClient> open({
    required String workerUrl,
    required String path,
    bool readOnly = false,
    String? physicalKey,
    int physicalKeyGeneration = 1,
  }) async {
    _unsupported();
  }

  Future<int> applyBatch(List<int> encodedOps) async => _unsupported();
  Future<List<int>?> get({
    required String table,
    required List<int> key,
  }) async => _unsupported();
  Future<List<(List<int>, List<int>)>> rangeScan({
    required String table,
    List<int>? start,
    List<int>? end,
  }) async => _unsupported();
  Future<List<String>> tables() async => _unsupported();
  Future<int> createSnapshot() async => _unsupported();
  Future<List<int>?> snapshotGet({
    required int snapshot,
    required String table,
    required List<int> key,
  }) async => _unsupported();
  Future<List<(List<int>, List<int>)>> snapshotRangeScan({
    required int snapshot,
    required String table,
    List<int>? start,
    List<int>? end,
  }) async => _unsupported();
  Future<void> dropSnapshot(int snapshot) async => _unsupported();
  Future<int> commitSequence() async => _unsupported();
  Future<bool> compact() async => _unsupported();
  Future<StorageStats> storageStats() async => _unsupported();
  Future<String> compatibilityHandshake() async => _unsupported();
  Future<void> close() async => _unsupported();
}
