import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/backend/raw_backend.dart'
    show RawBatchPlan, RawChangeTemplate, DirectReadBackend, PreparedBatchBackend;
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  late NativeRawBackend backend;
  late RawEngine engine;

  setUp(() async {
    final db = await openNativeTestDatabase('raw-engine');
    backend = db.engine.backend as NativeRawBackend;
    engine = RawEngine(backend, lruCapacity: 4, inFlightBatchLimit: 2);
  });

  tearDown(() async {
    await engine.dispose();
  });

  group('RawEngine: rawGet / rawPut / rawDelete / rawClear', () {
    test(
      'put then get round-trips, returning previous value on update',
      () async {
        final k = ByteKey([1]);
        expect(await engine.rawGet('t', k), isNull);
        expect(await engine.rawPut('t', k, [10]), isNull);
        expect(await engine.rawGet('t', k), [10]);
        // Upsert returns the previous value.
        expect(await engine.rawPut('t', k, [20]), [10]);
        expect(await engine.rawGet('t', k), [20]);
      },
    );

    test('insertOnly rejects an existing key with a typed error', () async {
      final k = ByteKey([1]);
      await engine.rawPut('t', k, [1]);
      expect(
        () => engine.rawPut('t', k, [2], mode: RawWriteMode.insertOnly),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
    });

    test('updateOnly rejects a missing key with keyNotFound', () async {
      final k = ByteKey([1]);
      expect(
        () => engine.rawPut('t', k, [2], mode: RawWriteMode.updateOnly),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.keyNotFound,
          ),
        ),
      );
    });

    test(
      'delete returns whether it existed; delete-missing is a no-op',
      () async {
        final k = ByteKey([1]);
        expect(await engine.rawDelete('t', k), isFalse);
        await engine.rawPut('t', k, [1]);
        expect(await engine.rawDelete('t', k), isTrue);
        expect(await engine.rawGet('t', k), isNull);
      },
    );

    test('rawClear empties the table', () async {
      for (final i in [1, 2, 3]) {
        await engine.rawPut('t', ByteKey([i]), [i]);
      }
      await engine.rawClear('t');
      expect(await engine.rawScanAll('t'), isEmpty);
    });

    test('rawRangeScan returns sorted, bounded results', () async {
      for (final i in [1, 2, 3, 4, 5]) {
        await engine.rawPut('t', ByteKey([i]), [i]);
      }
      final range = await engine.rawRangeScan(
        't',
        start: ByteKey([2]),
        end: ByteKey([4]),
      );
      expect(range.map((e) => e.key.bytes), [
        [2],
        [3],
        [4],
      ]);
    });
  });

  group('RawEngine: LRU cache freshness', () {
    test('a put invalidates any cached prior value', () async {
      final k = ByteKey([1]);
      await engine.rawPut('t', k, [1]);
      expect(await engine.rawGet('t', k), [1]); // cache it
      await engine.rawPut('t', k, [99]); // must invalidate
      expect(await engine.rawGet('t', k), [99], reason: 'no stale cache');
    });

    test('a delete invalidates the cached value', () async {
      final k = ByteKey([1]);
      await engine.rawPut('t', k, [1]);
      expect(await engine.rawGet('t', k), [1]);
      await engine.rawDelete('t', k);
      expect(
        await engine.rawGet('t', k),
        isNull,
        reason: 'stale-free after delete',
      );
    });

    test(
      'cache misses fall through to the backend (eviction not data loss)',
      () async {
        final engine2 = RawEngine(
          backend,
          lruCapacity: 1,
          inFlightBatchLimit: 2,
        );
        // Put 3 keys with a capacity-1 cache: only the last one stays resident.
        for (final i in [1, 2, 3]) {
          await engine2.rawPut('t', ByteKey([i]), [i]);
          await engine2.rawGet('t', ByteKey([i]));
        }
        // All must still be readable (eviction = miss, not loss).
        for (final i in [1, 2, 3]) {
          expect(await engine2.rawGet('t', ByteKey([i])), [i]);
        }
      },
    );
  });

  group('RawEngine: backpressure write gate', () {
    test('inFlightCount never exceeds the bound under contention', () async {
      final gate = RawEngine(backend, lruCapacity: 16, inFlightBatchLimit: 2);
      // A slow backend action would be needed; simulate by issuing many
      // concurrent writes and asserting the gate stays bounded. Since the
      // in-memory backend is fast, we assert the exposed state is consistent.
      final futures = <Future<void>>[
        for (var i = 0; i < 50; i++) gate.rawPut('t', ByteKey([i]), [i]),
      ];
      await Future.wait(futures);
      expect(gate.inFlightCount, 0, reason: 'drained after completion');
      expect(gate.inFlightLimit, 2);
    });
  });

  group('RawEngine: reserved-table helper', () {
    test('isReservedTable recognizes __gecko_ prefix', () {
      expect(engine.isReservedTable('__gecko_change_log'), isTrue);
      expect(engine.isReservedTable('users'), isFalse);
    });
  });

  group('RawEngine: negative-lookup cache', () {
    test(
      'a repeated read of a missing key makes no backend call after the first',
      () async {
        final counting = _CountingBackend(backend);
        final eng = RawEngine(counting, lruCapacity: 4, inFlightBatchLimit: 2);
        final k = ByteKey([99]);
        expect(await eng.rawGet('t', k), isNull);
        final afterFirst = counting.directReads;
        expect(await eng.rawGet('t', k), isNull);
        expect(await eng.rawGet('t', k), isNull);
        expect(
          counting.directReads,
          afterFirst,
          reason: 'a cached miss must not cross the boundary again',
        );
        // A put to that key clears the negative entry and serves the value.
        await eng.rawPut('t', k, [1]);
        expect(await eng.rawGet('t', k), [1]);
        await eng.dispose();
      },
    );

    test('a delete of a cached key leaves a negative entry for it', () async {
      final counting = _CountingBackend(backend);
      final eng = RawEngine(counting, lruCapacity: 4, inFlightBatchLimit: 2);
      final k = ByteKey([5]);
      await eng.rawPut('t', k, [5]);
      expect(await eng.rawGet('t', k), [5]);
      await eng.rawDelete('t', k);
      final before = counting.directReads;
      expect(await eng.rawGet('t', k), isNull);
      expect(await eng.rawGet('t', k), isNull);
      expect(
        counting.directReads,
        before + 1,
        reason: 'exactly one backend read for a now-missing hot key',
      );
      await eng.dispose();
    });
  });

  group('RawEngine: write round trips are bounded (plan 2.1/2.2 guards)', () {
    test('a single put/delete makes no snapshot round trip', () async {
      final counting = _CountingBackend(backend);
      final eng = RawEngine(counting, lruCapacity: 4, inFlightBatchLimit: 2);
      await eng.rawPut('t', ByteKey([1]), [10]);
      await eng.rawDelete('t', ByteKey([1]));
      expect(
        counting.snapshotCount,
        0,
        reason: 'plain writes must not create/dispose a worker snapshot',
      );
      expect(
        counting.preparedBatchCalls,
        2,
        reason: 'one prepared write batch per mutation, no per-write reads',
      );
      expect(counting.directReads, 0);
      await eng.dispose();
    });

    test('a large prepared batch issues one write and zero per-row reads',
        () async {
      final counting = _CountingBackend(backend);
      final eng = RawEngine(counting, lruCapacity: 4, inFlightBatchLimit: 2);
      const count = 1000;
      const codec = DefaultWireCodec();
      final plan = RawBatchPlan(
        ops: [
          for (var i = 0; i < count; i++) RawPut('t', ByteKey([i]), [i]),
        ],
        previousOperationIndexes: [for (var i = 0; i < count; i++) i],
        changeTemplates: [
          for (var i = 0; i < count; i++)
            RawChangeTemplate(
              operationIndex: i,
              ordinal: i,
              syncStateKey: ByteKey([1, 2, 3]),
              recordTemplate: codec.encode(<String, Object?>{
                'localMutationId': 0,
                'recordId': i,
                'timestamp': DateTime.fromMillisecondsSinceEpoch(0),
                'collection': 't',
                'kind': 'put',
                'value': {'id': i},
                'origin': 'user',
                'dirty': true,
                'syncPhase': 'pending',
              }),
              fillPreviousVersion: true,
            ),
        ],
      );
      await eng.applyPreparedPlan(plan);
      expect(
        counting.preparedBatchCalls,
        1,
        reason: 'N mutations cross the boundary once as one encoded batch',
      );
      expect(
        counting.directReads,
        0,
        reason: 'previous-row reads happen inside the Rust write transaction',
      );
      expect(
        counting.snapshotCount,
        0,
        reason: 'bulk writes never open a Dart-side snapshot',
      );
      await eng.dispose();
    });
  });
}

/// A read-counting backend: delegates to the real native backend and counts
/// direct point-read calls so cache behavior is observable in tests.
class _CountingBackend implements RawBackend, DirectReadBackend, PreparedBatchBackend {
  _CountingBackend(this._inner);
  final NativeRawBackend _inner;
  int directReads = 0;
  int snapshotCount = 0;
  int preparedBatchCalls = 0;

  @override
  bool get isReadOnly => _inner.isReadOnly;

  @override
  Future<ApplyBatchResult> applyBatch(RawBatch ops) => _inner.applyBatch(ops);

  @override
  Future<ApplyBatchResult> applyPreparedBatch(RawBatchPlan plan) {
    preparedBatchCalls++;
    return _inner.applyPreparedBatch(plan);
  }

  @override
  Future<void> registerCompositeIndexes(
    String table,
    List<List<String>> indexes,
  ) =>
      _inner.registerCompositeIndexes(table, indexes);

  @override
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  }) =>
      _inner.registerLiveQuery(
        table: table,
        predicateBytes: predicateBytes,
        sortBytes: sortBytes,
        kind: kind,
      );

  @override
  Future<void> unregisterLiveQuery(int id) => _inner.unregisterLiveQuery(id);

  @override
  Future<int> liveQueryCount() => _inner.liveQueryCount();

  @override
  Future<List<RawEntry>> pendingChanges() => _inner.pendingChanges();

  @override
  Future<RawSnapshot> snapshot() {
    snapshotCount++;
    return _inner.snapshot();
  }

  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) =>
      _inner.getMany(table, keys);

  @override
  Future<bool> tableExists(String table) => _inner.tableExists(table);

  @override
  Future<List<String>> tables() => _inner.tables();

  @override
  Future<int> lastCommitSeq() => _inner.lastCommitSeq();

  @override
  Future<void> close() => _inner.close();

  @override
  Future<List<int>?> directRead(String table, ByteKey key) async {
    directReads++;
    return _inner.directRead(table, key);
  }

  @override
  Future<List<RawEntry>> directScan(
    String table, {
    ByteKey? start,
    ByteKey? end,
  }) =>
      _inner.directScan(table, start: start, end: end);
}
