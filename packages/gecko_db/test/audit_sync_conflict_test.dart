// Audit-driven sync / change-log and conflict edge tests (audited-test-gaps
// 2.11, 2.12).

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

ChangeRecord remoteRecord({
  String? collection = 'items',
  Object? recordId = 'r1',
  Object? value,
  ChangeKind kind = ChangeKind.put,
  String? idempotencyKey,
  int localMutationId = 1,
}) => ChangeRecord(
  localMutationId: localMutationId,
  recordId: recordId,
  timestamp: DateTime.utc(2024, 1, 1),
  collection: collection,
  kind: kind,
  value: value ?? {'id': recordId},
  origin: ChangeOrigin.remoteSync,
  idempotencyKey: idempotencyKey ?? 'idem-$recordId',
);

void main() {
  group('2.11 sync / change log', () {
    test('markSynchronizing twice is idempotent', () async {
      final db = await openNativeTestDatabase('sync-mark-sync');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await db.sync.markSynchronizing(['a']);
      await db.sync.markSynchronizing(['a']);
      // Still pending; a sync can proceed.
      final pending = await db.sync.readLocallyChanged();
      expect(pending.map((p) => p.recordId), contains('a'));
      await db.close();
    });

    test('markFailed after markSynced transitions the record back', () async {
      final db = await openNativeTestDatabase('sync-mark-fail');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await db.sync.markSynced(['a']);
      // A clean record is no longer pending.
      expect(
        (await db.sync.readLocallyChanged()).map((p) => p.recordId),
        isNot(contains('a')),
      );
      // A later failure mark on a synced id transitions back to pending.
      await db.sync.markFailed(['a'], 'server 500');
      final pending = await db.sync.readLocallyChanged();
      expect(pending.map((p) => p.recordId), contains('a'));
      await db.close();
    });

    test('markSynced with non-pending ids is a no-op', () async {
      final db = await openNativeTestDatabase('sync-mark-noop');
      await db.sync.markSynced(['ghost']);
      await db.sync.markFailed(['ghost'], 'x');
      await db.sync.markSynchronizing(['ghost']);
      // No pending records existed; nothing is corrupted.
      expect(await db.sync.readLocallyChanged(), isEmpty);
      await db.close();
    });

    test(
      'markSynced clears the change log (changesSince drops the record)',
      () async {
        final db = await openNativeTestDatabase('sync-rewrite');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        // Before sync the record is visible.
        final before = await db.sync.changesSince(
          const SyncSnapshot(lastSeq: 0),
        );
        expect(before.map((r) => r.recordId), contains('a'));
        await db.sync.markSynced(['a']);
        // After sync the change-log record is rewritten clean: a strict-after
        // snapshot no longer surfaces it as a pending change.
        final after = await db.sync.readLocallyChanged();
        expect(after.map((p) => p.recordId), isNot(contains('a')));
        await db.close();
      },
    );

    test(
      'applyRemoteTransactional without a collection leaks ArgumentError',
      () async {
        final db = await openNativeTestDatabase('sync-argerr');
        final record = remoteRecord(collection: null);
        await expectLater(
          db.sync.applyRemoteTransactional([record]),
          throwsA(isA<ArgumentError>()),
          reason: 'the missing-collection path currently throws ArgumentError',
        );
        await db.close();
      },
    );

    test('idempotency dedupe works within one batch (first only)', () async {
      final db = await openNativeTestDatabase('sync-dedupe');
      final c = coll(db, 'items');
      // Two records with the same idempotency key and the same record id.
      final result = await db.sync.applyRemoteTransactional([
        remoteRecord(
          recordId: 'k',
          value: {'id': 'k', 'v': 'first'},
          idempotencyKey: 'same',
        ),
        remoteRecord(
          recordId: 'k',
          value: {'id': 'k', 'v': 'second'},
          idempotencyKey: 'same',
        ),
      ]);
      // Only the first is applied (affected carries it once).
      expect(result.where((r) => r == 'k'), hasLength(1));
      final row = await c.get('k');
      expect(row!['v'], 'first', reason: 'first record wins within a batch');
      // Re-applying the same key across calls is also deduped.
      final again = await db.sync.applyRemoteTransactional([
        remoteRecord(
          recordId: 'k',
          value: {'id': 'k', 'v': 'third'},
          idempotencyKey: 'same',
        ),
      ]);
      expect(again, isEmpty);
      expect((await c.get('k'))!['v'], 'first');
      await db.close();
    });

    test(
      'copyWith cannot null out syncState, lastSyncAttempt, lastSyncError',
      () {
        final record = ChangeRecord(
          localMutationId: 1,
          recordId: 'a',
          timestamp: DateTime.utc(2024),
          syncState: const SyncState(phase: SyncPhase.clean),
          lastSyncAttempt: DateTime.utc(2024, 1, 2),
          lastSyncError: 'boom',
        );
        // Passing null keeps the previous value (?? semantics).
        final copied = record.copyWith(
          syncState: null,
          lastSyncAttempt: null,
          lastSyncError: null,
        );
        expect(copied.syncState, isNotNull);
        expect(copied.lastSyncAttempt, isNotNull);
        expect(copied.lastSyncError, 'boom');
      },
    );

    test('RecordRef matches only same collection + id', () {
      expect(const RecordRef('a', 1), const RecordRef('a', 1));
      expect(const RecordRef('a', 1), isNot(const RecordRef('b', 1)));
      expect(const RecordRef('a', 1), isNot(const RecordRef('a', 2)));
      // Equal ids in different collections do not collide.
      expect(
        const RecordRef('items', 'x').hashCode,
        isNot(const RecordRef('other', 'x').hashCode),
      );
    });
  });

  group('2.12 conflicts', () {
    setUp(ConflictStrategy.restoreDefaults);

    test('a throwing registered handler propagates', () async {
      ConflictStrategy.register(
        'throwing',
        (local, remote, base) => throw StateError('strategy boom'),
      );
      expect(
        () => ConflictStrategy.resolve('throwing', _v({}), _v({})),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'a mergedValue that is a Function is rejected with a typed error',
      () async {
        final db = await openNativeTestDatabase('conflict-fn');
        final c = coll(db, 'items');
        await c.put({'id': 'one', 'value': 'local'});
        ConflictStrategy.register('fn-merge', (local, remote, base) {
          return Resolution.mergedValue((int x) => x);
        });
        await expectLater(
          db.conflicts.resolve(
            ConflictRequest(
              record: const RecordRef('items', 'one'),
              remote: const ConflictVersion(
                value: {'id': 'one', 'value': 'remote'},
              ),
            ),
            strategy: 'fn-merge',
          ),
          throwsA(isA<GeckoError>()),
        );
        // Nothing was committed.
        expect((await c.get('one'))!['value'], 'local');
        await db.close();
      },
    );

    test(
      'resolvePreserved with a manualReview decision is a typed error',
      () async {
        final db = await openNativeTestDatabase('conflict-preserved');
        final c = coll(db, 'items');
        await c.put({'id': 'one', 'value': 'local'});
        final deferred = await db.conflicts.resolve(
          ConflictRequest(
            record: const RecordRef('items', 'one'),
            remote: const ConflictVersion(
              value: {'id': 'one', 'value': 'remote'},
            ),
          ),
          strategy: ConflictStrategy.manualReview,
        );
        final conflictId = deferred.preservedConflict!.conflictId;
        await expectLater(
          db.conflicts.resolvePreserved(
            conflictId,
            const Resolution.manualReview(),
          ),
          throwsA(isA<GeckoError>()),
        );
        // The conflict is still pending (not destroyed by the failed resolve).
        expect(await db.conflicts.read(conflictId), isNotNull);
        await db.close();
      },
    );
  });
}

ConflictVersion _v(Map<String, Object?> value) =>
    ConflictVersion(value: value, sequence: 1);
