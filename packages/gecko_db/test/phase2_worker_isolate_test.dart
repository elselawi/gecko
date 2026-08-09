// Worker-isolate and Finalizer liveness tests (Workstream 1 hardening).
//
// These tests exercise the dedicated FRB worker isolate introduced by
// ADR-0003/ADR-0005:
//   * reads/writes execute on a separate isolate (never the caller's),
//   * `close()` tears the worker down deterministically,
//   * the `Finalizer` teardown path shuts the worker down deterministically
//     through the test seam (`NativeRawBackend.disposeForTest`), because a
//     real GC-driven finalization is inherently non-deterministic.
import 'dart:io';
import 'dart:isolate';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-worker-');
    path = '${tempDir.path}${Platform.pathSeparator}database.redb';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<DatabaseImpl> open() => DatabaseImpl.open(
    path,
    useInMemory: false,
    config: DatabaseConfig(nativeLibraryPath: nativePath),
  );

  test('reads and writes execute on a dedicated worker isolate', () async {
    final db = await open();
    final backend = db.engine.backend as NativeRawBackend;
    try {
      // Startup handshake observed: the worker isolate reported its own name
      // and is alive.
      expect(backend.workerAlive, isTrue);
      expect(backend.workerIsolateName, isNotNull);
      expect(
        backend.workerIsolateName,
        isNot(Isolate.current.debugName),
        reason: 'the native worker must not run on the caller isolate',
      );

      // A round trip across the isolate boundary completes and is consistent.
      const codec = DefaultWireCodec();
      final key = ByteKey(codec.encode('live'));
      await db.engine.rawPut('items', key, codec.encode('value'));
      final raw = await db.rawGet('items', key);
      expect(codec.decode(raw!), 'value');
    } finally {
      await db.close();
    }
  });

  test('close tears the worker isolate down deterministically', () async {
    final db = await open();
    final backend = db.engine.backend as NativeRawBackend;
    expect(backend.workerAlive, isTrue);
    await db.close();
    expect(
      backend.workerAlive,
      isFalse,
      reason: 'close() must observe worker termination, not just fire it',
    );
    // Subsequent requests fail with a typed error instead of hanging. The
    // closure form is required: `DatabaseImpl.rawGet` is not `async`, so a
    // closed database throws synchronously.
    await expectLater(
      () => db.rawGet('items', ByteKey(const [1, 2, 3])),
      throwsA(isA<GeckoError>()),
    );
  });

  test('Finalizer teardown path shuts the worker down deterministically', () async {
    final db = await open();
    final backend = db.engine.backend as NativeRawBackend;
    expect(backend.workerAlive, isTrue);

    // Exercise the exact Finalizer callback path without waiting for GC.
    await backend.disposeForTest();

    expect(
      backend.workerAlive,
      isFalse,
      reason: 'the finalizer path must terminate the worker isolate',
    );
    // The worker is gone: requests fail fast with a typed error.
    await expectLater(
      () => db.rawGet('items', ByteKey(const [1, 2, 3])),
      throwsA(isA<GeckoError>()),
    );
    // Close remains idempotent after the finalizer already tore things down.
    await db.close();
  });
}
