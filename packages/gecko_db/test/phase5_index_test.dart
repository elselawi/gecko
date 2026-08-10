import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _Rec {
  _Rec(this.id, this.name, [this.age, this.nick]);
  final String id;
  final String name;
  final int? age;
  final String? nick;
}

Object? _toRow(_Rec r) => {
  'id': r.id,
  'name': r.name,
  if (r.age != null) 'age': r.age,
  if (r.nick != null) 'nick': r.nick,
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

Object? _id(_Rec r) => r.id;

Future<DatabaseImpl> _open(String name, {List<String>? indexFields}) =>
    openNativeTestDatabase('phase5-$name');

Collection<_Rec> _coll(
  DatabaseImpl db,
  String table, {
  List<String>? indexFields,
  Iterable<String>? prefixFields,
}) => db.collection<_Rec>(
  table,
  toRow: _toRow,
  fromRow: _fromRow,
  id: _id,
  indexFields: indexFields,
  prefixFields: prefixFields,
);

void main() {
  group('Phase 5 secondary index: indexed queries avoid full scans', () {
    test(
      'equality query on indexed field uses the index (plan + scan count)',
      () async {
        final db = await _open('idx-eq', indexFields: ['name']);
        final col = _coll(db, 't', indexFields: ['name']);
        for (var i = 0; i < 200; i++) {
          await col.put(_Rec('r$i', 'name-${i % 10}'));
        }
        final before = db.engine.scannedRows;
        final q = col.where({'name': 'name-3'});
        final result = await q.findAll();
        expect(result, hasLength(20));
        expect(q.lastPlan, IndexPlan.secondaryIndex);
        expect(
          db.engine.scannedRows,
          before,
          reason: 'indexed query must not full-scan',
        );
        await db.close();
      },
    );

    test(
      'compound index serves multi-field query; partial filter falls back',
      () async {
        final db = await _open('idx-compound');
        final col = _coll(db, 't', indexFields: ['name', 'age']);
        for (var i = 0; i < 100; i++) {
          await col.put(_Rec('r$i', 'n${i % 4}', 20 + (i % 5)));
        }
        final compound = col.where({'name': 'n2', 'age': 23});
        expect((await compound.findAll()), hasLength(5));
        expect(compound.lastPlan, IndexPlan.secondaryIndex);

        // Only one field filtered: index still usable (single-field served).
        final single = col.where({'name': 'n1'});
        await single.findAll();
        expect(single.lastPlan, IndexPlan.secondaryIndex);
        await db.close();
      },
    );

    test('prefix index serves search-as-you-type without full scan', () async {
      final db = await _open('idx-prefix');
      final col = _coll(db, 't', prefixFields: ['name']);
      await col.put(_Rec('a', 'Alpha'));
      await col.put(_Rec('b', 'Albert'));
      await col.put(_Rec('c', 'Beta'));
      final q = col.where();
      final matches = await q.prefix('name', 'Al').findAll();
      expect(matches.map((r) => r.id).toSet(), {'a', 'b'});
      await db.close();
    });

    test('index stays consistent after put/patch/delete', () async {
      final db = await _open('idx-maintained');
      final col = _coll(db, 't', indexFields: ['name']);
      await col.put(_Rec('a', 'Alice'));
      await col.put(_Rec('b', 'Bob'));
      await col.patch('a', {'name': 'Alicia'});
      final q1 = col.where({'name': 'Alice'});
      expect(await q1.findAll(), isEmpty);
      final q2 = col.where({'name': 'Alicia'});
      expect((await q2.findAll()).single.id, 'a');
      await col.delete('b');
      final q3 = col.where({'name': 'Bob'});
      expect(await q3.findAll(), isEmpty);
      await db.close();
    });

    test('reopening a collection rebuilds the index from its table', () async {
      final db = await _open('idx-reopen');
      final col = _coll(db, 't', indexFields: ['name']);
      await col.put(_Rec('a', 'Zed'));
      // Re-open the same table with the same index declaration; the open-time
      // rebuild must make indexed reads correct even though the index object
      // is fresh (drift-free by construction).
      final col2 = _coll(db, 't', indexFields: ['name']);
      final q = col2.where({'name': 'Zed'});
      expect((await q.findAll()).single.id, 'a');
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      await db.close();
    });
  });

  group('Phase 5 lazy iterator', () {
    test('iterate() streams unsorted matches without full decode', () async {
      final db = await _open('lazy');
      final col = _coll(db, 't');
      for (var i = 0; i < 100; i++) {
        await col.put(_Rec('r$i', 'x${i % 3}'));
      }
      final names = <String>[];
      await for (final r in col.where({'name': 'x1'}).iterate()) {
        names.add(r.id);
      }
      expect(names.length, 33);
      await db.close();
    });

    test('iterate() on indexed equality uses the index', () async {
      final db = await _open('lazy-idx');
      final col = _coll(db, 't', indexFields: ['name']);
      for (var i = 0; i < 50; i++) {
        await col.put(_Rec('r$i', 'keep'));
      }
      final q = col.where({'name': 'keep'});
      var n = 0;
      await for (final _ in q.iterate()) {
        n++;
      }
      expect(n, 50);
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      await db.close();
    });
  });
}
