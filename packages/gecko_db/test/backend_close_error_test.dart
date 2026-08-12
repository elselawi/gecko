// Every NativeRawBackend / NativeRawSnapshot method fails with a typed
// GeckoError after the database (and its worker) is closed. This is the
// defensive coverage for the pure error-translation `mapNativeError` catch
// lines: they are only reachable when the worker has already gone away.
import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/backend/raw_backend.dart' show RawBatchPlan;
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  test('every backend method fails with a typed error after close', () async {
    final db = await openNativeTestDatabase('backend-close-errors');
    final backend = db.engine.backend as NativeRawBackend;
    await backend.snapshot().then((s) => s.dispose());
    await db.close();

    Future<void> expectTyped(Future<Object?> Function() call) async {
      await expectLater(call(), throwsA(isA<GeckoError>()));
    }

    await expectTyped(() => backend.commitSequenceProbe());
    await expectTyped(() => backend.compact());
    await expectTyped(() => backend.storageStats());
    await expectTyped(() => backend.enableCounters());
    await expectTyped(() => backend.disableCounters());
    await expectTyped(() => backend.takeCounters());
    await expectTyped(() => backend.applyBatch(const []));
    await expectTyped(
      () => backend.registerCompositeIndexes('t', [
        ['a'],
      ]),
    );
    await expectTyped(
      () => backend.applyPreparedBatch(RawBatchPlan(ops: const [])),
    );
    await expectTyped(() => backend.directRead('t', ByteKey([1])));
    await expectTyped(() => backend.directScan('t'));
    await expectTyped(
      () => backend.registerLiveQuery(
        table: 't',
        predicateBytes: const [],
        sortBytes: const [],
        kind: 0,
      ),
    );
    await expectTyped(() => backend.unregisterLiveQuery(1));
    await expectTyped(() => backend.liveQueryCount());
    await expectTyped(() => backend.pendingChanges());
    await expectTyped(() => backend.syncStateMatching([
      [0],
    ]));
    await expectTyped(() => backend.changesSince(0));
    await expectTyped(() => backend.orphanedAttachments());
    await expectTyped(() => backend.snapshot());
    await expectTyped(() => backend.getMany('t', [ByteKey([1])]));
    await expectTyped(
      () => backend.repairIndex(table: 't', fields: ['a']),
    );
    await expectTyped(
      () => backend.queryIndexed(
        table: 't',
        start: ByteKey([0]),
        end: ByteKey([9]),
      ),
    );
    await expectTyped(
      () => backend.queryFilteredLimited(
        table: 't',
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => backend.querySorted(
        table: 't',
        predicateBytes: const [],
        sortSpecBytes: const [],
      ),
    );
    await expectTyped(
      () => backend.queryIndexedLimited(
        table: 't',
        start: ByteKey([0]),
        end: ByteKey([9]),
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => backend.queryIndexedOrdered(
        table: 't',
        start: ByteKey([0]),
        end: ByteKey([9]),
        predicateBytes: const [],
        sortField: 'a',
        eqBounded: false,
        descending: false,
        covered: false,
      ),
    );
    await expectTyped(
      () => backend.queryIndexedMulti(
        table: 't',
        ranges: [(ByteKey([0]), ByteKey([9]))],
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => backend.queryIndexedDistinct(
        table: 't',
        ranges: [(ByteKey([0]), ByteKey([9]))],
        predicateBytes: const [],
        field: 'a',
      ),
    );
    await expectTyped(
      () => backend.queryIndexedCount(
        table: 't',
        ranges: [(ByteKey([0]), ByteKey([9]))],
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => backend.queryFilteredCount(table: 't', predicateBytes: const []),
    );
    await expectTyped(
      () => backend.queryFilteredDistinct(
        table: 't',
        predicateBytes: const [],
        field: 'a',
      ),
    );
    await expectTyped(
      () => backend.queryFiltered(table: 't', predicateBytes: const []),
    );
    await expectTyped(() => backend.tableExists('t'));
    await expectTyped(() => backend.tables());
    await expectTyped(() => backend.lastCommitSeq());
  });

  test('snapshot methods fail with a typed error after the snapshot is disposed',
      () async {
    final db = await openNativeTestDatabase('snapshot-close-errors');
    final backend = db.engine.backend as NativeRawBackend;
    final snap = await backend.snapshot() as NativeRawSnapshot;
    await snap.dispose();

    Future<void> expectTyped(Future<Object?> Function() call) async {
      await expectLater(call(), throwsA(isA<GeckoError>()));
    }

    await expectTyped(() => snap.read('t', ByteKey([1])));
    await expectTyped(() => snap.scan('t'));
    await expectTyped(() => snap.scanAll('t'));
    await expectTyped(() => snap.getMany('t', [ByteKey([1])]));
    await expectTyped(
      () => snap.queryFiltered(table: 't', predicateBytes: const []),
    );
    await expectTyped(
      () => snap.queryIndexed(
        table: 't',
        start: ByteKey([0]),
        end: ByteKey([9]),
      ),
    );
    await expectTyped(
      () => snap.queryFilteredCount(table: 't', predicateBytes: const []),
    );
    await expectTyped(
      () => snap.queryFilteredDistinct(
        table: 't',
        predicateBytes: const [],
        field: 'a',
      ),
    );
    await expectTyped(
      () => snap.queryIndexedCount(
        table: 't',
        ranges: [(ByteKey([0]), ByteKey([9]))],
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => snap.queryIndexedDistinct(
        table: 't',
        ranges: [(ByteKey([0]), ByteKey([9]))],
        predicateBytes: const [],
        field: 'a',
      ),
    );
    await expectTyped(
      () => snap.queryIndexedMulti(
        table: 't',
        ranges: [(ByteKey([0]), ByteKey([9]))],
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => snap.queryIndexedLimited(
        table: 't',
        start: ByteKey([0]),
        end: ByteKey([9]),
        predicateBytes: const [],
      ),
    );
    await expectTyped(
      () => snap.querySorted(
        table: 't',
        predicateBytes: const [],
        sortSpecBytes: const [],
      ),
    );
    await expectTyped(
      () => snap.queryIndexedOrdered(
        table: 't',
        start: ByteKey([0]),
        end: ByteKey([9]),
        predicateBytes: const [],
        sortField: 'a',
        eqBounded: false,
        descending: false,
        covered: false,
      ),
    );
    // A second dispose is a documented no-op (never throws).
    await snap.dispose();
    await db.close();
  });
}
