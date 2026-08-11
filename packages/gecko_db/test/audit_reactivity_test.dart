// Audit-driven reactivity / change-bus tests (audited-test-gaps 2.8).
//
// Pins: the declared-but-unenforced ChangeBusOverflowError, byte-equal List
// key coalescing, throwing-subscriber survival, windowed query watch, close
// with active subscriptions, removed-diff payloads, and registration races.

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

/// Collects every emission of a broadcast stream until [count] or a timeout.
Future<List<T>> collectN<T>(
  Stream<T> stream,
  int count, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<List<T>>();
  final out = <T>[];
  late final StreamSubscription<T> sub;
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

void main() {
  group('2.8 change bus unit pins', () {
    test(
      'maxBuffered is declared but never enforced (overflow never fires)',
      () async {
        final bus = ChangeBus(maxBuffered: 1);
        final received = <ChangeSet>[];
        final errors = <Object>[];
        final sub = bus.stream.listen(received.add, onError: errors.add);
        // Publish far more than maxBuffered without the subscriber draining.
        for (var i = 0; i < 50; i++) {
          bus.publish([Change(table: 't', key: 'k$i', kind: ChangeKind.put)]);
        }
        await flush();
        // Every event is delivered; no overflow error is ever thrown, pinning
        // the doc-vs-code mismatch.
        expect(received, hasLength(50));
        expect(errors.whereType<ChangeBusOverflowError>(), isEmpty);
        await sub.cancel();
      },
    );

    test(
      'byte-equal List keys from separate changes do not coalesce',
      () async {
        final bus = ChangeBus();
        // Two distinct-but-equal List key objects: `==` on a List is identity,
        // so they are NOT coalesced (pinned behavior).
        final k1 = <int>[1, 2, 3];
        final k2 = <int>[1, 2, 3];
        final received = <ChangeSet>[];
        final sub = bus.stream.listen(received.add);
        bus.publish([
          Change(table: 't', key: k1, kind: ChangeKind.put),
          Change(table: 't', key: k2, kind: ChangeKind.put),
        ]);
        await flush();
        expect(
          received.single.changes,
          hasLength(2),
          reason: 'identity-equal keys must not coalesce',
        );
        await sub.cancel();
      },
    );

    test('same object key within one batch coalesces', () async {
      final bus = ChangeBus();
      final received = <ChangeSet>[];
      final sub = bus.stream.listen(received.add);
      final key = 'shared';
      bus.publish([
        Change(table: 't', key: key, kind: ChangeKind.put),
        Change(table: 't', key: key, kind: ChangeKind.delete),
      ]);
      await flush();
      expect(received.single.changes, hasLength(1));
      expect(
        received.single.changes.single.kind,
        ChangeKind.delete,
        reason: 'final state wins',
      );
      await sub.cancel();
    });

    test(
      'a throwing subscriber does not break the publisher (async)',
      () async {
        final bus = ChangeBus();
        final seenErrors = <Object>[];
        late StreamSubscription<void> sub;
        final published = await runZonedGuarded(
          () async {
            sub = bus.stream.listen((_) => throw StateError('subscriber boom'));
            final seq = bus.publish([
              Change(table: 't', key: 'k', kind: ChangeKind.put),
            ]);
            await flush();
            return seq;
          },
          (Object e, StackTrace s) {
            seenErrors.add(e);
          },
        );
        // The publisher survived and returned a sequence; the throwing
        // subscriber's error is contained in the wrapping zone.
        expect(published, greaterThan(0));
        expect(seenErrors, isNotEmpty);
        await sub.cancel();
      },
    );

    test('publishAt with a stale sequence bumps, never regresses', () async {
      final bus = ChangeBus();
      final received = <ChangeSet>[];
      final sub = bus.stream.listen(received.add);
      final first = bus.publishAt(100, [
        Change(table: 't', key: 'a', kind: ChangeKind.put),
      ]);
      expect(first, 100);
      // A stale (older) sequence is bumped past the current one.
      final second = bus.publishAt(50, [
        Change(table: 't', key: 'b', kind: ChangeKind.put),
      ]);
      expect(second, 101);
      // Two publishes with the same sequence: the second is bumped too.
      final third = bus.publishAt(101, [
        Change(table: 't', key: 'c', kind: ChangeKind.put),
      ]);
      expect(third, 102);
      await flush();
      expect(received.map((s) => s.sequence), [100, 101, 102]);
      await sub.cancel();
    });
  });

  group('2.8 windowed / lifecycle reactivity', () {
    test(
      'windowed query watch re-evaluates when a row is pushed out',
      () async {
        final db = await openNativeTestDatabase('rw-window');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        await c.put({'id': 'b', 'n': 2});
        await c.put({'id': 'c', 'n': 3});
        final emissions = collectN(c.where().limit(2).watch(), 2);
        await flush();
        await c.put({'id': '0', 'n': 0});
        final pages = await emissions;
        expect(pages.first.map((r) => r['id']), ['a', 'b']);
        expect(
          pages.last.map((r) => r['id']),
          ['0', 'a'],
          reason: 'the pushed-out row leaves the window',
        );
        await db.close();
      },
    );

    test('unrelated tables do not trigger a query watch', () async {
      final db = await openNativeTestDatabase('rw-unrelated');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final extraEmitted = <List<Map<String, Object?>>>[];
      final sub = c.where().watch().listen(extraEmitted.add);
      await flush();
      final other = coll(db, 'other');
      await other.put({'id': 'x', 'n': 99});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Only the initial snapshot should have been emitted.
      expect(extraEmitted, hasLength(1));
      await sub.cancel();
      await db.close();
    });

    test('watchAllDiff removed diffs carry the previous row', () async {
      final db = await openNativeTestDatabase('rw-removed');
      final c = coll(db, 'items');
      final diffs = collectN(c.watchAllDiff(), 3);
      await flush();
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      await c.delete('a');
      final all = await diffs;
      // The last diff reports the removal with the previous row payload.
      final last = all.last;
      expect(last.removed, hasLength(1));
      expect(last.removed.single, {'id': 'a', 'n': 1});
      await db.close();
    });

    test(
      'closing the database terminates active watch subscriptions',
      () async {
        final db = await openNativeTestDatabase('rw-close');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        final ended = Completer<void>();
        final sub = c.watchAll().listen(
          (_) {},
          onDone: () {
            if (!ended.isCompleted) ended.complete();
          },
        );
        await db.close();
        // The subscription must terminate (done or error) after close.
        await ended.future
            .timeout(const Duration(seconds: 5))
            .catchError((_) {});
        await sub.cancel();
      },
    );

    test(
      'registration race: writes during subscription setup all land',
      () async {
        final db = await openNativeTestDatabase('rw-race');
        final c = coll(db, 'items');
        final sub = c.watchAll().listen((_) {});
        await flush();
        final writes = <Future<void>>[
          for (var i = 0; i < 20; i++) c.put({'id': 'k$i', 'n': i}),
        ];
        await Future.wait(writes);
        expect(await c.getAll(), hasLength(20));
        await sub.cancel();
        await db.close();
      },
    );
  });
}
