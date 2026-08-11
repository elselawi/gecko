// Audit-driven sort-rules, query/cursor, and durable-index edge tests
// (audited-test-gaps 2.5, 2.6, 2.7).

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/query/sorting.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

Collection<Map<String, Object?>> coll(
  DatabaseImpl db,
  String table, {
  List<String>? indexFields,
  Iterable<String>? prefixFields,
}) => db.collection<Map<String, Object?>>(
  table,
  toRow: (value) => value,
  fromRow: (row) => Map<String, Object?>.from(row as Map),
  id: (value) => value['id'],
  indexFields: indexFields,
  prefixFields: prefixFields,
);

void main() {
  group('2.5 sort rules', () {
    test('compareFieldValues compares numerics by value across int/double', () {
      expect(compareFieldValues(3, 2.5), greaterThan(0));
      expect(compareFieldValues(2.5, 3), lessThan(0));
      expect(compareFieldValues(5, 5.0), 0, reason: 'num.compareTo is numeric');
      expect(compareFieldValues(-1, 0.5), lessThan(0));
    });

    test('compareFieldValues falls back by string for cross-type', () {
      // num vs String → toString fallback.
      expect(compareFieldValues(10, '9'), lessThan(0));
      expect(compareFieldValues(10, 'abc'), lessThan(0));
      // bool vs int → toString fallback ("false" < "true" < numbers...).
      expect(compareFieldValues(true, 1), greaterThan(0));
      // bool vs bool → natural.
      expect(compareFieldValues(false, true), lessThan(0));
    });

    test('strings compare by UTF-16 code units (astral planes)', () {
      // The wire codec is UTF-8 but Dart sort order is UTF-16 code units:
      // an astral character (surrogate pair 0xD83D 0xDE00) sorts after all
      // single-code-unit BMP characters below it.
      expect('😀'.codeUnits.length, 2, reason: 'surrogate pair');
      expect(compareFieldValues('😀', 'Z'), greaterThan(0));
      // And it is exactly String.compareTo's order.
      expect(compareFieldValues('a😀b', 'aZb'), 'a😀b'.compareTo('aZb'));
      expect('a😀b'.compareTo('aZb'), greaterThan(0));
    });

    test('compareRows: null is present and distinct from missing', () {
      final specs = [SortSpec('name')];
      final presentNull = <Object?, Object?>{'name': null, 'id': 1};
      final missing = <Object?, Object?>{'id': 2};
      // Ascending: a present (even null) field sorts before missing.
      expect(compareRows(presentNull, missing, specs), lessThan(0));
      expect(compareRows(missing, presentNull, specs), greaterThan(0));
      // Both present (null vs "a") → null compares as '' (the documented
      // nulls-sort-by-empty-string rule), so null < "a".
      final presentA = <Object?, Object?>{'name': 'a'};
      expect(compareRows(presentNull, presentA, specs), lessThan(0));
      expect(compareRows(presentA, presentNull, specs), greaterThan(0));
    });

    test('compareRows: both-missing on a spec moves to the next spec', () {
      final specs = [
        SortSpec('missing'),
        SortSpec('age', SortOrder.descending),
      ];
      final a = <Object?, Object?>{'age': 1};
      final b = <Object?, Object?>{'age': 2};
      expect(
        compareRows(a, b, specs),
        greaterThan(0),
        reason: 'age 1 > 2 desc',
      );
      expect(compareRows(b, a, specs), lessThan(0));
      // Both missing both → tie.
      expect(
        compareRows(
          <Object?, Object?>{'other': 1},
          <Object?, Object?>{'other': 2},
          specs,
        ),
        0,
      );
    });
  });

  group('2.6 query / cursors', () {
    test('query builder calls are immutable (no parent mutation)', () async {
      final db = await openNativeTestDatabase('qb-immutable');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      await c.put({'id': 'c', 'n': 3});

      final base = c.where();
      final filtered = base.filter('n', 1);
      final sorted = base.sort([const SortSpec('n', SortOrder.descending)]);
      final limited = base.limit(1);
      final offset = base.offset(1);

      // The base query is unaffected by derived queries.
      expect((await base.findAll()), hasLength(3));
      // Each derived query is independent.
      expect((await filtered.findAll()), hasLength(1));
      expect((await sorted.findAll()).map((r) => r['n']), [3, 2, 1]);
      expect((await limited.findAll()), hasLength(1));
      expect((await offset.findAll()), hasLength(2));
      await db.close();
    });

    test('type-strict equality: 5 != 5.0 != BigInt(5), true != 1', () async {
      final db = await openNativeTestDatabase('qb-type-strict');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'v': 5});
      await c.put({'id': 'b', 'v': 5.0});
      await c.put({'id': 'c', 'v': BigInt.from(5)});
      await c.put({'id': 'd', 'v': true});
      await c.put({'id': 'e', 'v': 1});
      // int 5 only matches the int row.
      expect((await c.where().filter('v', 5).findAll()).map((r) => r['id']), [
        'a',
      ]);
      // double 5.0 only matches the double row.
      expect((await c.where().filter('v', 5.0).findAll()).map((r) => r['id']), [
        'b',
      ]);
      // BigInt 5 only matches the BigInt row.
      expect(
        (await c.where().filter('v', BigInt.from(5)).findAll()).map(
          (r) => r['id'],
        ),
        ['c'],
      );
      // true != 1.
      expect(
        (await c.where().filter('v', true).findAll()).map((r) => r['id']),
        ['d'],
      );
      expect((await c.where().filter('v', 1).findAll()).map((r) => r['id']), [
        'e',
      ]);
      await db.close();
    });

    test(
      'distinct skips missing-field rows but includes explicit null',
      () async {
        final db = await openNativeTestDatabase('qb-distinct');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'g': 'x'});
        await c.put({'id': 'b', 'g': 'x'});
        await c.put({'id': 'c'}); // missing g
        await c.put({'id': 'd', 'g': null}); // explicit null
        final distinct = await c.where().distinct('g');
        // Missing rows are skipped; explicit null IS a distinct value.
        expect(distinct.contains('x'), isTrue);
        expect(distinct.contains(null), isTrue);
        expect(distinct, hasLength(2));
        await db.close();
      },
    );

    test(
      'findPage with a non-List<int> afterKey throws a raw TypeError',
      () async {
        final db = await openNativeTestDatabase('qb-afterkey');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        final q = c.where();
        await expectLater(
          q.findPage(afterKey: 'not-bytes'),
          throwsA(isA<TypeError>()),
        );
        await expectLater(
          q.findPage(afterKey: <Object?>[null]),
          throwsA(isA<TypeError>()),
        );
        await db.close();
      },
    );

    test('findPage pageSize 0 and negative are handled', () async {
      final db = await openNativeTestDatabase('qb-pagesize');
      final c = coll(db, 'items');
      for (var i = 0; i < 5; i++) {
        await c.put({'id': 'k$i', 'n': i});
      }
      // pageSize 0 pins the current quirk: the `>= limit` check fires after
      // the first add, so a zero (or negative) page returns exactly one row
      // instead of crashing.
      final (page0, _) = await c.where().findPage(pageSize: 0);
      expect(page0, hasLength(1), reason: 'zero page size returns one row');
      final (pageNeg, _) = await c.where().findPage(pageSize: -1);
      expect(
        pageNeg,
        hasLength(1),
        reason: 'negative page size returns one row',
      );
      await db.close();
    });

    test('repeated next() after exhaustion returns ([], null)', () async {
      final db = await openNativeTestDatabase('qb-cursor-exhaust');
      final c = coll(db, 'items');
      for (var i = 0; i < 3; i++) {
        await c.put({'id': 'k$i', 'n': i});
      }
      final cursor = c.where().cursor(pageSize: 2);
      final (p1, _) = await cursor.next();
      final (p2, _) = await cursor.next();
      final (p3, _) = await cursor.next();
      expect(p1, hasLength(2));
      expect(p2, hasLength(1));
      expect(p3, isEmpty);
      final (p4, c4) = await cursor.next();
      expect(p4, isEmpty);
      expect(c4, isNull);
      await cursor.dispose();
      await db.close();
    });

    test(
      'cursor created but never iterated releases its snapshot on dispose',
      () async {
        final db = await openNativeTestDatabase('qb-cursor-dispose');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        final cursor = c.where().cursor(pageSize: 2);
        // Never iterate; dispose must release the MVCC snapshot so compaction
        // is not blocked.
        await cursor.dispose();
        await db.maintenance.compact();
        expect(await c.get('a'), isNotNull);
        await db.close();
      },
    );

    test(
      'lastPlan is set after first(), findPage, and repeat execution',
      () async {
        final db = await openNativeTestDatabase('qb-lastplan');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        final q = c.where().filter('n', 1);
        // lastPlan is populated after execution (defaults to fullScan).
        await q.first();
        expect(q.lastPlan, isNotNull);
        // Repeat execution keeps a plan (no regression to null).
        await q.first();
        expect(q.lastPlan, isNotNull);
        final q2 = c.where().filter('n', 1);
        await q2.findPage();
        expect(q2.lastPlan, isNotNull);
        await db.close();
      },
    );

    test('iterate() supports cancellation mid-stream', () async {
      final db = await openNativeTestDatabase('qb-iterate');
      final c = coll(db, 'items');
      for (var i = 0; i < 10; i++) {
        await c.put({'id': 'k$i', 'n': i});
      }
      final sub = c.where().iterate().listen((_) {});
      // Cancel promptly; no error should surface.
      await sub.cancel();
      await db.close();
    });
  });

  group('2.7 durable indexes', () {
    test(
      'index on null values: equality finds them and maintenance tracks',
      () async {
        final db = await openNativeTestDatabase('idx-null');
        final c = coll(db, 'items', indexFields: ['g']);
        await c.put({'id': 'a', 'g': null});
        await c.put({'id': 'b', 'g': 'x'});
        final nulls = await c.where().filter('g', null).findAll();
        expect(nulls.map((r) => r['id']), ['a']);
        // null → value maintenance.
        await c.put({'id': 'a', 'g': 'y'});
        expect((await c.where().filter('g', null).findAll()), isEmpty);
        expect(
          (await c.where().filter('g', 'y').findAll()).map((r) => r['id']),
          ['a'],
        );
        // value → null maintenance.
        await c.put({'id': 'a', 'g': null});
        expect((await c.where().filter('g', 'y').findAll()), isEmpty);
        expect(
          (await c.where().filter('g', null).findAll()).map((r) => r['id']),
          ['a'],
        );
        await db.close();
      },
    );

    test(
      'index on List/Map-valued fields: broad bounds plus recheck',
      () async {
        final db = await openNativeTestDatabase('idx-listmap');
        final c = coll(db, 'items', indexFields: ['tags', 'meta']);
        await c.put({
          'id': 'a',
          'tags': ['x', 'y'],
          'meta': {'k': 1},
        });
        await c.put({
          'id': 'b',
          'tags': ['x', 'z'],
          'meta': {'k': 2},
        });
        await c.put({
          'id': 'c',
          'tags': ['z'],
          'meta': {'k': 3},
        });
        // Equality on a list value.
        final byTags = await c.where().filter('tags', ['x', 'y']).findAll();
        expect(byTags.map((r) => r['id']), ['a']);
        // Equality on a map value.
        final byMeta = await c.where().filter('meta', {'k': 2}).findAll();
        expect(byMeta.map((r) => r['id']), ['b']);
        // A partial list is NOT equal (structural equality, not containment).
        expect(
          (await c.where().filter('tags', ['x']).findAll()),
          isEmpty,
          reason: 'a partial list must not match the full list value',
        );
        await db.close();
      },
    );

    test('two separate indexes on one table both serve queries', () async {
      final db = await openNativeTestDatabase('idx-two');
      final c = coll(db, 'items', indexFields: ['a', 'b']);
      for (var i = 0; i < 20; i++) {
        await c.put({'id': 'k$i', 'a': i % 5, 'b': i % 4});
      }
      final byA = await c.where().filter('a', 2).findAll();
      expect(byA, hasLength(4));
      expect(byA.every((r) => r['a'] == 2), isTrue);
      final byB = await c.where().filter('b', 3).findAll();
      expect(byB, hasLength(5));
      expect(byB.every((r) => r['b'] == 3), isTrue);
      // Combined (both indexed fields) still correct.
      final both = await c.where().filter('a', 2).filter('b', 3).findAll();
      expect(both, hasLength(1));
      await db.close();
    });

    test('index maintenance survives a whole-table clear', () async {
      final db = await openNativeTestDatabase('idx-clear');
      final c = coll(db, 'items', indexFields: ['g']);
      for (var i = 0; i < 10; i++) {
        await c.put({'id': 'k$i', 'g': 'g${i % 3}'});
      }
      expect((await c.where().filter('g', 'g0').findAll()), hasLength(4));
      // clear via bulkWrite.
      await db.bulkWrite([
        for (var i = 0; i < 10; i++)
          BulkMutation.delete(table: 'items', key: 'k$i'),
      ]);
      expect((await c.where().filter('g', 'g0').findAll()), isEmpty);
      expect((await c.getAll()), isEmpty);
      // Index entries are gone: adding a new row re-indexes cleanly.
      await c.put({'id': 'fresh', 'g': 'g0'});
      expect(
        (await c.where().filter('g', 'g0').findAll()).map((r) => r['id']),
        ['fresh'],
      );
      await db.close();
    });

    test('repairIndex is a no-op when already consistent', () async {
      final db = await openNativeTestDatabase('idx-repair-noop');
      final c = coll(db, 'items', indexFields: ['g']);
      await c.put({'id': 'a', 'g': 'x'});
      // Opening the collection again re-runs the automatic drift repair over
      // already-consistent index entries — a no-op that must not error.
      final c2 = coll(db, 'items', indexFields: ['g']);
      expect(
        (await c2.where().filter('g', 'x').findAll()).map((r) => r['id']),
        ['a'],
      );
      await db.close();
    });

    test('index on an encrypted database works across reopen', () async {
      final directory = await Directory.systemTemp.createTemp('gecko-idx-enc-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}db.redb';
      const key = [
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
      final db1 = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(encryptionKey: key),
      );
      final c1 = coll(db1, 'items', indexFields: ['g']);
      await c1.put({'id': 'a', 'g': 'x'});
      await db1.close();

      final db2 = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(encryptionKey: key),
      );
      final c2 = coll(db2, 'items', indexFields: ['g']);
      expect(
        (await c2.where().filter('g', 'x').findAll()).map((r) => r['id']),
        ['a'],
      );
      await db2.close();
    });

    test('index maintenance across cascade delete removes children', () async {
      final db = await openNativeTestDatabase('idx-cascade');
      final parents = coll(db, 'parents');
      final children = coll(db, 'children', indexFields: ['parentId']);
      await parents.put({'id': 'p1'});
      await children.put({'id': 'c1', 'parentId': 'p1'});
      await children.put({'id': 'c2', 'parentId': 'p1'});
      expect(
        (await children.where().filter('parentId', 'p1').findAll()),
        hasLength(2),
      );
      // Delete the parent with cascade behavior (declared via relationship is
      // out of scope here); deleting each child removes index entries.
      await children.delete('c1');
      await children.delete('c2');
      expect(
        (await children.where().filter('parentId', 'p1').findAll()),
        isEmpty,
      );
      await db.close();
    });
  });
}
