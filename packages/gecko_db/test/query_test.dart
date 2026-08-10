import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _User {
  _User(this.id, this.name, this.age, [this.tags]);
  final String id;
  final String name;
  final int age;
  final List<String>? tags;
}

Object? _toRow(_User u) => {
  'name': u.name,
  'age': u.age,
  if (u.tags != null) 'tags': u.tags,
};
_User _fromRow(Object? row) {
  final m = row as Map;
  return _User(
    '',
    m['name'] as String,
    m['age'] as int,
    (m['tags'] as List?)?.cast<String>(),
  );
}

Object? _id(_User u) => u.id;

Future<DatabaseImpl> _open(String name) => openNativeTestDatabase('query-$name');

void main() {
  group('filter / findAll', () {
    test('equality filter returns only matching rows', () async {
      final db = await _open('eq');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('a', 'Alice', 30));
      await col.put(_User('b', 'Bob', 40));
      await col.put(_User('c', 'Cara', 30));

      final result = await col.where({'age': 30}).findAll();
      expect(result.map((u) => u.name), ['Alice', 'Cara']);
      await db.close();
    });

    test('range filter', () async {
      final db = await _open('range');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 1; i <= 10; i++) {
        await col.put(_User('u$i', 'U$i', 20 + i));
      }
      final result = await col.where().range('age', min: 25, max: 27).findAll();
      expect(result.map((u) => u.age).toList(), [25, 26, 27]);
      await db.close();
    });

    test('compound filters (AND) via chained filter()', () async {
      final db = await _open('compound');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('a', 'Alice', 30));
      await col.put(_User('b', 'Bob', 40));
      await col.put(_User('c', 'Carol', 30));

      final result = await col
          .where()
          .filter('age', 30)
          .filter('name', 'Alice')
          .findAll();
      expect(result, hasLength(1));
      expect(result.single.name, 'Alice');
      await db.close();
    });

    test('collaborative filter on an empty collection returns empty', () async {
      final db = await _open('empty');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      expect(await col.where({'age': 1}).findAll(), isEmpty);
      await db.close();
    });
  });

  group('sorting', () {
    test('ascending, descending, and multi-field sort', () async {
      final db = await _open('sort');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('a', 'Alice', 30));
      await col.put(_User('b', 'Bob', 20));
      await col.put(_User('c', 'Cara', 30));

      final asc = await col.where().sort([const SortSpec('age')]).findAll();
      expect(asc.map((u) => u.name).toList(), ['Bob', 'Alice', 'Cara']);

      final desc = await col.where().sort([
        const SortSpec('age', SortOrder.descending),
      ]).findAll();
      expect(desc.map((u) => u.name).toList(), ['Alice', 'Cara', 'Bob']);

      // Multi-field: age asc, then name desc.
      final multi = await col.where().sort([
        const SortSpec('age'),
        const SortSpec('name', SortOrder.descending),
      ]).findAll();
      expect(multi.map((u) => u.name).toList(), ['Bob', 'Cara', 'Alice']);
      await db.close();
    });

    test(
      'missing sort field: last for ascending, first for descending',
      () async {
        final db = await _open('missing');
        final col = db.collection<_Object>(
          'objs',
          toRow: (o) => o.row,
          fromRow: (Object? r) => _Object(Map<Object?, Object?>.from(r as Map)),
          id: (o) => o.row['id'],
        );
        await col.put(_Object({'id': 1, 'n': 1}));
        await col.put(_Object({'id': 2})); // no 'n'
        await col.put(_Object({'id': 3, 'n': 0}));

        final asc = await col.where().sort([const SortSpec('n')]).findAll();
        expect(asc.map((o) => o.row['id']).toList(), [
          3,
          1,
          2,
        ], reason: 'missing n last');

        final desc = await col.where().sort([
          const SortSpec('n', SortOrder.descending),
        ]).findAll();
        expect(desc.map((o) => o.row['id']).toList(), [
          2,
          1,
          3,
        ], reason: 'missing n first');
        await db.close();
      },
    );
  });

  group('limit / offset', () {
    test('limit and offset slice the ordered result', () async {
      final db = await _open('limit');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 1; i <= 10; i++) {
        await col.put(_User('u$i', 'U$i', 20 + i));
      }
      final page = await col
          .where()
          .sort([const SortSpec('age')])
          .limit(3)
          .offset(2)
          .findAll();
      expect(page.map((u) => u.age).toList(), [23, 24, 25]);
      await db.close();
    });
  });

  group('count / distinct / first', () {
    test('count matches findAll length', () async {
      final db = await _open('count');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 0; i < 50; i++) {
        await col.put(_User('u$i', 'U$i', 20 + (i % 5)));
      }
      final query = col.where().range('age', min: 22, max: 24);
      expect(await query.count(), (await query.findAll()).length);
      await db.close();
    });

    test('distinct returns unique values', () async {
      final db = await _open('distinct');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 0; i < 20; i++) {
        await col.put(_User('u$i', 'U$i', 20 + (i % 4)));
      }
      final distinct = await col.where().distinct('age');
      expect(distinct.toSet(), {20, 21, 22, 23});
      expect(distinct.length, 4);
      await db.close();
    });

    test('first returns the first result or null', () async {
      final db = await _open('first');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('a', 'A', 30));
      await col.put(_User('b', 'B', 30));
      final first = await col.where({'age': 30}).first();
      expect(first, isNotNull);
      expect(await col.where({'age': 99}).first(), isNull);
      await db.close();
    });
  });

  group('cursor pagination', () {
    test('pages are disjoint, order-preserving, and exhaustive', () async {
      final db = await _open('cursor');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 1; i <= 10; i++) {
        await col.put(_User('u$i', 'U$i', 20 + i));
      }
      final query = col.where().sort([const SortSpec('age')]);
      final collected = <int>[];
      Object? cursor;
      do {
        final (page, next) = await query.findPage(
          afterKey: cursor,
          pageSize: 3,
        );
        collected.addAll(page.map((u) => u.age));
        cursor = next;
        if (page.isEmpty) break;
      } while (cursor != null);

      expect(collected, [21, 22, 23, 24, 25, 26, 27, 28, 29, 30]);
      expect(collected.toSet().length, 10);
      await db.close();
    });

    test('resuming from an explicit cursor skips prior page', () async {
      final db = await _open('cursor2');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 1; i <= 5; i++) {
        await col.put(_User('u$i', 'U$i', 20 + i));
      }
      final query = col.where().sort([const SortSpec('age')]);
      final (first, cursor) = await query.findPage(pageSize: 2);
      expect(first, hasLength(2));
      expect(cursor, isNotNull);
      // Resume after the explicit cursor.
      final (second, _) = await query.findPage(afterKey: cursor, pageSize: 2);
      expect(second.map((u) => u.age).toList(), [23, 24]);
      await db.close();
    });

    test('findPage defaults page size when none provided', () async {
      final db = await _open('cursor3');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      for (var i = 1; i <= 60; i++) {
        await col.put(_User('u$i', 'U$i', 20 + i));
      }
      // No pageSize and no limit → default page size 50.
      final (page, cursor) = await col.where().findPage();
      expect(page, hasLength(50));
      expect(cursor, isNotNull);
      await db.close();
    });
  });

  group('reactive filtered query watch()', () {
    test(
      're-emits when a record starts matching, stops matching, or updates',
      () async {
        final db = await _open('watchq');
        final col = db.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await col.put(_User('a', 'A', 30)); // matches
        await col.put(_User('b', 'B', 10)); // does not match (age filter 25+)

        final query = col.where().range('age', min: 25);
        final snapshots = <int>[];
        final sub = query.watch().listen((list) => snapshots.add(list.length));
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.first, 1);

        // b now matches.
        await col.put(_User('b', 'B', 30));
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.last, 2);

        // a stops matching.
        await col.put(_User('a', 'A', 10));
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.last, 1);

        // Update a row that stays matching.
        await col.put(_User('b', 'B2', 31));
        await Future<void>.delayed(Duration.zero);
        expect(snapshots.last, 1);

        await sub.cancel();
        await db.close();
      },
    );

    test('does not re-emit for writes to another collection', () async {
      final db = await _open('watchqiso');
      final colA = db.collection<_User>(
        'a',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      final colB = db.collection<_User>(
        'b',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await colA.put(_User('a', 'A', 30));

      var emissions = 0;
      final sub = colA.where({'age': 30}).watch().listen((_) => emissions++);
      await Future<void>.delayed(Duration.zero);
      final initial = emissions;

      await colB.put(_User('b', 'B', 30));
      await Future<void>.delayed(Duration.zero);
      expect(emissions, initial, reason: 'write to B must not re-emit A query');

      await sub.cancel();
      await db.close();
    });
  });

  group('prefix search', () {
    test('matches prefixes and excludes non-matching', () async {
      final db = await _open('prefix');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('a', 'Alice', 30));
      await col.put(_User('b', 'Alan', 40));
      await col.put(_User('c', 'Bob', 50));

      final filter = Filter.prefix('name', 'Al');
      final all = await col.where().findAll();
      // Filter is a public type; verify directly on the filter.
      expect(
        all
            .where((u) => filter.matchesValue(u.name))
            .map((u) => u.name)
            .toList(),
        ['Alice', 'Alan'],
      );
      await db.close();
    });
  });

  group('diagnostics: index plan', () {
    test('lastPlan defaults to full scan and is set by execution', () async {
      final db = await _open('plan');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('a', 'A', 30));
      final query = col.where({'age': 30}) as QueryImpl<_User>;
      expect(query.lastPlan, IndexPlan.fullScan);
      await query.findAll();
      expect(query.lastPlan, IndexPlan.fullScan);
      await db.close();
    });
  });
}

class _Object {
  _Object(this.row);
  final Map<Object?, Object?> row;
}
