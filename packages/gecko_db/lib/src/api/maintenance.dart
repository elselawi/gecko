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

/// Per-stage breakdown of a single query execution (Phase 1 instrumentation).
///
/// Every stage is measured in microseconds and is 0 when the stage did not
/// run (e.g. `sort` is 0 for an unsorted query, `indexLookup` is 0 for a full
/// scan). Populated only when slow-query logging is armed
/// ([DatabaseConfig.slowQueryThresholdMicros] > 0); otherwise the record
/// carries a null [SlowQueryRecord.timings] and query execution pays no
/// timing overhead.
///
/// Stages, in execution order:
/// - `plan`        — building the [FilterGroup] and copying filters/sort.
/// - `indexLookup` — consulting the in-memory [SecondaryIndex] for candidate
///                   ids (0 for a full scan).
/// - `backendRead` — snapshot open + `scanAll`/per-id `read` calls.
/// - `decode`      — [WireCodec.decode] of every scanned row's bytes.
/// - `mapCopy`     — the defensive [_mapOf] copy of each decoded row.
/// - `predicate`   — [FilterGroup.test] over the candidate set.
/// - `model`       — `fromRow` materialization of matched rows.
/// - `sort`        — [compareRows] ordering of the matched set.
class QueryStageTimings {
  const QueryStageTimings({
    this.plan = 0,
    this.indexLookup = 0,
    this.backendRead = 0,
    this.decode = 0,
    this.mapCopy = 0,
    this.predicate = 0,
    this.model = 0,
    this.sort = 0,
    this.rowsScanned = 0,
    this.rowsMatched = 0,
  });

  /// Filter-group construction + filter/sort copy (µs).
  final int plan;

  /// In-memory secondary-index candidate-id lookup (µs; 0 for a full scan).
  final int indexLookup;

  /// Snapshot open + backend reads (µs).
  final int backendRead;

  /// Row byte decode (µs).
  final int decode;

  /// Defensive map copy of each decoded row (µs).
  final int mapCopy;

  /// Predicate evaluation over the candidate set (µs).
  final int predicate;

  /// `fromRow` model materialization of matched rows (µs).
  final int model;

  /// Sort of the matched set (µs; 0 when unsorted).
  final int sort;

  /// Rows decoded & predicated (the full-scan candidate count).
  final int rowsScanned;

  /// Rows that passed the predicate (the result count before limit/offset).
  final int rowsMatched;

  /// Total of all stage timings (µs). May be slightly less than
  /// [SlowQueryRecord.durationMicros] because the record's total also includes
  /// limit/offset slicing and small un-instrumented glue.
  int get total =>
      plan +
      indexLookup +
      backendRead +
      decode +
      mapCopy +
      predicate +
      model +
      sort;

  @override
  String toString() {
    final parts = <String>[
      'plan=$planµs',
      'index=$indexLookupµs',
      'read=$backendReadµs',
      'decode=$decodeµs',
      'mapCopy=$mapCopyµs',
      'pred=$predicateµs',
      'model=$modelµs',
      'sort=$sortµs',
    ];
    return 'QueryStageTimings(${parts.join(', ')}, '
        'scanned=$rowsScanned, matched=$rowsMatched)';
  }
}

/// A recorded slow-query entry (Workstream 5 slow-query logging).
class SlowQueryRecord {
  const SlowQueryRecord({
    required this.durationMicros,
    required this.table,
    required this.indexed,
    required this.filters,
    required this.sort,
    this.timings,
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

  /// Per-stage breakdown, populated only when slow-query logging is armed.
  /// Null when the query ran with timing disabled ([slowQueryThresholdMicros]
  /// == 0) or before the SlowQueryRecord was constructed.
  final QueryStageTimings? timings;

  @override
  String toString() =>
      'SlowQuery($durationMicrosµs, $table, ${indexed ? 'indexed' : 'scan'}, '
      '${filters.join('; ')})${timings == null ? '' : '\n  $timings'}';
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
