// Audit-driven lifecycle / open / config edge tests (audited-test-gaps 2.1).
//
// Each case pins a behavior the previous suite did not cover: read-only open
// of a brand-new path, close-blocks-until-writes-land on the public API,
// first-open-throws concurrency, path normalization, invalid path kinds, and
// config knob edge values.

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  Future<(Directory, String)> tempDb([String label = 'audit-lifecycle']) async {
    final directory = await Directory.systemTemp.createTemp('$label-');
    addTearDown(() => directory.delete(recursive: true));
    return (directory, '${directory.path}${Platform.pathSeparator}db.redb');
  }

  test('read-only open of a brand-new path fails with a typed error', () async {
    final (_, path) = await tempDb();
    // The store does not exist; a read-only open must not silently create it.
    await expectLater(
      DatabaseImpl.open(path, config: const DatabaseConfig(readOnly: true)),
      throwsA(isA<GeckoError>()),
    );
    // The failed open must not leak registry state.
    expect(DatabaseImpl.isOpenAt(path), isFalse);
    // The path must still be usable by a normal open afterwards.
    final db = await DatabaseImpl.open(path);
    await db.close();
    expect(DatabaseImpl.isOpenAt(path), isFalse);
  });

  test('close blocks until in-flight writes land (public API)', () async {
    final (_, path) = await tempDb('gecko-close-drain');
    final db = await DatabaseImpl.open(path);
    final codec = DefaultWireCodec();
    // Fire a burst of unawaited engine writes (each admitted to the write
    // gate synchronously), then close immediately. close() drains the gate,
    // so every admitted write must land before the close future completes.
    final writes = <Future<List<int>?>>[
      for (var i = 0; i < 50; i++)
        db.engine.rawPut(
          'items',
          ByteKey(codec.encode('k$i')),
          codec.encode({'n': i}),
        ),
    ];
    await db.close();
    final results = await Future.wait(writes);
    expect(results, hasLength(50));

    // Reopen: every write landed (close drained, did not abandon).
    final reopened = await DatabaseImpl.open(path);
    for (var i = 0; i < 50; i++) {
      final row = await reopened.rawGet('items', ByteKey(codec.encode('k$i')));
      expect(row, isNotNull, reason: 'write k$i must be durable after close');
    }
    await reopened.close();
  });

  test(
    'concurrent open where the first throws does not wedge the path',
    () async {
      final (_, path) = await tempDb();
      // First open fails (bad native library); the failed attempt must release
      // the opening latch so a subsequent open is not permanently stuck with
      // databaseAlreadyOpen.
      await expectLater(
        DatabaseImpl.open(
          path,
          config: const DatabaseConfig(nativeLibraryPath: 'missing.dll'),
        ),
        throwsA(isA<GeckoError>()),
      );
      expect(DatabaseImpl.isOpenAt(path), isFalse);
      // A follow-up open succeeds immediately (not wedged).
      final db = await DatabaseImpl.open(path);
      expect(DatabaseImpl.isOpenAt(path), isTrue);
      await db.close();
      expect(DatabaseImpl.isOpenAt(path), isFalse);
    },
  );

  test('close is idempotent and rejects operations after close', () async {
    final (_, path) = await tempDb();
    final db = await DatabaseImpl.open(path);
    await Future.wait([db.close(), db.close()]);
    expect(
      () => db.collection<Object?>(
        'items',
        toRow: (value) => value,
        fromRow: (row) => row,
      ),
      throwsA(isA<GeckoError>()),
    );
  });

  test(
    'same path with different spelling is a single open (normalization)',
    () async {
      final (directory, _) = await tempDb('gecko-norm');
      final path = '${directory.path}${Platform.pathSeparator}db.redb';
      final db = await DatabaseImpl.open(path);
      expect(DatabaseImpl.isOpenAt(path), isTrue);
      if (Platform.isWindows) {
        // Windows normalization: drive-letter case is folded.
        final upper = path.replaceFirst(
          '${path[0]}:',
          '${path[0].toUpperCase()}:',
        );
        expect(
          DatabaseImpl.isOpenAt(upper),
          isTrue,
          reason: 'drive-letter case must fold on Windows',
        );
      }
      // Relative-vs-absolute spelling maps to the same normalized path.
      final cwd = Directory.current;
      String? relative;
      if (path.startsWith(cwd.path)) {
        relative = path.substring(cwd.path.length + 1);
      }
      if (relative != null) {
        expect(
          DatabaseImpl.isOpenAt(relative),
          isTrue,
          reason: 'relative spelling must normalize to the same path',
        );
      }
      await db.close();
      expect(DatabaseImpl.isOpenAt(path), isFalse);
    },
  );

  test(
    'opening a directory path fails with a typed error and cleans up',
    () async {
      final directory = await Directory.systemTemp.createTemp('gecko-dir-');
      addTearDown(() => directory.delete(recursive: true));
      // Point the "database" at an existing directory.
      await expectLater(
        DatabaseImpl.open(directory.path),
        throwsA(isA<GeckoError>()),
      );
      expect(DatabaseImpl.isOpenAt(directory.path), isFalse);
    },
  );

  test(
    'opening a path whose parent does not exist fails and cleans up',
    () async {
      final root = await Directory.systemTemp.createTemp('gecko-noparent-');
      addTearDown(() => root.delete(recursive: true));
      final missing = '${root.path}${Platform.pathSeparator}missing-sub';
      final path = '$missing${Platform.pathSeparator}db.redb';
      await expectLater(DatabaseImpl.open(path), throwsA(isA<GeckoError>()));
      expect(DatabaseImpl.isOpenAt(path), isFalse);
    },
  );

  test(
    'config knob edge values are accepted or rejected without wedging',
    () async {
      // Each extreme either opens cleanly (pass-through/clamped) or fails
      // fast; the path must never be left in a stuck state either way.
      final configs = <String, DatabaseConfig>{
        'inFlightBatchLimit 0': const DatabaseConfig(inFlightBatchLimit: 0),
        'inFlightBatchLimit negative': const DatabaseConfig(
          inFlightBatchLimit: -1,
        ),
        'lruCapacity 1': const DatabaseConfig(lruCapacity: 1),
        'lruMaxWeight 0': const DatabaseConfig(lruMaxWeight: 0),
        'changeLogMaxEntries 0': const DatabaseConfig(changeLogMaxEntries: 0),
        'changeLogMaxEntries negative': const DatabaseConfig(
          changeLogMaxEntries: -1,
        ),
        'maxKnownSchemaVersion negative': const DatabaseConfig(
          maxKnownSchemaVersion: -1,
        ),
        'slowQueryThresholdMicros negative': const DatabaseConfig(
          slowQueryThresholdMicros: -1,
        ),
        'compactionSnapshotDrainTimeout zero': const DatabaseConfig(
          compactionSnapshotDrainTimeout: Duration.zero,
        ),
        'lruMaxWeight negative': const DatabaseConfig(lruMaxWeight: -5),
      };
      for (final entry in configs.entries) {
        final (_, path) = await tempDb('gecko-config');
        Object? outcome;
        DatabaseImpl? db;
        try {
          db = await DatabaseImpl.open(path, config: entry.value);
          outcome = db;
        } catch (error) {
          outcome = error;
        }
        // Either the open succeeded (and we can use + close it) or it threw;
        // in every case the path is not stuck.
        if (db != null) {
          await db.close();
        }
        expect(
          DatabaseImpl.isOpenAt(path),
          isFalse,
          reason: '${entry.key} must not leave the path open',
        );
        expect(outcome, isA<Object>(), reason: '${entry.key} must settle');
      }
    },
  );

  test('lruMaxWeight zero evicts immediately (never cached)', () async {
    final (_, path) = await tempDb();
    final db = await DatabaseImpl.open(
      path,
      config: const DatabaseConfig(lruMaxWeight: 0),
    );
    final codec = DefaultWireCodec();
    final key = ByteKey(codec.encode('a'));
    await db.engine.rawPut('items', key, codec.encode({'n': 1}));
    // A point read through the engine populates the cache; with maxWeight 0
    // the value is immediately evicted (and the cache never crashes on the
    // empty-map trim).
    final cached = await db.engine.rawGet('items', key);
    expect(cached, isNotNull);
    expect(db.engine.cacheLength, 0);
    expect(db.engine.cacheWeight, 0);
    await db.close();
  });

  test('lruCapacity one holds at most one entry', () async {
    final (_, path) = await tempDb();
    final db = await DatabaseImpl.open(
      path,
      config: const DatabaseConfig(lruCapacity: 1),
    );
    final codec = DefaultWireCodec();
    await db.engine.rawPut(
      'items',
      ByteKey(codec.encode('a')),
      codec.encode({'n': 1}),
    );
    await db.engine.rawPut(
      'items',
      ByteKey(codec.encode('b')),
      codec.encode({'n': 2}),
    );
    await db.engine.rawGet('items', ByteKey(codec.encode('a')));
    await db.engine.rawGet('items', ByteKey(codec.encode('b')));
    expect(db.engine.cacheLength, 1, reason: 'LRU capacity 1 must cap entries');
    await db.close();
  });
}
