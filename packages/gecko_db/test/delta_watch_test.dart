// Delta-only collection watch (terry-perf Item 16A).
//
// `Collection.watchAllDeltas()` emits only added/updated/removed rows — no
// full snapshot is ever built — while the existing `watchAllDiff` /
// `CollectionDiff.snapshot` behavior is unchanged.

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

Future<List<CollectionDelta<Map<String, Object?>>>> collectDeltas(
  Stream<CollectionDelta<Map<String, Object?>>> stream,
  int count, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final completer = Completer<List<CollectionDelta<Map<String, Object?>>>>();
  final out = <CollectionDelta<Map<String, Object?>>>[];
  late final StreamSubscription<CollectionDelta<Map<String, Object?>>> sub;
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
  group('watchAllDeltas (snapshot-less)', () {
    test('initial emission reports current rows as added', () async {
      final db = await openNativeTestDatabase('deltas-initial');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.put({'id': 'b', 'n': 2});
      final deltas = collectDeltas(c.watchAllDeltas(), 1);
      await flush();
      final all = await deltas;
      expect(ids(all.single.added), ['a', 'b']);
      expect(all.single.updated, isEmpty);
      expect(all.single.removed, isEmpty);
      await db.close();
    });

    test('put/delete produce added/updated/removed without a snapshot', () async {
      final db = await openNativeTestDatabase('deltas-diff');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final deltas = collectDeltas(c.watchAllDeltas(), 3);
      await flush();
      await c.put({'id': 'b', 'n': 2}); // added
      await c.put({'id': 'a', 'n': 9}); // updated
      await c.delete('a'); // removed
      final all = await deltas;
      expect(ids(all[1].added), ['b']);
      expect(ids(all[2].updated), ['a']);
      expect(ids(all[3].removed), ['a']);
      // The delta type has no snapshot member at all.
      expect(all.last, isA<CollectionDelta<Map<String, Object?>>>());
      await db.close();
    });

    test('idempotent writes do not emit', () async {
      final db = await openNativeTestDatabase('deltas-idem');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final deltas = collectDeltas(c.watchAllDeltas(), 1);
      await flush();
      await c.put({'id': 'a', 'n': 1}); // identical → no delta
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final all = await deltas;
      expect(all, hasLength(1), reason: 'no emission for an identical rewrite');
      await db.close();
    });

    test('watchAllDiff still carries its snapshot (unchanged behavior)', () async {
      final db = await openNativeTestDatabase('deltas-diff-snapshot');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final diffs = <CollectionDiff<Map<String, Object?>>>[];
      final sub = c.watchAllDiff().listen(diffs.add);
      await flush();
      await c.put({'id': 'b', 'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await sub.cancel();
      expect(diffs, isNotEmpty);
      expect(diffs.last.snapshot.map((r) => r['id']), ['a', 'b']);
      await db.close();
    });
  });
}
