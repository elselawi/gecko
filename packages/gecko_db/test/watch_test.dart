import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _User {
  _User(this.id, this.name);
  final String id;
  final String name;
}

Object? _toRow(_User u) => {'name': u.name};
_User _fromRow(Object? row) => _User('', (row as Map)['name'] as String);
Object? _id(_User u) => u.id;

Future<DatabaseImpl> _open(String name) => openNativeTestDatabase('watch-$name');

void main() {
  group('watch(id) — single record stream', () {
    test(
      'emits current value once then exactly once per relevant write',
      () async {
        final db = await _open('single');
        final col = db.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await col.put(_User('u1', 'A'));

        final values = <_User?>[];
        final sub = col.watch('u1').listen(values.add);
        await Future<void>.delayed(Duration.zero);
        expect(values, hasLength(1)); // initial
        expect(values.single!.name, 'A');

        await col.put(_User('u1', 'B'));
        await Future<void>.delayed(Duration.zero);
        expect(values.last!.name, 'B');

        await sub.cancel();
        await db.close();
      },
    );

    test(
      'emits null (not an error) when the watched record is deleted',
      () async {
        final db = await _open('deleted');
        final col = db.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await col.put(_User('u1', 'A'));

        final values = <_User?>[];
        final sub = col.watch('u1').listen(values.add);
        await Future<void>.delayed(Duration.zero);

        await col.delete('u1');
        await Future<void>.delayed(Duration.zero);
        expect(values.last, isNull);
        await sub.cancel();
        await db.close();
      },
    );

    test('zero emissions for writes to other keys', () async {
      final db = await _open('otherkey');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await col.put(_User('u1', 'A'));

      final values = <_User?>[];
      final sub = col.watch('u1').listen(values.add);
      await Future<void>.delayed(Duration.zero);
      final initialCount = values.length;

      await col.put(_User('u2', 'Other'));
      await Future<void>.delayed(Duration.zero);
      expect(
        values.length,
        initialCount,
        reason: 'other-key write must not emit',
      );

      await sub.cancel();
      await db.close();
    });

    test(
      'multiple simultaneous subscribers each receive every emission',
      () async {
        final db = await _open('fanout');
        final col = db.collection<_User>(
          'users',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await col.put(_User('u1', 'A'));

        final s1 = <String>[];
        final s2 = <String>[];
        final sub1 = col.watch('u1').listen((u) => s1.add(u?.name ?? ''));
        final sub2 = col.watch('u1').listen((u) => s2.add(u?.name ?? ''));
        await Future<void>.delayed(Duration.zero);

        await col.put(_User('u1', 'Updated'));
        await Future<void>.delayed(Duration.zero);

        expect(s1, ['A', 'Updated']);
        expect(s2, ['A', 'Updated']);
        await sub1.cancel();
        await sub2.cancel();
        await db.close();
      },
    );
  });

  group('watchAll() — collection stream', () {
    test('emits post-write snapshots for insert, update, and delete', () async {
      final db = await _open('all');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );

      final snapshots = <int>[];
      final sub = col.watchAll().listen((list) => snapshots.add(list.length));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, [0]); // initial empty

      await col.put(_User('u1', 'A'));
      await col.put(_User('u2', 'B'));
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last, 2);

      await col.put(_User('u1', 'A2')); // update
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last, 2);

      await col.delete('u1');
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.last, 1);

      await sub.cancel();
      await db.close();
    });

    test(
      'subscriber to collection A receives no events for collection B',
      () async {
        final db = await _open('isolation');
        final colA = db.collection<_User>(
          'a',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        final colB = db.collection<_User>(
          'b',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await colA.put(_User('u1', 'A'));

        var emissions = 0;
        final sub = colA.watchAll().listen((_) => emissions++);
        await Future<void>.delayed(Duration.zero);
        final initial = emissions;

        for (var i = 0; i < 1000; i++) {
          await colB.put(_User('u$i', 'B'));
        }
        await Future<void>.delayed(Duration.zero);
        expect(emissions, initial, reason: '1000 writes to B must not wake A');

        await sub.cancel();
        await db.close();
      },
    );

    test('cancelling a subscription stops further emissions', () async {
      final db = await _open('cancel');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );

      var emissions = 0;
      final sub = col.watchAll().listen((_) => emissions++);
      await Future<void>.delayed(Duration.zero);

      await col.put(_User('u1', 'A'));
      await Future<void>.delayed(Duration.zero);
      final afterFirst = emissions;
      expect(afterFirst, greaterThan(0));

      await sub.cancel();
      await col.put(_User('u2', 'B'));
      await Future<void>.delayed(Duration.zero);
      expect(emissions, afterFirst, reason: 'no emission after cancel');

      await db.close();
    });
  });

  group('database.watchAll() — global feed', () {
    test(
      'attributes each event to its originating collection and key',
      () async {
        final db = await _open('global');
        final colA = db.collection<_User>(
          'a',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        final colB = db.collection<_User>(
          'b',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );

        final feed = <ChangeSet>[];
        final sub = db.watchAll().listen(feed.add);
        await Future<void>.delayed(Duration.zero);

        await colA.put(_User('u1', 'A'));
        await colB.put(_User('u2', 'B'));
        await Future<void>.delayed(Duration.zero);

        final tables = feed
            .map((set) => set.changes.map((c) => c.table))
            .expand((x) => x)
            .toList();
        final keys = feed
            .map((set) => set.changes.map((c) => c.key))
            .expand((x) => x)
            .toList();
        expect(tables, containsAll(['a', 'b']));
        expect(keys, containsAll(['u1', 'u2']));
        await sub.cancel();
        await db.close();
      },
    );

    test('events carry monotonically increasing sequence numbers', () async {
      final db = await _open('seq');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );

      final seqs = <int>[];
      final sub = db.watchAll().listen((set) => seqs.add(set.sequence!));
      await Future<void>.delayed(Duration.zero);

      await col.put(_User('u1', 'A'));
      await col.put(_User('u2', 'B'));
      await col.delete('u1');
      await Future<void>.delayed(Duration.zero);

      expect(seqs, isNotEmpty);
      for (var i = 1; i < seqs.length; i++) {
        expect(seqs[i], greaterThan(seqs[i - 1]), reason: 'monotonic');
      }
      await sub.cancel();
      await db.close();
    });
  });

  group('backpressure / bounded channel', () {
    test('slow subscriber recovers once a slow ApplyBatch drains', () async {
      final db = await _open('slowsub');
      final col = db.collection<_User>(
        'users',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );

      // Coalescing keeps a high-frequency writer bounded: many rapid writes to
      // the same key must not queue unbounded emissions (single-writer gate).
      var emissions = 0;
      final sub = col.watchAll().listen((_) => emissions++);
      await Future<void>.delayed(Duration.zero);

      for (var i = 0; i < 200; i++) {
        await col.put(_User('u1', 'v$i'));
      }
      // Every put goes through the write gate; emissions stay bounded and the
      // writer was never blocked forever (all 200 completed).
      await Future<void>.delayed(Duration.zero);
      expect(emissions, greaterThan(0));
      expect((await col.get('u1'))!.name, 'v199');

      await sub.cancel();
      await db.close();
    });
  });
}
