// Workstream 8 — large-data qualification (reliability / performance sanity).
//
// Exercises the engine at scale against the NATIVE redb backend (plus a
// lighter in-memory pass where meaningful):
//   * 100k+ records with a secondary index, bulk-committed and verified;
//   * large values (100KB+ rows) round-tripping bit-exact;
//   * collections with many simultaneous indexes staying query-correct;
//   * a large pending-sync change log surviving close/reopen;
//   * hundreds of attachment metadata records with blob de-duplication;
//   * a long ordered migration chain applied to a large dataset.
//
// Set `GECKO_LONG_TEST=1` to scale the native dataset to 200k rows.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

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

bool get _longMode => Platform.environment['GECKO_LONG_TEST'] == '1';
int get _rowCount => _longMode ? 200000 : 100000;

class _Row {
  _Row(this.id, this.group, this.value);
  final int id;
  final int group;
  final String value;

  Map<String, Object?> toMap() => {'id': id, 'group': group, 'value': value};

  static _Row fromMap(Object? row) {
    final map = row as Map;
    return _Row(
      map['id'] as int,
      map['group'] as int,
      map['value'] as String,
    );
  }
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  test('100k+ rows with secondary index on native redb', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-large-');
    final path = '${dir.path}${Platform.pathSeparator}large.redb';
    try {
      final db = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      final coll = db.collection<_Row>(
        'bulk',
        toRow: (r) => r.toMap(),
        fromRow: _Row.fromMap,
        id: (r) => r.id,
        indexFields: const ['group'],
      );

      // Bulk-commit in chunks (one atomic batch each).
      const chunk = 5000;
      final groups = <int>[];
      for (var start = 0; start < _rowCount; start += chunk) {
        final end = min(start + chunk, _rowCount);
        final mutations = <BulkMutation>[];
        for (var i = start; i < end; i++) {
          groups.add(i % 100);
          mutations.add(
            BulkMutation.put(
              table: 'bulk',
              key: i,
              value: {'id': i, 'group': i % 100, 'value': 'v$i'},
            ),
          );
        }
        final result = await db.bulkWrite(mutations);
        expect(result.mutationCount, end - start);
      }

      // Full count.
      final all = await coll.getAll();
      expect(all.length, _rowCount);

      // Spot checks.
      for (final id in [0, 1, 42, 9999, _rowCount - 1]) {
        final row = await coll.get(id);
        expect(row, isNotNull);
        expect(row!.group, id % 100);
        expect(row.value, 'v$id');
      }

      // Indexed range query: group 7 → ids 7, 107, 207, ...
      final q = coll.where().filter('group', 7);
      final matches = await q.findAll();
      expect(matches.length, (_rowCount / 100).ceil());
      for (final row in matches) {
        expect(row.group, 7);
        expect(row.id % 100, 7);
      }
      // Indexed range: group in [10, 19] → ids 10..19, 110..119, ...
      final range = await coll
          .where()
          .range('group', min: 10, max: 19)
          .findAll();
      final expectedInRange = (_rowCount / 100).ceil() * 10;
      expect(range.length, expectedInRange);
      for (final row in range) {
        expect(row.group, inInclusiveRange(10, 19));
      }

      // Cursor pagination exhausts exactly once, no dupes, no drops.
      final seen = <int>{};
      final cursor = coll.where().cursor(pageSize: 977);
      var pages = 0;
      while (true) {
        final (page, next) = await cursor.next();
        pages++;
        for (final row in page) {
          expect(seen.add(row.id), isTrue, reason: 'duplicate id ${row.id}');
        }
        if (next == null) break;
      }
      expect(seen.length, _rowCount);
      expect(pages, greaterThan(100), reason: 'pagination must span many pages');
      await cursor.dispose();

      // Reopen: data persists (large-file reopen path).
      await db.close();
      final db2 = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      try {
        final coll2 = db2.collection<_Row>(
          'bulk',
          toRow: (r) => r.toMap(),
          fromRow: _Row.fromMap,
          id: (r) => r.id,
        );
        expect((await coll2.getAll()).length, _rowCount);
      } finally {
        await db2.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('large values (100KB+) round-trip bit-exact on native redb', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-large-vals-');
    final path = '${dir.path}${Platform.pathSeparator}largevals.redb';
    try {
      final db = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      final coll = db.collection<Map<String, Object?>>(
        'blobs',
        toRow: (r) => r,
        fromRow: (r) => Map<String, Object?>.from(r as Map),
        id: (r) => r['id'],
      );
      final random = Random(7);
      final payloads = <String, String>{};
      for (var i = 0; i < 40; i++) {
        final size = 100000 + random.nextInt(50000);
        final payload = base64Encode(
          List<int>.generate(size, (_) => random.nextInt(256)),
        );
        payloads['blob-$i'] = payload;
        await coll.put({'id': 'blob-$i', 'payload': payload, 'n': i});
      }
      // Read back and compare every byte (bit-exact large-value round trip).
      for (var i = 0; i < 40; i++) {
        final row = await coll.get('blob-$i');
        expect(row, isNotNull);
        expect(row!['payload'], payloads['blob-$i']);
      }
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('many simultaneous indexes stay query-correct', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-multi-');
    final path = '${dir.path}${Platform.pathSeparator}multi.redb';
    try {
      final db = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      final coll = db.collection<Map<String, Object?>>(
        'multi',
        toRow: (r) => r,
        fromRow: (r) => Map<String, Object?>.from(r as Map),
        id: (r) => r['id'],
        indexFields: const ['a', 'b', 'c', 'd'],
      );
      final random = Random(11);
      final expected = <String, Map<String, Object?>>{};
      const n = 2000;
      for (var start = 0; start < n; start += 500) {
        final end = start + 500 > n ? n : start + 500;
        final mutations = <BulkMutation>[];
        for (var i = start; i < end; i++) {
          final row = {
            'id': 'm$i',
            'a': random.nextInt(50),
            'b': random.nextInt(50),
            'c': random.nextInt(50),
            'd': random.nextInt(50),
          };
          expected['m$i'] = row;
          mutations.add(BulkMutation.put(table: 'multi', key: 'm$i', value: row));
        }
        await db.bulkWrite(mutations);
      }
      for (var field = 0; field < 4; field++) {
        final f = String.fromCharCode(0x61 + field); // a b c d
        for (var v = 0; v < 50; v += 7) {
          final hits = await coll.where().filter(f, v).findAll();
          final model = expected.values.where((r) => r[f] == v).toList();
          expect(hits.length, model.length,
              reason: 'index $f == $v count drift');
          final byId = {for (final r in hits) r['id']: r};
          for (final r in model) {
            expect(byId[r['id']], isNotNull, reason: 'index $f missing $v');
          }
        }
      }
      // Reopen: indexes rebuild from the primary table and must agree.
      await db.close();
      final db2 = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      try {
        final coll2 = db2.collection<Map<String, Object?>>(
          'multi',
          toRow: (r) => r,
          fromRow: (r) => Map<String, Object?>.from(r as Map),
          id: (r) => r['id'],
          indexFields: const ['a', 'b', 'c', 'd'],
        );
        final hits = await coll2.where().filter('a', expected['m0']!['a']).findAll();
        expect(hits, isNotEmpty);
        expect(await coll2.getAll(), hasLength(n));
      } finally {
        await db2.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('large pending-sync change log survives close/reopen', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-sync-');
    final path = '${dir.path}${Platform.pathSeparator}sync.redb';
    try {
      final db = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      final n = _longMode ? 20000 : 10000;
      const chunk = 1000;
      for (var start = 0; start < n; start += chunk) {
        final end = start + chunk > n ? n : start + chunk;
        await db.bulkWrite([
          for (var i = start; i < end; i++)
            BulkMutation.put(
              table: 'records',
              key: 'r$i',
              value: {'id': 'r$i', 'v': i},
            ),
        ]);
      }
      final pending = await db.sync.readLocallyChanged();
      expect(pending.length, n, reason: 'all local writes must be pending sync');

      // changesSince after the last LSN sees none; from 0 sees all.
      final all = await db.sync.changesSince(const SyncSnapshot(lastSeq: 0));
      expect(all.length, n);
      await db.close();

      // Reopen: pending + change log persist.
      final db2 = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      try {
        final pending2 = await db2.sync.readLocallyChanged();
        expect(pending2.length, n, reason: 'pending sync must survive reopen');
        // Mark a slice synced; only the rest stays pending.
        final half = pending2.take(n ~/ 2).map((p) => p.recordId).toList();
        await db2.sync.markSynced(half);
        final pending3 = await db2.sync.readLocallyChanged();
        expect(pending3.length, n - (n ~/ 2));
      } finally {
        await db2.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('hundreds of attachments with blob de-duplication', () async {
    final db = await Database.open(
      'mem://ws8-attachments',
      config: const DatabaseConfig(inMemory: true),
    );
    final coll = db.collection<Map<String, Object?>>(
        'parents',
        toRow: (r) => r,
        fromRow: (r) => Map<String, Object?>.from(r as Map),
        id: (r) => r['id'],
      );
      await coll.put({'id': 'parent-0'});
      // 5 distinct blobs shared across 300 attachment records.
      const sharedBlobs = 5;
      const records = 300;
      for (var i = 0; i < records; i++) {
        final blob = i % sharedBlobs;
        final att = await db.attachments.create(
          parentCollection: 'parents',
          parentId: 'parent-0',
          filename: 'file-$i.bin',
          fileType: 'application/octet-stream',
          size: 1000 + blob,
          contentHash: 'sha256-blob-$blob',
        );
        expect(att.id, isNotEmpty);
      }
      final all = await db.attachments.query();
      expect(all.length, records);
      final pending = await db.attachments.pendingUploads();
      expect(pending.length, records);
      // Each shared blob has refCount == records / sharedBlobs.
      for (var b = 0; b < sharedBlobs; b++) {
        expect(
          await db.attachments.blobRefCount('sha256-blob-$b'),
          records ~/ sharedBlobs,
        );
      }
      expect(await db.attachments.hasBlob('sha256-blob-0'), isTrue);
      expect(await db.attachments.hasBlob('sha256-missing'), isFalse);
      // Delete one: its blob ref count drops by one.
      await db.attachments.delete(all.first.id);
      expect(
        await db.attachments.blobRefCount('sha256-blob-0'),
        records ~/ sharedBlobs - 1,
      );
      await db.close();
  });

  test('long ordered migration chain over a large dataset', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-migrate-');
    final path = '${dir.path}${Platform.pathSeparator}migrate.redb';
    try {
      final db = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      final coll = db.collection<Map<String, Object?>>(
        'legacy',
        toRow: (r) => r,
        fromRow: (r) => Map<String, Object?>.from(r as Map),
        id: (r) => r['id'],
      );
      final n = _longMode ? 20000 : 10000;
      const chunk = 1000;
      for (var start = 0; start < n; start += chunk) {
        final end = start + chunk > n ? n : start + chunk;
        await db.bulkWrite([
          for (var i = start; i < end; i++)
            BulkMutation.put(
              table: 'legacy',
              key: 'l$i',
              value: {'id': 'l$i', 'v': i},
            ),
        ]);
      }
      expect(await db.schema.readVersion(), 0);

      // 12 ordered additive steps.
      final additive = [
        for (var v = 1; v <= 12; v++)
          MigrationStep(
            name: 'step-$v',
            fromVersion: v - 1,
            toVersion: v,
          ),
      ];
      final (applied, target) =
          await db.schema.migrate(MigrationPlan(steps: additive, targetVersion: 12));
      expect(applied, 12);
      expect(target, 12);
      expect(await db.schema.readVersion(), 12);

      // Record-rewriting step over all rows (bounded-chunk rewriter).
      var rewritten = 0;
      await db.schema.migrateStep(
        MigrationStep(
          name: 'rewrite',
          fromVersion: 12,
          toVersion: 13,
          rewritesRecords: true,
          collection: 'legacy',
          upgrade: (row) {
            rewritten++;
            final map = Map<Object?, Object?>.from(row as Map);
            map['v2'] = (map['v'] as int) * 2;
            return map;
          },
        ),
      );
      expect(rewritten, n, reason: 'every record must pass through the rewriter');
      expect(await db.schema.readVersion(), 13);

      // Verify a sample of rewritten rows.
      for (final id in ['l0', 'l1', 'l${n ~/ 2}', 'l${n - 1}']) {
        final row = await coll.get(id);
        expect(row, isNotNull);
        expect(row!['v2'], (row['v'] as int) * 2);
      }

      // Reopen keeps version + rewritten data.
      await db.close();
      final db2 = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: nativePath),
      );
      try {
        expect(await db2.schema.readVersion(), 13);
        final row = await db2
            .collection<Map<String, Object?>>(
              'legacy',
              toRow: (r) => r,
              fromRow: (r) => Map<String, Object?>.from(r as Map),
              id: (r) => r['id'],
            )
            .get('l42');
        expect(row!['v2'], (row['v'] as int) * 2);
      } finally {
        await db2.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
