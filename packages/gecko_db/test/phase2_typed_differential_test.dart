// Workstream 2 — typed-level backend differential.
//
// The raw differential (`phase2_differential_test.dart`) proves the backend
// layer is byte-equivalent. This suite additionally replays higher-level,
// deterministic typed scenarios (schema/defaults/generated ids/unknown-field
// preservation, transactions, change tracking + sync transitions, bulk
// writes, diagnostics) through `DatabaseImpl` on two independent native file
// backends and asserts identical public results, identical change feeds, and
// byte-equivalent final snapshots.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/differential.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

/// A deterministic clock so change-record timestamps match across backends.
DateTime _fixedClock() => DateTime.fromMillisecondsSinceEpoch(1700000000000);

Collection<Map<String, Object?>> _collection(
  DatabaseImpl db,
  String name, {
  RowSchema? schema,
}) => db.collection<Map<String, Object?>>(
  name,
  toRow: (m) => m,
  fromRow: (m) => Map<String, Object?>.from(m as Map),
  id: (m) => m['id'],
  schema: schema,
);

Future<Map<String, Map<String, Object?>>> _typedDump(DatabaseImpl db) async {
  final tables = await db.engine.backend.tables()
    ..sort();
  final out = <String, Map<String, Object?>>{};
  for (final table in tables) {
    final snap = await db.engine.backend.snapshot();
    try {
      final entries = await snap.scanAll(table);
      out[table] = {
        for (final entry in entries)
          entry.key.bytes
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join():
              entry.value,
      };
    } finally {
      await snap.dispose();
    }
  }
  return out;
}

Future<Map<String, Object?>> _captureWithFeed(
  DatabaseImpl db,
  Future<Map<String, Object?>> Function() body,
) async {
  final feed = <String>[];
  final sub = db.engine.changes.stream.listen((set) {
    feed.add(
      'seq=${set.sequence}['
      '${set.changes.map((c) => '${c.table}/${c.key}:${c.kind.name}').join(',')}]',
    );
  });
  try {
    final result = await body();
    result['changeFeed'] = feed;
    return result;
  } finally {
    await sub.cancel();
  }
}

void main() {
  final nativePath = _nativeLibraryPath(_repoRoot());

  Future<(DatabaseImpl, Directory)> openNative() async {
    final dir = await Directory.systemTemp.createTemp('gecko-typed-');
    final db = await DatabaseImpl.open(
      '${dir.path}${Platform.pathSeparator}db.redb',
      config: DatabaseConfig(nativeLibraryPath: nativePath, clock: _fixedClock),
    );
    return (db, dir);
  }

  Future<(DatabaseImpl, Directory)> openSecond(String tag) async {
    final dir = await Directory.systemTemp.createTemp('gecko-typed-$tag-');
    final db = await DatabaseImpl.open(
      '${dir.path}${Platform.pathSeparator}db.redb',
      config: DatabaseConfig(nativeLibraryPath: nativePath, clock: _fixedClock),
    );
    return (db, dir);
  }

  Future<void> expectTypedDifferential(
    String label,
    Future<Map<String, Object?>> Function(DatabaseImpl db) scenario,
  ) async {
    final (secondDb, secondDir) = await openSecond(label);
    final (nativeDb, dir) = await openNative();
    try {
      final a = await scenario(secondDb);
      final b = await scenario(nativeDb);
      expect(
        canonical(a),
        canonical(b),
        reason: 'typed differential ($label): public results diverged',
      );
      final snapA = await _typedDump(secondDb);
      final snapB = await _typedDump(nativeDb);
      expect(
        canonical(snapA),
        canonical(snapB),
        reason: 'typed differential ($label): final snapshots diverged',
      );
    } finally {
      await secondDb.close();
      await nativeDb.close();
      await dir.delete(recursive: true);
      await secondDir.delete(recursive: true);
    }
  }

  test(
    'typed CRUD, schema, defaults, generated ids, patch, unknown fields',
    () async {
      await expectTypedDifferential('crud-schema', (db) async {
        final schema = RowSchema.of({
          'id': const FieldSpec(name: 'id', required: true),
          'qty': const FieldSpec(
            name: 'qty',
            hasDefault: true,
            defaultValue: 1,
          ),
        });
        final items = _collection(db, 'items', schema: schema);
        final errors = <String>[];
        try {
          await items.put({'qty': 5}); // missing required 'id'
        } on GeckoError catch (error) {
          errors.add(error.type.name);
        }
        await items.put({'id': 'a', 'qty': 5});
        await items.put({'id': 'b'}); // default qty=1
        await items.put({'id': 'c', 'qty': 3, 'note': 'kept'}); // unknown field
        await items.patch('a', {'qty': 9});
        await items.delete('b');

        // Generated ids live on a schema-less collection (a required-id schema
        // rejects missing ids by design).
        final gen = _collection(db, 'gen');
        final generated = await gen.put({'v': 7});
        return <String, Object?>{
          'errors': errors,
          'generatedId': generated,
          'a': await items.get('a'),
          'c': await items.get('c'),
          'bAbsent': await items.get('b'),
          'generated': await gen.get(generated),
          'itemsAll': await items.getAll(),
          'genAll': await gen.getAll(),
        };
      });
    },
  );

  test('transactions: own-write visibility, commit, and rollback', () async {
    await expectTypedDifferential('transactions', (db) async {
      final ownWrite = <Object?>{};
      await db.writeTxn((txn) async {
        final c = txn.collection<Map<String, Object?>>(
          'txn',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        await c.put({'id': 'x', 'v': 1});
        ownWrite.add((await c.get('x'))?['v']);
        await c.put({'id': 'x', 'v': 2});
        ownWrite.add((await c.get('x'))?['v']);
      });
      final afterCommit = await db
          .collection<Map<String, Object?>>(
            'txn',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          )
          .get('x');

      var rollbackThrew = false;
      try {
        await db.writeTxn((txn) async {
          final c = txn.collection<Map<String, Object?>>(
            'rolled',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          await c.put({'id': 'r', 'v': 1});
          throw StateError('force rollback');
        });
      } on StateError {
        rollbackThrew = true;
      }
      final rolledAbsent = await db
          .collection<Map<String, Object?>>(
            'rolled',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          )
          .get('r');

      return <String, Object?>{
        'ownWriteVisibility': ownWrite.toList(),
        'afterCommitV': afterCommit?['v'],
        'rollbackThrew': rollbackThrew,
        'rolledBackAbsent': rolledAbsent,
      };
    });
  });

  test('change tracking, sync transitions, and remote dedupe', () async {
    await expectTypedDifferential('sync', (db) async {
      return _captureWithFeed(db, () async {
        final items = _collection(db, 'sync');
        await items.put({'id': 's1', 'v': 1});
        await items.put({'id': 's2', 'v': 2});
        final changed = await db.sync.readLocallyChanged();
        final ids = changed.map((p) => p.recordId).toList()..sort();
        final states =
            changed.map((p) => p.change.syncState?.phase.name).toSet().toList()
              ..sort();

        await db.sync.markSynced(ids);
        final afterSync = await db.sync.readLocallyChanged();

        await db.sync.storeRemoteVersion(42);
        final remoteVersion = await db.sync.readRemoteVersion();
        final since = await db.sync.changesSince(
          const SyncSnapshot(lastSeq: 0),
        );

        // Remote dedupe: applying a remote record with an idempotency key
        // registers it; a second application is rejected as a duplicate.
        final remote = ChangeRecord(
          localMutationId: 900,
          recordId: 'remote-1',
          timestamp: _fixedClock(),
          collection: 'sync',
          kind: ChangeKind.put,
          value: {'id': 'remote-1', 'v': 9},
          origin: ChangeOrigin.remoteSync,
          idempotencyKey: 'dedupe-me',
        );
        final firstApply = await db.sync.applyRemoteTransactional([remote]);
        final duplicate = await db.sync.isDuplicate('dedupe-me');
        final secondApply = await db.sync.applyRemoteTransactional([remote]);
        final remoteRow = await _collection(db, 'sync').get('remote-1');

        return <String, Object?>{
          'locallyChangedIds': ids,
          'syncPhases': states,
          'afterSyncCount': afterSync.length,
          'remoteVersion': remoteVersion,
          'changesSinceCount': since.length,
          'firstApplyIds': firstApply,
          'duplicate': duplicate,
          'secondApplyIds': secondApply,
          'remoteRow': remoteRow,
        };
      });
    });
  });

  test('bulk writes and diagnostics counters', () async {
    await expectTypedDifferential('bulk-diag', (db) async {
      db.diagnostics.enable();
      final bulk = await db.bulkWrite([
        BulkMutation.put(table: 'bulk', key: 'k1', value: {'id': 'k1'}),
        BulkMutation.put(table: 'bulk', key: 'k2', value: {'id': 'k2'}),
        BulkMutation.delete(table: 'bulk', key: 'k1'),
      ]);
      final rows = await _collection(db, 'bulk').getAll();
      final diag = db.diagnostics.snapshot();
      return <String, Object?>{
        'bulkCount': bulk.mutationCount,
        'bulkSeq': bulk.sequence,
        'rows': rows,
        'diagWrites': diag.totalWrites,
        'diagReads': diag.totalReads,
      };
    });
  });
}
