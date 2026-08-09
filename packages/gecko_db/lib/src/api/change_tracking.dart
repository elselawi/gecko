/// Change-tracking / sync-hook contract (Phase 7).
///
/// The sync **transport**, identity, and conflict policies are out of scope.
/// In scope here is the local, transactional change-tracking metadata a sync
/// engine *would* consume, and local conflict resolution against it (Phase 8).
library;

import 'change.dart';
import 'sync_state.dart';

/// The origin of a change. Origin tagging prevents sync loops.
enum ChangeOrigin { user, remoteSync, migration, backgroundProcess }

/// A single change-tracking record, as specified by Phase 7.
class ChangeRecord {
  const ChangeRecord({
    required this.localMutationId,
    required this.recordId,
    required this.timestamp,
    this.collection,
    this.kind,
    this.value,
    this.remoteVersion,
    this.dirty = true,
    this.previousVersion,
    this.changedFields,
    this.origin = ChangeOrigin.user,
    this.syncState,
    this.lastSyncAttempt,
    this.retryCount = 0,
    this.lastSyncError,
    this.idempotencyKey,
  });

  /// The local mutation id (LSN) this change was committed under.
  final int localMutationId;

  /// The id of the affected record.
  final Object? recordId;

  /// Optional routing/payload fields used by the sync adapter. They are
  /// additive to the original metadata contract and may be absent on a
  /// metadata-only record.
  final String? collection;
  final ChangeKind? kind;
  final Object? value;
  final Object? remoteVersion;

  /// Wall-clock timestamp (advisory; ordering is LSN, never wall-clock).
  final DateTime timestamp;

  /// Whether this change is pending local sync.
  final bool dirty;

  /// Previous version of the record, when available.
  final Object? previousVersion;

  /// Changed fields, when available.
  final List<String>? changedFields;

  /// Change origin.
  final ChangeOrigin origin;

  final SyncState? syncState;
  final DateTime? lastSyncAttempt;
  final int retryCount;
  final String? lastSyncError;
  final String? idempotencyKey;

  ChangeRecord copyWith({
    bool? dirty,
    SyncState? syncState,
    DateTime? lastSyncAttempt,
    int? retryCount,
    String? lastSyncError,
    int? localMutationId,
  }) {
    return ChangeRecord(
      localMutationId: localMutationId ?? this.localMutationId,
      recordId: recordId,
      timestamp: timestamp,
      collection: collection,
      kind: kind,
      value: value,
      remoteVersion: remoteVersion,
      dirty: dirty ?? this.dirty,
      previousVersion: previousVersion,
      changedFields: changedFields,
      origin: origin,
      syncState: syncState ?? this.syncState,
      lastSyncAttempt: lastSyncAttempt ?? this.lastSyncAttempt,
      retryCount: retryCount ?? this.retryCount,
      lastSyncError: lastSyncError ?? this.lastSyncError,
      idempotencyKey: idempotencyKey,
    );
  }
}

/// A lightweight snapshot for `changesSince` / sync reconciliation.
class SyncSnapshot {
  const SyncSnapshot({required this.lastSeq, this.watermark});
  final int lastSeq;

  /// Compaction-pruned watermark, when present (gap-tolerant changesSince).
  final int? watermark;
}

/// A stable collection/id pair used by additive sync helpers.
class RecordRef {
  const RecordRef(this.collection, this.id);

  final String collection;
  final Object? id;

  @override
  bool operator ==(Object other) =>
      other is RecordRef && other.collection == collection && other.id == id;

  @override
  int get hashCode => Object.hash(collection, id);

  @override
  String toString() => 'RecordRef($collection, $id)';
}

/// A pending locally-changed record exposed to a sync engine.
class PendingChange {
  const PendingChange({required this.recordId, required this.change});
  final Object? recordId;
  final ChangeRecord change;
}

/// The small sync-facing interface a sync engine consumes (Phase 7).
///
/// Implemented by the engine against the same `redb` file — no second
/// persistence system.
abstract class SyncHookApi {
  /// Records with a pending, unsynced local change.
  Future<List<PendingChange>> readLocallyChanged();

  /// Marks [ids] as currently synchronizing.
  Future<void> markSynchronizing(List<Object?> ids);

  /// Marks [ids] as successfully synced, clearing their pending flag.
  Future<void> markSynced(List<Object?> ids);

  /// Marks [ids] as failed, preserving pending state and incrementing retry.
  Future<void> markFailed(List<Object?> ids, String error);

  /// Applies remote changes transactionally; returns affected record ids.
  Future<List<Object?>> applyRemoteTransactional(List<ChangeRecord> records);

  /// Applies remote deletions.
  Future<void> applyRemoteDeletion(List<Object?> ids);

  /// Reads the stored remote version counter.
  Future<Object?> readRemoteVersion();

  /// Stores the remote version counter.
  Future<void> storeRemoteVersion(Object? version);

  /// Changes strictly after [snapshot], gap-tolerant.
  Future<List<ChangeRecord>> changesSince(SyncSnapshot snapshot);

  /// True if [idempotencyKey] has already been applied (dedupe).
  Future<bool> isDuplicate(String idempotencyKey);
}
