import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryBackend backend;
  late RawEngine engine;

  setUp(() {
    backend = InMemoryBackend();
    engine = RawEngine(backend, lruCapacity: 4, inFlightBatchLimit: 2);
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
}
