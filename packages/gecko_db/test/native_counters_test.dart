// Physical-work counters at the worker boundary (perf plan P1): zero-cost
// when off by default, populated when enabled, and drained/reset by
// `take_counters`. These tests verify the Dart surface (`NativeRawBackend`)
// end-to-end through the worker isolate.
import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  late DatabaseImpl db;
  late NativeRawBackend backend;

  setUp(() async {
    db = await openNativeTestDatabase('native-counters');
    backend = db.engine.backend as NativeRawBackend;
  });

  tearDown(() async {
    await db.close();
  });

  test('counters are zero by default (disabled) even after work', () async {
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    await col.put({'id': 'a', 'num': 1});
    await col.get('a');
    final counters = await backend.takeCounters();
    expect(counters.batchesApplied, BigInt.zero);
    expect(counters.rowsWritten, BigInt.zero);
    expect(counters.rowsReturned, BigInt.zero);
    expect(counters.bytesReturned, BigInt.zero);
  });

  test('enabled counters count writes/reads and take drains them', () async {
    await backend.enableCounters();
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    await col.put({'id': 'a', 'num': 1});
    await col.get('a');
    final counters = await backend.takeCounters();
    expect(counters.batchesApplied, greaterThan(BigInt.zero));
    expect(counters.rowsWritten, greaterThan(BigInt.zero));
    expect(counters.rowsReturned, greaterThan(BigInt.zero));
    expect(counters.bytesReturned, greaterThan(BigInt.zero));
    // take drained: no intervening work → all zero again.
    final drained = await backend.takeCounters();
    expect(drained.batchesApplied, BigInt.zero);
    expect(drained.rowsWritten, BigInt.zero);
  });

  test('disable resets counters and stops recording', () async {
    await backend.enableCounters();
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    await col.put({'id': 'a', 'num': 1});
    await backend.disableCounters();
    final reset = await backend.takeCounters();
    expect(reset.batchesApplied, BigInt.zero);
    expect(reset.rowsWritten, BigInt.zero);
    await col.put({'id': 'b', 'num': 2});
    final afterWork = await backend.takeCounters();
    expect(afterWork.batchesApplied, BigInt.zero);
    expect(afterWork.rowsWritten, BigInt.zero);
  });

  test(
    'indexed queries count index entries visited and rows fetched',
    () async {
      await backend.enableCounters();
      final col = db.collection<Map<String, Object?>>(
        'items',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
        indexFields: ['num'],
      );
      for (var i = 0; i < 50; i++) {
        await col.put({'id': 'r$i', 'num': i});
      }
      final rows = await col.where({'num': 7}).findAll();
      expect(rows, hasLength(1));
      final counters = await backend.takeCounters();
      expect(counters.indexEntriesVisited, greaterThan(BigInt.zero));
      expect(counters.primaryRowsFetched, greaterThan(BigInt.zero));
      expect(counters.rowsReturned, greaterThan(BigInt.zero));
    },
  );

  test('bulk writes count table opens and previous-value reads', () async {
    await backend.enableCounters();
    db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    final result = await db.bulkWrite([
      for (var i = 0; i < 50; i++)
        BulkMutation.put(
          table: 'items',
          key: 'r$i',
          value: {'id': 'r$i', 'n': i},
        ),
    ]);
    expect(result.mutationCount, 50);
    final counters = await backend.takeCounters();
    // One encoded batch; the per-batch handle cache must not open `items`
    // once per operation, and every plain upsert performs exactly one
    // previous-value read (the insert return value).
    expect(counters.batchesApplied, BigInt.one);
    expect(counters.rowsWritten, BigInt.parse('50'));
    expect(counters.tableOpens, lessThanOrEqualTo(BigInt.from(6)));
    expect(
      counters.previousValueReads,
      greaterThanOrEqualTo(BigInt.parse('50')),
    );
  });

  test(
    'indexed writes count index maintenance ops through the boundary',
    () async {
      await backend.enableCounters();
      db.collection<Map<String, Object?>>(
        'items',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
        indexFields: ['num'],
      );
      await db.bulkWrite([
        for (var i = 0; i < 20; i++)
          BulkMutation.put(
            table: 'items',
            key: 'r$i',
            value: {'id': 'r$i', 'num': i},
          ),
      ]);
      final counters = await backend.takeCounters();
      expect(
        counters.indexMaintenanceOps,
        greaterThanOrEqualTo(BigInt.parse('20')),
      );
      // Re-putting an identical row: the encoded indexed field is byte-identical,
      // so no index entry is inserted or removed.
      await db.bulkWrite([
        BulkMutation.put(
          table: 'items',
          key: 'r0',
          value: {'id': 'r0', 'num': 0},
        ),
      ]);
      final second = await backend.takeCounters();
      expect(second.indexMaintenanceOps, BigInt.zero);
    },
  );

  test('watched collections count registry clone/update work', () async {
    await backend.enableCounters();
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    await col.put({'id': 'a', 'num': 1});
    final sub = col.watchAll().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    // A put after registration must flow through the registry: it joins the
    // result set (added) and every touched registration clones its snapshot.
    await col.put({'id': 'b', 'num': 2});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    final counters = await backend.takeCounters();
    expect(counters.registryRowsAdded, greaterThan(BigInt.zero));
    expect(counters.registryRowsCloned, greaterThan(BigInt.zero));
    expect(counters.registrySnapshotBytes, greaterThan(BigInt.zero));
  });
}
