/// opt-in diagnostics contracts.
library;

import '../worker/native_worker_client.dart' show WorkerContention;
export '../worker/native_worker_client.dart' show WorkerContention;

/// A point-in-time diagnostics snapshot. Counters are zero-cost when
/// diagnostics are disabled because the engine only updates them when enabled.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.enabled,
    required this.totalReads,
    required this.totalScannedRows,
    required this.totalWrites,
    required this.totalWriteDurationMicros,
    required this.totalQueryDurationMicros,
    required this.failedWrites,
    required this.activeSubscribers,
    required this.pendingMutations,
    required this.cacheEntries,
    required this.cacheWeight,
    required this.inFlightWrites,
    required this.inFlightLimit,
    required this.compacting,
    this.slowQueryCount = 0,
    this.lockContentionCount = 0,
    this.compactionCount = 0,
    this.lastCompactionDurationMicros = 0,
    this.lastCompactionBytesReclaimed = 0,
    this.maintenanceState = 'idle',
    this.workerContention = const WorkerContention(
      requestCount: 0,
      queueDepthHighWater: 0,
      avgServiceMicros: 0,
      maxServiceMicros: 0,
    ),
  });

  final bool enabled;
  final int totalReads;
  final int totalScannedRows;
  final int totalWrites;
  final int totalWriteDurationMicros;
  final int totalQueryDurationMicros;
  final int failedWrites;
  final int activeSubscribers;
  final int pendingMutations;
  final int cacheEntries;
  final int cacheWeight;
  final int inFlightWrites;
  final int inFlightLimit;
  final bool compacting;

  /// Slow queries recorded since open 
  final int slowQueryCount;

  /// Write-batch waits on the in-flight gate (lock contention).
  final int lockContentionCount;

  /// Compactions completed since open.
  final int compactionCount;

  /// Duration (µs) of the most recent compaction.
  final int lastCompactionDurationMicros;

  /// Bytes reclaimed by the most recent compaction.
  final int lastCompactionBytesReclaimed;

  /// Current maintenance state name (`idle|compacting|committed|failed|recovering`).
  final String maintenanceState;

  /// Serial worker queue depth high-water + service latency (native isolate
  /// worker). Zero when the backend runs in the caller isolate (web).
  final WorkerContention workerContention;

  @override
  String toString() =>
      'DiagnosticsSnapshot(reads=$totalReads, writes=$totalWrites, '
      'scanned=$totalScannedRows, failed=$failedWrites, '
      'maintenance=$maintenanceState, slowQueries=$slowQueryCount)';
}

/// Opt-in diagnostics controller.
abstract class DiagnosticsApi {
  bool get enabled;

  /// Enables counters/timing instrumentation. Disabled by default.
  void enable();

  /// Disables counters/timing instrumentation and clears collected counters.
  void disable();

  DiagnosticsSnapshot snapshot();

  /// Resets counters while preserving the enabled/disabled state.
  void reset();
}
