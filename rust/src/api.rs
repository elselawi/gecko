//! Minimal FRB-facing API for the file-backed redb worker.
//!
//! This module intentionally exposes owned, serialization-friendly values so
//! generated Dart bindings do not need to hold Rust transaction handles.

use crate::compatibility::CompatibilityHandshake;
use crate::worker::{ByteEntry, RedbWorker, StorageStats, WorkerError};

const NATIVE_BUILD_ID: &str = concat!(env!("CARGO_PKG_VERSION"), "+rust");

fn encode_worker_error(error: WorkerError) -> String {
    let details = match &error {
        WorkerError::DatabaseLocked(message) => Some(serde_json::json!({
            "reason": message,
            "retryable": true,
        })),
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
        old_gen: u8,
    ) -> Result<(), String> {
        if old_key.len() != 32 || new_key.len() != 32 {
            return Err(crate::error::GeckoErrorEnvelope::new(
                crate::error::GeckoErrorType::InvalidOperation,
                "encryption keys must be exactly 32 bytes (AES-256)",
            )
            .encode());
        }
        let mut old = [0u8; 32];
        let mut new = [0u8; 32];
        old.copy_from_slice(&old_key);
        new.copy_from_slice(&new_key);
        crate::crypto_storage::rekey_file(std::path::Path::new(&path), old, new, old_gen).map_err(
            |error| {
                crate::error::GeckoErrorEnvelope::new(
                    crate::error::GeckoErrorType::Unknown,
                    format!("key rotation failed: {error}"),
                )
                .encode()
            },
        )
    }

    /// Returns the compatibility handshake before callers use the worker.
    pub async fn compatibility_handshake(&self) -> String {
        CompatibilityHandshake::current(NATIVE_BUILD_ID)
            .encode()
            .expect("compatibility handshake constants must encode")
    }

    pub async fn apply_batch(&mut self, encoded_ops: Vec<u8>) -> Result<u64, String> {
        let operations = crate::wire::Op::decode_batch(&encoded_ops).map_err(|error| {
            crate::error::GeckoErrorEnvelope::new(
                crate::error::GeckoErrorType::InvalidOperation,
                error.to_string(),
            )
            .encode()
        })?;
        self.worker
            .apply_batch(&operations)
            .map_err(encode_worker_error)
    }

    pub async fn get(&self, table: String, key: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        self.worker.get(&table, &key).map_err(encode_worker_error)
    }

    pub async fn range_scan(
        &self,
        table: String,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .range_scan(&table, start.as_deref(), end.as_deref())
            .map_err(encode_worker_error)
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
        key: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, String> {
        self.worker
            .snapshot_get(snapshot, &table, &key)
            .map_err(encode_worker_error)
    }

    pub async fn snapshot_range_scan(
        &self,
        snapshot: u64,
        table: String,
        start: Option<Vec<u8>>,
        end: Option<Vec<u8>>,
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
    pub async fn query_indexed(
        &self,
        table: String,
        index_table: String,
        start: Vec<u8>,
        end: Vec<u8>,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_indexed(&table, &index_table, &start, &end)
            .map_err(encode_worker_error)
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
        end: Vec<u8>,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_indexed(snapshot, &table, &index_table, &start, &end)
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
        predicate_bytes: Vec<u8>,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .query_filtered(&table, &predicate_bytes)
            .map_err(encode_worker_error)
    }

    /// Snapshot-bound variant of [Self::query_filtered]: the scan + predicate
    /// evaluation observe one consistent committed state.
    pub async fn snapshot_query_filtered(
        &self,
        snapshot: u64,
        table: String,
        predicate_bytes: Vec<u8>,
    ) -> Result<Vec<ByteEntry>, String> {
        self.worker
            .snapshot_query_filtered(snapshot, &table, &predicate_bytes)
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
