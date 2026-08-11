import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _M {
  _M(this.id, this.v);
  final String id;
  final String v;
}

Object? _toRow(_M m) => {'v': m.v};
_M _fromRow(Object? r) => _M('', (r as Map)['v'] as String);
Object? _id(_M m) => m.id;

void main() {
  group('keyNotFoundError helper', () {
    test('produces a typed keyNotFound error naming the table', () {
      final e = keyNotFoundError('users', ByteKey([1]));
      expect(e, isA<GeckoError>());
      expect(e.type, GeckoErrorType.keyNotFound);
      expect(e.details, contains('table'));
    });
  });

  group('Internal helpers (test/diagnostic surface)', () {
    test('RawEngine exposes its backend', () async {
      final db = await openNativeTestDatabase('edge-backend');
      final b = db.engine.backend;
      final e = RawEngine(b);
      expect(identical(e.backend, b), isTrue);
      await db.close();
    });
  });

  group('DatabaseImpl: edge paths', () {
    test(
      'file-backed open without a path works via the bundled artifact',
      () async {
        final bundled = await bundledArtifactPath();
        if (bundled == null) {
          // Host has no bundled artifact (unsupported platform); the open must
          // still fail with a typed error, never hang or crash.
          await expectLater(
            DatabaseImpl.open('file://x'),
            throwsA(isA<GeckoError>()),
          );
          return;
        }
        final dir = await Directory.systemTemp.createTemp('gecko-edge-');
        try {
          final path = '${dir.path}${Platform.pathSeparator}db.redb';
          // No `nativeLibraryPath`: the resolver's bundled-artifact fallback
          // must load the worker (no-build-steps path).
          final db = await DatabaseImpl.open(path);
          const codec = DefaultWireCodec();
          await db.engine.rawPut(
            'items',
            ByteKey(codec.encode('k')),
            codec.encode('v'),
          );
          expect(
            codec.decode(
              (await db.rawGet('items', ByteKey(codec.encode('k'))))!,
            ),
            'v',
          );
          await db.close();
          // A nonsense path still fails with a typed error. Deterministic
          // (never exists), so the test stays offline and clock-free.
          await expectLater(
            DatabaseImpl.open(
              'file://xxxxxxxx/nonexistent-path-for-backend-edge-test',
            ),
            throwsA(isA<GeckoError>()),
          );
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );

    test('writeTxn rethrows a throwing body (no silent swallow)', () async {
      final db = await openNativeTestDatabase('edge1');
      await expectLater(
        db.writeTxn((txn) async => throw StateError('boom')),
        throwsStateError,
      );
      await db.close();
    });

    test('hasLiveOpen reflects open databases', () async {
      final before = DatabaseImpl.hasLiveOpen;
      final db = await openNativeTestDatabase('edge3');
      expect(DatabaseImpl.hasLiveOpen, isTrue);
      await db.close();
      expect(DatabaseImpl.hasLiveOpen, before);
    });

    test('rawGet on the impl surfaces the engine path', () async {
      final db = await openNativeTestDatabase('edge4');
      await db.rawGet('t', ByteKey([1]));
      await db.close();
    });

    test('watch streams are reactive after ', () async {
      final db = await openNativeTestDatabase('edge5');
      final col = db.collection<_M>(
        'c',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      // Initial emissions reflect current (empty) state.
      await expectLater(col.watch('x'), emits(null));
      await expectLater(col.watchAll(), emits(<_M>[]));
      await db.close();
    });

    test('patch on an existing record updates it ()', () async {
      final db = await openNativeTestDatabase('edge6');
      final col = db.collection<_M>(
        'c',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_M('a', '1'));
      await col.patch('a', {'v': '2'});
      expect((await col.get('a'))!.v, '2');
      await db.close();
    });

    test('where(query) builds a query after ', () async {
      final db = await openNativeTestDatabase('edge7');
      final col = db.collection<_M>(
        'c',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      expect(col.where(), isA<Query<_M>>());
      await db.close();
    });

    test(
      'transaction handle exposes the collection/get/commit/rollback paths',
      () async {
        final db = await openNativeTestDatabase('edge8');
        final col = db.collection<_M>(
          'c',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await col.put(_M('a', '1'));

        await db.writeTxn((txn) async {
          expect(txn.isReadOnly, isFalse);
          final tcol = txn.collection<_M>(
            'c',
            toRow: _toRow,
            fromRow: _fromRow,
            id: _id,
          );
          expect((await tcol.get('a'))!.v, '1');
          final viaGet = await txn.get<_M>(
            'c',
            'a',
            toRow: _toRow,
            fromRow: _fromRow,
          );
          expect(viaGet!.v, '1');
          await txn.commit();
          await txn.rollback(); // both must be no-ops in 
        });
        await db.close();
      },
    );
  });
}
