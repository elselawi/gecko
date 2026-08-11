import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _Item {
  _Item(this.id, this.value);
  final String id;
  final String value;
}

Object? _itemToRow(_Item item) => {'value': item.value};
_Item _itemFromRow(Object? row) => _Item('', (row as Map)['value'] as String);
Object? _itemId(_Item item) => item.id;

Future<DatabaseImpl> _open(String suffix, {int maxLog = 1000}) =>
    openNativeTestDatabase(
      'sync-$suffix',
      config: DatabaseConfig(changeLogMaxEntries: maxLog),
    );

Collection<_Item> _items(Database db, String name) => db.collection<_Item>(
  name,
  toRow: _itemToRow,
  fromRow: _itemFromRow,
  id: _itemId,
);

ChangeRecord _remote({
  required String collection,
  required String id,
  required String value,
  String? key,
  ChangeKind kind = ChangeKind.put,
}) => ChangeRecord(
  localMutationId: 0,
  recordId: id,
  timestamp: DateTime.utc(2026),
  collection: collection,
  kind: kind,
  value: value == '' ? null : {'value': value},
  idempotencyKey: key,
  origin: ChangeOrigin.remoteSync,
);

void main() {
  group('writeTxn', () {
    test('rolls back single and multi-collection writes', () async {
      final db = await _open('rollback');
      final a = _items(db, 'a');
      final b = _items(db, 'b');
      await expectLater(
        db.writeTxn((txn) async {
          await txn
              .collection<_Item>(
                'a',
                toRow: _itemToRow,
                fromRow: _itemFromRow,
                id: _itemId,
              )
              .put(_Item('a1', 'x'));
          await txn
              .collection<_Item>(
                'b',
                toRow: _itemToRow,
                fromRow: _itemFromRow,
                id: _itemId,
              )
              .put(_Item('b1', 'y'));
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(await a.getAll(), isEmpty);
      expect(await b.getAll(), isEmpty);
      await db.close();
    });

    test('reads own staged writes and not a concurrent commit', () async {
      final db = await _open('isolation');
      final a = _items(db, 'a');
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = db.writeTxn((txn) async {
        final tx = txn.collection<_Item>(
          'a',
          toRow: _itemToRow,
          fromRow: _itemFromRow,
          id: _itemId,
        );
        await tx.put(_Item('own', 'staged'));
        expect((await tx.get('own'))!.value, 'staged');
        entered.complete();
        await release.future;
        expect(await tx.get('other'), isNull);
      });
      await entered.future;
      final second = a.put(_Item('other', 'concurrent'));
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await first;
      await second;
      expect((await a.get('other'))!.value, 'concurrent');
      await db.close();
    });

    test('local put patch delete produce one pending record each', () async {
      final db = await _open('local-records');
      final a = _items(db, 'a');
      await a.put(_Item('x', '1'));
      await a.patch('x', {'value': '2'});
      await a.delete('x');
      final changes = await db.sync.readLocallyChanged();
      expect(changes, hasLength(1), reason: 'latest state is one pending ref');
      expect(changes.single.change.origin, ChangeOrigin.user);
      expect(changes.single.change.kind, ChangeKind.delete);
      expect(changes.single.change.localMutationId, 3);
      await db.close();
    });
  });

  group('sync hooks', () {
    test(
      'remote writes emit watchAll but do not become locally pending',
      () async {
        final db = await _open('remote-watch');
        final events = <ChangeSet>[];
        final sub = db.watchAll().listen(events.add);
        await Future<void>.delayed(Duration.zero);
        await db.sync.applyRemoteTransactional([
          _remote(collection: 'a', id: 'r1', value: 'remote', key: 'k1'),
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        expect(events.single.changes.single.table, 'a');
        expect(await db.sync.readLocallyChanged(), isEmpty);
        await sub.cancel();
        await db.close();
      },
    );

    test('syncing then synced clears, failed preserves and retries', () async {
      final db = await _open('states');
      final a = _items(db, 'a');
      await a.put(_Item('x', 'v'));
      await db.sync.markSynchronizing(['x']);
      expect(
        (await db.sync.readLocallyChanged()).single.change.syncState!.phase,
        SyncPhase.synchronizing,
      );
      await db.sync.markFailed(['x'], 'offline');
      final failed = (await db.sync.readLocallyChanged()).single.change;
      expect(failed.dirty, isTrue);
      expect(failed.retryCount, 1);
      expect(failed.lastSyncError, 'offline');
      await db.sync.markSynced(['x']);
      expect(await db.sync.readLocallyChanged(), isEmpty);
      await db.close();
    });

    test('idempotency dedupe persists for repeat remote mutations', () async {
      final db = await _open('dedupe');
      final record = _remote(collection: 'a', id: 'r', value: 'v', key: 'same');
      expect(await db.sync.isDuplicate('same'), isFalse);
      expect(await db.sync.applyRemoteTransactional([record]), ['r']);
      expect(await db.sync.isDuplicate('same'), isTrue);
      expect(await db.sync.applyRemoteTransactional([record]), isEmpty);
      await db.close();
    });

    test('changesSince is strictly after and LSNs are monotonic', () async {
      final db = await _open('changes-since');
      final a = _items(db, 'a');
      await a.put(_Item('1', 'one'));
      final first = (await db.sync.changesSince(
        const SyncSnapshot(lastSeq: 0),
      )).single;
      await a.put(_Item('2', 'two'));
      final all = await db.sync.changesSince(const SyncSnapshot(lastSeq: 0));
      expect(all.map((c) => c.localMutationId).toList(), [1, 2]);
      expect(
        (await db.sync.changesSince(
          SyncSnapshot(lastSeq: first.localMutationId),
        )).map((c) => c.recordId),
        ['2'],
      );
      expect(
        await db.sync.changesSince(const SyncSnapshot(lastSeq: 2)),
        isEmpty,
      );
      await db.close();
    });

    test('remote version is persisted in reserved metadata', () async {
      final db = await _open('remote-version');
      await db.sync.storeRemoteVersion(42);
      expect(await db.sync.readRemoteVersion(), 42);
      await db.close();
    });

    test('GC advances watermark and never prunes pending changes', () async {
      final db = await _open('gc', maxLog: 1);
      final a = _items(db, 'a');
      await a.put(_Item('1', 'one'));
      await db.sync.markSynced(['1']);
      await a.put(_Item('2', 'two'));
      await a.put(_Item('3', 'three'));
      final records = await db.sync.changesSince(
        const SyncSnapshot(lastSeq: 0),
      );
      expect(records.any((record) => record.recordId == '2'), isTrue);
      expect(records.any((record) => record.recordId == '3'), isTrue);
      expect(
        (await db.sync.readLocallyChanged()).map((p) => p.recordId),
        containsAll(['2', '3']),
      );
      await db.close();
    });
  });
}
