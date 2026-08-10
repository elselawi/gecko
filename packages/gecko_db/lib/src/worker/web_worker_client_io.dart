/// VM stub for the web-worker client: Web Workers only exist on the web.
library;

import '../backend/raw_backend.dart';
import '../native/generated/worker.dart' show StorageStats;

/// Throws on the VM — the web-worker client is web-only (see the web
/// implementation in `web_worker_client_web.dart`).
Never _unsupported() => throw UnsupportedError(
  'WebWorkerClient requires the web platform (dart:js_interop). On the VM, '
  'use the isolate-based native worker client instead.',
);

// coverage:ignore-start web only validated live by the browser smoke suites
// (tool/web_smoke). On the VM every method throws _unsupported, so these
// stubs are never exercised by `dart test` and would drag down the aggregate
// line coverage without adding any real protection.
class WebWorkerClient {
  WebWorkerClient._();

  static Future<WebWorkerClient> open({
    required String workerUrl,
    required String path,
    bool readOnly = false,
    List<int>? encryptionKey,
    int encryptionKeyGeneration = 1,
  }) async {
    _unsupported();
  }

  Future<List<RegistryDelta>> applyBatch(
    List<int> encodedOps, {
    List<List<Object?>> indexDefinitions = const [],
  }) async => _unsupported();
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  }) async => _unsupported();
  Future<void> unregisterLiveQuery(int id) async => _unsupported();
  Future<int> liveQueryCount() async => _unsupported();
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
  Future<List<(List<int>, List<int>)>> queryIndexed({
    required String table,
    required String indexTable,
    required List<int> start,
    required List<int> end,
  }) async => _unsupported();
  Future<List<(List<int>, List<int>)>> snapshotQueryIndexed({
    required int snapshot,
    required String table,
    required String indexTable,
    required List<int> start,
    required List<int> end,
  }) async => _unsupported();
  Future<List<(List<int>, List<int>)>> queryFiltered({
    required String table,
    required List<int> predicateBytes,
  }) async => _unsupported();
  Future<List<(List<int>, List<int>)>> snapshotQueryFiltered({
    required int snapshot,
    required String table,
    required List<int> predicateBytes,
  }) async => _unsupported();
  Future<void> dropSnapshot(int snapshot) async => _unsupported();
  Future<int> commitSequence() async => _unsupported();
  Future<bool> compact() async => _unsupported();
  Future<StorageStats> storageStats() async => _unsupported();
  Future<String> compatibilityHandshake() async => _unsupported();
  Future<void> close() async => _unsupported();
}

// coverage:ignore-end web
