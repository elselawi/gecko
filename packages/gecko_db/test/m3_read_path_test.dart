// Milestone 3 — read-path completion + getMany (ADR-0018).
//
// The suite runs against the native file backend and locks the M3 contracts:
//   1. `iterate()` routes through the native fast path (indexed eq + predicate
//      push) instead of the old per-id `snap.read` loop.
//   2. `count()` / `distinct()` push the aggregate to Rust on native
//      (no row transfer).
//   3. `getMany(ids)` is a batched point-read (one native hop) returning rows
//      in input order, skipping absent ids, and observing the transaction
//      overlay inside a transaction.
//   4. `first()` / `findPage()` stay routed through the native fast path.
//   5. Relationship eager-loading (children of an indexed FK) still resolves
//      correctly — it now batches via `getMany`.
import 'dart:io';

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

Collection<_Rec> _coll(
  DatabaseImpl db,
  String table, {
  List<String>? indexFields,
}) => db.collection<_Rec>(
  table,
  toRow: _toRow,
  fromRow: _fromRow,
  id: _id,
  indexFields: indexFields,
);

Future<void> _seed(
  DatabaseImpl db,
  String table, {
  List<String>? indexFields,
}) async {
  final col = _coll(db, table, indexFields: indexFields);
  for (var i = 0; i < 40; i++) {
    // Groups repeat every 10; ages are i so filters are exact.
    await col.put(_Rec('r$i', 'n$i', i, 'g${i % 10}'));
  }
}

void main() {
  final nativePath = _nativeLibraryPath(_repoRoot());

  void runSuite(String label, Future<DatabaseImpl> Function(String tag) open) {
    group('M3 read path ($label)', () {
      test(
        'iterate() matches findAll() and routes through the fast path',
        () async {
          final db = await open('iterate');
          await _seed(db, 't');

          // Unindexed predicate: iterate must go through the predicate path
          // (nativeFilteredScan on native, fullScan in-memory) — NOT a bypass.
          final unindexed = _coll(db, 't').where({'nick': 'g3'});
          final iterated = await unindexed.iterate().toList();
          expect(iterated, hasLength(4));
          expect(
            unindexed.lastPlan,
            anyOf(IndexPlan.fullScan, IndexPlan.nativeFilteredScan),
          );
          expect(
            iterated.map((r) => r.id).toSet(),
            (await unindexed.findAll()).map((r) => r.id).toSet(),
          );

          // Indexed-eq: iterate must use the index (single hop on native).
          final indexed = _coll(
            db,
            't',
            indexFields: ['nick'],
          ).where({'nick': 'g3'});
          final indexedIds = await indexed.iterate().map((r) => r.id).toList();
          expect(indexedIds, hasLength(4));
          expect(indexed.lastPlan, IndexPlan.secondaryIndex);
          await db.close();
        },
      );

      test(
        'count() matches findAll().length and pushes the aggregate on native',
        () async {
          final db = await open('count');
          await _seed(db, 't');
          final q = _coll(db, 't').where().range('age', min: 10, max: 19);
          final all = await q.findAll();
          expect(all, hasLength(10));
          expect(await q.count(), 10);
          expect(
            q.lastPlan,
            anyOf(IndexPlan.fullScan, IndexPlan.nativeFilteredScan),
          );

          // Empty predicate counts the whole table.
          final allCount = _coll(db, 't').where();
          expect(await allCount.count(), 40);

          // Indexed-eq count/distinct keep the index path (secondary != null
          // exercises the aggregate-pushdown fallback branch). One collection
          // object is reused for both (re-creating the same indexed collection
          // would schedule a redundant rebuild).
          final indexedCol = _coll(db, 't', indexFields: ['nick']);
          final indexed = indexedCol.where({'nick': 'g3'});
          expect(await indexed.count(), 4);
          expect(indexed.lastPlan, IndexPlan.secondaryIndex);
          final indexedDistinct = indexedCol.where({'nick': 'g3'});
          expect(await indexedDistinct.distinct('nick'), ['g3']);
          await db.close();
        },
      );

      test(
        'distinct() matches the Dart set semantics on both backends',
        () async {
          final db = await open('distinct');
          await _seed(db, 't');
          final q = _coll(db, 't').where();
          final nickValues = await q.distinct('nick');
          expect(nickValues.toSet(), {for (var i = 0; i < 10; i++) 'g$i'});
          expect(nickValues, hasLength(10));

          // Filtered distinct.
          final filtered = _coll(db, 't').where().range('age', min: 0, max: 19);
          expect((await filtered.distinct('nick')).toSet(), {
            'g0',
            'g1',
            'g2',
            'g3',
            'g4',
            'g5',
            'g6',
            'g7',
            'g8',
            'g9',
          });
          await db.close();
        },
      );

      test('first() and findPage() stay correct on the fast path', () async {
        final db = await open('first-page');
        await _seed(db, 't');
        final q = _coll(db, 't').where().range('age', min: 10, max: 19);
        final first = await q.first();
        expect(first, isNotNull);
        expect((await q.findAll()).first.id, first!.id);

        final (page, cursor) = await q.findPage(pageSize: 3);
        expect(page, hasLength(3));
        expect(cursor, isNotNull);
        final (page2, _) = await q.findPage(afterKey: cursor, pageSize: 3);
        expect(page2, hasLength(3));
        // Pages are disjoint.
        expect(
          page
              .map((r) => r.id)
              .toSet()
              .intersection(page2.map((r) => r.id).toSet()),
          isEmpty,
        );
        await db.close();
      });

      test(
        'getMany(ids) returns rows in input order, skipping absent ids',
        () async {
          final db = await open('getmany');
          await _seed(db, 't');
          final col = _coll(db, 't');
          final rows = await col.getMany(['r1', 'missing', 'r2', 'r3']);
          expect(rows.map((r) => r.id).toList(), ['r1', 'r2', 'r3']);
          expect(await col.getMany([]), isEmpty);
          expect(await col.getMany(['nope']), isEmpty);
          // A single id matches get().
          expect(
            (await col.getMany(['r5'])).single.id,
            (await col.get('r5'))!.id,
          );
          await db.close();
        },
      );

      test(
        'getMany(ids) observes the transaction overlay inside a txn',
        () async {
          final db = await open('getmany-txn');
          await _seed(db, 't');
          final col = _coll(db, 't');
          await db.writeTxn((txn) async {
            final tcol = txn.collection<_Rec>(
              't',
              toRow: _toRow,
              fromRow: _fromRow,
              id: _id,
            );
            await tcol.put(_Rec('staged', 'staged-name'));
            await tcol.delete('r0');
            // The overlay is visible: staged row appears, deleted row disappears.
            final rows = await tcol.getMany(['r0', 'staged', 'r1']);
            expect(rows.map((r) => r.id).toList(), ['staged', 'r1']);
            // Outside the txn the old state holds.
            final outer = await col.getMany(['r0', 'staged']);
            expect(outer.map((r) => r.id).toList(), ['r0']);
          });
          await db.close();
        },
      );

      test(
        'relationship children still resolve via the batched getMany path',
        () async {
          final db = await open('rel');
          final posts = db.collection<Map<String, Object?>>(
            'posts',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
            indexFields: ['authorId'],
          );
          final authors = db.collection<Map<String, Object?>>(
            'authors',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          final r = db.relationships;
          r.registerAccessors(
            'posts',
            RowAccessors(
              childIdOf: (row) => row['id'],
              parentIdOf: (row) => row['authorId'],
            ),
          );
          const rel = Relationship(
            name: 'author_posts',
            parentCollection: 'authors',
            childCollection: 'posts',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'authorId',
          );
          r.declare(rel);
          await authors.put({'id': 'a1'});
          await authors.put({'id': 'a2'});
          for (var i = 0; i < 50; i++) {
            await posts.put({'id': 'p$i', 'authorId': 'a${i % 5}'});
          }
          final before = db.engine.scannedRows;
          final kids = await db.relationships.children(rel, 'a1');
          expect(kids, hasLength(10));
          // The indexed FK lookup must not full-scan the child table.
          expect(db.engine.scannedRows, before);
          await db.close();
        },
      );
    });
  }

  runSuite('native file', (tag) async {
    final dir = await Directory.systemTemp.createTemp('gecko-m3-$tag-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    return DatabaseImpl.open(
      '${dir.path}${Platform.pathSeparator}db.redb',
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );
  });

  // Native-only: the new batched snapshot methods surface a typed error when
  // their snapshot has been released (worker-side unknown-snapshot guard).
  group('M3 native snapshot error paths', () {
    test('getMany/count/distinct on a dropped snapshot fail typed', () async {
      final dir = await Directory.systemTemp.createTemp('gecko-m3-err-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final db = await DatabaseImpl.open(
        '${dir.path}${Platform.pathSeparator}db.redb',
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      await _seed(db, 't');
      final snap = await db.engine.backend.snapshot() as NativeRawSnapshot;
      await snap.dispose();
      final key = ByteKey(const [1]);
      await expectLater(snap.getMany('t', [key]), throwsA(isA<GeckoError>()));
      await expectLater(
        snap.queryFilteredCount(table: 't', predicateBytes: const [1, 0]),
        throwsA(isA<GeckoError>()),
      );
      await expectLater(
        snap.queryFilteredDistinct(
          table: 't',
          predicateBytes: const [1, 0],
          field: 'nick',
        ),
        throwsA(isA<GeckoError>()),
      );
      await db.close();
    });
  });
}
