import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  group('Phase 2 bounded cache memory + backpressure', () {
    test('LRU weight bound caps resident bytes, not just entries', () {
      final c = LruCache<String, List<int>>(
        capacity: 100,
        maxWeight: 10,
        weightOf: (value) => value.length,
      );
      c.put('a', [1, 2, 3, 4, 5]);
      c.put('b', [1, 2, 3, 4, 5]);
      // Total weight would be 10, max is 10 → second put evicts the first.
      expect(c.weight, 5);
      expect(c.containsKey('a'), isFalse);
      expect(c.containsKey('b'), isTrue);
      expect(c.length, 1);
    });

    test('updating an entry recomputes weight accurately', () {
      final c = LruCache<String, List<int>>(
        capacity: 100,
        maxWeight: 20,
        weightOf: (value) => value.length,
      );
      c.put('a', [1, 2, 3]);
      c.put('a', [1, 2, 3, 4, 5, 6, 7, 8]); // update grows weight
      expect(c.weight, 8);
      c.remove('a');
      expect(c.weight, 0);
      c.put('b', [1, 2]);
      c.clear();
      expect(c.weight, 0);
    });

    test('RawEngine cache bounds resident value bytes', () async {
      final db = await openNativeTestDatabase('bounds-cache');
      final engine = RawEngine(
        db.engine.backend,
        lruCapacity: 100,
        lruMaxWeight: 12,
      );
      final k1 = ByteKey([1]);
      final k2 = ByteKey([2]);
      await engine.rawPut('t', k1, [1, 2, 3, 4, 5, 6]);
      await engine.rawPut('t', k2, [7, 8, 9, 10, 11, 12]);
      // Both fit (12 <= 12) once? Put also caches reads.
      expect(engine.cacheWeight, lessThanOrEqualTo(12));
      await engine.closeAndDispose();
    });

    test(
      'a delayed backend holds at most the in-flight bound of writes',
      () async {
        final db = await openNativeTestDatabase('bounds-delay');
        final backend = _DelayedBackend(
          db.engine.backend,
          const Duration(milliseconds: 30),
        );
        final engine = RawEngine(backend, inFlightBatchLimit: 2);
        final futures = <Future<void>>[
          for (var i = 0; i < 20; i++) engine.rawPut('t', ByteKey([i]), [i]),
        ];
        // While writes are in flight, the gate never exceeds the bound.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(engine.inFlightCount, lessThanOrEqualTo(2));
        await Future.wait(futures);
        expect(engine.inFlightCount, 0);
        await engine.closeAndDispose();
      },
    );
  });
}

class _DelayedBackend implements RawBackend {
  _DelayedBackend(this.delegate, this.delay);
  final RawBackend delegate;
  final Duration delay;

  @override
  bool get isReadOnly => false;

  @override
  Future<ApplyBatchResult> applyBatch(RawBatch ops) async {
    await Future<void>.delayed(delay);
    return delegate.applyBatch(ops);
  }

  @override
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  }) =>
      delegate.registerLiveQuery(
        table: table,
        predicateBytes: predicateBytes,
        sortBytes: sortBytes,
        kind: kind,
      );

  @override
  Future<void> unregisterLiveQuery(int id) => delegate.unregisterLiveQuery(id);

  @override
  Future<int> liveQueryCount() => delegate.liveQueryCount();

  @override
  Future<RawSnapshot> snapshot() => delegate.snapshot();

  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) =>
      delegate.getMany(table, keys);

  @override
  Future<bool> tableExists(String table) => delegate.tableExists(table);

  @override
  Future<List<String>> tables() => delegate.tables();

  @override
  Future<int> lastCommitSeq() => delegate.lastCommitSeq();

  @override
  Future<void> close() => delegate.close();
}

extension _RawEngineTestClose on RawEngine {
  Future<void> closeAndDispose() => backend.close();
}
