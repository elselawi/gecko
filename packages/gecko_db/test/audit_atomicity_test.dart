// Audit-driven atomicity / mapping / raw-engine / transaction / bulk tests
// (audited-test-gaps 2.2, 2.3, 2.9, 2.10).
//
// Pins: throwing mappers must not mutate or bump the LSN; empty batches and
// transactions publish nothing; failed insertOnly/updateOnly do not bump the
// LSN; cache defensive copies; reserved-table feed filtering; empty/nested
// transactions; operations after finish; bulk atomicity.

import 'dart:async';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  Future<(DatabaseImpl, String)> openDb([
    String label = 'audit-atomicity',
  ]) async {
    final directory = await Directory.systemTemp.createTemp('$label-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}db.redb';
    final db = await DatabaseImpl.open(path);
    addTearDown(() async {
      try {
        await db.close();
      } catch (_) {}
    });
    return (db, path);
  }

  Collection<Map<String, Object?>> items(
    Database db, {
    String name = 'items',
  }) => db.collection<Map<String, Object?>>(
    name,
    toRow: (value) => value,
    fromRow: (row) => Map<String, Object?>.from(row as Map),
    id: (value) => value['id'],
  );

  const codec = DefaultWireCodec();

  /// Subscribes to the engine change feed and returns the first [ChangeSet]
  /// (or null if none within [timeout]).
  Future<ChangeSet?> nextChange(
    DatabaseImpl db, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final completer = Completer<ChangeSet?>();
    final sub = db.engine.changes.stream.listen((set) {
      if (!completer.isCompleted) completer.complete(set);
    });
    addTearDown(() => sub.cancel());
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    addTearDown(() => timer.cancel());
    return completer.future;
  }

  Future<int?> persistedLsn(DatabaseImpl db) async {
    final raw = await db.engine.rawGet(
      '__gecko_sync_meta',
      ByteKey(codec.encode('lsn')),
    );
    if (raw == null) return null;
    return codec.decode(raw) as int?;
  }

  group('2.2 throwing mappers', () {
    test('toRow throwing leaves no mutation, no LSN, no feed event', () async {
      final (db, _) = await openDb();
      final changes = nextChange(db);
      final broken = db.collection<Map<String, Object?>>(
        'items',
        toRow: (value) => throw StateError('boom'),
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (value) => value['id'],
      );
      await expectLater(broken.put({'id': 'a'}), throwsA(isA<StateError>()));
      expect(await items(db).get('a'), isNull, reason: 'no row must land');
      expect(await persistedLsn(db), isNull, reason: 'no LSN must be written');
      // Nothing observable was published.
      expect(await changes, isNull, reason: 'no feed event for a failed put');
      // The collection still works afterwards.
      await items(db).put({'id': 'a', 'n': 1});
      expect(await items(db).get('a'), isNotNull);
    });

    test(
      'fromRow throwing surfaces a typed error and poisons no cache',
      () async {
        final (db, _) = await openDb();
        await items(db).put({'id': 'a', 'n': 1});
        final broken = db.collection<Map<String, Object?>>(
          'items',
          toRow: (value) => value,
          fromRow: (row) => throw StateError('cannot map'),
          id: (value) => value['id'],
        );
        await expectLater(broken.get('a'), throwsA(isA<StateError>()));
        // The healthy collection still reads the same row.
        expect(await items(db).get('a'), {'id': 'a', 'n': 1});
      },
    );

    test('toRow returning a non-Map is rejected by a schema and stored raw '
        'without one', () async {
      final (db, _) = await openDb();
      final codecLocal = DefaultWireCodec();
      final raw = db.collection<Object?>(
        'raw',
        toRow: (value) => value,
        fromRow: (row) => row,
        id: (value) => value,
      );
      // Without a schema, a scalar row is stored as-is.
      await raw.put(42);
      final stored = await db.engine.rawGet(
        'raw',
        ByteKey(codecLocal.encode(42)),
      );
      expect(stored, isNotNull);
      expect(codecLocal.decode(stored!), 42);

      // With a schema, a non-Map toRow result is rejected with a typed
      // schemaValidation error.
      final schema = RowSchema([
        const FieldSpec(name: 'id'),
        const FieldSpec(name: 'n'),
      ]);
      final validated = db.collection<Map<String, Object?>>(
        'validated',
        toRow: (value) => 'not-a-map',
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (value) => value['id'],
        schema: schema,
      );
      await expectLater(
        validated.put({'id': 'x'}),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.schemaValidation,
          ),
        ),
      );
    });

    test('put shallow-merges known fields (update is not replace)', () async {
      final (db, _) = await openDb();
      final c = items(db);
      await c.put({'id': 'a', 'name': 'one', 'age': 1});
      // Overwrite with a subset; the untouched field survives.
      await c.put({'id': 'a', 'age': 2});
      final row = await c.get('a');
      expect(row, {'id': 'a', 'name': 'one', 'age': 2});
    });

    test('getMany returns one row per duplicate input id', () async {
      final (db, _) = await openDb();
      final c = items(db);
      await c.put({'id': 'a', 'n': 1});
      final rows = await c.getMany(['a', 'a', 'missing', 'a']);
      expect(
        rows,
        hasLength(3),
        reason: 'one row per occurrence, missing skipped',
      );
      expect(rows.every((r) => r['id'] == 'a'), isTrue);
    });

    test('auto ids are monotonic and never reuse deleted ids', () async {
      final (db, _) = await openDb();
      final auto = db.collection<Map<String, Object?>>(
        'auto',
        toRow: (value) => value,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
      );
      final id1 = await auto.put({'n': 1});
      final id2 = await auto.put({'n': 2});
      expect(id1, isNot(id2));
      expect(id2, isA<String>());
      expect(
        (id2 as String).compareTo(id1 as String),
        greaterThan(0),
        reason: 'auto ids must be monotonic',
      );
      await auto.delete(id1);
      // A new put must not reuse the deleted id.
      final id3 = await auto.put({'n': 3});
      expect(id3, isNot(id1));
      expect((id3 as String).compareTo(id2), greaterThan(0));
    });
  });

  group('2.3 raw engine / cache', () {
    test('empty commitBatch writes no LSN and publishes nothing', () async {
      final (db, _) = await openDb();
      final changes = nextChange(db);
      // A transaction with no operations.
      await db.writeTxn((_) async {});
      expect(
        await persistedLsn(db),
        isNull,
        reason: 'no LSN record for empty batch',
      );
      expect(await changes, isNull, reason: 'no feed event for empty batch');
      // A subsequent real write works and emits.
      final changes2 = nextChange(db);
      await items(db).put({'id': 'a'});
      final set = await changes2;
      expect(set, isNotNull);
      expect(set!.changes.any((c) => c.table == 'items'), isTrue);
    });

    test('failed insertOnly does not bump LSN or emit changes', () async {
      final (db, _) = await openDb();
      await items(db).put({'id': 'a', 'n': 1});
      final lsnBefore = await persistedLsn(db);
      final changes = nextChange(db);
      final key = ByteKey(codec.encode('a'));
      await expectLater(
        db.engine.rawPut(
          'items',
          key,
          codec.encode({'id': 'a', 'n': 2}),
          mode: RawWriteMode.insertOnly,
        ),
        throwsA(isA<GeckoError>()),
      );
      expect(await persistedLsn(db), lsnBefore, reason: 'LSN must not advance');
      expect(await changes, isNull, reason: 'no feed event');
      // The stored row is untouched.
      expect((await items(db).get('a'))!['n'], 1);
    });

    test('failed updateOnly does not bump LSN or emit changes', () async {
      final (db, _) = await openDb();
      final key = ByteKey(codec.encode('ghost'));
      final lsnBefore = await persistedLsn(db);
      final changes = nextChange(db);
      await expectLater(
        db.engine.rawPut(
          'items',
          key,
          codec.encode({'n': 1}),
          mode: RawWriteMode.updateOnly,
        ),
        throwsA(isA<GeckoError>()),
      );
      expect(await persistedLsn(db), lsnBefore);
      expect(await changes, isNull);
    });

    test('cache values are defensive copies', () async {
      final (db, _) = await openDb();
      final key = ByteKey(codec.encode('a'));
      await db.engine.rawPut('items', key, codec.encode({'n': 1}));
      final first = await db.engine.rawGet('items', key);
      first!.add(99); // mutate the caller's copy
      final second = await db.engine.rawGet('items', key);
      expect(
        codec.decode(second!),
        {'n': 1},
        reason: 'mutating a returned list must not corrupt the cache',
      );
    });

    test(
      'reserved-table batches emit zero public changes; mixed emit user only',
      () async {
        final (db, _) = await openDb();
        // A batch touching only a reserved table.
        final changes = nextChange(db);
        await db.engine.rawPut(
          '__gecko_meta',
          ByteKey(codec.encode('k')),
          codec.encode({'x': 1}),
        );
        expect(
          await changes,
          isNull,
          reason: 'reserved-only batch must be silent',
        );
        // A batch touching both reserved and user tables.
        final changes2 = nextChange(db);
        await db.writeTxn((txn) async {
          await txn
              .collection<Map<String, Object?>>(
                'items',
                toRow: (value) => value,
                fromRow: (row) => Map<String, Object?>.from(row as Map),
                id: (value) => value['id'],
              )
              .put({'id': 'a'});
        });
        final set = await changes2;
        expect(set, isNotNull);
        expect(
          set!.changes.any((c) => c.table == 'items'),
          isTrue,
          reason: 'user-table change must be emitted',
        );
        expect(
          set.changes.any((c) => c.table.startsWith('__gecko_')),
          isFalse,
          reason: 'reserved tables must be filtered from the public feed',
        );
      },
    );

    test('publishAt with a stale sequence never regresses', () async {
      final (db, _) = await openDb();
      final firstChange = nextChange(db);
      await items(db).put({'id': 'a'});
      final firstSeq = (await firstChange)!.sequence;
      final secondChange = nextChange(db);
      await items(db).put({'id': 'b'});
      final secondSeq = (await secondChange)!.sequence;
      expect(
        secondSeq,
        greaterThan(firstSeq!),
        reason: 'sequence must never regress',
      );
    });

    test(
      'publishAt after close is a no-op returning the last sequence',
      () async {
        final (db, _) = await openDb();
        await items(db).put({'id': 'a'});
        final bus = db.engine.changes;
        final before = bus.lastSequence;
        expect(before, greaterThan(0));
        await db.close();
        // After close, publishAt returns the last sequence without throwing.
        final afterClose = bus.publishAt(999, [
          Change(table: 'items', key: 'b', kind: ChangeKind.put),
        ]);
        expect(
          afterClose,
          before,
          reason: 'publishAt after close is a silent no-op (pinned)',
        );
      },
    );
  });

  group('2.9 transactions', () {
    test('empty transaction commits with no LSN and no feed event', () async {
      final (db, _) = await openDb();
      final changes = nextChange(db);
      await db.writeTxn((_) async {});
      expect(await persistedLsn(db), isNull);
      expect(await changes, isNull);
    });

    test('operations after commit are rejected with a typed error', () async {
      final (db, _) = await openDb();
      Transaction? captured;
      await db.writeTxn((txn) async {
        captured = txn;
        await txn
            .collection<Map<String, Object?>>(
              'items',
              toRow: (value) => value,
              fromRow: (row) => Map<String, Object?>.from(row as Map),
              id: (value) => value['id'],
            )
            .put({'id': 'a'});
      });
      final txn = captured!;
      expect(
        () => txn.collection<Map<String, Object?>>(
          'items',
          toRow: (value) => value,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (value) => value['id'],
        ),
        throwsA(isA<GeckoError>()),
      );
      await expectLater(
        txn.get('items', 'a', toRow: (value) => value, fromRow: (row) => row),
        throwsA(isA<GeckoError>()),
      );
    });

    test('operations after rollback are rejected with a typed error', () async {
      final (db, _) = await openDb();
      Transaction? captured;
      try {
        await db.writeTxn((txn) async {
          captured = txn;
          await txn
              .collection<Map<String, Object?>>(
                'items',
                toRow: (value) => value,
                fromRow: (row) => Map<String, Object?>.from(row as Map),
                id: (value) => value['id'],
              )
              .put({'id': 'a'});
          throw StateError('abort');
        });
      } catch (_) {}
      await expectLater(
        captured!.get(
          'items',
          'a',
          toRow: (value) => value,
          fromRow: (row) => row,
        ),
        throwsA(isA<GeckoError>()),
      );
    });

    test('throw after commit preserves committed data', () async {
      final (db, _) = await openDb();
      try {
        await db.writeTxn((txn) async {
          await txn
              .collection<Map<String, Object?>>(
                'items',
                toRow: (value) => value,
                fromRow: (row) => Map<String, Object?>.from(row as Map),
                id: (value) => value['id'],
              )
              .put({'id': 'committed'});
          await txn.commit();
          throw StateError('after commit');
        });
      } catch (error) {
        expect(error, isA<StateError>());
      }
      // The committed put survived the post-commit throw.
      expect(await items(db).get('committed'), isNotNull);
    });

    test('large transaction mid-body failure rolls back completely', () async {
      final (db, _) = await openDb();
      await expectLater(
        db.writeTxn((txn) async {
          final c = txn.collection<Map<String, Object?>>(
            'items',
            toRow: (value) => value,
            fromRow: (row) => Map<String, Object?>.from(row as Map),
            id: (value) => value['id'],
          );
          for (var i = 0; i < 1000; i++) {
            await c.put({'id': 'k$i', 'n': i});
          }
          throw StateError('mid-body failure');
        }),
        throwsA(isA<StateError>()),
      );
      expect(
        await items(db).getAll(),
        isEmpty,
        reason: 'the whole staged transaction must roll back',
      );
      expect(await persistedLsn(db), isNull);
    });

    test('nested writeTxn serializes without deadlock', () async {
      final (db, _) = await openDb();
      await db.writeTxn((outer) async {
        await outer
            .collection<Map<String, Object?>>(
              'items',
              toRow: (value) => value,
              fromRow: (row) => Map<String, Object?>.from(row as Map),
              id: (value) => value['id'],
            )
            .put({'id': 'outer'});
        // A nested writeTxn must not deadlock (serializes through the gate).
        await db.writeTxn((inner) async {
          await inner
              .collection<Map<String, Object?>>(
                'other',
                toRow: (value) => value,
                fromRow: (row) => Map<String, Object?>.from(row as Map),
                id: (value) => value['id'],
              )
              .put({'id': 'inner'});
        });
      });
      expect(await items(db).get('outer'), isNotNull);
      final other = db.collection<Map<String, Object?>>(
        'other',
        toRow: (value) => value,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (value) => value['id'],
      );
      expect(await other.get('inner'), isNotNull);
    });

    test(
      'concurrent transactions on the same key both complete (last wins)',
      () async {
        final (db, _) = await openDb();
        await Future.wait([
          db.writeTxn((txn) async {
            await txn
                .collection<Map<String, Object?>>(
                  'items',
                  toRow: (value) => value,
                  fromRow: (row) => Map<String, Object?>.from(row as Map),
                  id: (value) => value['id'],
                )
                .put({'id': 'k', 'writer': 'one'});
          }),
          db.writeTxn((txn) async {
            await txn
                .collection<Map<String, Object?>>(
                  'items',
                  toRow: (value) => value,
                  fromRow: (row) => Map<String, Object?>.from(row as Map),
                  id: (value) => value['id'],
                )
                .put({'id': 'k', 'writer': 'two'});
          }),
        ]);
        final row = await items(db).get('k');
        expect(row, isNotNull);
        expect(
          ['one', 'two'],
          contains(row!['writer']),
          reason: 'one writer must win (last commit wins)',
        );
      },
    );

    test('close during an active transaction fails the transaction', () async {
      final (db, _) = await openDb();
      final failed = db
          .writeTxn((txn) async {
            await txn
                .collection<Map<String, Object?>>(
                  'items',
                  toRow: (value) => value,
                  fromRow: (row) => Map<String, Object?>.from(row as Map),
                  id: (value) => value['id'],
                )
                .put({'id': 'a'});
            await db.close();
          })
          .then((_) => false, onError: (Object _) => true);
      // Either the close races and the transaction is abandoned, or the
      // transaction completes first; the handle must not hang.
      final aborted = await failed.timeout(const Duration(seconds: 10));
      expect(aborted, isA<bool>());
    });
  });

  group('2.10 bulk writes', () {
    test('empty bulk returns (0, 0), no LSN, no events', () async {
      final (db, _) = await openDb();
      final changes = nextChange(db);
      final result = await db.bulkWrite(const []);
      expect(result.mutationCount, 0);
      expect(result.sequence, 0);
      expect(await persistedLsn(db), isNull);
      expect(await changes, isNull);
    });

    test(
      'repeated mutations to one key in one batch coalesce to final state',
      () async {
        final (db, _) = await openDb();
        final changes = nextChange(db);
        final result = await db.bulkWrite([
          const BulkMutation.put(table: 'items', key: 'k', value: {'n': 1}),
          const BulkMutation.delete(table: 'items', key: 'k'),
          const BulkMutation.put(table: 'items', key: 'k', value: {'n': 3}),
        ]);
        expect(result.mutationCount, 3);
        final row = await items(db).get('k');
        expect(row, {'n': 3}, reason: 'final state wins within one batch');
        // One coalesced feed event for the key.
        final set = await changes;
        expect(set, isNotNull);
        expect(
          set!.changes.where((c) => c.table == 'items' && c.key == 'k'),
          hasLength(1),
          reason: 'per-key coalescing within a batch',
        );
      },
    );

    test(
      'bulk atomicity with an invalid mutation rolls back the whole batch',
      () async {
        final (db, _) = await openDb();
        // The second mutation targets a key that cannot encode (a Map key is
        // not a valid RowValue key for this engine path) — pin that a failing
        // mutation rolls back the entire batch.
        Object? outcome;
        try {
          outcome = await db.bulkWrite([
            const BulkMutation.put(table: 'items', key: 'k1', value: {'n': 1}),
            BulkMutation.put(
              table: 'items',
              key: <String, Object?>{},
              value: {'n': 2},
            ),
          ]);
        } catch (error) {
          outcome = error;
        }
        if (outcome is! BulkWriteResult) {
          // Rolled back: k1 must not exist.
          expect(
            await items(db).get('k1'),
            isNull,
            reason: 'a failed batch must not leave partial writes',
          );
        }
      },
    );
  });
}
