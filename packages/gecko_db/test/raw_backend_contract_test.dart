// Shared behavioral contract for every raw backend available in the current
// process. The exact same tests run against the in-memory backend and the
// native file-backed backend (Workstream 2), so no backend can hide
// behavior behind a test that only exercises one implementation.
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

  void runContractSuite(
    String label,
    Future<RawBackend> Function() open,
    Future<void> Function(RawBackend)? cleanup,
  ) {
    group('raw backend contract: $label', () {
      late RawBackend backend;

      setUp(() async {
        backend = await open();
      });

      tearDown(() async {
        await backend.close();
        if (cleanup != null) {
          await cleanup(backend);
        }
      });

      test('put/read/delete sequence is deterministic', () async {
        final key = ByteKey([1]);
        await backend.applyBatch([
          RawPut('t', key, [9]),
        ]);
        var snapshot = await backend.snapshot();
        expect(await snapshot.read('t', key), [9]);

        await backend.applyBatch([RawDelete('t', key)]);
        snapshot = await backend.snapshot();
        expect(await snapshot.read('t', key), isNull);
      });

      test('range ordering and bounds are shared backend semantics', () async {
        for (final i in [1, 2, 3]) {
          await backend.applyBatch([
            RawPut('t', ByteKey([i]), [i]),
          ]);
        }
        final snapshot = await backend.snapshot();
        final entries = await snapshot.scan(
          't',
          start: ByteKey([1]),
          end: ByteKey([3]),
          endInclusive: false,
        );
        expect(entries.map((entry) => entry.key.bytes), [
          [1],
          [2],
        ]);
      });

      test('multi-op commit is all-or-nothing from a fresh snapshot', () async {
        await backend.applyBatch([
          RawPut('a', ByteKey([1]), [1]),
          RawPut('a', ByteKey([2]), [2]),
          RawPut('b', ByteKey([1]), [3]),
        ]);
        final snapshot = await backend.snapshot();
        expect(await snapshot.scanAll('a'), hasLength(2));
        expect(await snapshot.scanAll('b'), hasLength(1));
      });

      test('delete-range removes exactly the inclusive bounds', () async {
        for (final i in [1, 2, 3, 4]) {
          await backend.applyBatch([
            RawPut('t', ByteKey([i]), [i]),
          ]);
        }
        await backend.applyBatch([
          RawDeleteRange('t', ByteKey([2]), ByteKey([3])),
        ]);
        final snapshot = await backend.snapshot();
        final remaining = (await snapshot.scanAll('t'))
            .map((entry) => entry.key.bytes)
            .toList();
        expect(remaining, [
          [1],
          [4],
        ]);
      });

      test('clear empties only the target table', () async {
        await backend.applyBatch([
          RawPut('a', ByteKey([1]), [1]),
          RawPut('b', ByteKey([1]), [2]),
        ]);
        await backend.applyBatch([RawClear('a')]);
        final snapshot = await backend.snapshot();
        expect(await snapshot.scanAll('a'), isEmpty);
        expect(await snapshot.scanAll('b'), hasLength(1));
      });

      test('tableExists and tables reflect committed tables', () async {
        expect(await backend.tableExists('t'), isFalse);
        await backend.applyBatch([RawPut('t', ByteKey([1]), [1])]);
        expect(await backend.tableExists('t'), isTrue);
        expect(await backend.tables(), contains('t'));
      });

      test('empty scans return an empty list, never null', () async {
        final snapshot = await backend.snapshot();
        expect(await snapshot.scanAll('missing'), isEmpty);
        expect(await snapshot.scan('missing'), isEmpty);
      });

      test('snapshots are immutable point-in-time views', () async {
        await backend.applyBatch([RawPut('t', ByteKey([1]), [1])]);
        final old = await backend.snapshot();
        await backend.applyBatch([RawPut('t', ByteKey([1]), [2])]);
        // The old snapshot still sees the pre-write value.
        expect(await old.read('t', ByteKey([1])), [1]);
        final fresh = await backend.snapshot();
        expect(await fresh.read('t', ByteKey([1])), [2]);
      });
    });
  }

  runContractSuite(
    'in-memory',
    () async => InMemoryBackend(),
    null,
  );

  Directory? nativeDir;
  runContractSuite(
    'native file',
    () async {
      nativeDir = await Directory.systemTemp.createTemp('gecko-contract-');
      return NativeRawBackend.open(
        '${nativeDir!.path}${Platform.pathSeparator}db.redb',
        nativeLibraryPath: nativePath,
      );
    },
    (_) async {
      final dir = nativeDir;
      nativeDir = null;
      if (dir != null) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // Best effort: the backend is already closed, so any failure here
          // is an OS-level transient, not a leak in the contract.
        }
      }
    },
  );
}
