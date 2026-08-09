import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

class _Item {
  _Item(this.id, this.value);
  final String id;
  final String value;
}

Object? _toRow(_Item item) => {'id': item.id, 'value': item.value};
_Item _fromRow(Object? row) =>
    _Item((row as Map)['id'] as String? ?? '', row['value'] as String);
Object? _id(_Item item) => item.id;

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 20 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  group('Phase 12 bulk writes', () {
    test('bulkWrite commits atomically and emits one feed batch', () async {
      final db = await DatabaseImpl.open('mem://p12-bulk', useInMemory: true);
      final item = db.collection<_Item>(
        'items',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      final events = <ChangeSet>[];
      final sub = db.watchAll().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      final result = await db.bulkWrite([
        const BulkMutation.put(
          table: 'items',
          key: 'a',
          value: {'id': 'a', 'value': 'A'},
        ),
        const BulkMutation.put(
          table: 'items',
          key: 'b',
          value: {'id': 'b', 'value': 'B'},
        ),
        const BulkMutation.delete(table: 'items', key: 'missing'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(result.mutationCount, 3);
      expect((await item.getAll()).length, 2);
      expect(events, hasLength(1));
      expect(events.single.changes.length, 3);
      await sub.cancel();
      await db.close();
    });
  });

  group('Phase 12 diagnostics', () {
    test(
      'disabled diagnostics stay zero; enabled diagnostics observe work',
      () async {
        final db = await DatabaseImpl.open('mem://p12-diag', useInMemory: true);
        final item = db.collection<_Item>(
          'items',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _id,
        );
        await item.put(_Item('a', 'A'));
        expect(db.diagnostics.enabled, isFalse);
        expect(db.diagnostics.snapshot().totalWrites, 0);
        db.diagnostics.enable();
        await item.put(_Item('b', 'B'));
        await item.get('b');
        final snapshot = db.diagnostics.snapshot();
        expect(snapshot.enabled, isTrue);
        expect(snapshot.totalWrites, greaterThan(0));
        expect(snapshot.totalReads, greaterThan(0));
        expect(snapshot.inFlightLimit, greaterThan(0));
        db.diagnostics.reset();
        expect(db.diagnostics.snapshot().totalWrites, 0);
        db.diagnostics.disable();
        expect(db.diagnostics.enabled, isFalse);
        await db.close();
      },
    );
  });

  group('Phase 12 per-row diff watch', () {
    test('diff mode reports added, updated, and removed rows', () async {
      final db = await DatabaseImpl.open('mem://p12-diff', useInMemory: true);
      final item = db.collection<_Item>(
        'items',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await item.put(_Item('a', 'A'));
      final diffs = <CollectionDiff<_Item>>[];
      final sub = item.watchAllDiff().listen(diffs.add);
      await Future<void>.delayed(Duration.zero);
      expect(diffs.single.added, hasLength(1));
      await item.put(_Item('b', 'B'));
      await _waitFor(() => diffs.length >= 2);
      expect(diffs.last.added.single.id, 'b');
      await item.put(_Item('a', 'A2'));
      await _waitFor(() => diffs.any((diff) => diff.updated.isNotEmpty));
      expect(diffs.last.updated, hasLength(1));
      await item.delete('b');
      await _waitFor(() => diffs.any((diff) => diff.removed.isNotEmpty));
      expect(diffs.last.removed, hasLength(1));
      await sub.cancel();
      await db.close();
    });
  });
}
