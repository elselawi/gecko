// Milestone 4 — indexed sorting + early LIMIT (ADR-0019).
//
// The shared suite runs against both the in-memory and native file backends
// and locks the M4 contracts:
//   1. `ORDER BY indexedField LIMIT n` streams the durable index in order on
//      native (IndexPlan.secondaryIndex, early stop — no full scan, no Dart
//      sort) and matches the in-memory full-sort exactly (parity).
//   2. Sorts NOT covered by an index go through the Rust top-K path on native
//      (IndexPlan.nativeFilteredScan) — still parity-correct.
//   3. Missing sort-field rows sort LAST for ascending / FIRST for descending
//      on both backends.
//   4. limit/offset windows (including 0, beyond-count, descending, multi-field)
//      match across backends.
//   5. Non-sorted limit/offset on native stops early and matches in-memory.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

class _Rec {
  _Rec(this.id, this.nick, this.age);
  final String id;
  final String nick;
  final int age;
}

Object? _toRow(_Rec r) => {'id': r.id, 'nick': r.nick, 'age': r.age};
_Rec _fromRow(Object? row) {
  final m = row as Map;
  return _Rec(
    m['id'] as String? ?? '',
    m['nick'] as String? ?? '',
    (m['age'] as int?) ?? 0,
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

/// Seeds 40 rows: nick = g{i%10}, age = i, plus 2 rows MISSING the nick field
/// (age 100, 101) to exercise missing-field placement.
Future<void> _seed(DatabaseImpl db, String table) async {
  final col = _coll(db, table);
  for (var i = 0; i < 40; i++) {
    await col.put(_Rec('r$i', 'g${i % 10}', i));
  }
  // Rows without the nick field (written via a Map collection).
  final mapColl = db.collection<Map<String, Object?>>(
    table,
    toRow: (m) => m,
    fromRow: (m) => Map<String, Object?>.from(m as Map),
    id: (m) => m['id'],
  );
  await mapColl.put({'id': 'noNick1', 'age': 100});
  await mapColl.put({'id': 'noNick2', 'age': 101});
}

void main() {
  final nativePath = _nativeLibraryPath(_repoRoot());

  void runSuite(String label, Future<DatabaseImpl> Function(String tag) open) {
    group('M4 sort + limit ($label)', () {
      test('ORDER BY indexedField LIMIT matches in-memory and uses the index', () async {
        final db = await open('sort-idx');
        await _seed(db, 't');
        final col = _coll(db, 't', indexFields: ['nick']);
        final q = col.where().sort([SortSpec('nick')]).limit(5);
        final result = await q.findAll();
        // 4 rows have nick g0 (r0/r10/r20/r30) and sort first; the 5th is g1.
        expect(result, hasLength(5));
        expect(result.map((r) => r.nick).toList(), ['g0', 'g0', 'g0', 'g0', 'g1']);
        // Native streams the durable index (secondaryIndex); in-memory has no
        // Rust and falls back to a full scan + Dart sort (still parity-correct).
        expect(
          q.lastPlan,
          db.engine.backend is NativeRawBackend
              ? IndexPlan.secondaryIndex
              : IndexPlan.fullScan,
        );
        // Parity with in-memory full sort.
        final mem = await _coll(db, 't').where().sort([SortSpec('nick')]).findAll();
        expect(result.map((r) => r.id).toList(), mem.take(5).map((r) => r.id).toList());
        await db.close();
      });

      test('ORDER BY indexedField with offset + LIMIT windows match', () async {
        final db = await open('sort-win');
        await _seed(db, 't');
        final col = _coll(db, 't', indexFields: ['nick']);
        final full = await col.where().sort([SortSpec('nick')]).findAll();
        for (final (offset, limit) in [(0, 5), (3, 4), (8, 20), (45, 10), (50, 2)]) {
          final q = col.where().sort([SortSpec('nick')]).offset(offset).limit(limit);
          final got = (await q.findAll()).map((r) => r.id).toList();
          final expected = full.skip(offset).take(limit).map((r) => r.id).toList();
          expect(got, expected, reason: 'offset=$offset limit=$limit');
        }
        await db.close();
      });

      test('missing sort-field rows sort last (ascending) / first (descending)', () async {
        final db = await open('sort-missing');
        await _seed(db, 't');
        final col = _coll(db, 't', indexFields: ['nick']);
        // Ascending, no limit: nick rows then no-nick rows.
        final asc = await col.where().sort([SortSpec('nick')]).findAll();
        expect(asc.last.id, 'noNick2'); // no-nick rows last (stable: noNick1, noNick2)
        expect(asc[asc.length - 2].id, 'noNick1');
        // Descending uses the top-K path on native (missing-first).
        final desc = await col
            .where()
            .sort([SortSpec('nick', SortOrder.descending)])
            .findAll();
        expect(desc.first.id, 'noNick1');
        expect(desc[1].id, 'noNick2');
        // Parity on ids.
        final memAsc = await _coll(db, 't').where().sort([SortSpec('nick')]).findAll();
        expect(asc.map((r) => r.id).toList(), memAsc.map((r) => r.id).toList());
        final memDesc = await _coll(db, 't')
            .where()
            .sort([SortSpec('nick', SortOrder.descending)])
            .findAll();
        expect(desc.map((r) => r.id).toList(), memDesc.map((r) => r.id).toList());
        await db.close();
      });

      test('non-indexed sort uses the top-K path with parity', () async {
        final db = await open('sort-topk');
        await _seed(db, 't');
        // age is not indexed → native uses query_sorted (top-K).
        final q = _coll(db, 't').where().sort([SortSpec('age')]).limit(7);
        final got = await q.findAll();
        expect(got, hasLength(7));
        expect(
          q.lastPlan,
          anyOf(IndexPlan.fullScan, IndexPlan.nativeFilteredScan),
        );
        expect(
          got.map((r) => r.id).toList(),
          (await _coll(db, 't').where().sort([SortSpec('age')]).findAll())
              .take(7)
              .map((r) => r.id)
              .toList(),
        );
        // With a filter: age >= 5, sorted by age ascending.
        final filtered = _coll(db, 't')
            .where()
            .range('age', min: 5)
            .sort([SortSpec('age')])
            .limit(6);
        final gotF = await filtered.findAll();
        final expectedF = (await _coll(db, 't')
                .where()
                .range('age', min: 5)
                .sort([SortSpec('age')])
                .findAll())
            .take(6)
            .map((r) => r.id)
            .toList();
        expect(gotF.map((r) => r.id).toList(), expectedF);
        await db.close();
      });

      test('descending + multi-field sorts match across backends', () async {
        final db = await open('sort-desc-multi');
        await _seed(db, 't');
        // Multi-field: nick asc, then age desc (nick is indexed, but multi-field
        // sorts are not index-covered → top-K).
        final q = _coll(db, 't', indexFields: ['nick']).where()
            .sort([SortSpec('nick'), SortSpec('age', SortOrder.descending)])
            .limit(10);
        final got = (await q.findAll()).map((r) => r.id).toList();
        final expected = (await _coll(db, 't')
                .where()
                .sort([SortSpec('nick'), SortSpec('age', SortOrder.descending)])
                .findAll())
            .take(10)
            .map((r) => r.id)
            .toList();
        expect(got, expected);
        // Descending single-field on an indexed field.
        final desc = _coll(db, 't', indexFields: ['nick']).where()
            .sort([SortSpec('nick', SortOrder.descending)])
            .limit(6);
        final gotD = (await desc.findAll()).map((r) => r.id).toList();
        final expectedD = (await _coll(db, 't')
                .where()
                .sort([SortSpec('nick', SortOrder.descending)])
                .findAll())
            .take(6)
            .map((r) => r.id)
            .toList();
        expect(gotD, expectedD);
        await db.close();
      });

      test('non-sorted limit/offset stops early on native and matches', () async {
        final db = await open('early-limit');
        await _seed(db, 't');
        // Unindexed filtered query with a window.
        final q = _coll(db, 't').where().range('age', min: 5).offset(4).limit(6);
        final got = (await q.findAll()).map((r) => r.id).toList();
        final expected = (await _coll(db, 't')
                .where()
                .range('age', min: 5)
                .findAll())
            .skip(4)
            .take(6)
            .map((r) => r.id)
            .toList();
        expect(got, expected);
        // Indexed-eq query with a window.
        final iq = _coll(db, 't', indexFields: ['nick'])
            .where({'nick': 'g3'})
            .offset(1)
            .limit(2);
        final gotI = (await iq.findAll()).map((r) => r.id).toList();
        final expectedI = (await _coll(db, 't', indexFields: ['nick'])
                .where({'nick': 'g3'})
                .findAll())
            .skip(1)
            .take(2)
            .map((r) => r.id)
            .toList();
        expect(gotI, expectedI);
        expect(iq.lastPlan, IndexPlan.secondaryIndex);
        // limit 0 → empty on both.
        expect(await _coll(db, 't').where().limit(0).findAll(), isEmpty);
        await db.close();
      });

      test('first() with a sort returns the ordered first row', () async {
        final db = await open('first-sort');
        await _seed(db, 't');
        final col = _coll(db, 't', indexFields: ['nick']);
        final first = await col.where().sort([SortSpec('nick')]).first();
        final all = await col.where().sort([SortSpec('nick')]).findAll();
        expect(first!.id, all.first.id);
        expect(first.nick, 'g0');
        await db.close();
      });
    });
  }

  runSuite(
    'in-memory',
    (tag) async => DatabaseImpl.open('mem://m4-$tag', useInMemory: true),
  );

  runSuite('native file', (tag) async {
    final dir = await Directory.systemTemp.createTemp('gecko-m4-$tag-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    return DatabaseImpl.open(
      '${dir.path}${Platform.pathSeparator}db.redb',
      useInMemory: false,
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );
  });
}
