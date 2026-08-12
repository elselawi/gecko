import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/backend/raw_backend.dart'
    show RawBatchPlan, RawChangeTemplate;
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  const codec = DefaultWireCodec();

  Future<List<ChangeRecord>> changesSince(DatabaseImpl db, int sequence) async {
    return db.sync.changesSince(SyncSnapshot(lastSeq: sequence));
  }

  Collection<Map<String, Object?>> items(DatabaseImpl db) =>
      db.collection<Map<String, Object?>>(
        'items',
        toRow: (row) => row,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (row) => row['id'],
      );

  test(
    'bulkWrite keeps immediate previous versions for repeated keys',
    () async {
      final db = await openNativeTestDatabase('priority2-repeated-previous');
      addTearDown(db.close);
      final collection = items(db);
      await collection.put({'id': 'k', 'value': 0});
      final before = await db.engine.backend.lastCommitSeq();

      final result = await db.bulkWrite([
        const BulkMutation.put(
          table: 'items',
          key: 'k',
          value: {'id': 'k', 'value': 1},
        ),
        const BulkMutation.delete(table: 'items', key: 'k'),
        const BulkMutation.put(
          table: 'items',
          key: 'k',
          value: {'id': 'k', 'value': 3},
        ),
      ]);

      expect(result.sequence, before + 1);
      final records = await changesSince(db, before);
      expect(records, hasLength(3));
      expect(records.map((record) => record.localMutationId).toSet(), <int>{
        result.sequence,
      });
      expect(records[0].previousVersion, {'id': 'k', 'value': 0});
      expect(records[1].previousVersion, {'id': 'k', 'value': 1});
      expect(records[2].previousVersion, isNull);
      expect(await collection.get('k'), {'id': 'k', 'value': 3});
    },
  );

  test('bulkWrite uses one native batch and no snapshot creation', () async {
    final db = await openNativeTestDatabase('priority2-bulk-counters');
    addTearDown(db.close);
    final backend = db.engine.backend as NativeRawBackend;
    await backend.enableCounters();
    final mutations = [
      for (var i = 0; i < 100; i++)
        BulkMutation.put(
          table: 'items',
          key: 'k$i',
          value: {'id': 'k$i', 'n': i},
        ),
    ];
    final result = await db.bulkWrite(mutations);
    final counters = await backend.takeCounters();
    expect(result.mutationCount, 100);
    expect(counters.batchesApplied, BigInt.one);
    expect(counters.snapshotsCreated, BigInt.zero);
  });

  test(
    'bulk path requests no previous values from the worker but still fills them in the log',
    () async {
      final db = await openNativeTestDatabase('priority2-bulk-no-prev');
      addTearDown(db.close);
      final collection = items(db);
      await collection.put({'id': 'k', 'value': 0});
      final before = await db.engine.backend.lastCommitSeq();

      // Mirror exactly what DatabaseImpl.bulkWrite sends today: no
      // previousOperationIndexes, change templates with fillPreviousVersion.
      final result = await db.engine.applyPreparedPlan(
        RawBatchPlan(
          ops: [
            RawPut(
              'items',
              ByteKey(codec.encode('k')),
              codec.encode({'id': 'k', 'value': 1}),
            ),
          ],
          changeTemplates: [
            RawChangeTemplate(
              operationIndex: 0,
              ordinal: 0,
              syncStateKey: ByteKey(codec.encode('items:k')),
              recordTemplate: codec.encode({
                'localMutationId': 0,
                'recordId': 'k',
                'timestamp': DateTime.fromMillisecondsSinceEpoch(1),
                'collection': 'items',
                'kind': 'put',
                'value': {'id': 'k', 'value': 1},
                'previousVersion': null,
                'origin': 'user',
                'dirty': true,
                'syncPhase': 'pending',
              }),
              fillPreviousVersion: true,
            ),
          ],
        ),
      );
      expect(result.previousValues, isEmpty,
          reason: 'the bulk path must not carry old row bytes back');
      // The change log still records the prior value via the template.
      final records = await changesSince(db, before);
      expect(records, hasLength(1));
      expect(records.single.previousVersion, {'id': 'k', 'value': 0});
    },
  );

  test(
    'raw writes validate modes atomically and preserve error categories',
    () async {
      final db = await openNativeTestDatabase('priority2-raw-modes');
      addTearDown(db.close);
      final engine = db.engine;
      final key = ByteKey(codec.encode('k'));
      await engine.rawPut('items', key, codec.encode({'n': 1}));
      final sequence = await engine.backend.lastCommitSeq();

      await expectLater(
        engine.rawPut(
          'items',
          key,
          codec.encode({'n': 2}),
          mode: RawWriteMode.insertOnly,
        ),
        throwsA(
          isA<GeckoError>().having(
            (error) => error.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
      expect(await engine.backend.lastCommitSeq(), sequence);
      expect(codec.decode((await engine.rawGet('items', key))!), {'n': 1});

      final missing = ByteKey(codec.encode('missing'));
      await expectLater(
        engine.rawPut(
          'items',
          missing,
          codec.encode({'n': 2}),
          mode: RawWriteMode.updateOnly,
        ),
        throwsA(
          isA<GeckoError>().having(
            (error) => error.type,
            'type',
            GeckoErrorType.keyNotFound,
          ),
        ),
      );
      expect(await engine.backend.lastCommitSeq(), sequence);
    },
  );

  test('sequence continues after close and reopen', () async {
    final root = await Directory.systemTemp.createTemp('priority2-reopen-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}${Platform.pathSeparator}db.redb';
    final first = await DatabaseImpl.open(path);
    final firstResult = await first.bulkWrite([
      const BulkMutation.put(table: 'items', key: 'a', value: {'n': 1}),
    ]);
    await first.close();

    final second = await DatabaseImpl.open(path);
    addTearDown(second.close);
    final secondResult = await second.bulkWrite([
      const BulkMutation.put(table: 'items', key: 'b', value: {'n': 2}),
    ]);
    expect(secondResult.sequence, firstResult.sequence + 1);
  });
}
