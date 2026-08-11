import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _User {
  _User(this.id, this.name);
  final String id;
  final String name;
}

Object? _toRow(_User u) => {'name': u.name};
_User _fromRow(Object? row) => _User('', (row as Map)['name'] as String);
Object? _id(_User u) => u.id;

void main() {
  group('DatabaseImpl lifecycle', () {
    test('open, write, read, close; double-open rejected', () async {
      final db = await openNativeTestDatabase('database-a');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('u1', 'Alice'));
      expect((await col.get('u1'))!.name, 'Alice');
      expect(DatabaseImpl.isOpenAt(db.path), isTrue);

      await db.close();
      expect(DatabaseImpl.isOpenAt(db.path), isFalse);
    });

    test(
      'a second open of the same path fails with DatabaseAlreadyOpenError',
      () async {
        final directory = await Directory.systemTemp.createTemp('gecko-db-b-');
        addTearDown(() => directory.delete(recursive: true));
        final path = '${directory.path}${Platform.pathSeparator}db.redb';
        final db = await DatabaseImpl.open(path);
        expect(
          () => DatabaseImpl.open(path),
          throwsA(
            isA<GeckoError>().having(
              (e) => e.type,
              'type',
              GeckoErrorType.databaseAlreadyOpen,
            ),
          ),
        );
        await db.close();
      },
    );

    test('isReadOnly and path are surfaced', () async {
      final db = await openNativeTestDatabase('database-c');
      expect(db.isReadOnly, isFalse);
      expect(db.path, isNotEmpty);
      await db.close();
    });
  });

  group('DatabaseImpl typed collection (Tier 1 surface)', () {
    test('get/put/delete/getAll round-trip through the backend', () async {
      final db = await openNativeTestDatabase('database-d');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('u1', 'Alice'));
      await col.put(_User('u2', 'Bob'));
      expect((await col.get('u1'))!.name, 'Alice');
      expect(await col.get('missing'), isNull);
      expect((await col.getAll()).length, 2);

      await col.delete('u1');
      expect(await col.get('u1'), isNull);
      expect((await col.getAll()).length, 1);
      await db.close();
    });

    test(
      'put without an id extractor auto-assigns a stable id ()',
      () async {
        final db = await openNativeTestDatabase('database-e');
        final col = db.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
        ); // no id extractor
        final id1 = await col.put(_User('x', 'One'));
        final id2 = await col.put(_User('y', 'Two'));
        // Auto-assigned ids are distinct and stable.
        expect(id1, isNotNull);
        expect(id2, isNotNull);
        expect(id1, isNot(equals(id2)));
        expect((await col.get(id1))!.name, 'One');
        expect((await col.get(id2))!.name, 'Two');
        await db.close();
      },
    );

    test('collection rejects reserved table names', () async {
      final db = await openNativeTestDatabase('database-f');
      expect(
        () => db.collection<_User>(
          '__gecko_internal',
          toRow: _toRow,
          fromRow: _fromRow,
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
      await db.close();
    });

    test('patch on missing record throws keyNotFound', () async {
      final db = await openNativeTestDatabase('database-g');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await expectLater(
        col.patch('nope', {'name': 'x'}),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.keyNotFound,
          ),
        ),
      );
      await db.close();
    });

    test('writeTxn runs a body without error for existing records', () async {
      final db = await openNativeTestDatabase('database-h');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('u1', 'Alice'));
      await db.writeTxn((txn) async {
        final tcol = txn.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        expect((await tcol.get('u1'))!.name, 'Alice');
      });
      await db.close();
    });
  });

  group('Collection duplicates & id stability', () {
    test(
      'auto-assignment is not required; explicit duplicate id upserts',
      () async {
        final db = await openNativeTestDatabase('database-i');
        final col = db.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await col.put(_User('id1', 'A'));
        await col.put(_User('id1', 'B')); // same id → upsert
        expect((await col.get('id1'))!.name, 'B');
        await db.close();
      },
    );
  });
}
