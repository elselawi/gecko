// Focused native-snapshot and error-path coverage (/ ).
//
// The differential suites exercise the happy paths of the MVCC snapshot
// machinery. This file deterministically exercises the remaining branches:
// non-inclusive scans through a native snapshot, explicit snapshot disposal,
// `lastCommitSeq`, the backend error mapping paths (all operations after the
// worker is finalized), and the close-time drain of open snapshots.
import 'dart:io';

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
  final nativePath = _nativeLibraryPath(_repoRoot());
  late Directory tempDir;
  late String path;
  late NativeRawBackend backend;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-snap-');
    path = '${tempDir.path}${Platform.pathSeparator}db.redb';
    backend = await NativeRawBackend.open(path, nativeLibraryPath: nativePath);
  });

  tearDown(() async {
    await backend.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'native snapshot supports non-inclusive scans and explicit dispose',
    () async {
      await backend.applyBatch([
        for (var i = 1; i <= 5; i++) RawPut('t', ByteKey([i]), [i]),
      ]);
      final snap = await backend.snapshot();
      final exclusiveEnd = await snap.scan(
        't',
        start: ByteKey([2]),
        end: ByteKey([4]),
        endInclusive: false,
      );
      expect(exclusiveEnd.map((e) => e.key.bytes).toList(), [
        [2],
        [3],
      ]);
      final exclusiveStart = await snap.scan(
        't',
        start: ByteKey([2]),
        end: ByteKey([4]),
        startInclusive: false,
      );
      expect(exclusiveStart.map((e) => e.key.bytes).toList(), [
        [3],
        [4],
      ]);
      await snap.dispose();
    },
  );

  test('lastCommitSeq reports the persisted LSN after engine writes', () async {
    final engine = RawEngine(backend);
    try {
      await engine.rawPut('t', ByteKey([1]), [1]);
      await engine.rawPut('t', ByteKey([2]), [2]);
      // The engine persists the LSN into __gecko_sync_meta; the backend reads
      // it back through its own snapshot.
      expect(await backend.lastCommitSeq(), 2);
    } finally {
      await engine.dispose();
    }
  });

  test('close drains open, undisposed snapshots', () async {
    // Create snapshots and deliberately leave them undisposed: close() must
    // drop them all so no read transaction outlives the backend.
    final snap1 = await backend.snapshot();
    final snap2 = await backend.snapshot();
    await snap1.read('t', ByteKey([1]));
    expect(await snap2.scanAll('t'), isEmpty);
    await backend.close();
    // A fresh backend can reopen the same file (no held lock).
    final reopened = await NativeRawBackend.open(
      path,
      nativeLibraryPath: nativePath,
    );
    await reopened.close();
  });

  test('all operations after worker teardown fail with typed errors', () async {
    await backend.applyBatch([
      RawPut('t', ByteKey([1]), [1]),
    ]);
    final snap = await backend.snapshot();
    // Tear the worker down deterministically through the seam.
    await backend.disposeForTest();

    // Every subsequent backend operation maps to a typed GeckoError rather
    // than hanging or escaping as an untyped exception.
    await expectLater(backend.tables(), throwsA(isA<GeckoError>()));
    await expectLater(
      backend.applyBatch([
        RawPut('t', ByteKey([2]), [2]),
      ]),
      throwsA(isA<GeckoError>()),
    );
    await expectLater(backend.snapshot(), throwsA(isA<GeckoError>()));
    await expectLater(backend.lastCommitSeq(), throwsA(isA<GeckoError>()));
    await expectLater(snap.read('t', ByteKey([1])), throwsA(isA<GeckoError>()));
    await expectLater(snap.scanAll('t'), throwsA(isA<GeckoError>()));
    await expectLater(
      snap.scan('t', start: ByteKey([0]), end: ByteKey([9])),
      throwsA(isA<GeckoError>()),
    );
    await expectLater(snap.dispose(), throwsA(isA<GeckoError>()));
    // Idempotent: a second dispose is a no-op (already released locally).
    await snap.dispose();
  });
}
