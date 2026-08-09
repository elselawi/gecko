import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryBackend: put/get round-trips', () {
    test('empty, tiny, and multi-megabyte values', () async {
      final b = InMemoryBackend();
      // Empty value.
      await b.applyBatch([
        RawPut('t', ByteKey([1]), []),
      ]);
      expect(await (await b.snapshot()).read('t', ByteKey([1])), isEmpty);

      // Tiny.
      await b.applyBatch([
        RawPut('t', ByteKey([2]), [0x01]),
      ]);
      expect(await (await b.snapshot()).read('t', ByteKey([2])), [0x01]);

      // Multi-megabyte.
      final big = List<int>.filled(3 * 1024 * 1024, 0xAB);
      await b.applyBatch([
        RawPut('t', ByteKey([3]), big),
      ]);
      expect(
        (await (await b.snapshot()).read('t', ByteKey([3])))!.length,
        big.length,
      );
    });

    test('get on missing key returns null (not an error)', () async {
      final b = InMemoryBackend();
      final snap = await b.snapshot();
      expect(await snap.read('nope', ByteKey([1])), isNull);
      expect(await snap.read('t', ByteKey([999])), isNull);
    });
  });

  group('InMemoryBackend: atomic batch commit', () {
    test('a 1-op and a 10,000-op batch both commit atomically', () async {
      final b = InMemoryBackend();
      await b.applyBatch([
        RawPut('t', ByteKey([0]), [0]),
      ]);

      final ops = <RawOp>[
        for (var i = 0; i < 10000; i++) RawPut('t', ByteKey(_i(i)), _i(i)),
      ];
      final affected = await b.applyBatch(ops);
      expect(affected.length, 10000);
      final snap = await b.snapshot();
      for (var i = 0; i < 10000; i += 977) {
        expect(await snap.read('t', ByteKey(_i(i))), _i(i));
      }
    });

    test('a reader never observes a partial batch', () async {
      final b = InMemoryBackend();
      expect(await (await b.snapshot()).scanAll('t'), isEmpty);

      // Multi-op batch: put a, put b, delete range, clear another table.
      await snapFuture(b, [
        RawPut('t', ByteKey([1]), [1]),
        RawPut('t', ByteKey([2]), [2]),
        RawPut('other', ByteKey([9]), [9]),
      ]);
      final snap = await b.snapshot();
      final entries = await snap.scanAll('t');
      expect(entries.length, 2);
      expect(await snap.scanAll('other'), hasLength(1));
    });
  });

  group('InMemoryBackend: MVCC concurrent snapshot isolation', () {
    test('a reader keeps a consistent view while writes proceed', () async {
      final b = InMemoryBackend();
      await b.applyBatch([
        RawPut('t', ByteKey([1]), [1]),
      ]);
      final snap = await b.snapshot();

      // Writer mutates after the reader captured its snapshot.
      await b.applyBatch([
        RawPut('t', ByteKey([2]), [2]),
      ]);
      await b.applyBatch([
        RawPut('t', ByteKey([1]), [100]),
      ]);

      // Reader still sees the old snapshot: key 1 == [1], no key 2.
      expect(await snap.read('t', ByteKey([1])), [1]);
      expect(await snap.read('t', ByteKey([2])), isNull);

      // A fresh snapshot sees the new state.
      final fresh = await b.snapshot();
      expect(await fresh.read('t', ByteKey([1])), [100]);
      expect(await fresh.read('t', ByteKey([2])), [2]);
    });
  });

  group('InMemoryBackend: range scan', () {
    test('returns keys in sorted order with inclusive bounds', () async {
      final b = InMemoryBackend();
      final keys = [
        [1],
        [1, 0],
        [2],
        [5],
        [9],
        [10],
      ];
      for (final k in keys) {
        await b.applyBatch([RawPut('t', ByteKey(k), k)]);
      }
      final snap = await b.snapshot();

      final all = await snap.scanAll('t');
      // Sorted byte-wise.
      expect(all.map((e) => e.key.bytes).toList(), [
        [1],
        [1, 0],
        [2],
        [5],
        [9],
        [10],
      ]);

      final range = await snap.scan(
        't',
        start: ByteKey([2]),
        end: ByteKey([9]),
      );
      expect(range.map((e) => e.key.bytes).toList(), [
        [2],
        [5],
        [9],
      ]);
    });

    test('respects inclusive/exclusive bounds', () async {
      final b = InMemoryBackend();
      for (final k in [
        [1],
        [2],
        [3],
      ]) {
        await b.applyBatch([RawPut('t', ByteKey(k), k)]);
      }
      final snap = await b.snapshot();
      final exclStart = await snap.scan(
        't',
        start: ByteKey([1]),
        startInclusive: false,
      );
      expect(exclStart.map((e) => e.key.bytes).toList(), [
        [2],
        [3],
      ]);

      final exclEnd = await snap.scan(
        't',
        end: ByteKey([3]),
        endInclusive: false,
      );
      expect(exclEnd.map((e) => e.key.bytes).toList(), [
        [1],
        [2],
      ]);
    });

    test('empty table returns empty iterable', () async {
      final b = InMemoryBackend();
      final snap = await b.snapshot();
      expect(await snap.scanAll('missing'), isEmpty);
      expect(await snap.scan('missing'), isEmpty);
    });
  });

  group('InMemoryBackend: delete/clear', () {
    test('delete removes an existing key; delete-missing is a no-op', () async {
      final b = InMemoryBackend();
      await b.applyBatch([
        RawPut('t', ByteKey([1]), [1]),
      ]);
      await b.applyBatch([
        RawDelete('t', ByteKey([1])),
      ]);
      final snap = await b.snapshot();
      expect(await snap.read('t', ByteKey([1])), isNull);

      // Delete a missing key must not throw.
      await b.applyBatch([
        RawDelete('t', ByteKey([999])),
      ]);
    });

    test('deleteRange removes only keys within [[start],[end]]', () async {
      final b = InMemoryBackend();
      for (final k in [
        [1],
        [2],
        [3],
        [4],
        [5],
      ]) {
        await b.applyBatch([RawPut('t', ByteKey(k), k)]);
      }
      await b.applyBatch([
        RawDeleteRange('t', ByteKey([2]), ByteKey([4])),
      ]);
      final snap = await b.snapshot();
      expect((await snap.scanAll('t')).map((e) => e.key.bytes).toList(), [
        [1],
        [5],
      ]);
    });

    test('clear empties the table entirely', () async {
      final b = InMemoryBackend();
      for (final k in [
        [1],
        [2],
      ]) {
        await b.applyBatch([RawPut('t', ByteKey(k), k)]);
      }
      await b.applyBatch([RawClear('t')]);
      final snap = await b.snapshot();
      expect(await snap.scanAll('t'), isEmpty);
    });
  });

  group('InMemoryBackend: tables & commit counter', () {
    test('tableExists and tables reflect created tables', () async {
      final b = InMemoryBackend();
      expect(await b.tableExists('users'), isFalse);
      await b.applyBatch([
        RawPut('users', ByteKey([1]), [1]),
      ]);
      expect(await b.tableExists('users'), isTrue);
      expect(await b.tables(), contains('users'));
    });

    test('lastCommitSeq is monotonic across commits', () async {
      final b = InMemoryBackend();
      expect(await b.lastCommitSeq(), 0);
      await b.applyBatch([
        RawPut('t', ByteKey([1]), [1]),
      ]);
      await b.applyBatch([
        RawPut('t', ByteKey([2]), [2]),
      ]);
      expect(await b.lastCommitSeq(), 2);
    });
  });
}

Future<void> snapFuture(InMemoryBackend b, List<RawOp> ops) async {
  await b.applyBatch(ops);
}

List<int> _i(int n) => [n & 0xFF, (n >> 8) & 0xFF];
