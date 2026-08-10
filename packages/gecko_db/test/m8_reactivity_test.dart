// M8 — incremental reactivity qualification (ADR-0029).
//
// These tests prove that a write updates only the affected live result sets
// and never re-scans the watched collection: after the one-time initial
// materialization, `scannedRows` must not grow with subsequent writes, and
// every emission must stay byte-for-byte / set-for-set consistent with a full
// re-evaluation (`getAll()` / `findAll()`).
import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

/// Polls until [condition] holds (the native worker emits change-feed events
/// asynchronously, so a single event-loop turn is not enough).
Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 40 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

class _Rec {
  _Rec(this.id, this.group, this.n);
  final String id;
  final String group;
  final int n;
}

Object? _toRow(_Rec r) => {'id': r.id, 'group': r.group, 'n': r.n};
_Rec _fromRow(Object? row) {
  final m = row as Map;
  return _Rec(m['id'] as String, m['group'] as String, m['n'] as int);
}
Object? _id(_Rec r) => r.id;

Collection<_Rec> _coll(DatabaseImpl db, {List<String>? indexFields}) =>
    db.collection<_Rec>(
      'items',
      toRow: _toRow,
      fromRow: _fromRow,
      id: _id,
      indexFields: indexFields,
    );

Future<void> _seed(DatabaseImpl db, int count, {List<String>? indexFields}) async {
  final col = _coll(db, indexFields: indexFields);
  for (var i = 0; i < count; i++) {
    await col.put(_Rec('k$i', 'g${i % 3}', i));
  }
}

void main() {
  group('M8 incremental watchAll', () {
    test(
      'updates the cache incrementally without re-scanning the collection',
      () async {
        final db = await openNativeTestDatabase('m8-all');
        await _seed(db, 400);
        final emissions = <List<String>>[];
        final sub = _coll(db).watchAll().listen(
          (list) => emissions.add([for (final r in list) r.id]),
        );
        await _waitFor(() => emissions.isNotEmpty);
        expect(emissions.first, hasLength(400));
        expect(emissions.first.first, 'k0');
        expect(emissions.first.last, 'k399');
        final scannedAfterInitial = db.engine.scannedRows;

        // Insert, update, and delete rows (three separate batches).
        await _coll(db).put(_Rec('k400', 'g1', 400));
        await _coll(db).put(_Rec('k200', 'g0', -1)); // update
        await _coll(db).delete('k5'); // delete

        await _waitFor(() => emissions.length >= 4);
        final last = emissions.last;
        expect(last, hasLength(400));
        expect(last, contains('k400'));
        expect(last, contains('k200'));
        expect(last, isNot(contains('k5')));
        // Order stays byte-key order (parity with getAll()).
        // The incremental updates performed point reads, not full scans.
        // NOTE: assert BEFORE getAll() below — getAll() itself is a full scan.
        expect(
          db.engine.scannedRows,
          scannedAfterInitial,
          reason: 'watchAll must not re-scan the collection per batch',
        );
        expect(
          last,
          [for (final r in await _coll(db).getAll()) r.id],
          reason: 'incremental order must match getAll() order',
        );
        await sub.cancel();
        await db.close();
      },
    );

    test('a whole-table clear resets the emission to empty', () async {
      final db = await openNativeTestDatabase('m8-clear');
      await _seed(db, 30);
      final lengths = <int>[];
      final sub = _coll(db).watchAll().listen((list) => lengths.add(list.length));
      await _waitFor(() => lengths.isNotEmpty);
      expect(lengths.first, 30);
      await db.engine.rawClear('items');
      await _waitFor(() => lengths.last == 0);
      expect(lengths.last, 0);
      await sub.cancel();
      await db.close();
    });
  });

  group('M8 incremental watchAllDiff', () {
    test('reports added, updated, and removed from incremental updates', () async {
      final db = await openNativeTestDatabase('m8-diff');
      await _seed(db, 20);
      final diffs = <CollectionDiff<_Rec>>[];
      final sub = _coll(db).watchAllDiff().listen(diffs.add);
      await _waitFor(() => diffs.isNotEmpty);
      expect(diffs.first.added, hasLength(20));
      final scannedBefore = db.engine.scannedRows;

      await _coll(db).put(_Rec('k20', 'g2', 20)); // add
      await _coll(db).put(_Rec('k1', 'g0', 101)); // update (changed value)
      await _coll(db).delete('k2'); // remove
      // Each batch yields its own diff; accumulate across all of them.
      await _waitFor(
        () => diffs.any(
          (d) => d.removed.map((r) => r.id).contains('k2'),
        ),
      );
      final added = [for (final d in diffs) ...d.added.map((r) => r.id)];
      final updated = [for (final d in diffs) ...d.updated.map((r) => r.id)];
      final removed = [for (final d in diffs) ...d.removed.map((r) => r.id)];
      expect(added, contains('k20'));
      expect(updated, contains('k1'));
      expect(removed, contains('k2'));
      expect(diffs.last.snapshot, hasLength(20));
      expect(
        db.engine.scannedRows,
        scannedBefore,
        reason: 'no per-batch rescans',
      );
      await sub.cancel();
      await db.close();
    });
  });

  group('M8 incremental watch lifecycle', () {
    test('cancelling the subscription stops all further updates', () async {
      final db = await openNativeTestDatabase('m8-cancel');
      await _seed(db, 10);
      final emissions = <List<String>>[];
      final sub = _coll(db).watchAll().listen(
        (list) => emissions.add([for (final r in list) r.id]),
      );
      await _waitFor(() => emissions.isNotEmpty);
      final countAfterInitial = emissions.length;
      await sub.cancel();
      await _coll(db).put(_Rec('k10', 'g1', 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        emissions.length,
        countAfterInitial,
        reason: 'no emissions after cancel',
      );
      await db.close();
    });
  });

  group('M8 incremental watchAllDiff', () {
    test('an idempotent put with an unchanged value emits no diff', () async {
      final db = await openNativeTestDatabase('m8-idempotent');
      await _seed(db, 5);
      final diffs = <CollectionDiff<_Rec>>[];
      final sub = _coll(db).watchAllDiff().listen(diffs.add);
      await _waitFor(() => diffs.isNotEmpty);
      final before = diffs.length;
      // Same key, same value: nothing observable changes.
      await _coll(db).put(_Rec('k1', 'g1', 1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        diffs.length,
        before,
        reason: 'unchanged value must not emit a diff',
      );
      await sub.cancel();
      await db.close();
    });
  });

  group('M8 incremental filtered query watch', () {
    test(
      'updates matching rows incrementally without re-scanning the collection',
      () async {
        final db = await openNativeTestDatabase('m8-query');
        await _seed(db, 600);
        final emissions = <List<String>>[];
        final q = _coll(db).where({'group': 'g1'});
        final sub = q.watch().listen(
          (list) => emissions.add([for (final r in list) r.id]),
        );
        await _waitFor(() => emissions.isNotEmpty);
        expect(emissions.first, hasLength(200)); // 600 / 3
        final scannedAfterInitial = db.engine.scannedRows;

        // k600 (new, g1) joins; k1 (g1 -> g2) leaves; k2 (g2 -> g1) joins;
        // k4 stays in g1 (update within the match).
        await _coll(db).put(_Rec('k600', 'g1', 600));
        await _coll(db).put(_Rec('k1', 'g2', -1));
        await _coll(db).put(_Rec('k2', 'g1', -2));
        await _coll(db).put(_Rec('k4', 'g1', -4));

        await _waitFor(() => emissions.length >= 5);
        final last = emissions.last;
        expect(last, contains('k600'));
        expect(last, isNot(contains('k1')));
        expect(last, contains('k2'));
        expect(last, contains('k4'));
        expect(last, hasLength(201));
        // Parity with a fresh findAll().
        expect(
          last,
          [for (final r in await q.findAll()) r.id],
          reason: 'incremental filtered query must match findAll()',
        );
        expect(
          db.engine.scannedRows,
          scannedAfterInitial,
          reason: 'filtered query watch must not re-scan per batch',
        );
        await sub.cancel();
        await db.close();
      },
    );

    test('emits once per batch (coalesced), not once per key', () async {
      final db = await openNativeTestDatabase('m8-coalesce');
      await _seed(db, 10);
      final emissions = <int>[];
      final sub = _coll(db).where({'group': 'g0'}).watch().listen(
        (list) => emissions.add(list.length),
      );
      await _waitFor(() => emissions.isNotEmpty);
      final before = emissions.length;
      // One batch touching 5 rows in g0.
      await db.bulkWrite([
        for (var i = 0; i < 5; i++)
          BulkMutation.put(
            table: 'items',
            key: 'k$i',
            value: {'id': 'k$i', 'group': 'g0', 'n': i},
          ),
      ]);
      await _waitFor(() => emissions.length > before);
      expect(
        emissions.length,
        before + 1,
        reason: 'one coalesced emission per batch',
      );
      await sub.cancel();
      await db.close();
    });
  });

  group('M8 incremental sorted query watch', () {
    test('keeps emissions in comparator order after updates', () async {
      final db = await openNativeTestDatabase('m8-sorted');
      final col = _coll(db);
      for (var i = 0; i < 40; i++) {
        await col.put(_Rec('k$i', 'g${i % 2}', 40 - i)); // n descending by i
      }
      final q = col.where().sort([const SortSpec('n')]);
      final emissions = <List<String>>[];
      final sub = q.watch().listen(
        (list) => emissions.add([for (final r in list) r.id]),
      );
      await _waitFor(() => emissions.isNotEmpty);
      expect(emissions.first, hasLength(40));

      await col.put(_Rec('k40', 'g0', 100)); // highest n -> last (ascending)
      await col.put(_Rec('k0', 'g0', -100)); // lowest n -> first (ascending)
      await _waitFor(() => emissions.length >= 3);
      final last = emissions.last;
      // SortSpec is ascending: k0 (n=-100) first, k40 (n=100) last.
      expect(last.first, 'k0');
      expect(last.last, 'k40');
      expect(
        last,
        [for (final r in await q.findAll()) r.id],
        reason: 'incremental sorted query must match findAll() order',
      );
      await sub.cancel();
      await db.close();
    });
  });
}
