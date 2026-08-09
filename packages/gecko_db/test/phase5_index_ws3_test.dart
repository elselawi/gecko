// Workstream 3 — durable indexes, range-index support, and the snapshot-bound
// cursor contract. The shared suite runs against both the in-memory and
// native file backends; the durable close/reopen and drift-repair tests are
// native-only (they require real persistence).
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart' show geckoIndexTable;
import 'package:gecko_db/src/query/predicate_codec.dart' show encodePredicate;
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

/// Increments the last byte with carry, mirroring durable_index_bounds' helper.
List<int> _bumpLast(List<int> bytes) {
  final out = List<int>.of(bytes);
  var i = out.length - 1;
  while (i >= 0) {
    if (out[i] < 0xFF) {
      out[i] += 1;
      return out.sublist(0, i + 1);
    }
    out.removeLast();
    i--;
  }
  return bytes;
}

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
        // A full-scan-class plan: the in-memory backend does a Dart scan
        // (fullScan); the native backend pushes the predicate to Rust
        // (nativeFilteredScan — Phase 2 step 2). Neither uses a secondary index.
        expect(
          q.lastPlan,
          anyOf(IndexPlan.fullScan, IndexPlan.nativeFilteredScan),
        );
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

  // Phase 2 native query fast path: indexed equality traverses the durable
  // `__gecko_index` table in one FRB hop instead of N per-id point reads.
  group('Phase 2 native query fast path (native file)', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('gecko-phase2-');
      path = '${dir.path}${Platform.pathSeparator}db.redb';
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<DatabaseImpl> openNative({int slowQueryThreshold = 0}) =>
        DatabaseImpl.open(
          path,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            slowQueryThresholdMicros: slowQueryThreshold,
          ),
        );

    test(
      'indexed equality matches the documented result set exactly',
      () async {
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 300; i++) {
          await col.put(_Rec('r$i', 'n$i', null, 'g${i % 7}'));
        }
        // Single covered equality filter — the Phase 2 native path.
        final q = col.where({'nick': 'g3'});
        final result = await q.findAll();
        expect(q.lastPlan, IndexPlan.secondaryIndex);
        // Indices 3,10,…,296 → 43 ids (300/7 = 42.857). The query is
        // unsorted, so compare as a set (order is unspecified).
        expect(result, hasLength(43));
        expect(
          result.map((r) => r.id).toSet(),
          equals({for (var i = 3; i < 300; i += 7) 'r$i'}),
        );
        await db.close();
      },
    );

    test(
      'indexed equality with a sort still agrees with the in-memory plan',
      () async {
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 200; i++) {
          await col.put(_Rec('r$i', 'n$i', 20 + (i % 50), 'g${i % 5}'));
        }
        final q = col.where({'nick': 'g2'}).sort([const SortSpec('age')]);
        final result = await q.findAll();
        expect(q.lastPlan, IndexPlan.secondaryIndex);
        // Every result is in group g2 and ages are ascending.
        for (final r in result) {
          expect(r.nick, 'g2');
        }
        final ages = result.map((r) => r.age!).toList();
        expect(ages, equals(ages..sort()));
        // Re-run without the fast path (in-memory backend) and compare the id
        // set — plans must agree across backends.
        final db2 = await DatabaseImpl.open(
          'mem://phase2-parity',
          useInMemory: true,
        );
        final col2 = _coll(db2, 't', indexFields: ['nick']);
        for (var i = 0; i < 200; i++) {
          await col2.put(_Rec('r$i', 'n$i', 20 + (i % 50), 'g${i % 5}'));
        }
        final q2 = col2.where({'nick': 'g2'}).sort([const SortSpec('age')]);
        final result2 = await q2.findAll();
        expect(
          result.map((r) => r.id).toSet(),
          equals(result2.map((r) => r.id).toSet()),
        );
        await db.close();
        await db2.close();
      },
    );

    test('fast path uses one backend hop, not N point reads', () async {
      final db = await openNative(slowQueryThreshold: 1);
      final col = _coll(db, 't', indexFields: ['nick']);
      for (var i = 0; i < 500; i++) {
        await col.put(_Rec('r$i', 'n$i', null, 'g${i % 5}'));
      }
      await col.where({'nick': 'g1'}).findAll();
      final rec = db.engine.recentSlowQueries.last;
      final t = rec.timings!;
      expect(rec.indexed, isTrue);
      expect(t.rowsScanned, 100, reason: 'one row per matched id (g1)');
      expect(t.rowsMatched, 100);
      // backendRead is the single queryIndexed hop: it must be much smaller
      // than 100 per-id point reads would be (~rawGetCold * 100 ~ 10 ms on
      // this machine). Assert < 4 ms as a conservative regression guard
      // (the Phase 1 baseline showed the N+1 path at ~33 ms for 1000 ids;
      // 100 ids would be ~3.3 ms, so the fast path must be well under that).
      expect(
        t.backendRead,
        lessThan(4000),
        reason: 'fast path is one boundary hop, not N point reads',
      );
      expect(t.total, lessThanOrEqualTo(rec.durationMicros));
      await db.close();
    });

    test(
      'non-snapshot NativeRawBackend.queryIndexed joins index→row in one hop',
      () async {
        // Exercises the non-snapshot variant (opens its own read txn) plus
        // the 'queryIndexed' dispatch case and NativeWorkerClient.queryIndexed.
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 60; i++) {
          await col.put(_Rec('r$i', 'n$i', null, 'g${i % 3}'));
        }
        final backend = db.engine.backend as NativeRawBackend;
        final codec = const DefaultWireCodec();
        // Build eq bounds for nick == 'g1' inline (the query impl does this
        // automatically; here we exercise the raw backend method).
        final full = codec.encode(['t', 'nick', 'g1', null]);
        final start = ByteKey(full.sublist(0, full.length - 1));
        final end = ByteKey(_bumpLast(start.bytes));
        final entries = await backend.queryIndexed(
          table: 't',
          start: start,
          end: end,
        );
        expect(entries, hasLength(20));
        // Every returned row decodes to nick == 'g1'.
        for (final entry in entries) {
          final row = codec.decode(entry.value ?? const []) as Map;
          expect(row['nick'], 'g1');
        }
        await db.close();
      },
    );

    test(
      'non-snapshot NativeRawBackend.queryFiltered pushes the predicate',
      () async {
        // Exercises the non-snapshot variant (opens its own read txn) plus
        // the 'queryFiltered' dispatch case and NativeWorkerClient.queryFiltered.
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 60; i++) {
          await col.put(_Rec('r$i', 'n$i', 20 + (i % 30), 'g${i % 3}'));
        }
        final backend = db.engine.backend as NativeRawBackend;
        // Predicate: age == 21 (i where 20 + (i % 30) == 21 → i % 30 == 1).
        final predBytes = encodePredicate([Filter.eq('age', 21)]);
        final entries = await backend.queryFiltered(
          table: 't',
          predicateBytes: predBytes,
        );
        // i ∈ {1, 31} → 2 matches.
        expect(entries, hasLength(2));
        final codec = const DefaultWireCodec();
        for (final entry in entries) {
          final row = codec.decode(entry.value ?? const []) as Map;
          expect(row['age'], 21);
        }
        await db.close();
      },
    );

    test(
      'multi-eq / range / prefix fall back to the Dart per-id path',
      () async {
        // Phase 2 step 1 indexed-eq fast path handles single covered equality
        // only; mixed filters (eq + range, range alone, prefix) are not
        // index-served. On the native backend they now go through the Phase 2
        // step 2 predicate-push full scan (`nativeFilteredScan`); on the
        // in-memory backend they use the Dart per-id read path. Either way
        // the results must be correct.
        final db = await openNative();
        final col = _coll(
          db,
          't',
          indexFields: ['nick'],
          prefixFields: ['name'],
        );
        for (var i = 0; i < 120; i++) {
          await col.put(
            _Rec('r$i', 'name-${i % 4}', 20 + (i % 30), 'g${i % 3}'),
          );
        }
        // Range on a numeric indexed field (no eq) — Dart path.
        final rangeQ = col.where().range('age', min: 20, max: 25);
        final rangeResult = await rangeQ.findAll();
        expect(rangeResult, isNotEmpty);
        // Prefix on a prefixed field — Dart path.
        final prefixQ = col.where().prefix('name', 'name-1');
        final prefixResult = await prefixQ.findAll();
        expect(prefixResult, hasLength(30)); // 'name-1' for i ≡ 1 mod 4 → 30
        await db.close();
      },
    );

    test(
      'Phase 2 step 2: unindexed full scan pushes the predicate to Rust',
      () async {
        // A query with no usable index on the native backend must use the
        // nativeFilteredScan plan (predicate pushed to Rust) and return only
        // matching rows. Parity: the result set must match the in-memory
        // backend's Dart full scan exactly.
        final db = await openNative(slowQueryThreshold: 1);
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 200; i++) {
          await col.put(_Rec('r$i', 'n$i', 20 + (i % 50), 'g${i % 4}'));
        }
        // Unindexed equality on 'age' (not an index field).
        final q = col.where({'age': 33});
        final result = await q.findAll();
        expect(q.lastPlan, IndexPlan.nativeFilteredScan);
        // age == 33 for i where 20 + (i % 50) == 33 → i % 50 == 13 →
        // i ∈ {13, 63, 113, 163}.
        expect(result, hasLength(4));
        expect(
          result.map((r) => r.id).toSet(),
          equals({'r13', 'r63', 'r113', 'r163'}),
        );
        // Only the 4 matches were scanned in Dart (predicate pushed to Rust).
        final rec = db.engine.recentSlowQueries.last;
        final t = rec.timings!;
        expect(t.rowsScanned, 4, reason: 'only matches cross back to Dart');
        expect(t.rowsMatched, 4);
        await db.close();
      },
    );

    test(
      'Phase 2 step 2: range + prefix predicates are also pushed to Rust',
      () async {
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 100; i++) {
          await col.put(_Rec('r$i', 'name-${i % 5}', 20 + (i % 30), 'g0'));
        }
        // Range on a non-indexed field.
        final rangeQ = col.where().range('age', min: 20, max: 25);
        final rangeResult = await rangeQ.findAll();
        expect(rangeQ.lastPlan, IndexPlan.nativeFilteredScan);
        // Every result has age in [20, 25].
        for (final r in rangeResult) {
          expect(r.age, greaterThanOrEqualTo(20));
          expect(r.age, lessThanOrEqualTo(25));
        }
        // Prefix on a non-prefixed field.
        final prefixQ = col.where().prefix('name', 'name-1');
        final prefixResult = await prefixQ.findAll();
        expect(prefixQ.lastPlan, IndexPlan.nativeFilteredScan);
        expect(prefixResult, hasLength(20)); // 'name-1' for i ≡ 1 mod 5 → 20
        await db.close();
      },
    );

    test(
      'Phase 2 step 2: empty predicate (where().findAll) returns all rows',
      () async {
        // An empty predicate matches everything; on native it goes through
        // the predicate-push path with an empty filter list, on in-memory it
        // is the Dart full scan. Both must return every row.
        final db = await openNative();
        final col = _coll(db, 't', indexFields: ['nick']);
        for (var i = 0; i < 25; i++) {
          await col.put(_Rec('r$i', 'n$i', null, 'g${i % 3}'));
        }
        final q = col.where();
        final result = await q.findAll();
        expect(result, hasLength(25));
        // No usable index → full-scan-class plan.
        expect(
          q.lastPlan,
          anyOf(IndexPlan.fullScan, IndexPlan.nativeFilteredScan),
        );
        await db.close();
      },
    );
  });
}
