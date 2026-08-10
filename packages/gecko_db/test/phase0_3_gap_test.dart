import 'dart:typed_data';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _GapUser {
  _GapUser(this.id, this.name);
  final String id;
  final String name;
}

Object? _gapRow(_GapUser user) => {'name': user.name};
_GapUser _gapFromRow(Object? row) =>
    _GapUser('', (row as Map<Object?, Object?>)['name'] as String);
Object? _gapId(_GapUser user) => user.id;

void main() {
  test('typed delete of a missing record is a no-op', () async {
    final db = await openNativeTestDatabase('gap-delete');
    final users = db.collection<_GapUser>(
      'users',
      toRow: _gapRow,
      fromRow: _gapFromRow,
      id: _gapId,
    );
    await users.delete('missing');
    expect(await users.getAll(), isEmpty);
    await db.close();
  });

  test('typed getAll of an empty collection returns an empty list', () async {
    final db = await openNativeTestDatabase('gap-empty');
    final users = db.collection<_GapUser>(
      'users',
      toRow: _gapRow,
      fromRow: _gapFromRow,
      id: _gapId,
    );
    final result = await users.getAll();
    expect(result, isA<List<_GapUser>>());
    expect(result, isEmpty);
    await db.close();
  });

  test('calls after close fail with typed InvalidOperationError', () async {
    final db = await openNativeTestDatabase('gap-close');
    final users = db.collection<_GapUser>(
      'users',
      toRow: _gapRow,
      fromRow: _gapFromRow,
      id: _gapId,
    );
    await db.close();

    expect(
      () => db.collection<_GapUser>(
        'other',
        toRow: _gapRow,
        fromRow: _gapFromRow,
        id: _gapId,
      ),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.invalidOperation,
        ),
      ),
    );
    expect(() => users.get('x'), throwsA(isA<GeckoError>()));
    expect(() => users.put(_GapUser('x', 'X')), throwsA(isA<GeckoError>()));
    expect(() => users.delete('x'), throwsA(isA<GeckoError>()));
    expect(() => users.getAll(), throwsA(isA<GeckoError>()));
    expect(() => users.watch('x'), throwsA(isA<GeckoError>()));
    expect(() => users.watchAll(), throwsA(isA<GeckoError>()));
    expect(() => db.watchAll(), throwsA(isA<GeckoError>()));
  });

  test('schema definition validates at collection-open', () async {
    final db = await openNativeTestDatabase('gap-schema');
    expect(
      () => db.collection<_GapUser>(
        'bad',
        toRow: _gapRow,
        fromRow: _gapFromRow,
        schema: RowSchema([
          const FieldSpec(name: 'name'),
          const FieldSpec(name: 'name'),
        ]),
      ),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.schemaValidation,
        ),
      ),
    );
    expect(
      () => db.collection<_GapUser>(
        'bad-empty',
        toRow: _gapRow,
        fromRow: _gapFromRow,
        schema: RowSchema([const FieldSpec(name: '')]),
      ),
      throwsA(isA<GeckoError>()),
    );
    await db.close();
  });

  test('typed put preserves unknown stored fields on rewrite', () async {
    final db = await openNativeTestDatabase('gap-unknown');
    final users = db.collection<_GapUser>(
      'users',
      toRow: _gapRow,
      fromRow: _gapFromRow,
      id: _gapId,
    );
    const codec = DefaultWireCodec();
    await db.engine.rawPut(
      'users',
      ByteKey(codec.encode('u1')),
      codec.encode({'name': 'before', 'legacy': 'preserve'}),
    );

    await users.put(_GapUser('u1', 'after'));
    final raw = await db.rawGet('users', ByteKey(codec.encode('u1')));
    final row = codec.decode(raw!) as Map<Object?, Object?>;
    expect(row['name'], 'after');
    expect(row['legacy'], 'preserve');
    await db.close();
  });

  test('typed multi-megabyte binary values round-trip', () async {
    final db = await openNativeTestDatabase('gap-large');
    final codec = const DefaultWireCodec();
    final bytes = Uint8List.fromList(List<int>.filled(3 * 1024 * 1024, 0x5A));
    await db.engine.rawPut(
      'blobs',
      ByteKey(codec.encode('blob')),
      codec.encode(bytes),
    );
    final raw = await db.rawGet('blobs', ByteKey(codec.encode('blob')));
    final decoded = codec.decode(raw!) as Uint8List;
    expect(decoded.length, bytes.length);
    expect(decoded.first, 0x5A);
    expect(decoded.last, 0x5A);
    await db.close();
  });

  test('RawEngine cache is isolated by table as well as key', () async {
    final backend = InMemoryBackend();
    final engine = RawEngine(backend, lruCapacity: 8);
    final key = ByteKey([1]);
    await engine.rawPut('a', key, [10]);
    await engine.rawPut('b', key, [20]);
    expect(await engine.rawGet('a', key), [10]);
    expect(await engine.rawGet('b', key), [20]);
  });
}
