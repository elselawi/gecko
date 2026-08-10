//! Minimal FRB-facing API for the file-backed redb worker.
//!
//! This module intentionally exposes owned, serialization-friendly values so
//! generated Dart bindings do not need to hold Rust transaction handles.

use crate::compatibility::CompatibilityHandshake;
use crate::worker::{ ByteEntry, RedbWorker, StorageStats, WorkerError };

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
        WorkerError::DatabaseLocked(_) => crate::error::GeckoErrorType::DatabaseLocked,
        WorkerError::Storage(_) => crate::error::GeckoErrorType::Unknown,
    };
    let mut envelope = crate::error::GeckoErrorEnvelope::new(kind, error.to_string());
    envelope.details = details;
    envelope.encode()
}

pub struct NativeWorker {
    worker: RedbWorker,
}

impl NativeWorker {
    /// Opens a database. Async so the web (wasm) build dispatches through the
    /// async runtime instead of FRB's sync WorkerPool (see ADR-0013).
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
        index_definitions: Vec<(String, Vec<String>)>
    ) -> Result<u64, String> {
        let operations = crate::wire::Op
            ::decode_batch(&encoded_ops)
            .map_err(|error| {
                crate::error::GeckoErrorEnvelope
                    ::new(crate::error::GeckoErrorType::InvalidOperation, error.to_string())
                    .encode()
            })?;
        self.worker
            .apply_batch_with_indexes(&operations, &index_definitions)
            .map_err(encode_worker_error)
    }

    pub async fn get(&self, table: String, key: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        self.worker.get(&table, &key).map_err(encode_worker_error)
    }

    pub async fn range_scan(
        &self,
        table: String,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .range_scan(&table, start.as_deref(), end.as_deref())
            .map_err(encode_worker_error)
    }

    /// M3: batched point-read — fetches N keys in ONE read transaction,
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

    pub async fn snapshot_range_scan(
        &self,
        snapshot: u64,
        table: String,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_range_scan(snapshot, &table, start.as_deref(), end.as_deref())
            .map_err(encode_worker_error)
    }

    /// Phase 2 native query fast path: range-scans the durable index table
    /// [index_table] for keys in `[start..=end]`, joins each entry's value
    /// (the user-table row key) back to its row in [table], and returns the
    /// `(recordId, row)` pairs in one hop. [start]/[end] are the already
    /// codec-encoded `[table, field, value, ...]` key bounds. Eliminates the
    /// Dart-side N+1 (one boundary crossing instead of one per candidate id).
    /// M7: verifies and atomically repairs durable index entries for [table].
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

    /// M5: intersects multiple durable-index candidate ranges in one
    /// snapshot-bound operation and rechecks the complete predicate in Rust.
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_multi(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_indexed_multi(snapshot, &table, &index_table, &ranges, &predicate_bytes)
            .map_err(encode_worker_error)
    }

    /// M7.1: snapshot-bound count over durable-index candidates. The complete
    /// predicate is rechecked in Rust and only the scalar count crosses FRB.
    #[allow(clippy::too_many_arguments)]
    pub async fn snapshot_query_indexed_count(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>
    ) -> Result<u64, String> {
        self.worker
            .snapshot_query_indexed_count(
                snapshot,
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
            )
            .map_err(encode_worker_error)
    }

    /// M7.1: snapshot-bound distinct extraction over durable-index
    /// candidates. Only encoded values for [field] cross FRB.
    pub async fn snapshot_query_indexed_distinct(
        &self,
        snapshot: u64,
        table: String,
        index_table: String,
        ranges: Vec<(Vec<u8>, Vec<u8>)>,
        predicate_bytes: Vec<u8>,
        field: String
    ) -> Result<Vec<Vec<u8>>, String> {
        self.worker
            .snapshot_query_indexed_distinct(
                snapshot,
                &table,
                &index_table,
                &ranges,
                &predicate_bytes,
                &field,
            )
            .map_err(encode_worker_error)
    }

    /// Phase 2 step 2: full-scan with a pushed predicate. Scans every row in
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

    /// M4: full-scan + predicate with an early LIMIT/OFFSET — skips the first
    /// [offset] matches and returns at most [limit] of the rest, stopping the
    /// scan as soon as the window fills (matching rows beyond it are never
    /// transferred).
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

    /// M4: index-served query with an early LIMIT/OFFSET. Streams the durable
    /// index range `[start..=end]`, joins to rows, applies [predicate_bytes]
    /// (so early-stop is correct with additional filters), and stops once the
    /// window fills.
    #[allow(clippy::too_many_arguments)]
    pub async fn query_indexed_limited(
        &self,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>,
        predicate_bytes: Vec<u8>,
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
                limit,
                offset
            )
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
                limit,
                offset
            )
            .map_err(encode_worker_error)
    }

    /// M4: full-scan + top-K sort. Evaluates [predicate_bytes] and returns the
    /// `[offset, offset+limit)` window ordered by [sort_spec_bytes] (a port of
    /// Dart `compareRows`), keeping only the window in memory — the full
    /// candidate set is never materialized or transferred.
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

    /// M4: index-ordered early-stop sort. Streams the durable-index range
    /// `[start..=end]` in index-key order (the same order Dart's stable sort of
    /// the field produces), joins to rows, applies [predicate_bytes], and
    /// stops once `offset + limit` matches are collected. [eq_bounded]
    /// indicates `start..=end` is an equality bound on [sort_field] (so
    /// index-key order is correct for either direction); when false, the
    /// stream covers all values of [sort_field] (ascending only; missing-field
    /// rows are appended if the window is not filled).
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

    /// M3: aggregate pushdown — counts matching rows WITHOUT transferring
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

    /// M3: aggregate pushdown — emits only the bytes of [field] for each
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

    /// Reports physical/logical size and health counters (Workstream 5).
    pub async fn storage_stats(&self) -> Result<StorageStats, String> {
        self.worker.storage_stats().map_err(encode_worker_error)
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
