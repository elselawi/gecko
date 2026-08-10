// Workstream 5 coverage hardening.
//
// These tests close the branch/line gaps introduced by the maintenance and
// diagnostics surfaces: maintenance toStrings, raw-key validation,
// recovery from a failed compaction, read-only marker handling, preserved
// conflict round-trips with a resolution, and M7.5 native query coverage.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart'
    show
        geckoConflictTable,
        geckoMaintenanceCompacting,
        geckoMaintenanceStateKey,
        geckoMaintenanceTable;
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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-ws5cov-');
    path = '${tempDir.path}${Platform.pathSeparator}database.redb';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('maintenance toStrings are human readable', () async {
    final db = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(
        nativeLibraryPath: nativePath,
        slowQueryThresholdMicros: 1,
      ),
    );
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    for (var i = 0; i < 5; i++) {
      await col.put({'id': 'k$i', 'n': i});
    }
    await col.where({'n': 3}).findAll();

    final stats = await db.maintenance.storageStats();
    expect(stats.toString(), contains('physical='));
    expect(stats.toString(), contains('logical='));
    expect(db.engine.recentSlowQueries, isNotEmpty);
    expect(db.engine.recentSlowQueries.first.toString(), contains('µs'));
    await db.close();
  });

  test('an invalid raw key fails before the file is created', () async {
    await expectLater(
      DatabaseImpl.open(
        path,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          encryptionKey: const [1, 2],
        ),
      ),
      throwsA(
        isA<GeckoError>().having(
          (e) => e.type,
          'type',
          GeckoErrorType.invalidOperation,
        ),
      ),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('recover() clears a failed compaction state', () async {
    final db = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(
        nativeLibraryPath: nativePath,
        compactionSnapshotDrainTimeout: const Duration(milliseconds: 50),
      ),
    );
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    await col.put({'id': 'one', 'n': 1});
    // Hold a cursor open so compaction times out and transitions to failed.
    final cursor = col.where().cursor();
    try {
      await expectLater(
        () => db.maintenance.compact(),
        throwsA(isA<GeckoError>()),
      );
      expect(db.maintenance.state, MaintenanceState.failed);
    } finally {
      await cursor.dispose();
    }
    // recover() returns the prior state and resets to idle.
    expect(await db.maintenance.recover(), MaintenanceState.failed);
    expect(db.maintenance.state, MaintenanceState.idle);
    await db.close();
  });

  test(
    'read-only open with an interrupted marker recovers in memory',
    () async {
      // Write a `compacting` marker, close, reopen read-only.
      final db = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      const codec = DefaultWireCodec();
      await db.engine.commitBatch(
        (lsn, snapshot) => [
          RawPut(
            geckoMaintenanceTable,
            ByteKey(codec.encode(geckoMaintenanceStateKey)),
            codec.encode(geckoMaintenanceCompacting),
          ),
        ],
      );
      await db.close();

      final ro = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath, readOnly: true),
      );
      expect(ro.maintenance.state, MaintenanceState.recovering);
      // recover() cannot persist a marker in read-only mode but still resets.
      expect(await ro.maintenance.recover(), MaintenanceState.recovering);
      expect(ro.maintenance.state, MaintenanceState.idle);
      await ro.close();
    },
  );

  test(
    'preserved conflict with a resolution round-trips and is resolved',
    () async {
      final db = await DatabaseImpl.open(path);
      const codec = DefaultWireCodec();
      // Write a preserved conflict that already carries a concrete resolution
      // (as produced by an external resolver), then read it back.
      final resolvedMap = <String, Object?>{
        'conflictId': 'cf-one',
        'collection': 'items',
        'recordId': 'one',
        'local': <String, Object?>{
          'value': {'id': 'one', 'v': 'l'},
          'deleted': false,
        },
        'remote': <String, Object?>{
          'value': {'id': 'one', 'v': 'r'},
          'deleted': false,
        },
        'base': null,
        'resolution': <String, Object?>{'kind': 'useRemote', 'value': null},
        'resolutionTimestamp': null,
        'resolutionSource': 'test',
      };
      await db.engine.commitBatch(
        (lsn, snapshot) => [
          RawPut(
            geckoConflictTable,
            ByteKey(codec.encode('cf-one')),
            codec.encode(resolvedMap),
          ),
        ],
      );

      final preserved = await db.conflicts.read('cf-one');
      expect(preserved, isNotNull);
      expect(preserved!.isResolved, isTrue);
      expect(preserved.remote.value, {'id': 'one', 'v': 'r'});
      // Resolving an already-resolved preserved conflict is a typed error.
      await expectLater(
        () => db.conflicts.resolvePreserved(
          'cf-one',
          const Resolution.useRemote(),
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.conflict,
          ),
        ),
      );
      await db.close();
    },
  );

  group('M7.5 native query coverage', () {
    test(
      'timing-armed sorted/indexed/limited routes populate stage timings',
      () async {
        final db = await DatabaseImpl.open(
          path,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            slowQueryThresholdMicros: 1,
          ),
        );
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['group'],
        );
        for (var i = 0; i < 60; i++) {
          await col.put({'id': 'k$i', 'group': 'g${i % 3}', 'n': i});
        }
        // Eq + sort on the SAME indexed field: the index-covered ordered
        // route takes the eq-on-field branch (index-key order == sort order).
        final eqSorted = col
            .where({'group': 'g1'})
            .sort([const SortSpec('group')])
            .limit(10);
        expect(await eqSorted.findAll(), hasLength(10));
        expect(eqSorted.lastPlan, IndexPlan.secondaryIndex);
        // Sorted + limited without an eq: Rust top-K route.
        final topK = col.where().sort([const SortSpec('n')]).limit(5);
        expect(await topK.findAll(), hasLength(5));
        expect(topK.lastPlan, IndexPlan.nativeFilteredScan);
        // Sorted without a window: streams through `_scanWith` with the
        // timing-armed Dart sort stage.
        final sorted = col.where().sort([const SortSpec('n')]);
        expect(await sorted.findAll(), hasLength(60));
        // Indexed eq without a window: single-eq join + Dart predicate
        // recheck (timing-armed).
        final eq = col.where({'group': 'g2'});
        expect(await eq.findAll(), hasLength(20));
        expect(eq.lastPlan, IndexPlan.secondaryIndex);
        // Unindexed range with timing: native predicate count.
        final unindexed = col.where().range('n', min: 10, max: 19);
        expect(await unindexed.count(), 10);
        // `first()` with timing arms the windowed scan path.
        final first = col.where({'group': 'g0'}).first();
        expect((await first)!['n'], isA<int>());
        // Slow-query records were captured for the timed queries.
        expect(db.engine.recentSlowQueries, isNotEmpty);
        await db.close();
      },
    );
  });
}
