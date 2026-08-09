// Workstream 5 coverage hardening.
//
// These tests close the branch/line gaps introduced by the maintenance and
// diagnostics surfaces: maintenance toStrings, key-provider failures,
// recovery from a failed compaction, read-only marker handling, preserved
// conflict round-trips with a resolution, and secondary-index edge paths.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart'
    show
        geckoConflictTable,
        geckoMaintenanceCompacting,
        geckoMaintenanceStateKey,
        geckoMaintenanceTable;
import 'package:gecko_db/src/query/secondary_index.dart';
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

class _ThrowingKeyProvider implements KeyProvider {
  @override
  String get name => 'throwing-test';

  @override
  Future<List<int>?> obtain() async {
    throw StateError('secret unavailable');
  }
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
      useInMemory: false,
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

  test('a throwing key provider fails before the file is created', () async {
    await expectLater(
      DatabaseImpl.open(
        path,
        useInMemory: false,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          keyProvider: _ThrowingKeyProvider(),
        ),
      ),
      throwsA(
        isA<GeckoError>().having(
          (e) => e.type,
          'type',
          GeckoErrorType.keyUnavailable,
        ),
      ),
    );
    expect(File(path).existsSync(), isFalse);
  });

  test('recover() clears a failed compaction state', () async {
    final db = await DatabaseImpl.open(
      path,
      useInMemory: false,
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
        useInMemory: false,
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
        useInMemory: false,
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
      final db = await DatabaseImpl.open(path, useInMemory: true);
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

  group('secondary index edge paths', () {
    test('remove/replace handle absent fields and fresh ids', () {
      final idx = SecondaryIndex(
        fields: const ['name', 'age'],
        prefixFields: const ['name'],
      );
      idx.insert('a', {'name': 'alice', 'age': 30});
      idx.insert('b', {'name': 'bob'});
      // replace on an id with an empty old row and no current entry -> insert.
      idx.replace('c', const {}, {'name': 'carol', 'age': 25});
      expect(idx.lookupEq({'name': 'carol'}), contains('c'));
      // replace an existing id.
      idx.replace('a', {'name': 'alice', 'age': 30}, {'name': 'alicia'});
      expect(idx.lookupEq({'name': 'alice'}), isEmpty);
      expect(idx.lookupEq({'name': 'alicia'}), contains('a'));
      // remove a row whose value lacks some indexed fields.
      idx.remove('b', {'name': 'bob'});
      idx.remove('c', {'name': 'carol', 'age': 25});
      // lookupRange with no bounds returns everything; empty field -> empty.
      final range = idx.lookupRange('name');
      expect(range, contains('a'));
      expect(idx.lookupRange('age'), isEmpty);
      // prefix lookups and removals.
      expect(idx.lookupPrefix('name', 'ali'), contains('a'));
      expect(idx.lookupRange('missing'), isNull);
      expect(idx.lookupPrefix('missing', 'x'), isNull);
    });

    test('empty index reports empty range and clears for rebuild', () {
      final idx = SecondaryIndex(fields: const ['name']);
      expect(idx.lookupRange('name', min: 'a', max: 'z'), isEmpty);
      idx.insert('a', {'name': 'alice'});
      idx.clearForRebuild();
      expect(idx.lookupEq({'name': 'alice'}), isEmpty);
    });
  });
}
