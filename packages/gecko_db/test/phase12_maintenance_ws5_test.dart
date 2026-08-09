// Workstream 5: compaction, maintenance state machine, and diagnostics tests.
//
// Compaction uses redb's supported in-place compact path: it is crash-safe
// (two-phase commits), preserves every table (data, change log, sync metadata,
// indexes, attachments, encryption), and refuses to run while MVCC snapshots
// are open. These tests verify:
//   * the maintenance state machine (idle→compacting→committed/failed,
//     recovering after an interrupted compaction),
//   * logical/physical size reporting,
//   * compaction guards (in-memory, read-only, open snapshots),
//   * preservation of data, LSN, change log, indexes, and encryption,
//   * LSN continuity across compaction,
//   * concurrent readers observing consistent data while compaction runs,
//   * a real process kill during compaction reopening a complete image,
//   * slow-query logging (threshold + indexed/unindexed attribution),
//   * counters (lock contention, active subscribers).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart'
    show
        geckoChangeLogTable,
        geckoLsnKey,
        geckoMaintenanceCompacting,
        geckoMaintenanceStateKey,
        geckoMaintenanceTable,
        geckoSyncMetaTable;
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

Future<Process> _spawnHelper(List<String> args, String root) {
  return Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/native_process_helper.dart', ...args],
    workingDirectory: root,
    mode: ProcessStartMode.normal,
  );
}

Future<void> _waitForLine(Process process, String target) async {
  final reached = Completer<void>();
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == target && !reached.isCompleted) reached.complete();
      });
  try {
    await reached.future.timeout(const Duration(seconds: 120));
  } finally {
    await sub.cancel();
  }
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-ws5-');
    path = '${tempDir.path}${Platform.pathSeparator}database.redb';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<DatabaseImpl> openNative({DatabaseConfig? config, String? at}) =>
      DatabaseImpl.open(
        at ?? path,
        useInMemory: false,
        config: config ?? DatabaseConfig(nativeLibraryPath: nativePath),
      );

  Future<void> writeRows(DatabaseImpl db, int count, {String prefix = 'r'}) {
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    return Future.wait([
      for (var i = 0; i < count; i++)
        col.put({
          'id': '$prefix-$i',
          'index': i,
          'group': i.isEven ? 'even' : 'odd',
        }),
    ]);
  }

  Future<int> readLsn(DatabaseImpl db) async {
    const codec = DefaultWireCodec();
    final snapshot = await db.engine.backend.snapshot();
    try {
      final raw = await snapshot.read(
        geckoSyncMetaTable,
        ByteKey(codec.encode(geckoLsnKey)),
      );
      return raw == null ? 0 : codec.decode(raw) as int;
    } finally {
      await snapshot.dispose();
    }
  }

  Future<int> changeLogEntries(DatabaseImpl db) async {
    final entries = await db.engine.rawScanAll(geckoChangeLogTable);
    return entries.length;
  }

  Future<List<String>> rowIds(DatabaseImpl db) async {
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    return (await col.getAll()).map((m) => m['id'] as String).toList();
  }

  group('Workstream 5 maintenance state machine', () {
    test(
      'compact lifecycle transitions idle → compacting → committed',
      () async {
        final db = await openNative();
        await writeRows(db, 50);
        // Delete most rows so compaction has something to reclaim.
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        for (var i = 0; i < 45; i++) {
          await col.delete('r-$i');
        }
        expect(db.maintenance.state, MaintenanceState.idle);

        final before = await db.maintenance.storageStats();
        final madeProgress = await db.maintenance.compact();
        final after = await db.maintenance.storageStats();

        expect(db.maintenance.compactionCount, 1);
        expect(db.maintenance.lastCompactionDurationMicros, greaterThan(0));
        expect(madeProgress, isA<bool>());
        // Data survives.
        final remaining = await rowIds(db);
        expect(remaining, hasLength(5));
        // Physical size never grows beyond the pre-compaction size.
        expect(after.physicalBytes, lessThanOrEqualTo(before.physicalBytes));
        // State settles to committed (if progress) or idle (if already compact).
        expect(
          db.maintenance.state,
          anyOf(MaintenanceState.committed, MaintenanceState.idle),
        );
        await db.close();
      },
    );

    test(
      'compaction preserves LSN and change-log entries (LSN continuity)',
      () async {
        final db = await openNative();
        await writeRows(db, 40);
        final lsnBefore = await readLsn(db);
        final logBefore = await changeLogEntries(db);
        expect(lsnBefore, greaterThan(0));
        expect(logBefore, greaterThan(0));

        await db.maintenance.compact();

        // Watermark/LSN and change log survive compaction exactly.
        final lsnAfter = await readLsn(db);
        expect(lsnAfter, lsnBefore);
        expect(await changeLogEntries(db), logBefore);

        // The next write commits at the next LSN (continuity, no reuse).
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        await col.put({'id': 'post-compact', 'index': -1});
        final lsnPost = await readLsn(db);
        expect(lsnPost, greaterThan(lsnAfter));
        await db.close();
      },
    );

    test('compaction preserves secondary indexes', () async {
      final db = await openNative();
      final col = db.collection<Map<String, Object?>>(
        'items',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
        indexFields: const ['group'],
      );
      for (var i = 0; i < 30; i++) {
        await col.put({
          'id': 'i-$i',
          'index': i,
          'group': i.isEven ? 'even' : 'odd',
        });
      }
      final q = col.where({'group': 'even'});
      expect((await q.findAll()), hasLength(15));
      expect(q.lastPlan, IndexPlan.secondaryIndex);

      await db.maintenance.compact();

      // The durable index survives and still serves the query without a scan.
      final q2 = col.where({'group': 'even'});
      expect((await q2.findAll()), hasLength(15));
      expect(q2.lastPlan, IndexPlan.secondaryIndex);
      await db.close();
    });

    test('size reporting matches expectations', () async {
      final db = await openNative();
      await writeRows(db, 100);
      final stats = await db.maintenance.storageStats();
      expect(stats.physicalBytes, greaterThan(0));
      expect(stats.logicalBytes, greaterThan(0));
      expect(stats.physicalBytes, greaterThanOrEqualTo(stats.logicalBytes));
      expect(stats.tableCount, greaterThanOrEqualTo(1));
      expect(stats.commitSequence, greaterThan(0));
      // Physical file on disk agrees with the report.
      expect(File(path).lengthSync(), stats.physicalBytes);
      await db.close();
    });

    test('in-memory backend reports stats but refuses compaction', () async {
      final db = await DatabaseImpl.open('mem://ws5', useInMemory: true);
      await writeRows(db, 20);
      final stats = await db.maintenance.storageStats();
      expect(stats.physicalBytes, stats.logicalBytes);
      expect(stats.logicalBytes, greaterThan(0));
      expect(stats.tableCount, greaterThanOrEqualTo(1));

      await expectLater(
        db.maintenance.compact(),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
      await db.close();
    });

    test(
      'compaction refuses with open MVCC snapshots and on read-only',
      () async {
        final db = await openNative(
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            compactionSnapshotDrainTimeout: const Duration(milliseconds: 100),
          ),
        );
        await writeRows(db, 10);

        // A snapshot-bound cursor held open means compaction waits (bounded)
        // for it to drain, then fails with a typed timeout error.
        final cursor = db
            .collection<Map<String, Object?>>(
              'items',
              toRow: (m) => m,
              fromRow: (m) => Map<String, Object?>.from(m as Map),
              id: (m) => m['id'],
            )
            .where()
            .cursor();
        try {
          await expectLater(
            () => db.maintenance.compact(),
            throwsA(
              isA<GeckoError>().having(
                (e) => e.type,
                'type',
                GeckoErrorType.invalidOperation,
              ),
            ),
          );
          expect(db.maintenance.state, isNot(MaintenanceState.compacting));
        } finally {
          await cursor.dispose();
        }
        // After the cursor is disposed, compaction proceeds.
        await db.maintenance.compact();
        await db.close();

        // Read-only open refuses compaction.
        final ro = await openNative(
          config: DatabaseConfig(nativeLibraryPath: nativePath, readOnly: true),
        );
        await expectLater(
          () => ro.maintenance.compact(),
          throwsA(
            isA<GeckoError>().having(
              (e) => e.type,
              'type',
              GeckoErrorType.invalidOperation,
            ),
          ),
        );
        await ro.close();
      },
    );

    test(
      'interrupted compaction marker surfaces as recovering on reopen',
      () async {
        final db = await openNative();
        await writeRows(db, 25);
        // Simulate a crash mid-compaction: write the durable `compacting`
        // marker directly, then close without clearing it.
        const codec = DefaultWireCodec();
        await db.engine.commitBatch(
          (lsn, snapshot) => [
            RawPut(
              geckoMaintenanceTable,
              ByteKey(codec.encode(geckoMaintenanceStateKey)),
              codec.encode(geckoMaintenanceCompacting),
            ),
          ],
        );
        await db.close();

        final reopened = await openNative();
        try {
          expect(reopened.maintenance.state, MaintenanceState.recovering);
          // Data is intact (redb's two-phase compaction never leaves a partial
          // image, and in this simulation nothing was actually compacted).
          expect(await rowIds(reopened), hasLength(25));
          // recover() clears the marker and returns to idle.
          expect(
            await reopened.maintenance.recover(),
            MaintenanceState.recovering,
          );
          expect(reopened.maintenance.state, MaintenanceState.idle);
        } finally {
          await reopened.close();
        }
      },
    );

    test(
      'concurrent readers see consistent data while compaction runs',
      () async {
        final db = await openNative();
        await writeRows(db, 200);

        // Fire compaction and, while it is in flight, a burst of reads. The
        // reads queue behind the compaction request in the worker and must
        // return consistent, complete results.
        final compactFuture = db.maintenance.compact();
        final reads = await Future.wait([
          for (var i = 0; i < 5; i++) rowIds(db),
        ]);
        await compactFuture;
        for (final ids in reads) {
          expect(ids, hasLength(200));
        }
        expect(await rowIds(db), hasLength(200));
        await db.close();
      },
    );

    test(
      'process killed during compaction reopens a complete image',
      () async {
        final process = await _spawnHelper([
          'compact',
          path,
          nativePath,
          '40',
          '20',
        ], root);
        try {
          await _waitForLine(process, 'compacting');
          // Kill the OS process during the compaction window.
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 30));
        } finally {
          process.kill(ProcessSignal.sigkill);
        }

        // Reopen: the file must be a complete, consistent image and never
        // `failed` (redb's in-place compaction is crash-safe).
        final db = await openNative();
        try {
          // The helper wrote 40x20 raw rows keyed `k{batch}_{i}` with fat
          // payloads; verify every key survived the kill-during-compaction.
          const codec = DefaultWireCodec();
          final entries = await db.engine.rawScanAll('items');
          expect(entries, hasLength(40 * 20));
          final keys = {
            for (final entry in entries)
              codec.decode(entry.key.bytes) as String,
          };
          for (var b = 0; b < 40; b++) {
            for (var i = 0; i < 20; i++) {
              expect(
                keys.contains('k${b}_$i'),
                isTrue,
                reason: 'row k${b}_$i must survive a kill during compaction',
              );
            }
          }
          expect(
            db.maintenance.state,
            isNot(MaintenanceState.failed),
            reason: 'an interrupted compaction must not leave a failed state',
          );
          // If the marker was left as `compacting`, recovery clears it.
          await db.maintenance.recover();
          expect(db.maintenance.state, MaintenanceState.idle);
        } finally {
          await db.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'encrypted databases compact in place and reopen with the key',
      () async {
        const key = 0x5A;
        final db = await DatabaseImpl.open(
          path,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            physicalEncryptionKey: List<int>.filled(32, key),
          ),
        );
        await writeRows(db, 60);
        await db.maintenance.compact();
        await db.close();

        final reopened = await DatabaseImpl.open(
          path,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            physicalEncryptionKey: List<int>.filled(32, key),
          ),
        );
        try {
          expect(await rowIds(reopened), hasLength(60));
        } finally {
          await reopened.close();
        }
      },
    );
  });

  group('Workstream 5 diagnostics', () {
    test(
      'slow-query logging records indexed vs full-scan with a threshold',
      () async {
        final db = await openNative(
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            slowQueryThresholdMicros: 1,
          ),
        );
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['group'],
        );
        for (var i = 0; i < 40; i++) {
          await col.put({
            'id': 'k-$i',
            'group': i.isEven ? 'even' : 'odd',
            'n': i,
          });
        }
        // Unindexed query -> full-scan record.
        await col.where({'n': 7}).findAll();
        // Indexed query -> index-served record.
        final indexed = col.where({'group': 'even'});
        await indexed.findAll();
        expect(indexed.lastPlan, IndexPlan.secondaryIndex);

        expect(db.engine.slowQueryCount, greaterThanOrEqualTo(2));
        expect(db.engine.recentSlowQueries, isNotEmpty);
        expect(
          db.engine.recentSlowQueries.any((r) => !r.indexed),
          isTrue,
          reason: 'an unindexed query must be attributed as a full scan',
        );
        expect(
          db.engine.recentSlowQueries.any((r) => r.indexed),
          isTrue,
          reason: 'an indexed query must be attributed as index-served',
        );
        expect(db.engine.recentSlowQueries.first.table, 'items');
        // Diagnostics snapshot reflects the counter.
        expect(
          db.diagnostics.snapshot().slowQueryCount,
          greaterThanOrEqualTo(2),
        );
        await db.close();
      },
    );

    test('slow-query logging is off by default (near-zero overhead)', () async {
      final db = await openNative();
      final col = db.collection<Map<String, Object?>>(
        'items',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      for (var i = 0; i < 30; i++) {
        await col.put({'id': 'k-$i', 'n': i});
      }
      await col.where({'n': 1}).findAll();
      expect(db.engine.slowQueryCount, 0);
      expect(db.diagnostics.snapshot().slowQueryCount, 0);
      await db.close();
    });

    test(
      'Phase 1 per-stage timers attribute full-scan vs index-served costs',
      () async {
        final db = await openNative(
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            slowQueryThresholdMicros: 1,
          ),
        );
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['group'],
        );
        for (var i = 0; i < 60; i++) {
          await col.put({
            'id': 'k-$i',
            'group': i.isEven ? 'even' : 'odd',
            'n': i,
          });
        }

        // Full scan with a non-indexed filter: on the native backend the
        // predicate is pushed to Rust (Phase 2 step 2), so only matching rows
        // cross back to Dart — rowsScanned == rowsMatched == 1. On the
        // in-memory backend every row is decoded (rowsScanned == 60). This
        // test runs native, so assert the predicate-push contract.
        await col.where({'n': 7}).findAll();
        final scanRec = db.engine.recentSlowQueries.last;
        final scanT = scanRec.timings!;
        expect(scanRec.indexed, isFalse);
        expect(scanRec.table, 'items');
        // Predicate push: only the 1 match is scanned/decoded in Dart.
        expect(
          scanT.rowsScanned,
          1,
          reason: 'native predicate push returns only matches',
        );
        expect(scanT.rowsMatched, 1);
        expect(scanT.decode, greaterThan(0));
        expect(scanT.mapCopy, greaterThan(0));
        // predicate was evaluated in Rust; the Dart-side predicate timer is
        // near-zero (no re-test). model still runs for the matched row.
        expect(scanT.model, greaterThan(0));
        expect(scanT.sort, 0, reason: 'unsorted query');
        expect(
          scanT.total,
          lessThanOrEqualTo(scanRec.durationMicros),
          reason: 'stage sum must not exceed the query total',
        );

        // Index-served: indexLookup runs, only matching ids are read.
        final indexed = col.where({'group': 'even'});
        await indexed.findAll();
        final idxRec = db.engine.recentSlowQueries.last;
        final idxT = idxRec.timings!;
        expect(idxRec.indexed, isTrue);
        expect(idxT.rowsScanned, 30, reason: 'only the 30 even ids are read');
        expect(idxT.rowsMatched, 30);
        expect(idxT.indexLookup, greaterThan(0), reason: 'index was consulted');
        expect(idxT.decode, greaterThan(0));
        expect(idxT.total, lessThanOrEqualTo(idxRec.durationMicros));
        await db.close();
      },
    );

    test(
      'Phase 1 per-stage timers report the sort stage on ordered queries',
      () async {
        final db = await openNative(
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            slowQueryThresholdMicros: 1,
          ),
        );
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        for (var i = 0; i < 40; i++) {
          await col.put({'id': 'k-$i', 'n': i});
        }
        await col.where().sort([const SortSpec('n')]).findAll();
        final rec = db.engine.recentSlowQueries.last;
        final t = rec.timings!;
        expect(t.rowsScanned, 40);
        expect(t.rowsMatched, 40);
        expect(t.sort, greaterThan(0), reason: 'sorted query must time sort');
        expect(t.total, lessThanOrEqualTo(rec.durationMicros));
        await db.close();
      },
    );

    test('lock-contention and active-subscriber counters', () async {
      final db = await openNative(
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          inFlightBatchLimit: 1,
        ),
      );
      // Fire many concurrent writes through the bounded gate; with limit 1
      // most must wait (lock contention).
      await Future.wait([
        for (var i = 0; i < 30; i++)
          db.engine.rawPut(
            'contend',
            ByteKey(List<int>.from(utf8.encode('k$i'))),
            List<int>.from(utf8.encode('v$i')),
          ),
      ]);
      expect(db.engine.lockContentionCount, greaterThan(0));
      expect(db.diagnostics.snapshot().lockContentionCount, greaterThan(0));

      // Active subscriber counting.
      final sub = db.watchAll().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        db.diagnostics.snapshot().activeSubscribers,
        greaterThanOrEqualTo(1),
      );
      await sub.cancel();
      // onCancel is async; allow the counter to settle.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(db.diagnostics.snapshot().activeSubscribers, 0);
      await db.close();
    });

    test('diagnostics snapshot reports maintenance state and counts', () async {
      final db = await openNative();
      db.diagnostics.enable();
      await writeRows(db, 20);
      await db.maintenance.compact();
      final snap = db.diagnostics.snapshot();
      expect(snap.enabled, isTrue);
      expect(snap.totalWrites, greaterThan(0));
      expect(snap.compactionCount, 1);
      expect(snap.lastCompactionDurationMicros, greaterThan(0));
      expect(
        snap.maintenanceState,
        anyOf(MaintenanceState.committed.name, MaintenanceState.idle.name),
      );
      expect(snap.compacting, isFalse);
      await db.close();
    });
  });
}
