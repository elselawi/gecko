import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

class _Rec {
  _Rec(this.id, this.name, [this.age, this.nick]);
  final String id;
  final String name;
  final int? age;
  final String? nick;
}

Object? _toRow(_Rec r) => {
  'name': r.name,
  if (r.age != null) 'age': r.age,
  if (r.nick != null) 'nick': r.nick,
};

/// A `toRow` that omits `name` entirely when it is empty, so a missing
/// required field can be exercised through `put`.
Object? _toRowMissingName(_Rec r) => {
  if (r.name.isNotEmpty) 'name': r.name,
  if (r.age != null) 'age': r.age,
};
_Rec _fromRow(Object? row) {
  final m = row as Map;
  return _Rec(
    m['id'] as String? ?? '',
    m['name'] as String,
    m['age'] as int?,
    m['nick'] as String?,
  );
}

Object? _recId(_Rec r) => r.id;

void main() {
  group('Phase 3 integration: schema + Tier 1 CRUD', () {
    late DatabaseImpl db;

    setUp(() async {
      db = await DatabaseImpl.open('mem://p3', useInMemory: true);
    });

    tearDown(() async {
      await db.close();
    });

    Collection<_Rec> schemaColl({required bool ageRequired}) {
      final schema = RowSchema.of({
        'name': FieldSpec(name: 'name', required: true),
        if (ageRequired) 'age': FieldSpec(name: 'age', required: true),
      });
      return db.collection<_Rec>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
        schema: schema,
      );
    }

    test('put validates schema and rejects a missing required field', () async {
      final schema = RowSchema.of({
        'name': FieldSpec(name: 'name', required: true),
      });
      final schemaCol = db.collection<_Rec>(
        'users2',
        toRow: _toRowMissingName,
        fromRow: _fromRow,
        id: _recId,
        schema: schema,
      );
      await expectLater(
        schemaCol.put(_Rec('u1', '')),
        throwsA(
          isA<GeckoError>()
              .having((e) => e.type, 'type', GeckoErrorType.schemaValidation)
              .having((e) => e.message, 'message', contains('name')),
        ),
      );
    });

    test('get/put/delete/getAll round-trip with a schema', () async {
      final col = schemaColl(ageRequired: false);
      await col.put(_Rec('a', 'Alice', 30));
      expect((await col.get('a'))!.name, 'Alice');
      expect((await col.getAll()).length, 1);
      expect(identical(col.database, db), isTrue, reason: 'database getter');
      await col.delete('a');
      expect(await col.get('a'), isNull);
    });
  });

  group('Phase 3 integration: patch preserves missing/null', () {
    late DatabaseImpl db;

    setUp(() async {
      db = await DatabaseImpl.open('mem://p3b', useInMemory: true);
    });

    tearDown(() async {
      await db.close();
    });

    test('patch updates only specified fields; unrelated unchanged', () async {
      final col = db.collection<_Rec>(
        't',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
      );
      await col.put(_Rec('a', 'Alice', 30));
      await col.patch('a', {'name': 'Alicia'});
      final got = await col.get('a');
      expect(got!.name, 'Alicia');
      expect(got.age, 30, reason: 'untouched field preserved');
    });

    test('patch with an explicit null is distinct from missing', () async {
      final col = db.collection<_Rec>(
        't',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
      );
      await col.put(_Rec('a', 'Alice', 30));
      await col.patch('a', {'nick': null});
      final raw = await db.rawGet('t', ByteKey(DefaultWireCodec().encode('a')));
      final decoded = DefaultWireCodec().decode(raw!) as Map;
      expect(decoded.containsKey('nick'), isTrue, reason: 'null is present');
      expect(decoded['nick'], isNull);
    });

    test('patch on a missing record throws keyNotFound', () async {
      final col = db.collection<_Rec>(
        't',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
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
    });

    test('patch with a schema rejects an unknown field', () async {
      final schema = RowSchema.of({'name': FieldSpec(name: 'name')});
      final col = db.collection<_Rec>(
        't',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
        schema: schema,
      );
      await col.put(_Rec('a', 'Alice'));
      await expectLater(
        col.patch('a', {'zz': 1}),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.schemaValidation,
          ),
        ),
      );
    });

    test('patch with a schema applies defaults on the merged row', () async {
      final schema = RowSchema.of({
        'name': FieldSpec(name: 'name'),
        'status': FieldSpec(
          name: 'status',
          hasDefault: true,
          defaultValue: 'active',
        ),
      });
      final col = db.collection<_Rec>(
        't2',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
        schema: schema,
      );
      await col.put(_Rec('a', 'Alice'));
      await col.patch('a', {'name': 'Alicia'});
      const codec = DefaultWireCodec();
      final raw = await db.rawGet('t2', ByteKey(codec.encode('a')));
      final row = codec.decode(raw!) as Map;
      expect(row['name'], 'Alicia');
      expect(row['status'], 'active', reason: 'default applied on merged row');
    });
  });

  group('Phase 3: auto-assigned ids', () {
    test('are unique across a large batch of inserts', () async {
      final db = await DatabaseImpl.open('mem://p3c', useInMemory: true);
      final col = db.collection<_Rec>(
        't',
        toRow: _toRow,
        fromRow: _fromRow,
      ); // no id extractor
      final ids = <Object?>{};
      for (var i = 0; i < 1000; i++) {
        ids.add(await col.put(_Rec('', 'u$i')));
      }
      expect(ids.length, 1000, reason: 'all auto ids unique');
      final stored = await col.getAll();
      expect(stored.length, 1000);
      await db.close();
    });
  });

  group('Phase 3: unknown stored fields survive round-trip', () {
    test('fields absent from fromRow mapping are preserved on write', () async {
      final db = await DatabaseImpl.open('mem://p3d', useInMemory: true);
      final col = db.collection<_Rec>(
        't',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
      );
      // Stow a row carrying a column the mapping doesn't know about (e.g. via
      // the raw engine), then read it back with get().
      const codec = DefaultWireCodec();
      await db.engine.rawPut(
        't',
        ByteKey(codec.encode('a')),
        codec.encode({'name': 'Alice', 'legacy': 'keep-me'}),
      );
      final typed = await col.get('a');
      expect(typed!.name, 'Alice');
      // The raw row still has the legacy field (not dropped by writing/get).
      final raw = await db.rawGet('t', ByteKey(codec.encode('a')));
      expect((codec.decode(raw!) as Map)['legacy'], 'keep-me');
      await db.close();
    });
  });
}
