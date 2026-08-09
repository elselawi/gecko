// Workstream 3 — durable indexes, range-index support, and the snapshot-bound
// cursor contract. The shared suite runs against both the in-memory and
// native file backends; the durable close/reopen and drift-repair tests are
// native-only (they require real persistence).
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart' show geckoIndexTable;
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
  Iterable<String>? prefixFields,
}) => db.collection<_Rec>(
  table,
  toRow: _toRow,
  fromRow: _fromRow,
  id: _id,
  indexFields: indexFields,
  prefixFields: prefixFields,
);

Future<int> _durableIndexCount(DatabaseImpl db) async {
  final snap = await db.engine.backend.snapshot();
  try {
    return (await snap.scanAll(geckoIndexTable)).length;
  } finally {
    await snap.dispose();
  }
}

void main() {
  final nativePath = _nativeLibraryPath(_repoRoot());

  void runSuite(String label, Future<DatabaseImpl> Function(String tag) open) {
    group('WS3 range index + cursor ($label)', () {
      test(
        'range query on an indexed field uses the index, not a full scan',
        () async {
          final db = await open('range');
          final col = _coll(db, 't', indexFields: ['age']);
          for (var i = 0; i < 200; i++) {
            await col.put(_Rec('r$i', 'n$i', 20 + (i % 50)));
          }
          final before = db.engine.scannedRows;
          final q = col.where().range('age', min: 30, max: 34);
          final result = await q.findAll();
          expect(result, hasLength(20)); // 30..34 inclusive × 4 rows each
          expect(q.lastPlan, IndexPlan.secondaryIndex);
          expect(
            db.engine.scannedRows,
            before,
            reason: 'indexed range query must not full-scan',
          );
          await db.close();
        },
      );

      test('range with only one bound is index-served', () async {
        final db = await open('range-open');
        final col = _coll(db, 't', indexFields: ['age']);
        for (var i = 0; i < 100; i++) {
          await col.put(_Rec('r$i', 'n$i', i));
        }
        final minOnly = col.where().range('age', min: 90);
        expect((await minOnly.findAll()), hasLength(10));
        expect(minOnly.lastPlan, IndexPlan.secondaryIndex);
        final maxOnly = col.where().range('age', max: 9);
        expect((await maxOnly.findAll()), hasLength(10));
        expect(maxOnly.lastPlan, IndexPlan.secondaryIndex);
        final both = col.where().range('age', min: 45, max: 54);
        expect((await both.findAll()), hasLength(10));
        expect(both.lastPlan, IndexPlan.secondaryIndex);
        await db.close();
      });

      test('range + equality filters intersect through the index', () async {
        final db = await open('range-eq');
        final col = _coll(db, 't', indexFields: ['name', 'age']);
        for (var i = 0; i < 200; i++) {
          // name-3 rows are exactly i = 3,13,...,193 (age = i).
          await col.put(_Rec('r$i', 'name-${i % 10}', i));
        }
        final q = col.where({'name': 'name-3'}).range('age', min: 30, max: 34);
        final result = await q.findAll();
        // Only i=33 matches both filters (name-3 and age in 30..34).
        expect(result.single.id, 'r33');
        expect(q.lastPlan, IndexPlan.secondaryIndex);
        await db.close();
      });

      test('unindexed range query falls back to a full scan', () async {
        final db = await open('range-unindexed');
        final col = _coll(db, 't');
        for (var i = 0; i < 50; i++) {
          await col.put(_Rec('r$i', 'n$i', i));
        }
        final q = col.where().range('age', min: 10, max: 19);
        expect((await q.findAll()), hasLength(10));
        expect(q.lastPlan, IndexPlan.fullScan);
        await db.close();
      });

      test(
        'rollback leaves no durable index entries for uncommitted rows',
        () async {
          final db = await open('rollback');
          final col = _coll(db, 't', indexFields: ['name']);
          await col.put(_Rec('a', 'Alpha'));
          try {
            await db.writeTxn((txn) async {
              await txn
                  .collection<_Rec>(
                    't',
                    toRow: _toRow,
                    fromRow: _fromRow,
                    id: _id,
                    indexFields: ['name'],
                  )
                  .put(_Rec('b', 'Beta'));
              throw StateError('rollback');
            });
          } on StateError {
            // expected
          }
          expect(await col.where({'name': 'Beta'}).findAll(), isEmpty);
          expect(
            await _durableIndexCount(db),
            1,
            reason: 'only "a" is committed',
          );
          await db.close();
        },
      );

      test(
        'snapshot-bound cursor pages exhaustively with no dupes/drops',
        () async {
          final db = await open('cursor');
          final col = _coll(db, 't', indexFields: ['name']);
          for (var i = 0; i < 100; i++) {
            await col.put(_Rec('r${i.toString().padLeft(3, '0')}', 'n$i'));
          }
          final cursor = col
              .where()
              .sort([const SortSpec('name')])
              .cursor(pageSize: 17);
          final seen = <String>{};
          var pages = 0;
          while (true) {
            final (page, next) = await cursor.next();
            if (page.isEmpty && next == null) break;
            pages++;
            expect(page.length, lessThanOrEqualTo(17));
            for (final rec in page) {
              expect(seen.add(rec.id), isTrue, reason: 'duplicate ${rec.id}');
            }
            if (page.length < 17) break;
          }
          expect(seen, hasLength(100));
          expect(pages, greaterThanOrEqualTo(6));
          await cursor.dispose();
          await db.close();
        },
      );

      test(
        'cursor is frozen: concurrent writes never disturb pagination',
        () async {
          final db = await open('cursor-frozen');
          final col = _coll(db, 't');
          for (var i = 0; i < 60; i++) {
            await col.put(_Rec('r${i.toString().padLeft(3, '0')}', 'n$i'));
          }
          final cursor = col.where().cursor(pageSize: 10);
          final seen = <String>{};
          for (var page = 0; page < 3; page++) {
            final (items, _) = await cursor.next();
            for (final rec in items) {
              seen.add(rec.id);
            }
            // Concurrent mutation between pages.
            await col.put(_Rec('new-$page', 'x'));
            await col.delete('r${page.toString().padLeft(3, '0')}');
          }
          // Drain the rest of the frozen snapshot.
          while (true) {
            final (rest, _) = await cursor.next();
            if (rest.isEmpty) break;
            for (final rec in rest) {
              seen.add(rec.id);
            }
          }
          expect(seen, hasLength(60));
          for (var i = 0; i < 60; i++) {
            expect(seen.contains('r${i.toString().padLeft(3, '0')}'), isTrue);
          }
          expect(seen.any((id) => id.startsWith('new-')), isFalse);
          await cursor.dispose();
          await db.close();
        },
      );

      test('disposed cursor rejects further pages', () async {
        final db = await open('cursor-dispose');
        final col = _coll(db, 't');
        await col.put(_Rec('a', 'A'));
        final cursor = col.where().cursor();
        final (page, _) = await cursor.next();
        expect(page, hasLength(1));
        await cursor.dispose();
        await expectLater(cursor.next(), throwsA(isA<GeckoError>()));
        await db.close();
      });
    });
  }

  runSuite(
    'in-memory',
    (tag) async => DatabaseImpl.open('mem://ws3-$tag', useInMemory: true),
  );

  runSuite('native file', (tag) async {
    final dir = await Directory.systemTemp.createTemp('gecko-ws3-$tag-');
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

  // ---- Native-only durable index tests (require real persistence). ----

  group('WS3 durable indexes (native file)', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gecko-ws3-native-');
      path = '${dir.path}${Platform.pathSeparator}db.redb';
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<DatabaseImpl> openNative() => DatabaseImpl.open(
      path,
      useInMemory: false,
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );

    test('index entries are durable and survive close/reopen', () async {
      final db = await openNative();
      final col = _coll(db, 't', indexFields: ['name']);
      for (var i = 0; i < 50; i++) {
        await col.put(_Rec('r$i', 'name-${i % 5}'));
      }
      expect(await _durableIndexCount(db), 50);
      await db.close();

      final reopened = await openNative();
      try {
        final col2 = _coll(reopened, 't', indexFields: ['name']);
        final q = col2.where({'name': 'name-2'});
        final result = await q.findAll();
        expect(result, hasLength(10));
        expect(q.lastPlan, IndexPlan.secondaryIndex);
      } finally {
        await reopened.close();
      }
    });

    test(
      'drifted durable index is detected and repaired atomically on open',
      () async {
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['name']);
        for (var i = 0; i < 30; i++) {
          await col.put(_Rec('r$i', 'name-${i % 3}'));
        }
        expect(await _durableIndexCount(db), 30);
        await db.close();

        // Corrupt the durable index: drop half of its keys directly at the
        // backend level.
        final backend = await NativeRawBackend.open(
          path,
          nativeLibraryPath: nativePath,
        );
        final snap = await backend.snapshot();
        final entries = await snap.scanAll(geckoIndexTable);
        await snap.dispose();
        final ops = [
          for (final entry in entries.take(entries.length ~/ 2))
            RawDelete(geckoIndexTable, entry.key),
        ];
        await backend.applyBatch(ops);
        await backend.close();

        // Reopen: rebuild detects drift and repairs it.
        final reopened = await openNative();
        try {
          final col2 = _coll(reopened, 't', indexFields: ['name']);
          final q = col2.where({'name': 'name-1'});
          expect(await q.findAll(), hasLength(10));
          expect(q.lastPlan, IndexPlan.secondaryIndex);
          expect(await _durableIndexCount(reopened), 30);
        } finally {
          await reopened.close();
        }
      },
    );

    test('index/data atomicity across worker termination', () async {
      final db = await openNative();
      final col = _coll(db, 't', indexFields: ['name']);
      await col.put(_Rec('a', 'Alpha'));
      // Force the worker to tear down mid-session (deterministic finalizer
      // seam) and verify a fresh open sees a consistent primary + index.
      await (db.engine.backend as NativeRawBackend).disposeForTest();
      await db.close();

      final reopened = await openNative();
      try {
        final col2 = _coll(reopened, 't', indexFields: ['name']);
        final q = col2.where({'name': 'Alpha'});
        expect((await q.findAll()).single.id, 'a');
        expect(await _durableIndexCount(reopened), 1);
      } finally {
        await reopened.close();
      }
    });
  });
}
