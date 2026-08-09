/// Workstream 5: compaction, maintenance, and complete diagnostics contracts.
library;

/// Lifecycle states of the database maintenance (compaction) state machine.
enum MaintenanceState {
  /// No maintenance activity. The default.
  idle,

  /// A compaction is in progress.
  compacting,

  /// The most recent compaction completed and reclaimed space.
  committed,

  /// The most recent compaction failed with a typed error.
  failed,

  /// A previous session crashed mid-compaction; the file has been recovered
  /// (redb's two-phase compaction is crash-safe) and [`MaintenanceApi.recover`]
  /// clears the interrupted-compaction marker.
  recovering,
}

/// Storage-level size/health report (Workstream 5).
class StorageStats {
  const StorageStats({
    required this.physicalBytes,
    required this.logicalBytes,
    required this.tableCount,
    required this.openSnapshots,
    required this.commitSequence,
  });

  /// Bytes the database file occupies on disk (physical). For the in-memory
  /// backend this equals [logicalBytes].
  final int physicalBytes;

  /// Sum of key + value payload bytes across every table (logical size).
  final int logicalBytes;

  /// Number of tables (user + reserved metadata tables).
  final int tableCount;

  /// Open point-in-time MVCC snapshots.
  final int openSnapshots;

  /// Committed write batches so far.
  final int commitSequence;

  @override
  String toString() =>
      'StorageStats(physical=$physicalBytes, logical=$logicalBytes, '
      'tables=$tableCount, snapshots=$openSnapshots, lsn=$commitSequence)';
}

/// A recorded slow-query entry (Workstream 5 slow-query logging).
class SlowQueryRecord {
  const SlowQueryRecord({
    required this.durationMicros,
    required this.table,
    required this.indexed,
    required this.filters,
    required this.sort,
  });

  /// Observed execution time in microseconds.
  final int durationMicros;

  /// Collection/table queried.
  final String table;

  /// True when the query was served from a secondary index, false for a full
  /// scan. Populated from the query's [`IndexPlan`] at execution time.
  final bool indexed;

  /// Human-readable filter descriptions.
  final List<String> filters;

  /// Human-readable sort specifications.
  final List<String> sort;

  @override
  String toString() =>
      'SlowQuery($durationMicrosµs, $table, ${indexed ? 'indexed' : 'scan'}, '
      '${filters.join('; ')})';
}

/// Maintenance/compaction controller.
///
/// Compaction uses redb's supported in-place compact path: it is crash-safe
/// (two-phase commits), readers that run during a compaction observe
/// consistent snapshots, and every write after a compaction commits at the
/// next LSN. Compaction requires no open MVCC snapshots (snapshot-bound
/// cursors/transactions must be disposed first), a writable database, and is
/// refused while another compaction is running.
abstract class MaintenanceApi {
  /// The current maintenance state.
  MaintenanceState get state;

  /// Compacts the database file in place.
  ///
  /// Returns `true` when space was reclaimed and `false` when the file was
  /// already fully compacted. Transitions the state machine
  /// `idle → compacting → committed` (or `failed`). A durable marker written
  /// before compaction starts means an interrupted compaction is detected on
  /// the next open as `recovering`.
  ///
  /// Throws a typed [`GeckoError`]:
  /// - `invalidOperation` when the database is in-memory, read-only, already
  ///   compacting, or has open MVCC snapshots;
  /// - `unknown`/`storage` on compaction failure.
  Future<bool> compact();

  /// Resolves an interrupted or failed compaction.
  ///
  /// When a previous session crashed mid-compaction (state `recovering`) or
  /// the last compaction failed (state `failed`), clears the durable marker
  /// and returns to `idle`. Safe to call in any state; no-op otherwise.
  /// Returns the state *before* recovery.
  Future<MaintenanceState> recover();

  /// Reports logical and physical size plus health counters.
  Future<StorageStats> storageStats();

  /// Number of compactions completed since open.
  int get compactionCount;

  /// Duration (microseconds) of the most recent compaction, or 0.
  int get lastCompactionDurationMicros;

  /// Bytes reclaimed by the most recent compaction, or 0.
  int get lastCompactionBytesReclaimed;
}
