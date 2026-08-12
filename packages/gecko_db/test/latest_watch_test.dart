// Opt-in latest-state coalescing (terry-perf Item 16B).
//
// `latestStateOnly` collapses events produced within one event-loop turn to a
// single emission of the latest event; `Collection.watchAllLatest()` applies it
// to `watchAll()`. Default streams keep their semantics.

import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

Collection<Map<String, Object?>> coll(DatabaseImpl db, String table) =>
    db.collection<Map<String, Object?>>(
      table,
      toRow: (value) => value,
      fromRow: (row) => Map<String, Object?>.from(row as Map),
      id: (value) => value['id'],
    );

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('latestStateOnly (unit)', () {
    test('burst within one turn collapses to the final event', () async {
      final source = StreamController<int>(sync: true);
      final out = <int>[];
      final sub = latestStateOnly(source.stream).listen(out.add);
      addTearDown(() => sub.cancel());
      source.add(1);
      source.add(2);
      source.add(3);
      await flush();
      expect(out, [3], reason: 'intermediate events dropped');
      source.add(4);
      await flush();
      expect(out, [3, 4]);
      await source.close();
    });

    test('single events are delivered one at a time', () async {
      final source = StreamController<int>(sync: true);
      final out = <int>[];
      final sub = latestStateOnly(source.stream).listen(out.add);
      addTearDown(() => sub.cancel());
      source.add(1);
      await flush();
      source.add(2);
      await flush();
      source.add(3);
      await flush();
      expect(out, [1, 2, 3]);
      await source.close();
    });

    test('pending event is flushed before done', () async {
      final source = StreamController<int>(sync: true);
      final out = <int>[];
      var done = false;
      final sub = latestStateOnly(source.stream).listen(
        out.add,
        onDone: () => done = true,
      );
      addTearDown(() => sub.cancel());
      source.add(7);
      await source.close();
      await flush();
      expect(out, [7]);
      expect(done, isTrue);
    });

    test('error forwards', () async {
      final source = StreamController<int>(sync: true);
      final errors = <Object>[];
      final sub = latestStateOnly(source.stream).listen(
        (_) {},
        onError: (Object e) => errors.add(e),
      );
      addTearDown(() => sub.cancel());
      source.addError(StateError('boom'));
      await flush();
      expect(errors, hasLength(1));
      await source.close();
    });
  });

  group('watchAllLatest (collection)', () {
    test('initial state and post-change state are delivered', () async {
      final db = await openNativeTestDatabase('latest-initial');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final out = <List<Map<String, Object?>>>[];
      final sub = c.watchAllLatest().listen(out.add);
      await flush();
      await c.put({'id': 'b', 'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await sub.cancel();
      expect(out, isNotEmpty);
      expect(out.first.map((r) => r['id']), ['a']);
      expect(out.last.map((r) => r['id']), ['a', 'b']);
      await db.close();
    });

    test('final state is always delivered after a change burst', () async {
      final db = await openNativeTestDatabase('latest-final');
      final c = coll(db, 'items');
      final out = <List<Map<String, Object?>>>[];
      final sub = c.watchAllLatest().listen(out.add);
      await flush();
      // A single atomic transaction yields one registry delta; the latest-state
      // wrapper still delivers the resulting final state.
      await db.writeTxn((txn) async {
        final t = txn.collection<Map<String, Object?>>(
          'items',
          toRow: (value) => value,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (value) => value['id'],
        );
        await t.put({'id': 'a', 'n': 1});
        await t.put({'id': 'b', 'n': 2});
        await t.put({'id': 'c', 'n': 3});
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await sub.cancel();
      expect(out.last.map((r) => r['id']), ['a', 'b', 'c']);
      await db.close();
    });

    test('watchAll (default) still emits every intermediate state', () async {
      final db = await openNativeTestDatabase('latest-default-unchanged');
      final c = coll(db, 'items');
      final out = <List<Map<String, Object?>>>[];
      final sub = c.watchAll().listen(out.add);
      await flush();
      await c.put({'id': 'a', 'n': 1});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await c.put({'id': 'b', 'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();
      expect(out.map((rows) => rows.map((r) => r['id']).toList()), [
        isEmpty,
        ['a'],
        ['a', 'b'],
      ]);
      await db.close();
    });
  });
}
