//! Minimal FRB-facing API for the file-backed redb worker.
//!
//! This module intentionally exposes owned, serialization-friendly values so
//! generated Dart bindings do not need to hold Rust transaction handles.

use crate::compatibility::CompatibilityHandshake;
use crate::worker::{
    ByteEntry,
    GroupedChildEntries,
    PreparedChangeTemplate,
    RedbWorker,
    StorageStats,
    SyncTransitionUpdate,
    WorkCounters,
    WorkerError,
};

const NATIVE_BUILD_ID: &str = concat!(env!("CARGO_PKG_VERSION"), "+rust");

fn encode_worker_error(error: WorkerError) -> String {
    let details = match &error {
        WorkerError::DatabaseLocked(message) =>
            Some(
                serde_json::json!({
            "reason": message,
            "retryable": true,
        })
            ),
        _ => None,
    };
    let kind = match &error {
        WorkerError::InvalidOperation(_) | WorkerError::Wire(_) => {
            crate::error::GeckoErrorType::InvalidOperation
        }
        WorkerError::KeyNotFound(_) => crate::error::GeckoErrorType::KeyNotFound,
        WorkerError::DatabaseLocked(_) => crate::error::GeckoErrorType::DatabaseLocked,
        WorkerError::Storage(_) => crate::error::GeckoErrorType::Unknown,
    };
    let mut envelope = crate::error::GeckoErrorEnvelope::new(kind, error.to_string());
    envelope.details = details;
    envelope.encode()
}

/// outcome of one committed batch — worker sequence plus one
/// delta per touched live registration.
#[derive(Debug, Clone)]
pub struct ApplyBatchResult {
    pub sequence: u64,
    pub deltas: Vec<QueryDelta>,
    pub previous_values: Vec<Option<Vec<u8>>>,
    pub removed_keys: Vec<(String, Vec<u8>)>,
    /// Tables wholesale-cleared by `Clear` operations (batch order).
    pub cleared: Vec<String>,
}

/// Additional metadata for one change record completed by Rust inside the
/// prepared write transaction.
#[derive(Debug, Clone)]
pub struct PreparedChange {
    pub operation_index: u64,
    pub ordinal: u64,
    pub sync_state_key: Vec<u8>,
    pub record_template: Vec<u8>,
    pub fill_previous_version: bool,
}

/// one per-registration delta produced by a committed batch.
#[derive(Debug, Clone)]
pub struct QueryDelta {
    pub id: u64,
    pub added: Vec<ByteEntry>,
    pub updated: Vec<ByteEntry>,
    pub removed: Vec<ByteEntry>,
    pub snapshot: Vec<ByteEntry>,
    pub unchanged: bool,
}

impl From<crate::registry::RegistryDelta> for QueryDelta {
    fn from(value: crate::registry::RegistryDelta) -> Self {
        Self {
            id: value.id,
            added: value.added,
            updated: value.updated,
            removed: value.removed,
            snapshot: value.snapshot,
            unchanged: value.unchanged,
        }
    }
}

/// the result of registering a live query.
#[derive(Debug, Clone)]
pub struct RegisterLiveQueryResult {
    pub id: u64,
    pub initial: Vec<ByteEntry>,
}

pub struct NativeWorker {
    worker: RedbWorker,
}

impl NativeWorker {
    /// Opens a database. Async so the web (wasm) build dispatches through the
    /// async runtime instead of FRB's sync WorkerPool.
    pub async fn open(path: String, read_only: bool) -> Result<Self, String> {
        RedbWorker::open(path, read_only)
            .map(|worker| Self { worker })
            .map_err(encode_worker_error)
    }

    /// Opens (or creates) an AES-256-GCM encrypted database. [key] must be
    /// exactly 32 bytes. Any interrupted key rotation is resolved first, so
    /// the file is consistent under the provided key generation before any
    /// data is returned.
    pub async fn open_encrypted(path: String, key: Vec<u8>, key_gen: u8) -> Result<Self, String> {
        RedbWorker::open_encrypted(path, &key, key_gen)
            .map(|worker| Self { worker })
            .map_err(encode_worker_error)
    }

    /// Atomically re-encrypts a *closed* encrypted database file from
    /// [old_key] to [new_key]. The database must not be open anywhere; a
    /// rotation marker lets an interrupted rotation be recovered to either the
    /// old or the new key on the next open.
    pub async fn rekey_encrypted_file(
        path: String,
        old_key: Vec<u8>,
        new_key: Vec<u8>,
        old_gen: u8
    ) -> Result<(), String> {
        if old_key.len() != 32 || new_key.len() != 32 {
            return Err(
                crate::error::GeckoErrorEnvelope
                    ::new(
                        crate::error::GeckoErrorType::InvalidOperation,
                        "encryption keys must be exactly 32 bytes (AES-256)"
                    )
                    .encode()
            );
        }
        let mut old = [0u8; 32];
        let mut new = [0u8; 32];
        old.copy_from_slice(&old_key);
        new.copy_from_slice(&new_key);
        crate::crypto_storage
            ::rekey_file(std::path::Path::new(&path), old, new, old_gen)
            .map_err(|error| {
                crate::error::GeckoErrorEnvelope
                    ::new(
                        crate::error::GeckoErrorType::Unknown,
                        format!("key rotation failed: {error}")
                    )
                    .encode()
            })
    }

    /// Returns the compatibility handshake before callers use the worker.
    pub async fn compatibility_handshake(&self) -> String {
        CompatibilityHandshake::current(NATIVE_BUILD_ID)
            .encode()
            .expect("compatibility handshake constants must encode")
    }

    pub async fn apply_batch(
        &mut self,
        encoded_ops: Vec<u8>,
        index_definitions: Vec<(String, Vec<String>)>,
        change_log_max_entries: u64,
        report_removed_keys: bool
    ) -> Result<ApplyBatchResult, String> {
        let operations = crate::wire::Op
            ::decode_batch(&encoded_ops)
            .map_err(|error| {
                crate::error::GeckoErrorEnvelope
                    ::new(crate::error::GeckoErrorType::InvalidOperation, error.to_string())
                    .encode()
            })?;
        let result = self.worker
            .apply_batch_reactive_with_retention_mode(
                &operations,
                &index_definitions,
                change_log_max_entries,
                report_removed_keys
            )
            .map_err(encode_worker_error)?;
        Ok(ApplyBatchResult {
            sequence: result.sequence,
            deltas: result.deltas.into_iter().map(QueryDelta::from).collect(),
            previous_values: result.previous_values,
            removed_keys: result.removed_keys,
            cleared: result.cleared,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn apply_prepared_batch(
        &mut self,
        encoded_ops: Vec<u8>,
        index_definitions: Vec<(String, Vec<String>)>,
        change_log_max_entries: u64,
        previous_operation_indexes: Vec<String>,
        put_modes: Vec<(u64, u8)>,
        changes: Vec<PreparedChange>,
        report_removed_keys: bool
    ) -> Result<ApplyBatchResult, String> {
        let operations = crate::wire::Op
            ::decode_batch(&encoded_ops)
            .map_err(|error| {
                crate::error::GeckoErrorEnvelope
                    ::new(crate::error::GeckoErrorType::InvalidOperation, error.to_string())
                    .encode()
            })?;
        let templates = changes
            .into_iter()
            .map(|change| PreparedChangeTemplate {
                operation_index: change.operation_index as usize,
                ordinal: change.ordinal,
                sync_state_key: change.sync_state_key,
                record_template: change.record_template,
                fill_previous_version: change.fill_previous_version,
            })
            .collect::<Vec<_>>();
        let indexes = previous_operation_indexes
            .into_iter()
            .map(|index| {
                index
                    .parse::<usize>()
                    .map_err(|_| WorkerError::InvalidOperation("invalid previous index".into()))
            })
            .collect::<Result<Vec<_>, _>>()
            .map_err(encode_worker_error)?;
        let modes = put_modes
            .into_iter()
            .map(|(index, mode)| (index as usize, mode))
            .collect::<Vec<_>>();
        let result = self.worker
            .apply_prepared_batch_mode(
                &operations,
                &index_definitions,
                change_log_max_entries,
                &indexes,
                &modes,
                &templates,
                report_removed_keys
            )
            .map_err(encode_worker_error)?;
        Ok(ApplyBatchResult {
            sequence: result.sequence,
            deltas: result.deltas.into_iter().map(QueryDelta::from).collect(),
            previous_values: result.previous_values,
            removed_keys: result.removed_keys,
            cleared: result.cleared,
        })
    }

    /// registers a live query with the worker's reactive
    /// registry. [kind] is 0 = watchAll, 1 = watchAllDiff, 2 = query. Returns
    /// the registration id and the initial result set in result order. A
    /// windowed query ([limit] is Some) receives only the ordered slice
    /// `[offset, offset + limit)`; the registry maintains the full matching
    /// set incrementally so the window stays correct under writes.
    pub async fn register_live_query(
        &mut self,
        table: String,
        predicate_bytes: Vec<u8>,
        sort_bytes: Vec<u8>,
        kind: u8,
        limit: Option<u64>,
        offset: u64,
    ) -> Result<RegisterLiveQueryResult, String> {
        self.worker
            .register_live_query(&table, &predicate_bytes, &sort_bytes, kind, limit, offset)
            .map(|(id, initial)| RegisterLiveQueryResult { id, initial })
            .map_err(encode_worker_error)
    }

    /// removes a live-query registration (idempotent).
    pub async fn unregister_live_query(&mut self, id: u64) -> Result<(), String> {
        self.worker.unregister_live_query(id);
        Ok(())
    }

    /// Aggregates the pending local changes from the
    /// sync-state table (dirty, non-remote, ordered by localMutationId) in
    /// Rust. Dart decodes the returned records into `PendingChange`.
    pub async fn pending_changes(&self) -> Result<Vec<ByteEntry>, String> {
        self.worker.pending_changes().map_err(encode_worker_error)
    }

    /// Filters the sync-state table to the records matching the encoded
    /// matchers (plain recordIds and `(collection, recordId)` RecordRefs) in
    /// Rust. See [`RedbWorker::sync_state_matching`] for the matcher layout.
    /// Used by sync transitions and remote-deletion candidate selection so a
    /// large sync-state table is never scanned + decoded in Dart.
    pub async fn sync_state_matching(
        &self,
        matchers: Vec<Vec<u8>>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .sync_state_matching(&matchers)
            .map_err(encode_worker_error)
    }

    /// Range-filtered `changesSince(lastSeq)`: scans the change log in Rust
    /// and returns only the records whose `localMutationId` exceeds [seq].
    /// Only the required records cross the boundary.
    pub async fn changes_since(&self, seq: u64) -> Result<Vec<ByteEntry>, String> {
        self.worker.changes_since(seq).map_err(encode_worker_error)
    }

    /// Applies mark-synchronizing / mark-synced / mark-failed transitions in
    /// ONE Rust write transaction (sync state, plus the matching change-log
    /// records when [update_log] is set). See
    /// [`RedbWorker::sync_transition`].
    pub async fn sync_transition(
        &mut self,
        updates: Vec<SyncTransitionUpdate>,
        update_log: bool
    ) -> Result<(), String> {
        self.worker.sync_transition(&updates, update_log).map_err(encode_worker_error)
    }

    /// Returns the attachment metadata entries whose parent row no longer
    /// exists — the `orphaned()` scan + parent-existence checks run inside one
    /// Rust read transaction.
    pub async fn orphaned_attachments(&self) -> Result<Vec<ByteEntry>, String> {
        self.worker.orphaned_attachments().map_err(encode_worker_error)
    }

    /// Scans a metadata table ([table]) and returns the entries whose row
    /// matches [predicate_bytes] — filtering and ordering execute in Rust, so
    /// attachment/conflict listing never materializes the whole catalog in
    /// Dart. Deterministic ascending key order.
    pub async fn metadata_query(
        &self,
        table: String,
        predicate_bytes: Vec<u8>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .metadata_query(&table, &predicate_bytes)
            .map_err(encode_worker_error)
    }

    /// Number of active live-query registrations (diagnostics).
    pub async fn live_query_count(&self) -> Result<u64, String> {
        Ok(self.worker.live_query_count() as u64)
    }

    pub async fn get(&self, table: String, key: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        self.worker.get(&table, &key).map_err(encode_worker_error)
    }

    pub async fn range_scan(
        &self,
        table: String,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>,
        limit: Option<u64>,
        start_inclusive: bool,
        end_inclusive: bool,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .range_scan(
                &table,
                start.as_deref(),
                end.as_deref(),
                limit,
                start_inclusive,
                end_inclusive,
            )
            .map_err(encode_worker_error)
    }

    /// batched point-read — fetches N keys in ONE read transaction,
    /// returning `(key, row)` pairs for keys that exist. Absent keys are
    /// omitted; a missing table is an empty result, never an error. Kills the
    /// relationship N+1 (one boundary crossing instead of one per id).
    pub async fn get_many(
        &self,
        table: String,
        keys: Vec<Vec<u8>>
    ) -> Result<Vec<ByteEntry>, String> {
        let borrowed: Vec<&[u8]> = keys
            .iter()
            .map(|k| k.as_slice())
            .collect();
        self.worker.get_many(&table, &borrowed).map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::get_many]: every read observes one
    /// consistent committed state.
    pub async fn snapshot_get_many(
        &self,
        snapshot: u64,
        table: String,
        keys: Vec<Vec<u8>>
    ) -> Result<Vec<ByteEntry>, String> {
        let borrowed: Vec<&[u8]> = keys
            .iter()
            .map(|k| k.as_slice())
            .collect();
        self.worker.snapshot_get_many(snapshot, &table, &borrowed).map_err(encode_worker_error)
    }

    /// Creates a point-in-time MVCC snapshot handle (a held redb read
    /// transaction). Reads through the returned id observe the committed state
    /// at creation time, not later writes.
    pub async fn create_snapshot(&mut self) -> Result<u64, String> {
        self.worker.create_snapshot().map_err(encode_worker_error)
    }

    pub async fn snapshot_get(
        &self,
        snapshot: u64,
        table: String,
        key: Vec<u8>
    ) -> Result<Option<Vec<u8>>, String> {
        self.worker.snapshot_get(snapshot, &table, &key).map_err(encode_worker_error)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_range_scan(
        &self,
        snapshot: u64,
        table: String,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>,
        limit: Option<u64>,
        start_inclusive: bool,
        end_inclusive: bool,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_range_scan(
                snapshot,
                &table,
                start.as_deref(),
                end.as_deref(),
                limit,
                start_inclusive,
                end_inclusive,
            )
            .map_err(encode_worker_error)
    }

    /// native query fast path: range-scans the durable index table
    /// [index_table] for keys in `[start..=end]`, joins each entry's value
    /// (the user-table row key) back to its row in [table], and returns the
    /// `(recordId, row)` pairs in one hop. [start]/[end] are the already
    /// codec-encoded `[table, field, value, ...]` key bounds. Eliminates the
    /// Dart-side N+1 (one boundary crossing instead of one per candidate id).
    /// verifies and atomically repairs durable index entries for [table].
    pub async fn repair_index(&mut self, table: String, fields: Vec<String>) -> Result<(), String> {
        self.worker.repair_index(&table, &fields).map_err(encode_worker_error)
    }

    pub async fn query_indexed(
        &self,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker.query_indexed(&table, &index_table, &start, &end).map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_indexed]: reads through an
    /// existing MVCC snapshot so the index→row join observes one consistent
    /// committed state.
    pub async fn snapshot_query_indexed(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_indexed(snapshot, &table, &index_table, &start, &end)
            .map_err(encode_worker_error)
    }

    /// Session-scoped composite durable-index declaration: [indexes] is the
    /// ordered field list of each composite index on [table].
    pub async fn set_composite_indexes(&mut self, table: String, indexes: Vec<Vec<String>>) {
        self.worker.set_composite_indexes(&table, &indexes);
    }

    /// intersects multiple durable-index candidate ranges in one
    /// snapshot-bound operation. [covered] skips the per-row predicate
    /// recheck (Priority 5); [limit]/[offset] apply an early window.
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_multi(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_indexed_multi(
                snapshot,
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
                covered,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// direct multi-range indexed query.
    #[allow(clippy::too_many_arguments)]
    pub async fn query_indexed_multi(
        &self,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_indexed_multi(
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
                covered,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// snapshot-bound count over durable-index candidates. [covered] skips
    /// the per-row predicate recheck (Priority 5).
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_count(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        covered: bool
    ) -> Result<u64, String> {
        self.worker
            .snapshot_query_indexed_count(
                snapshot,
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
                covered
            )
            .map_err(encode_worker_error)
    }

    /// direct count over durable-index candidates.
    #[allow(clippy::too_many_arguments)]
    pub async fn query_indexed_count(
        &self,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        covered: bool
    ) -> Result<u64, String> {
        self.worker
            .query_indexed_count(&table, &index_table, &ranges, &predicate_bytes, covered)
            .map_err(encode_worker_error)
    }

    /// snapshot-bound distinct extraction over durable-index
    /// candidates. Only encoded values for [field] cross FRB.
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_distinct(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        field: String,
        covered: bool
    ) -> Result<Vec<Vec<u8>>, String> {
        self.worker
            .snapshot_query_indexed_distinct(
                snapshot,
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
                &field,
                covered
            )
            .map_err(encode_worker_error)
    }

    /// Direct indexed distinct extraction using one worker-owned read
    /// transaction.
    #[allow(clippy::too_many_arguments)]
    pub async fn query_indexed_distinct(
        &self,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        field: String,
        covered: bool
    ) -> Result<Vec<Vec<u8>>, String> {
        self.worker
            .query_indexed_distinct(
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
                &field,
                covered
            )
            .map_err(encode_worker_error)
    }

    /// step 2: full-scan with a pushed predicate. Scans every row in
    /// [table], evaluates [predicate] against each row's encoded bytes IN RUST
    /// (decoding only the referenced fields), and returns only the matching
    /// `(recordId, row)` pairs in one hop. Non-matching rows are never decoded
    /// in Dart. [predicate_bytes] is the Dart-serialized `Predicate` payload.
    pub async fn query_filtered(
        &self,
        table: String,
        predicate_bytes: Vec<u8>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker.query_filtered(&table, &predicate_bytes).map_err(encode_worker_error)
    }

    /// direct full-scan + predicate with an early LIMIT/OFFSET.
    pub async fn query_filtered_limited(
        &self,
        table: String,
        predicate_bytes: Vec<u8>,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_filtered_limited(&table, &predicate_bytes, limit, offset)
            .map_err(encode_worker_error)
    }

    /// direct indexed query with an early LIMIT/OFFSET. [covered] skips the
    /// per-row predicate recheck (Priority 5).
    #[allow(clippy::too_many_arguments)]
    pub async fn query_indexed_limited(
        &self,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>,
        predicate_bytes: Vec<u8>,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_indexed_limited(
                &table,
                &index_table,
                &start,
                &end,
                &predicate_bytes,
                covered,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// direct Rust top-K sorted query.
    pub async fn query_sorted(
        &self,
        table: String,
        predicate_bytes: Vec<u8>,
        sort_spec_bytes: Vec<u8>,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_sorted(&table, &predicate_bytes, &sort_spec_bytes, limit, offset)
            .map_err(encode_worker_error)
    }

    /// direct index-ordered sorted query. [descending] streams the index in
    /// reverse (Priority 5); [covered] skips the per-row predicate recheck.
    #[allow(clippy::too_many_arguments)]
    pub async fn query_indexed_ordered(
        &self,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>,
        predicate_bytes: Vec<u8>,
        sort_field: String,
        eq_bounded: bool,
        descending: bool,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_indexed_ordered(
                &table,
                &index_table,
                &start,
                &end,
                &predicate_bytes,
                &sort_field,
                eq_bounded,
                descending,
                covered,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_filtered_limited].
    pub async fn snapshot_query_filtered_limited(
        &self,
        snapshot: u64,
        table: String,
        predicate_bytes: Vec<u8>,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_filtered_limited(snapshot, &table, &predicate_bytes, limit, offset)
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_indexed_limited].
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_limited(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>,
        predicate_bytes: Vec<u8>,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_indexed_limited(
                snapshot,
                &table,
                &index_table,
                &start,
                &end,
                &predicate_bytes,
                covered,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_sorted].
    pub async fn snapshot_query_sorted(
        &self,
        snapshot: u64,
        table: String,
        predicate_bytes: Vec<u8>,
        sort_spec_bytes: Vec<u8>,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_sorted(
                snapshot,
                &table,
                &predicate_bytes,
                &sort_spec_bytes,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_indexed_ordered].
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_ordered(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>,
        predicate_bytes: Vec<u8>,
        sort_field: String,
        eq_bounded: bool,
        descending: bool,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_indexed_ordered(
                snapshot,
                &table,
                &index_table,
                &start,
                &end,
                &predicate_bytes,
                &sort_field,
                eq_bounded,
                descending,
                covered,
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_filtered]: the scan + predicate
    /// evaluation observe one consistent committed state.
    pub async fn snapshot_query_filtered(
        &self,
        snapshot: u64,
        table: String,
        predicate_bytes: Vec<u8>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_filtered(snapshot, &table, &predicate_bytes)
            .map_err(encode_worker_error)
    }

    /// snapshot-bound parent lookup. Rust extracts the child FK and
    /// performs the parent point read before returning the parent row.
    pub async fn snapshot_relationship_parent(
        &self,
        snapshot: u64,
        child_table: String,
        child_key: Vec<u8>,
        parent_table: String,
        foreign_key_field: String
    ) -> Result<Option<ByteEntry>, String> {
        self.worker
            .snapshot_relationship_parent(
                snapshot,
                &child_table,
                &child_key,
                &parent_table,
                &foreign_key_field
            )
            .map_err(encode_worker_error)
    }

    /// /snapshot-bound child retrieval using durable index ranges or
    /// a pushed FK predicate. Rust classifies matching child rows by FK and
    /// returns them **grouped by parent id**, so Dart never re-decodes every
    /// candidate row to bucket it.
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_relationship_children(
        &self,
        snapshot: u64,
        child_table: String,
        foreign_key_field: String,
        parent_ids: Vec<Vec<u8>>,
        index_table: String,
        index_ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>
    ) -> Result<Vec<GroupedChildEntries>, String> {
        self.worker
            .snapshot_relationship_children(
                snapshot,
                &child_table,
                &foreign_key_field,
                &parent_ids,
                &index_table,
                &index_ranges,
                &predicate_bytes
            )
            .map_err(encode_worker_error)
    }

    /// snapshot-bound many-to-many join ID retrieval.
    pub async fn snapshot_relationship_join_ids(
        &self,
        snapshot: u64,
        join_table: String,
        field: String,
        wanted_id: Vec<u8>
    ) -> Result<Vec<Vec<u8>>, String> {
        self.worker
            .snapshot_relationship_join_ids(snapshot, &join_table, &field, &wanted_id)
            .map_err(encode_worker_error)
    }

    /// aggregate pushdown — counts matching rows WITHOUT transferring
    /// them. Scans [table], evaluates [predicate_bytes] against each row's
    /// bytes IN RUST, and returns only the count. A `count()` query no longer
    /// pays the decode + transfer cost of every matching row.
    pub async fn query_filtered_count(
        &self,
        table: String,
        predicate_bytes: Vec<u8>
    ) -> Result<u64, String> {
        self.worker.query_filtered_count(&table, &predicate_bytes).map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_filtered_count].
    pub async fn snapshot_query_filtered_count(
        &self,
        snapshot: u64,
        table: String,
        predicate_bytes: Vec<u8>
    ) -> Result<u64, String> {
        self.worker
            .snapshot_query_filtered_count(snapshot, &table, &predicate_bytes)
            .map_err(encode_worker_error)
    }

    /// aggregate pushdown — emits only the bytes of [field] for each
    /// matching row, so a `distinct(field)` query transfers one value per row
    /// instead of the whole row. Returns a list of raw encoded `RowValue`
    /// bytes (the slice starting at the value's tag byte, self-delimiting
    /// under the codec); the Dart side decodes and dedups them. Rows where
    /// [field] is absent are omitted (matches Dart `distinct()`).
    pub async fn query_filtered_distinct(
        &self,
        table: String,
        predicate_bytes: Vec<u8>,
        field: String
    ) -> Result<Vec<Vec<u8>>, String> {
        self.worker
            .query_filtered_distinct(&table, &predicate_bytes, &field)
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_filtered_distinct].
    pub async fn snapshot_query_filtered_distinct(
        &self,
        snapshot: u64,
        table: String,
        predicate_bytes: Vec<u8>,
        field: String
    ) -> Result<Vec<Vec<u8>>, String> {
        self.worker
            .snapshot_query_filtered_distinct(snapshot, &table, &predicate_bytes, &field)
            .map_err(encode_worker_error)
    }

    pub async fn drop_snapshot(&mut self, snapshot: u64) {
        self.worker.drop_snapshot(snapshot);
    }

    pub async fn commit_sequence(&self) -> u64 {
        self.worker.commit_sequence()
    }

    /// Compacts the database file in place (redb's supported compact path).
    /// Returns true when compaction reclaimed space, false when the file was
    /// already fully compacted. Fails with a typed error if any MVCC snapshot
    /// is still open or the database is read-only.
    pub async fn compact(&mut self) -> Result<bool, String> {
        self.worker.compact().map_err(encode_worker_error)
    }

    /// Reports physical/logical size and health counters
    pub async fn storage_stats(&self) -> Result<StorageStats, String> {
        self.worker.storage_stats().map_err(encode_worker_error)
    }

    /// The on-disk file length, O(1) — for compaction reporting where the
    /// logical-size scan is never needed. See [`RedbWorker::physical_size`].
    pub async fn physical_size(&self) -> Result<u64, String> {
        self.worker.physical_size().map_err(encode_worker_error)
    }

    /// Starts recording physical-work counters (zero-cost when off by
    /// default). Drain with [Self::take_counters].
    pub async fn enable_counters(&self) {
        self.worker.enable_counters();
    }

    /// Stops recording and resets all physical-work counters to zero.
    pub async fn disable_counters(&self) {
        self.worker.disable_counters();
    }

    /// Snapshots and resets the physical-work counters accumulated since the
    /// last drain. Returns a zeroed snapshot when counters are disabled.
    pub async fn take_counters(&self) -> WorkCounters {
        self.worker.take_counters()
    }

    pub async fn tables(&self) -> Result<Vec<String>, String> {
        self.worker.tables().map_err(encode_worker_error)
    }

    /// Explicitly releases the redb file handle before the Dart object is
    /// dropped. This is required for deterministic reopen on Windows.
    pub async fn close(self) {}
}

// Keep WorkerError visible to generated documentation and future typed mapping.
#[allow(dead_code)]
fn _worker_error_type(_: WorkerError) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::{ GeckoErrorEnvelope, GeckoErrorType };
    use std::time::{ SystemTime, UNIX_EPOCH };

    /// Runs an async fn to completion. All `NativeWorker` methods are async
    /// only so the wasm build dispatches through the FRB async runtime; on
    /// native they contain no real awaits, so a noop-waker poll loop is
    /// sufficient.
    fn block_on<F: std::future::Future>(fut: F) -> F::Output {
        let waker = std::task::Waker::noop();
        let mut cx = std::task::Context::from_waker(waker);
        let mut fut = std::pin::pin!(fut);
        loop {
            match fut.as_mut().poll(&mut cx) {
                std::task::Poll::Ready(value) => {
                    return value;
                }
                std::task::Poll::Pending => std::thread::yield_now(),
            }
        }
    }

    fn temp_path(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        std::env::temp_dir().join(format!("gecko-api-{label}-{nonce}.redb"))
    }

    fn decode_envelope(s: &str) -> GeckoErrorEnvelope {
        serde_json::from_str(s).expect("error envelope must be valid JSON")
    }

    // ── encode_worker_error mapping ────────────────────────────────────────

    #[test]
    fn encode_worker_error_maps_invalid_operation_and_wire() {
        let invalid = decode_envelope(
            &encode_worker_error(WorkerError::InvalidOperation("bad".into()))
        );
        assert_eq!(invalid.error_type, GeckoErrorType::InvalidOperation);
        assert!(invalid.details.is_none());

        let wire = decode_envelope(&encode_worker_error(WorkerError::Wire("bad bytes".into())));
        assert_eq!(wire.error_type, GeckoErrorType::InvalidOperation);
        assert!(wire.details.is_none());
    }

    #[test]
    fn encode_worker_error_maps_database_locked_with_retryable_details() {
        let envelope = decode_envelope(
            &encode_worker_error(WorkerError::DatabaseLocked("already open".into()))
        );
        assert_eq!(envelope.error_type, GeckoErrorType::DatabaseLocked);
        let details = envelope.details.expect("DatabaseLocked must carry details");
        assert_eq!(details["reason"], "already open");
        assert_eq!(details["retryable"], true);
    }

    #[test]
    fn encode_worker_error_maps_storage_to_unknown() {
        let envelope = decode_envelope(
            &encode_worker_error(WorkerError::Storage("disk full".into()))
        );
        assert_eq!(envelope.error_type, GeckoErrorType::Unknown);
        assert!(envelope.details.is_none());
        assert!(envelope.message.contains("disk full"));
    }

    #[test]
    fn encode_worker_error_never_produces_decryption_type() {
        // `GeckoErrorType::Decryption` is declared on the Dart side but the
        // worker→envelope mapping never emits it today (encryption failures
        // surface as Unknown via the `Storage` arm). Pin that so a future
        // change is deliberate.
        let storage = decode_envelope(
            &encode_worker_error(WorkerError::Storage("auth failed".into()))
        );
        assert_ne!(storage.error_type, GeckoErrorType::Decryption);
        let wire = decode_envelope(&encode_worker_error(WorkerError::Wire("x".into())));
        assert_ne!(wire.error_type, GeckoErrorType::Decryption);
        let locked = decode_envelope(&encode_worker_error(WorkerError::DatabaseLocked("x".into())));
        assert_ne!(locked.error_type, GeckoErrorType::Decryption);
        let invalid = decode_envelope(
            &encode_worker_error(WorkerError::InvalidOperation("x".into()))
        );
        assert_ne!(invalid.error_type, GeckoErrorType::Decryption);
    }

    // ── rekey_encrypted_file key-length pre-check ──────────────────────────

    #[test]
    fn rekey_rejects_wrong_length_keys_before_any_fs_work() {
        // The path does not exist; only the length pre-check can reject.
        let missing = temp_path("rekey-missing");
        let short = vec![0u8; 31];
        let long = vec![0u8; 33];
        let err = block_on(
            NativeWorker::rekey_encrypted_file(
                missing.display().to_string(),
                short.clone(),
                vec![0u8; 32],
                1
            )
        ).unwrap_err();
        let envelope = decode_envelope(&err);
        assert_eq!(envelope.error_type, GeckoErrorType::InvalidOperation);
        assert!(envelope.message.contains("exactly 32 bytes"));

        let err = block_on(
            NativeWorker::rekey_encrypted_file(
                missing.display().to_string(),
                vec![0u8; 32],
                long,
                1
            )
        ).unwrap_err();
        let envelope = decode_envelope(&err);
        assert_eq!(envelope.error_type, GeckoErrorType::InvalidOperation);
        let _ = short;
    }

    #[test]
    fn rekey_accepts_all_zero_32_byte_key_length_only() {
        // A 32-byte all-zero key passes the length pre-check; the failure that
        // follows must be a rotation/fs error (Unknown), NOT the length error.
        let missing = temp_path("rekey-zero");
        let err = block_on(
            NativeWorker::rekey_encrypted_file(
                missing.display().to_string(),
                vec![0u8; 32],
                vec![0u8; 32],
                1
            )
        ).unwrap_err();
        let envelope = decode_envelope(&err);
        assert_ne!(envelope.error_type, GeckoErrorType::InvalidOperation);
        assert_eq!(envelope.error_type, GeckoErrorType::Unknown);
        assert!(envelope.message.contains("key rotation failed"));
    }

    // ── open / apply_batch / register_live_query through the API surface ──

    #[test]
    fn open_and_apply_batch_undecodable_bytes_is_invalid_operation() {
        let path = temp_path("apply-undecodable");
        let worker = block_on(NativeWorker::open(path.display().to_string(), false)).unwrap();
        let mut worker = worker;
        // Garbage that cannot decode as an op batch → InvalidOperation.
        let err = block_on(
            worker.apply_batch(vec![0xde, 0xad, 0xbe, 0xef], vec![], 0, true)
        ).unwrap_err();
        let envelope = decode_envelope(&err);
        assert_eq!(envelope.error_type, GeckoErrorType::InvalidOperation);
        // A well-formed empty batch applies cleanly (an empty write
        // transaction still commits, advancing the worker sequence to 1).
        let ok = block_on(worker.apply_batch(vec![1, 0], vec![], 0, true)).unwrap();
        assert_eq!(ok.sequence, 1);
        assert!(ok.removed_keys.is_empty());
        assert!(ok.cleared.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn register_live_query_invalid_kind_is_invalid_operation() {
        let path = temp_path("reg-kind");
        let worker = block_on(NativeWorker::open(path.display().to_string(), false)).unwrap();
        let mut worker = worker;
        let err = block_on(
            worker.register_live_query("items".into(), vec![1, 0], vec![1, 0], 99, None, 0)
        ).unwrap_err();
        let envelope = decode_envelope(&err);
        assert_eq!(envelope.error_type, GeckoErrorType::InvalidOperation);
        assert!(envelope.message.contains("kind"));
        // Valid kind registers.
        let result = block_on(
            worker.register_live_query("items".into(), vec![1, 0], vec![1, 0], 0, None, 0)
        ).unwrap();
        assert_eq!(result.id, 0);
        assert!(result.initial.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn native_build_id_format() {
        // `NATIVE_BUILD_ID` = "<package-version>+rust".
        assert!(NATIVE_BUILD_ID.ends_with("+rust"));
        let version = NATIVE_BUILD_ID.strip_suffix("+rust").expect("+rust suffix");
        assert_eq!(version, env!("CARGO_PKG_VERSION"));
        assert!(!version.is_empty());
        // It round-trips through the compatibility handshake (must not panic).
        let worker_path = temp_path("build-id");
        let worker = block_on(
            NativeWorker::open(worker_path.display().to_string(), false)
        ).unwrap();
        let handshake = block_on(worker.compatibility_handshake());
        // The handshake JSON embeds the build id (camelCase field).
        let value: serde_json::Value = serde_json::from_str(&handshake).expect("valid JSON");
        assert_eq!(value["nativeBuildId"], NATIVE_BUILD_ID);
        assert_eq!(value["packageVersion"], env!("CARGO_PKG_VERSION"));
        let _ = std::fs::remove_file(worker_path);
    }

    #[test]
    fn open_maps_database_already_open_to_locked_envelope() {
        let path = temp_path("open-locked");
        let worker = block_on(NativeWorker::open(path.display().to_string(), false)).unwrap();
        drop(worker);
        // Reopening after close must succeed (release of the handle).
        let reopened = block_on(NativeWorker::open(path.display().to_string(), false)).unwrap();
        drop(reopened);
        let _ = std::fs::remove_file(path);
    }
}
