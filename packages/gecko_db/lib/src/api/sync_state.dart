/// Sync state contract (Phase 7/8 surface).
library;

/// The phase of a record's sync lifecycle.
enum SyncPhase { unknown, clean, pending, synchronizing, synced, failed }

/// Sync state attached to a record's change-tracking metadata.
class SyncState {
  const SyncState({
    this.phase = SyncPhase.clean,
    this.lastSyncAttempt,
    this.retryCount = 0,
    this.lastSyncError,
    this.idempotencyKey,
  });

  final SyncPhase phase;
  final DateTime? lastSyncAttempt;
  final int retryCount;
  final String? lastSyncError;
  final String? idempotencyKey;
}
