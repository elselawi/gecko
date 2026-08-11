import 'dart:async';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

String _nativeLibraryPath() {
  final root = Directory.current.path.endsWith('gecko_db')
      ? Directory.current.parent.parent.path
      : Directory.current.path;
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

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
  group('bulk writes', () {
    test('bulkWrite commits atomically and emits one feed batch', () async {
      final db = await openNativeTestDatabase('perf-bulk');
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

    test(
      'bulkWrite maintains secondary indexes across insert/update/delete and reopen',
      () async {
        final dir = await Directory.systemTemp.createTemp('perf-bulk-index-');
        final path = '${dir.path}${Platform.pathSeparator}db.redb';
        try {
          final db = await DatabaseImpl.open(
            path,
            config: DatabaseConfig(nativeLibraryPath: _nativeLibraryPath()),
          );
          final item = db.collection<_Item>(
            'items',
            toRow: _toRow,
            fromRow: _fromRow,
            id: _id,
            indexFields: const ['value'],
          );

          // Insert 100 rows via bulkWrite.
          await db.bulkWrite([
            for (var i = 0; i < 100; i++)
              BulkMutation.put(
                table: 'items',
                key: 'k$i',
                value: {'id': 'k$i', 'value': 'g${i % 10}'},
              ),
          ]);
          expect(
            (await item.where().filter('value', 'g3').findAll()).length,
            10,
          );

          // Update 5 of the 10 g3 rows (k3, k23, ...) to g9 via bulkWrite.
          await db.bulkWrite([
            for (var i = 3; i < 100; i += 20)
              BulkMutation.put(
                table: 'items',
                key: 'k$i',
                value: {'id': 'k$i', 'value': 'g9'},
              ),
          ]);
          expect(
            (await item.where().filter('value', 'g3').findAll()).length,
            5,
            reason: 'updated rows must leave the old index value',
          );
          expect(
            (await item.where().filter('value', 'g9').findAll()).length,
            15,
          );

          // Delete one row via bulkWrite.
          await db.bulkWrite([BulkMutation.delete(table: 'items', key: 'k9')]);
          expect(
            (await item.where().filter('value', 'g9').findAll()).length,
            14,
            reason: 'deleted row must leave the index',
          );
          expect((await item.get('k9')), isNull);

          // Reopen: the durable index must rebuild from the primary table and
          // agree with the same queries.
          await db.close();
          final db2 = await DatabaseImpl.open(
            path,
            config: DatabaseConfig(nativeLibraryPath: _nativeLibraryPath()),
          );
          try {
            final item2 = db2.collection<_Item>(
              'items',
              toRow: _toRow,
              fromRow: _fromRow,
              id: _id,
              indexFields: const ['value'],
            );
            expect(
              (await item2.where().filter('value', 'g3').findAll()).length,
              5,
            );
            expect(
              (await item2.where().filter('value', 'g9').findAll()).length,
              14,
            );
          } finally {
            await db2.close();
          }
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  });

  group('diagnostics', () {
    test(
      'disabled diagnostics stay zero; enabled diagnostics observe work',
      () async {
        final db = await openNativeTestDatabase('perf-diag');
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

  group('per-row diff watch', () {
    test('diff mode reports added, updated, and removed rows', () async {
      final db = await openNativeTestDatabase('perf-diff');
      final item = db.collection<_Item>(
        'items',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _id,
      );
      await item.put(_Item('a', 'A'));
      final diffs = <CollectionDiff<_Item>>[];
      final sub = item.watchAllDiff().listen(diffs.add);
      await _waitFor(() => diffs.isNotEmpty);
      expect(diffs.first.added, hasLength(1));
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
