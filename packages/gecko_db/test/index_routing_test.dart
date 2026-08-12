// Priority 5 — Dart-side routing tests: covered-filter skip (no predicate
// recheck), index-ordered descending sorts with missing-field placement,
// composite-index routing (eq prefix + trailing range/prefix and composite
// sorts), and native limit/offset pushdown to indexed multi-range queries.
//
// Every assertion exercises the real Rust/redb engine (native file backend).
import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _Rec {
  _Rec(this.id, this.name, [this.age]);
  final String id;
  final String name;
  final int? age;
}

Object? _toRow(_Rec r) => {
  'id': r.id,
  'name': r.name,
  if (r.age != null) 'age': r.age,
};
_Rec _fromRow(Object? row) {
  final m = row as Map;
  return _Rec(
    m['id'] as String,
    m['name'] as String,
    m['age'] as int?,
  );
}

Object? _id(_Rec r) => r.id;

Collection<_Rec> _coll(
  DatabaseImpl db,
  String table, {
  List<String>? indexFields,
  Iterable<List<String>>? compositeIndexes,
}) => db.collection<_Rec>(
  table,
  toRow: _toRow,
  fromRow: _fromRow,
  id: _id,
  indexFields: indexFields,
  compositeIndexes: compositeIndexes,
);

List<String> _ids(Iterable<_Rec> rows) => [for (final r in rows) r.id];

void main() {
  group('covered-filter skip', () {
    test('index-covered equality query skips the predicate recheck', () async {
      final db = await openNativeTestDatabase('p5-covered-eq');
      final col = _coll(db, 't', indexFields: ['age']);
      for (var i = 0; i < 100; i++) {
        await col.put(_Rec('r$i', 'n$i', 20 + (i % 10)));
      }
      final backend = db.engine.backend as NativeRawBackend;
      await backend.enableCounters();
      final before = await backend.takeCounters();
      final q = col.where().filter('age', 24);
      final result = await q.findAll();
      final after = await backend.takeCounters();
      expect(result, hasLength(10)); // ages 24 appear 10×
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      expect(
        after.predicateEvaluations - before.predicateEvaluations,
        BigInt.zero,
        reason: 'a fully covered predicate must not be rechecked in Rust',
      );
      await db.close();
    });

    test('filter outside the index forces a Rust recheck', () async {
      final db = await openNativeTestDatabase('p5-uncovered');
      final col = _coll(db, 't', indexFields: ['age']);
      for (var i = 0; i < 50; i++) {
        await col.put(_Rec('r$i', 'n$i', 20 + (i % 5)));
      }
      final backend = db.engine.backend as NativeRawBackend;
      await backend.enableCounters();
      final before = await backend.takeCounters();
      // `name` is not indexed, so the eq on `age` cannot prove the predicate.
      final q = col.where().filter('age', 22).filter('name', 'n2');
      final result = await q.findAll();
      final after = await backend.takeCounters();
      expect(result, hasLength(1)); // only r2 has age 22 and name n2
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      expect(
        after.predicateEvaluations - before.predicateEvaluations,
        greaterThan(BigInt.zero),
        reason: 'an uncovered predicate must recheck candidate rows',
      );
      await db.close();
    });
  });

  group('descending index-ordered sort', () {
    test('descending sort on an indexed field streams the index in reverse',
        () async {
      final db = await openNativeTestDatabase('p5-desc');
      final col = _coll(db, 't', indexFields: ['age']);
      await col.put(_Rec('r0', 'n0', 30));
      await col.put(_Rec('r1', 'n1', 10));
      await col.put(_Rec('r2', 'n2', 20));
      await col.put(_Rec('r3', 'n3')); // missing age → sorts first for DESC
      await col.put(_Rec('r4', 'n4', 10));
      await col.put(_Rec('r5', 'n5', 20));
      final q = col.where().sort([SortSpec('age', SortOrder.descending)]);
      final result = await q.findAll();
      // Missing-first, then descending value, ties by ascending record key.
      expect(_ids(result), ['r3', 'r0', 'r2', 'r5', 'r1', 'r4']);
      expect(
        q.lastPlan,
        IndexPlan.secondaryIndex,
        reason: 'DESC must stream the durable index, not run a top-K scan',
      );
      await db.close();
    });

    test('descending sort with an eq bound on the sort field stays in order',
        () async {
      final db = await openNativeTestDatabase('p5-desc-eq');
      final col = _coll(db, 't', indexFields: ['age']);
      await col.put(_Rec('r0', 'n0', 20));
      await col.put(_Rec('r1', 'n1', 20));
      await col.put(_Rec('r2', 'n2', 20));
      final q = col
          .where()
          .filter('age', 20)
          .sort([SortSpec('age', SortOrder.descending)]);
      final result = await q.findAll();
      expect(_ids(result), ['r0', 'r1', 'r2']); // ties break ascending
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      await db.close();
    });
  });

  group('composite indexes', () {
    test('eq on the first field + range on the trailing field is one scan',
        () async {
      final db = await openNativeTestDatabase('p5-comp-range');
      final col = _coll(
        db,
        't',
        indexFields: ['age'],
        compositeIndexes: const [
          ['age', 'name'],
        ],
      );
      await col.put(_Rec('r0', 'alice', 20));
      await col.put(_Rec('r1', 'bob', 20));
      await col.put(_Rec('r2', 'alice', 30));
      await col.put(_Rec('r3', 'carol', 20));
      await col.put(_Rec('r4', 'bob', 40));
      final q = col.where().filter('age', 20).range('name', min: 'a', max: 'c');
      final result = await q.findAll();
      expect(_ids(result), ['r0', 'r1']); // alice, bob ('carol' > 'c')
      expect(
        q.lastPlan,
        IndexPlan.secondaryIndex,
        reason: 'composite must serve the compound predicate as one scan',
      );
      await db.close();
    });

    test('fully-covered composite equality skips the predicate recheck',
        () async {
      final db = await openNativeTestDatabase('p5-comp-covered');
      final col = _coll(
        db,
        't',
        indexFields: ['age'],
        compositeIndexes: const [
          ['age', 'name'],
        ],
      );
      await col.put(_Rec('r0', 'alice', 20));
      await col.put(_Rec('r1', 'bob', 20));
      await col.put(_Rec('r2', 'alice', 30));
      final backend = db.engine.backend as NativeRawBackend;
      await backend.enableCounters();
      final before = await backend.takeCounters();
      final q = col.where().filter('age', 20).filter('name', 'bob');
      final result = await q.findAll();
      final after = await backend.takeCounters();
      expect(_ids(result), ['r1']);
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      expect(
        after.predicateEvaluations - before.predicateEvaluations,
        BigInt.zero,
        reason: 'eq prefix + eq trailing is proven by the composite bounds',
      );
      await db.close();
    });

    test('composite with a filter outside the index rechecks', () async {
      final db = await openNativeTestDatabase('p5-comp-recheck');
      final col = _coll(
        db,
        't',
        indexFields: ['age'],
        compositeIndexes: const [
          ['age', 'name'],
        ],
      );
      await col.put(_Rec('r0', 'alice', 20));
      await col.put(_Rec('r1', 'bob', 20));
      await col.put(_Rec('r2', 'alice', 30));
      final backend = db.engine.backend as NativeRawBackend;
      await backend.enableCounters();
      final before = await backend.takeCounters();
      // `id` is outside the composite, so the composite bounds (eq on age)
      // cannot prove it — Rust must recheck the predicate per candidate row.
      final q = col.where().filter('age', 20).filter('id', 'r1');
      final result = await q.findAll();
      final after = await backend.takeCounters();
      expect(_ids(result), ['r1']);
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      expect(
        after.predicateEvaluations - before.predicateEvaluations,
        greaterThan(BigInt.zero),
        reason: 'a filter outside the composite is not proven by the bounds',
      );
      await db.close();
    });

    test('sort on the composite trailing field is index-served', () async {
      final db = await openNativeTestDatabase('p5-comp-sort');
      final col = _coll(
        db,
        't',
        indexFields: ['age'],
        compositeIndexes: const [
          ['age', 'name'],
        ],
      );
      await col.put(_Rec('r0', 'alice', 20));
      await col.put(_Rec('r1', 'bob', 20));
      await col.put(_Rec('r2', 'alice', 30));
      await col.put(_Rec('r3', 'carol', 20));
      final q = col
          .where()
          .filter('age', 20)
          .sort([SortSpec('name', SortOrder.ascending)]);
      final result = await q.findAll();
      expect(_ids(result), ['r0', 'r1', 'r3']); // alice, bob, carol
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      await db.close();
    });
  });

  group('limit/offset pushdown', () {
    test('indexed range with a limit stops early in Rust', () async {
      final db = await openNativeTestDatabase('p5-limit');
      final col = _coll(db, 't', indexFields: ['age']);
      for (var i = 0; i < 100; i++) {
        await col.put(_Rec('r$i', 'n$i', 20 + (i % 50)));
      }
      final backend = db.engine.backend as NativeRawBackend;
      await backend.enableCounters();
      final before = await backend.takeCounters();
      final q = col.where().range('age', min: 20, max: 69).limit(3);
      final result = await q.findAll();
      final after = await backend.takeCounters();
      expect(result, hasLength(3));
      expect(q.lastPlan, IndexPlan.secondaryIndex);
      final visited =
          after.indexEntriesVisited - before.indexEntriesVisited;
      expect(
        visited,
        lessThan(BigInt.from(100)),
        reason: 'a 3-row window must not visit the whole 100-row index span',
      );
      await db.close();
    });
  });
}
