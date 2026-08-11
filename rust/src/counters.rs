//! Zero-cost-when-off physical-work counters at the worker boundary.
//!
//! These counters attribute *where* time goes inside the engine: primary rows
//! visited, index entries visited, candidate keys materialized, predicate
//! evaluations, rows/bytes returned, change-log entries scanned/pruned,
//! MVCC snapshots created, and the registry's clone/add/update/remove work.
//! Every optimization claim in the perf plan must show which layer improved;
//! these counters make that measurable from the Dart side.
//!
//! Every counter is an `AtomicU64` gated behind a single `enabled` flag.
//! When counters are disabled (the default) the hot-path helper is one
//! predicted-false branch and no atomic is ever touched, so production runs
//! pay nothing. Enable with `RedbWorker::enable_counters`, then drain with
//! `take_counters` (which snapshots and resets).

use std::sync::atomic::{ AtomicBool, AtomicU64, Ordering };

/// Plain, FRB-visible snapshot of the physical work a worker has done since
/// the last `take_counters`. All fields are monotonically accumulated while
/// counters are enabled.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WorkCounters {
    /// Committed write batches applied.
    pub batches_applied: u64,
    /// Rows written (put / delete / delete-range / clear).
    pub rows_written: u64,
    /// Tables opened inside write transactions.
    pub table_opens: u64,
    /// Previous-value reads performed by the write path.
    pub previous_value_reads: u64,
    /// Durable-index entries inserted or removed during maintenance.
    pub index_maintenance_ops: u64,
    /// Change-log entries scanned by retention pruning.
    pub change_log_scanned: u64,
    /// Change-log entries actually pruned.
    pub change_log_pruned: u64,
    /// Primary-table rows visited by scans and query loops.
    pub primary_rows_visited: u64,
    /// Durable-index entries visited.
    pub index_entries_visited: u64,
    /// Candidate row keys materialized by indexed intersections.
    pub candidate_keys_allocated: u64,
    /// Primary rows fetched to join index candidates.
    pub primary_rows_fetched: u64,
    /// Predicate evaluations (rows tested against a filter in Rust).
    pub predicate_evaluations: u64,
    /// Rows returned to the caller.
    pub rows_returned: u64,
    /// Payload bytes returned to the caller (key + value bytes).
    pub bytes_returned: u64,
    /// MVCC snapshots created.
    pub snapshots_created: u64,
    /// Registry rows added to result sets.
    pub registry_rows_added: u64,
    /// Registry rows updated in result sets.
    pub registry_rows_updated: u64,
    /// Registry rows removed from result sets.
    pub registry_rows_removed: u64,
    /// Registry rows cloned into emitted snapshots.
    pub registry_rows_cloned: u64,
    /// Payload bytes emitted in registry snapshots (key + value bytes).
    pub registry_snapshot_bytes: u64,
}

/// Atomic counter set owned by a worker; only touched while enabled.
#[derive(Debug, Default)]
pub struct AtomicCounters {
    enabled: AtomicBool,
    pub batches_applied: AtomicU64,
    pub rows_written: AtomicU64,
    pub table_opens: AtomicU64,
    pub previous_value_reads: AtomicU64,
    pub index_maintenance_ops: AtomicU64,
    pub change_log_scanned: AtomicU64,
    pub change_log_pruned: AtomicU64,
    pub primary_rows_visited: AtomicU64,
    pub index_entries_visited: AtomicU64,
    pub candidate_keys_allocated: AtomicU64,
    pub primary_rows_fetched: AtomicU64,
    pub predicate_evaluations: AtomicU64,
    pub rows_returned: AtomicU64,
    pub bytes_returned: AtomicU64,
    pub snapshots_created: AtomicU64,
    pub registry_rows_added: AtomicU64,
    pub registry_rows_updated: AtomicU64,
    pub registry_rows_removed: AtomicU64,
    pub registry_rows_cloned: AtomicU64,
    pub registry_snapshot_bytes: AtomicU64,
}

impl AtomicCounters {
    /// Increments [counter] by [amount] only while counters are enabled. The
    /// single relaxed load is the entire overhead when disabled.
    #[inline(always)]
    pub fn bump(&self, counter: &AtomicU64, amount: u64) {
        if self.enabled.load(Ordering::Relaxed) {
            counter.fetch_add(amount, Ordering::Relaxed);
        }
    }

    /// Whether counters are currently being recorded.
    #[inline(always)]
    pub fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
        if !enabled {
            self.reset();
        }
    }

    /// Snapshots every counter and resets them to zero.
    pub fn snapshot_take(&self) -> WorkCounters {
        let snapshot = WorkCounters {
            batches_applied: self.batches_applied.swap(0, Ordering::Relaxed),
            rows_written: self.rows_written.swap(0, Ordering::Relaxed),
            table_opens: self.table_opens.swap(0, Ordering::Relaxed),
            previous_value_reads: self.previous_value_reads.swap(0, Ordering::Relaxed),
            index_maintenance_ops: self.index_maintenance_ops.swap(0, Ordering::Relaxed),
            change_log_scanned: self.change_log_scanned.swap(0, Ordering::Relaxed),
            change_log_pruned: self.change_log_pruned.swap(0, Ordering::Relaxed),
            primary_rows_visited: self.primary_rows_visited.swap(0, Ordering::Relaxed),
            index_entries_visited: self.index_entries_visited.swap(0, Ordering::Relaxed),
            candidate_keys_allocated: self.candidate_keys_allocated.swap(0, Ordering::Relaxed),
            primary_rows_fetched: self.primary_rows_fetched.swap(0, Ordering::Relaxed),
            predicate_evaluations: self.predicate_evaluations.swap(0, Ordering::Relaxed),
            rows_returned: self.rows_returned.swap(0, Ordering::Relaxed),
            bytes_returned: self.bytes_returned.swap(0, Ordering::Relaxed),
            snapshots_created: self.snapshots_created.swap(0, Ordering::Relaxed),
            registry_rows_added: self.registry_rows_added.swap(0, Ordering::Relaxed),
            registry_rows_updated: self.registry_rows_updated.swap(0, Ordering::Relaxed),
            registry_rows_removed: self.registry_rows_removed.swap(0, Ordering::Relaxed),
            registry_rows_cloned: self.registry_rows_cloned.swap(0, Ordering::Relaxed),
            registry_snapshot_bytes: self.registry_snapshot_bytes.swap(0, Ordering::Relaxed),
        };
        snapshot
    }

    fn reset(&self) {
        let _ = self.snapshot_take();
    }
}

/// Bumps a worker counter: `crate::work_count!(self, rows_written, 1)`.
/// Expands to a single `enabled`-gated atomic add; when counters are disabled
/// the branch is predicted false and no atomic is touched.
#[macro_export]
macro_rules! work_count {
    ($worker:expr, $counter:ident, $amount:expr) => {
        $worker
            .counters
            .bump(&$worker.counters.$counter, $amount)
    };
}
