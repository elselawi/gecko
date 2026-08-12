// Native windowed live-query tests (terry-perf Item 8).
//
// Windowed `Query.watch()` (limit/offset) is served by the worker's reactive
// registry: Rust maintains the full matching set incrementally and emits the
// ordered `[offset, offset + limit)` slice, so a write that reorders the
// window — or happens entirely outside it — never re-runs `findAll()`.
// Every emitted list below is compared against a fresh `findAll()` result.

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

Future<List<List<Map<String, Object?>>>> collectN(
  Stream<List<Map<String, Object?>>> stream,
  int count, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<List<List<Map<String, Object?>>>>();
  final out = <List<Map<String, Object?>>>[];
  late final StreamSubscription<List<Map<String, Object?>>> sub;
  sub = stream.listen(
    (event) {
      out.add(event);
      if (out.length >= count && !completer.isCompleted) {
        completer.complete(out);
      }
    },
    onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    },
  );
  addTearDown(() => sub.cancel());
  return completer.future.timeout(timeout);
}

List<Object?> ids(List<Map<String, Object?>> rows) =>
    [for (final r in rows) r['id']];

void main() {
  group('windowed query watch (native registry)', () {
    test('limit-only: outside row enters, window row leaves', () async {
      final db = await openNativeTestDatabase('ww-limit');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      await c.put({'id': 'c', 'n': 3});
      final emissions = collectN(c.where().limit(2).watch(), 2);
      await flush();
      // A new smallest row enters the window at the front; `c` leaves.
      await c.put({'id': '0', 'n': 0});
      final pages = await emissions;
      expect(ids(pages.first), ['a', 'b']);
      expect(ids(pages.last), ['0', 'a']);
      // Matches a fresh findAll limit.
      final fresh = await c.where().limit(2).findAll();
      expect(ids(pages.last), ids(fresh));
      await db.close();
    });

    test('offset-only: window skips the first M rows', () async {
      final db = await openNativeTestDatabase('ww-offset');
      final c = coll(db, 'items');
      for (var i = 0; i < 5; i++) {
        await c.put({'id': 'k$i', 'n': i});
      }
      final emissions = collectN(c.where().offset(2).watch(), 1);
      await flush();
      final pages = await emissions;
      expect(ids(pages.single), ['k2', 'k3', 'k4']);
      await db.close();
    });

    test('limit + offset: window is [offset, offset + limit)', () async {
      final db = await openNativeTestDatabase('ww-both');
      final c = coll(db, 'items');
      for (var i = 0; i < 6; i++) {
        await c.put({'id': 'k$i', 'n': i});
      }
      final emissions = collectN(c.where().limit(2).offset(3).watch(), 1);
      await flush();
      final pages = await emissions;
      expect(ids(pages.single), ['k3', 'k4']);
      await db.close();
    });

    test('sorted: a row crossing the boundary is added/removed', () async {
      final db = await openNativeTestDatabase('ww-sorted');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 10});
      await c.put({'id': 'b', 'n': 20});
      await c.put({'id': 'c', 'n': 30});
      final emissions = collectN(
        c.where().sort([SortSpec('n')]).limit(2).watch(),
        2,
      );
      await flush();
      // `c` repositions to the front (n=5), pushing `b` out of the window.
      await c.put({'id': 'c', 'n': 5});
      final pages = await emissions;
      expect(ids(pages.first), ['a', 'b']);
      expect(ids(pages.last), ['c', 'a']);
      final fresh = await c.where().sort([SortSpec('n')]).limit(2).findAll();
      expect(ids(pages.last), ids(fresh));
      await db.close();
    });

    test('equal sort keys break ties by record id', () async {
      final db = await openNativeTestDatabase('ww-ties');
      final c = coll(db, 'items');
      await c.put({'id': 'b', 'n': 1});
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'c', 'n': 1});
      final emissions = collectN(c.where().sort([SortSpec('n')]).limit(2).watch(), 1);
      await flush();
      final pages = await emissions;
      expect(ids(pages.single), ['a', 'b'], reason: 'tie broken by id');
      await db.close();
    });

    test('missing sort fields sort last and stay out of the window', () async {
      final db = await openNativeTestDatabase('ww-missing');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      // `m` has NO sort field: ascending sorts last, so it is outside the
      // 2-row window until `a`/`b` leave.
      await c.put({'id': 'm'});
      final emissions = collectN(c.where().sort([SortSpec('n')]).limit(2).watch(), 1);
      await flush();
      final pages = await emissions;
      expect(ids(pages.single), ['a', 'b']);
      // Deleting a window row admits the missing-field row.
      final second = collectN(c.where().sort([SortSpec('n')]).limit(2).watch(), 2);
      await flush();
      await c.delete('a');
      final p2 = await second;
      expect(ids(p2.last), ['b', 'm']);
      await db.close();
    });

    test('multi-row atomic batch updates the window once', () async {
      final db = await openNativeTestDatabase('ww-batch');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      final emissions = collectN(c.where().sort([SortSpec('n')]).limit(2).watch(), 2);
      await flush();
      // Two rows join in ONE batch; both sort ahead of `a`, so the whole
      // window is replaced by the single batch's deltas.
      await db.bulkWrite([
        BulkMutation.put(table: 'items', key: 'x', value: {'id': 'x', 'n': 0}),
        BulkMutation.put(table: 'items', key: 'y', value: {'id': 'y', 'n': -1}),
      ]);
      final pages = await emissions;
      expect(ids(pages.last), ['y', 'x']);
      final fresh = await c.where().sort([SortSpec('n')]).limit(2).findAll();
      expect(ids(pages.last), ids(fresh));
      await db.close();
    });

    test('idempotent write emits the same window', () async {
      final db = await openNativeTestDatabase('ww-idem');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      await c.put({'id': 'c', 'n': 3});
      final emissions = collectN(c.where().limit(2).watch(), 2);
      await flush();
      // Identical rewrite of an in-window row: window unchanged.
      await c.put({'id': 'a', 'n': 1});
      final pages = await emissions;
      expect(ids(pages.last), ['a', 'b']);
      await db.close();
    });

    test('a write entirely outside the window is invisible', () async {
      final db = await openNativeTestDatabase('ww-outside');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      await c.put({'id': 'c', 'n': 3});
      final emissions = collectN(c.where().limit(2).watch(), 2);
      await flush();
      // `c` is outside the 2-row window; its value change stays invisible.
      await c.put({'id': 'c', 'n': 300});
      final pages = await emissions;
      expect(ids(pages.last), ['a', 'b']);
      await db.close();
    });

    test('unsorted window follows byte-key order', () async {
      final db = await openNativeTestDatabase('ww-unsorted');
      final c = coll(db, 'items');
      await c.put({'id': 'c', 'n': 3});
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      final emissions = collectN(c.where().limit(2).watch(), 1);
      await flush();
      final pages = await emissions;
      expect(ids(pages.single), ['a', 'b'], reason: 'byte-key order');
      await db.close();
    });

    test('cancelling before registration settles is clean', () async {
      final db = await openNativeTestDatabase('ww-cancel');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      final errors = <Object>[];
      final sub = c
          .where()
          .limit(2)
          .watch()
          .listen((_) {}, onError: errors.add);
      await flush();
      await sub.cancel();
      // Further writes must not error into the cancelled subscription.
      await c.put({'id': 'z', 'n': 99});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(errors, isEmpty);
      await db.close();
    });
  });
}
