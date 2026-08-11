import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _User {
  _User(this.id, this.name, this.age);
  final String id;
  final String name;
  final int age;
}

Object? _toRow(_User user) => {
  'id': user.id,
  'name': user.name,
  'age': user.age,
};
_User _fromRow(Object? row) {
  final map = Map<Object?, Object?>.from(row as Map);
  return _User(map['id'] as String, map['name'] as String, map['age'] as int);
}

Object? _id(_User user) => user.id;

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

const List<int> _testKey = [
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
];

void main() {
  test('quickstart example compiles and runs', () async {
    final db = await openNativeTestDatabase('examples-quick');
    final users = db.collection<_User>(
      'users',
      toRow: _toRow,
      fromRow: _fromRow,
      id: _id,
      indexFields: ['age'],
    );
    await users.put(_User('u1', 'Alice', 30));
    await users.patch('u1', {'name': 'Alicia'});
    final adults = await users.where().range(ageField, min: 18).findAll();
    expect(adults.single.name, 'Alicia');
    await db.close();
  });

  test('advanced example compiles and runs', () async {
    final db = await openNativeTestDatabase('examples-advanced');
    db.diagnostics.enable();
    final bulk = await db.bulkWrite([
      const BulkMutation.put(
        table: 'settings',
        key: 'theme',
        value: {'value': 'dark'},
      ),
      const BulkMutation.put(
        table: 'settings',
        key: 'sync',
        value: {'value': 'enabled'},
      ),
    ]);
    expect(bulk.mutationCount, 2);
    expect(db.diagnostics.snapshot().totalWrites, greaterThan(0));
    await db.schema.stamp(1);
    await db.schema.migrateStep(
      const MigrationStep(
        name: 'add-settings-version',
        fromVersion: 1,
        toVersion: 2,
      ),
    );
    expect(await db.schema.readVersion(), 2);
    await db.close();
  });

  test(
    'consumer example runs end-to-end as a subprocess',
    () async {
      final root = _repoRoot();
      final native = _nativeLibraryPath(root);
      final dir = await Directory.systemTemp.createTemp('gecko-consumer-run-');
      addTearDown(() => dir.delete(recursive: true));
      final dbPath = '${dir.path}${Platform.pathSeparator}db.redb';
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        '$root${Platform.pathSeparator}examples'
            '${Platform.pathSeparator}consumer.dart',
        dbPath,
        native,
      ], workingDirectory: root);
      final output = await process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final errorOutput = await process.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      final exitCode = await process.exitCode;
      expect(
        exitCode,
        0,
        reason: 'consumer fixture must exit 0: $output\n$errorOutput',
      );
      expect(output, contains('CONSUMER-OK'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'malformed encryption keys fail cleanly and the path stays reopenable',
    () async {
      final root = _repoRoot();
      final native = _nativeLibraryPath(root);
      final dir = await Directory.systemTemp.createTemp('gecko-badkey-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}db.redb';

      // Short / long / non-hex-able keys fail with typed errors and never
      // leave the path wedged.
      for (final bad in [
        <int>[1, 2, 3], // short
        List<int>.filled(40, 7), // long
        <int>[
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
          13,
          14,
          15,
          16,
          17,
          18,
          19,
          20,
          21,
          22,
          23,
          24,
          25,
          26,
          27,
          28,
          29,
          30,
          31,
        ], // 31
      ]) {
        await expectLater(
          DatabaseImpl.open(
            path,
            config: DatabaseConfig(
              nativeLibraryPath: native,
              encryptionKey: bad,
            ),
          ),
          throwsA(isA<GeckoError>()),
        );
        expect(DatabaseImpl.isOpenAt(path), isFalse);
      }
      // The path is still usable with a valid key.
      final db = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(
          nativeLibraryPath: native,
          encryptionKey: _testKey,
        ),
      );
      final notes = db.collection<Map<String, Object?>>(
        'notes',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      await notes.put({'id': 'n1', 'text': 'ok'});
      await db.close();
    },
  );

  test(
    'wrong-key open fails cleanly and the right key reopens the data',
    () async {
      final root = _repoRoot();
      final native = _nativeLibraryPath(root);
      final dir = await Directory.systemTemp.createTemp('gecko-wrongkey-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}db.redb';

      final writer = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(
          nativeLibraryPath: native,
          encryptionKey: _testKey,
        ),
      );
      final notes = writer.collection<Map<String, Object?>>(
        'notes',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      await notes.put({'id': 'n1', 'text': 'secret'});
      await writer.close();

      // A wrong key must fail with a typed error.
      final wrongKey = List<int>.generate(32, (i) => 200 + i);
      await expectLater(
        DatabaseImpl.open(
          path,
          config: DatabaseConfig(
            nativeLibraryPath: native,
            encryptionKey: wrongKey,
          ),
        ),
        throwsA(isA<GeckoError>()),
      );
      expect(DatabaseImpl.isOpenAt(path), isFalse);

      // The right key reopens and reads the data.
      final reader = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(
          nativeLibraryPath: native,
          encryptionKey: _testKey,
        ),
      );
      final notes2 = reader.collection<Map<String, Object?>>(
        'notes',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      expect((await notes2.get('n1'))!['text'], 'secret');
      await reader.close();
    },
  );
}

const ageField = 'age';
