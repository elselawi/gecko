// Audit-driven long-running tests (audited-test-gaps 2.21). These extend the
// heavy suite; run with GECKO_LONG_TEST=1. Covers encrypted-vs-plaintext
// differential parity and holding a snapshot cursor open across compaction.

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

bool get _longMode => Platform.environment['GECKO_LONG_TEST'] == '1';

const List<int> _key = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
  22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
];

Collection<Map<String, Object?>> coll(
  DatabaseImpl db,
  String table,
) => db.collection<Map<String, Object?>>(
  table,
  toRow: (value) => value,
  fromRow: (row) => Map<String, Object?>.from(row as Map),
  id: (value) => value['id'],
);

/// Runs the same deterministic script against [db].
Future<List<Map<String, Object?>>> runScript(DatabaseImpl db) async {
  final items = coll(db, 'items');
  for (var i = 0; i < 50; i++) {
    await items.put({'id': 'k$i', 'group': 'g${i % 5}', 'n': i});
  }
  for (var i = 0; i < 10; i++) {
    await items.put({'id': 'k$i', 'group': 'g${i % 3}', 'n': i * 10});
  }
  await items.delete('k0');
  final all = await items.getAll()
    ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  final filtered = await items.where().filter('group', 'g1').findAll()
    ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
  final count = await items.where().range('n', min: 20).count();
  return [...all, ...filtered, {'_count': count}];
}

void main() {
  group('2.21 encrypted-vs-plaintext differential', () {
    test(
      'identical script yields identical logical results in both directions',
      () async {
        final dir = await Directory.systemTemp.createTemp('gecko-diff-enc-');
        addTearDown(() => dir.delete(recursive: true));
        final plainPath = '${dir.path}${Platform.pathSeparator}plain.redb';
        final encPath = '${dir.path}${Platform.pathSeparator}enc.redb';

        final plain = await DatabaseImpl.open(plainPath);
        final plainResult = await runScript(plain);
        await plain.close();

        final encrypted = await DatabaseImpl.open(
          encPath,
          config: DatabaseConfig(encryptionKey: _key),
        );
        final encResult = await runScript(encrypted);
        await encrypted.close();

        // Plaintext vs encrypted: identical logical results.
        expect(encResult, plainResult,
            reason: 'encryption must not change logical query results');
      },
      skip: !_longMode,
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'compaction with an open snapshot cursor times out, then succeeds '
      'after dispose',
      () async {
        final db = await openNativeTestDatabase(
          'long-cursor-compact',
          config: const DatabaseConfig(
            compactionSnapshotDrainTimeout: Duration(milliseconds: 200),
          ),
        );
        final items = coll(db, 'items');
        for (var i = 0; i < 200; i++) {
          await items.put({'id': 'k$i', 'payload': 'x' * 1000});
        }
        final cursor = items.where().cursor(pageSize: 50);
        final (firstPage, _) = await cursor.next();
        expect(firstPage, hasLength(50));
        // A held snapshot cursor blocks compaction: it waits for the drain
        // timeout, then fails with a typed error (never a crash).
        await expectLater(
          db.maintenance.compact(),
          throwsA(
            isA<GeckoError>().having(
              (e) => e.type,
              'type',
              GeckoErrorType.invalidOperation,
            ),
          ),
        );
        // The frozen cursor still pages the pre-compaction view.
        final (secondPage, _) = await cursor.next();
        expect(secondPage, hasLength(50));
        // After dispose, compaction proceeds.
        await cursor.dispose();
        expect(await db.maintenance.compact(), isA<bool>());
        await db.close();
      },
      skip: !_longMode,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
