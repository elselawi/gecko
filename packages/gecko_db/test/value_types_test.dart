import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

/// Exercises the public value/contract types that Phase 0 locks in, raising
/// coverage of the API surface to satisfy the ≥95% gate.
void main() {
  group('Change', () {
    test('toString includes table, key, kind, and sequence', () {
      final c = Change(table: 't', key: 2, kind: ChangeKind.put, sequence: 7);
      final s = c.toString();
      expect(s, contains('t'));
      expect(s, contains('2'));
      expect(s, contains('put'));
      expect(s, contains('7'));
    });

    test('ChangeSet exposes length and isEmpty', () {
      final empty = ChangeSet(const []);
      expect(empty.length, 0);
      expect(empty.isEmpty, isTrue);

      final nonEmpty = ChangeSet([
        Change(table: 'a', key: 1, kind: ChangeKind.delete),
      ]);
      expect(nonEmpty.isEmpty, isFalse);
      expect(nonEmpty.length, 1);
    });
  });

  group('ChangeRecord & copyWith', () {
    test('constructs with full fields', () {
      final rec = ChangeRecord(
        localMutationId: 5,
        recordId: 'r1',
        timestamp: DateTime.fromMicrosecondsSinceEpoch(0),
        dirty: true,
        previousVersion: {'old': true},
        changedFields: ['name'],
        origin: ChangeOrigin.user,
        syncState: const SyncState(phase: SyncPhase.pending),
        lastSyncAttempt: null,
        retryCount: 2,
        lastSyncError: 'boom',
        idempotencyKey: 'idem-1',
      );
      expect(rec.localMutationId, 5);
      expect(rec.recordId, 'r1');
      expect(rec.dirty, isTrue);
      expect(rec.previousVersion, {'old': true});
      expect(rec.changedFields, ['name']);
      expect(rec.origin, ChangeOrigin.user);
      expect(rec.syncState!.phase, SyncPhase.pending);
      expect(rec.retryCount, 2);
      expect(rec.lastSyncError, 'boom');
      expect(rec.idempotencyKey, 'idem-1');
    });

    test('copyWith overrides only requested fields', () {
      final rec = ChangeRecord(
        localMutationId: 1,
        recordId: 'r',
        timestamp: DateTime.utc(2020),
      );
      final updated = rec.copyWith(
        dirty: false,
        retryCount: 3,
        lastSyncError: 'e',
      );
      expect(updated.localMutationId, 1, reason: 'untouched');
      expect(updated.recordId, 'r', reason: 'untouched');
      expect(updated.dirty, isFalse);
      expect(updated.retryCount, 3);
      expect(updated.lastSyncError, 'e');
      expect(updated.lastSyncAttempt, isNull);
    });

    test('copyWith can replace syncState and localMutationId', () {
      final rec = ChangeRecord(
        localMutationId: 1,
        recordId: 'r',
        timestamp: DateTime.utc(2020),
      );
      final st = const SyncState(phase: SyncPhase.synced);
      final updated = rec.copyWith(syncState: st, localMutationId: 9);
      expect(updated.syncState!.phase, SyncPhase.synced);
      expect(updated.localMutationId, 9);
    });
  });

  group('SyncState / SyncSnapshot / PendingChange / DatabaseConfig', () {
    test('SyncState defaults', () {
      const s = SyncState();
      expect(s.phase, SyncPhase.clean);
      expect(s.retryCount, 0);
      expect(s.lastSyncAttempt, isNull);
      expect(s.lastSyncError, isNull);
      expect(s.idempotencyKey, isNull);
    });

    test('SyncSnapshot carries lastSeq and optional watermark', () {
      const snap = SyncSnapshot(lastSeq: 42);
      expect(snap.lastSeq, 42);
      expect(snap.watermark, isNull);
      const withWm = SyncSnapshot(lastSeq: 42, watermark: 30);
      expect(withWm.watermark, 30);
    });

    test('PendingChange exposes recordId and change', () {
      final rec = ChangeRecord(
        localMutationId: 1,
        recordId: 'x',
        timestamp: DateTime.utc(2020),
        origin: ChangeOrigin.remoteSync,
      );
      final pending = PendingChange(recordId: 'x', change: rec);
      expect(pending.recordId, 'x');
      expect(pending.change.origin, ChangeOrigin.remoteSync);
    });

    test('DatabaseConfig defaults and overrides', () {
      const c = DatabaseConfig();
      expect(c.readOnly, isFalse);
      expect(c.encryptionKey, isNull);
      expect(c.nativeLibraryPath, isNull);
      expect(c.inFlightBatchLimit, isNull);

      const custom = DatabaseConfig(
        readOnly: true,
        encryptionKey: [1, 2, 3],
        nativeLibraryPath: '/x/lib.so',
        inFlightBatchLimit: 10,
      );
      expect(custom.readOnly, isTrue);
      expect(custom.encryptionKey, [1, 2, 3]);
      expect(custom.nativeLibraryPath, '/x/lib.so');
      expect(custom.inFlightBatchLimit, 10);
    });
  });

  group('ChangeOrigin & SyncPhase enums', () {
    test('all ChangeOrigin values are enumerable', () {
      expect(ChangeOrigin.values, [
        ChangeOrigin.user,
        ChangeOrigin.remoteSync,
        ChangeOrigin.migration,
        ChangeOrigin.backgroundProcess,
      ]);
    });

    test('all SyncPhase values are enumerable', () {
      expect(SyncPhase.values.length, 6);
      expect(
        SyncPhase.values,
        containsAll([
          SyncPhase.unknown,
          SyncPhase.clean,
          SyncPhase.pending,
          SyncPhase.synchronizing,
          SyncPhase.synced,
          SyncPhase.failed,
        ]),
      );
    });
  });
}
