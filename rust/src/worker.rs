//! File-backed redb worker core.
//!
//! This module is deliberately independent of flutter_rust_bridge. It owns one
//! `redb::Database` handle and applies each batch in exactly one write
//! transaction. FRB/native bindings can expose this worker without changing its
//! atomicity or error behavior.

use redb::{
    backends::FileBackend, Database, DatabaseError, ReadOnlyDatabase, ReadTransaction,
    ReadableDatabase, ReadableTable, TableDefinition, TableHandle,
};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};

use crate::crypto_storage::EncryptingStorageBackend;
use crate::wire::{Op, OpKind, WireError};

const TABLE_PREFIX: &str = "__gecko_user_";

type BytesTable = TableDefinition<'static, &'static [u8], &'static [u8]>;
pub type ByteEntry = (Vec<u8>, Vec<u8>);

/// Storage-level size/health report (Workstream 5).
#[derive(Debug, Clone)]
pub struct StorageStats {
    /// Bytes the database file occupies on disk (physical).
    pub physical_bytes: u64,
    /// Sum of key + value bytes across every table (logical payload).
    pub logical_bytes: u64,
    /// Number of tables (user + reserved metadata).
    pub table_count: u64,
    /// Open point-in-time MVCC snapshots.
    pub open_snapshots: u64,
    /// Committed write batches so far.
    pub commit_sequence: u64,
}

#[derive(Debug)]
pub enum WorkerError {
    Storage(String),
    Wire(String),
    InvalidOperation(String),
    DatabaseLocked(String),
}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Storage(message) => write!(f, "storage error: {message}"),
            Self::Wire(message) => write!(f, "wire error: {message}"),
            Self::InvalidOperation(message) => write!(f, "invalid operation: {message}"),
            Self::DatabaseLocked(message) => write!(f, "database locked: {message}"),
        }
    }
}
impl std::error::Error for WorkerError {}

impl From<WireError> for WorkerError {
    fn from(value: WireError) -> Self {
        Self::Wire(value.0)
    }
}

enum WorkerDatabase {
    ReadWrite(Database),
    // On wasm32 the OPFS backend always opens read-write (the read-only flag
    // is enforced at the API layer), so this variant is unused there.
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))]
    ReadOnly(ReadOnlyDatabase),
}

/// A single-writer file-backed engine.
pub struct RedbWorker {
    database: WorkerDatabase,
    /// Path the database file lives at (used for physical-size reporting).
    path: PathBuf,
    commit_sequence: u64,
    read_only: bool,
    /// Open point-in-time MVCC snapshots: each is a held redb read
    /// transaction that observes exactly the committed state at creation
    /// time, even after later write transactions commit.
    snapshots: HashMap<u64, ReadTransaction>,
    next_snapshot_id: u64,
}

impl RedbWorker {
    /// Creates or opens a database. redb performs file locking and crash
    /// recovery during this call.
    ///
    /// On `wasm32` this uses an OPFS-backed storage backend instead of a local
    /// file: the Dart side must have already registered a
    /// `FileSystemSyncAccessHandle` for [path] (see `crate::opfs`), otherwise
    /// a typed [`WorkerError::InvalidOperation`] is returned. Read-only mode
    /// is honored at the API layer; OPFS handles always permit writes.
    pub fn open(path: impl AsRef<Path>, read_only: bool) -> Result<Self, WorkerError> {
        #[cfg(target_arch = "wasm32")]
        {
            return Self::open_wasm_opfs(path.as_ref(), read_only);
        }
        #[cfg(not(target_arch = "wasm32"))]
        {
            let path_display = path.as_ref().display().to_string();
            let path_buf = path.as_ref().to_path_buf();
            let database = if read_only {
                WorkerDatabase::ReadOnly(
                    ReadOnlyDatabase::open(&path)
                        .map_err(|error| map_open_error(error, &path_display))?,
                )
            } else {
                WorkerDatabase::ReadWrite(
                    Database::create(&path)
                        .map_err(|error| map_open_error(error, &path_display))?,
                )
            };
            Ok(Self {
                database,
                path: path_buf,
                commit_sequence: 0,
                read_only,
                snapshots: HashMap::new(),
                next_snapshot_id: 0,
            })
        }
    }

    /// Opens a database over an OPFS sync-access handle (wasm32 only). See the
    /// module-level docs on `crate::opfs` for the acquisition protocol.
    ///
    /// The special path `:memory:` opens a native redb database backed by an
    /// in-memory backend (no OPFS handle required) — useful on the web before
    /// a Worker-provided OPFS handle is available.
    #[cfg(target_arch = "wasm32")]
    fn open_wasm_opfs(path: &Path, read_only: bool) -> Result<Self, WorkerError> {
        let path_display = path.display().to_string();
        let database = if path_display == ":memory:" {
            Database::builder()
                .create_with_backend(redb::backends::InMemoryBackend::new())
                .map_err(|error| map_open_error(error, &path_display))?
        } else {
            let handle = crate::opfs::take_handle_for_path(&path_display).ok_or_else(|| {
                WorkerError::InvalidOperation(format!(
                    "no OPFS sync-access handle registered for {path_display}; \
                     the web worker must acquire and register it before opening"
                ))
            })?;
            let backend = crate::opfs::WasmOpfsBackend::new(handle, path_display.clone());
            Database::builder()
                .create_with_backend(backend)
                .map_err(|error| map_open_error(error, &path_display))?
        };
        Ok(Self {
            database: WorkerDatabase::ReadWrite(database),
            path: path.to_path_buf(),
            commit_sequence: 0,
            read_only,
            snapshots: HashMap::new(),
            next_snapshot_id: 0,
        })
    }

    /// Creates or opens an *encrypted* database (Workstream 4). Every physical
    /// page is AES-256-GCM authenticated under [key] (32 bytes). The key is
    /// held only in this worker's memory and never written to disk. Only
    /// read-write mode is supported for encrypted files.
    pub fn open_encrypted(
        path: impl AsRef<Path>,
        key: &[u8],
        key_gen: u8,
    ) -> Result<Self, WorkerError> {
        let path_display = path.as_ref().display().to_string();
        let path_buf = path.as_ref().to_path_buf();
        if key.len() != 32 {
            return Err(WorkerError::InvalidOperation(
                "encryption key must be exactly 32 bytes (AES-256)".into(),
            ));
        }
        let mut key_bytes = [0u8; 32];
        key_bytes.copy_from_slice(key);
        // Resolve any interrupted rotation before opening so the file is
        // consistent under whichever key the caller holds.
        crate::crypto_storage::recover_rotation(path.as_ref(), key_gen).map_err(|error| {
            WorkerError::Storage(format!(
                "rotation recovery failed for {path_display}: {error}"
            ))
        })?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .map_err(|error| {
                WorkerError::Storage(format!("could not open {path_display}: {error}"))
            })?;
        let backend = EncryptingStorageBackend::new(
            Box::new(FileBackend::new(file).map_err(|error| {
                WorkerError::Storage(format!(
                    "could not initialize file backend for {path_display}: {error}"
                ))
            })?),
            key_bytes,
            key_gen,
        );
        let database = Database::builder()
            .create_with_backend(backend)
            .map_err(|error| map_open_error(error, &path_display))?;
        Ok(Self {
            database: WorkerDatabase::ReadWrite(database),
            path: path_buf,
            commit_sequence: 0,
            read_only: false,
            snapshots: HashMap::new(),
            next_snapshot_id: 0,
        })
    }

    fn begin_read(&self) -> Result<ReadTransaction, WorkerError> {
        match &self.database {
            WorkerDatabase::ReadWrite(database) => database
                .begin_read()
                .map_err(|error| WorkerError::Storage(error.to_string())),
            WorkerDatabase::ReadOnly(database) => database
                .begin_read()
                .map_err(|error| WorkerError::Storage(error.to_string())),
        }
    }

    /// Applies an entire operation batch in exactly one write transaction.
    pub fn apply_batch(&mut self, operations: &[Op]) -> Result<u64, WorkerError> {
        if self.read_only {
            return Err(WorkerError::InvalidOperation(
                "database is read-only; writes are not allowed".into(),
            ));
        }
        let transaction = match &self.database {
            WorkerDatabase::ReadWrite(database) => database
                .begin_write()
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            WorkerDatabase::ReadOnly(_) => unreachable!("read-only worker rejected above"),
        };

        for operation in operations {
            let definition = table_definition(&operation.table);
            let mut table = transaction
                .open_table(definition)
                .map_err(|error| WorkerError::Storage(error.to_string()))?;

            match operation.kind {
                OpKind::Put => {
                    let key = operation
                        .key
                        .as_deref()
                        .ok_or_else(|| WorkerError::InvalidOperation("put requires key".into()))?;
                    let value = operation.value.as_deref().ok_or_else(|| {
                        WorkerError::InvalidOperation("put requires value".into())
                    })?;
                    table
                        .insert(key, value)
                        .map_err(|error| WorkerError::Storage(error.to_string()))?;
                }
                OpKind::Delete => {
                    let key = operation.key.as_deref().ok_or_else(|| {
                        WorkerError::InvalidOperation("delete requires key".into())
                    })?;
                    table
                        .remove(key)
                        .map_err(|error| WorkerError::Storage(error.to_string()))?;
                }
                OpKind::DeleteRange => {
                    let start = operation.start.as_deref().ok_or_else(|| {
                        WorkerError::InvalidOperation("deleteRange requires start".into())
                    })?;
                    let end = operation.end.as_deref().ok_or_else(|| {
                        WorkerError::InvalidOperation("deleteRange requires end".into())
                    })?;
                    let keys: Vec<Vec<u8>> = table
                        .range(start..=end)
                        .map_err(|error| WorkerError::Storage(error.to_string()))?
                        .filter_map(|entry| entry.ok().map(|(key, _)| key.value().to_vec()))
                        .collect();
                    for key in keys {
                        table
                            .remove(key.as_slice())
                            .map_err(|error| WorkerError::Storage(error.to_string()))?;
                    }
                }
                OpKind::Clear => {
                    let keys: Vec<Vec<u8>> = table
                        .iter()
                        .map_err(|error| WorkerError::Storage(error.to_string()))?
                        .filter_map(|entry| entry.ok().map(|(key, _)| key.value().to_vec()))
                        .collect();
                    for key in keys {
                        table
                            .remove(key.as_slice())
                            .map_err(|error| WorkerError::Storage(error.to_string()))?;
                    }
                }
                OpKind::Get | OpKind::RangeScan => {
                    return Err(WorkerError::InvalidOperation(
                        "read operations cannot be committed in a write batch".into(),
                    ));
                }
            }
        }

        transaction
            .commit()
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        self.commit_sequence += 1;
        Ok(self.commit_sequence)
    }

    /// Reads one key using a consistent read transaction.
    pub fn get(&self, table: &str, key: &[u8]) -> Result<Option<Vec<u8>>, WorkerError> {
        let transaction = self.begin_read()?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(None),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let value = table
            .get(key)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|value| value.value().to_vec());
        Ok(value)
    }

    /// Reads a sorted inclusive range using one consistent snapshot.
    pub fn range_scan(
        &self,
        table: &str,
        start: Option<&[u8]>,
        end: Option<&[u8]>,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        let table = match transaction.open_table(table_definition(table)) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut result = Vec::new();
        let iterator = match (start, end) {
            (Some(start), Some(end)) => table
                .range(start..=end)
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            (Some(start), None) => table
                .range(start..)
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, Some(end)) => table
                .range(..=end)
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, None) => table
                .iter()
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
        };
        for entry in iterator {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            result.push((key.value().to_vec(), value.value().to_vec()));
        }
        Ok(result)
    }

    /// Creates a point-in-time MVCC snapshot: a held redb read transaction
    /// that observes exactly the committed state at creation time, even after
    /// later write transactions commit. Returns an opaque id for the caller.
    pub fn create_snapshot(&mut self) -> Result<u64, WorkerError> {
        let transaction = self.begin_read()?;
        let id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        self.snapshots.insert(id, transaction);
        Ok(id)
    }

    fn snapshot_transaction(&self, id: u64) -> Result<&ReadTransaction, WorkerError> {
        self.snapshots
            .get(&id)
            .ok_or_else(|| WorkerError::InvalidOperation(format!("unknown snapshot {id}")))
    }

    /// Reads one key through a previously created snapshot.
    pub fn snapshot_get(
        &self,
        id: u64,
        table: &str,
        key: &[u8],
    ) -> Result<Option<Vec<u8>>, WorkerError> {
        let transaction = self.snapshot_transaction(id)?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(None),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let value = table
            .get(key)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|value| value.value().to_vec());
        Ok(value)
    }

    /// Scans a sorted inclusive range through a previously created snapshot.
    pub fn snapshot_range_scan(
        &self,
        id: u64,
        table: &str,
        start: Option<&[u8]>,
        end: Option<&[u8]>,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(id)?;
        let table = match transaction.open_table(table_definition(table)) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut result = Vec::new();
        let iterator = match (start, end) {
            (Some(start), Some(end)) => table
                .range(start..=end)
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            (Some(start), None) => table
                .range(start..)
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, Some(end)) => table
                .range(..=end)
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, None) => table
                .iter()
                .map_err(|error| WorkerError::Storage(error.to_string()))?,
        };
        for entry in iterator {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            result.push((key.value().to_vec(), value.value().to_vec()));
        }
        Ok(result)
    }

    /// Releases a snapshot. Idempotent: unknown ids are ignored.
    pub fn drop_snapshot(&mut self, id: u64) {
        self.snapshots.remove(&id);
    }

    /// Phase 2 native query fast path: range-scans the durable `__gecko_index`
    /// table for keys in `[start..=end]`, then joins each index entry's value
    /// (which is the user-table row key) back to the matching row in [table],
    /// returning `(recordId, row)` pairs in ONE hop. This eliminates the
    /// Dart-side N+1: instead of one boundary crossing per candidate id,
    /// there is one boundary crossing for the whole result set.
    ///
    /// [index_table] is the durable index table name (typically
    /// `__gecko_index`); [start]/[end] are the already codec-encoded
    /// `[table, field, value, ...]` key bounds. Caller-bound semantics match
    /// [Self::range_scan]: a missing table is an empty result, never an error.
    pub fn query_indexed(
        &self,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_with(&transaction, table, index_table, start, end)
    }

    /// Snapshot-bound variant of [Self::query_indexed]: reads through a
    /// previously created MVCC snapshot so the index→row join observes one
    /// consistent committed state.
    pub fn snapshot_query_indexed(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_with(transaction, table, index_table, start, end)
    }

    /// Shared index→row join: scans [index_table] in `[start..=end]`, collects
    /// the values (user-table row keys), and reads each row from [table].
    /// Preserves index-key order (ascending) so callers that sort by the
    /// indexed field can skip a Dart-side sort.
    fn query_indexed_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        // Collect the index entries' VALUES (the user-table row keys) in
        // ascending index-key order.
        let row_keys: Vec<Vec<u8>> = index_table
            .range(start..=end)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .filter_map(|entry| entry.ok().map(|(_, value)| value.value().to_vec()))
            .collect();
        if row_keys.is_empty() {
            return Ok(Vec::new());
        }
        // Join back to the user table in the same read transaction.
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut result = Vec::with_capacity(row_keys.len());
        for row_key in row_keys {
            let value = user_table
                .get(row_key.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .map(|value| value.value().to_vec());
            if let Some(row_bytes) = value {
                result.push((row_key, row_bytes));
            }
            // A missing user-table row (e.g. an index entry whose row was
            // deleted out of band) is silently skipped: the durable index is
            // maintained atomically with the data, so this should not happen
            // in normal operation, and skipping is the safe fallback.
        }
        Ok(result)
    }

    /// Phase 2 step 2: full-scan with a pushed predicate. Scans every row in
    /// [table], evaluates [predicate] against each row's encoded bytes IN RUST
    /// (decoding only the referenced fields via `find_field`), and returns
    /// only the matching `(recordId, row)` pairs in ONE hop. Non-matching
    /// rows are never decoded in Dart — the dominant saving for unindexed
    /// queries (the Phase 1 profile showed `scanAll` transferring the whole
    /// table dominated 70% of a 100k-row full scan).
    ///
    /// [predicate_bytes] is the Dart-serialized `Predicate` wire payload
    /// (version-prefixed AND-composed filter list, see `predicate.rs`).
    pub fn query_filtered(
        &self,
        table: &str,
        predicate_bytes: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_filtered_with(&transaction, table, predicate_bytes)
    }

    /// Snapshot-bound variant of [Self::query_filtered]: the scan + predicate
    /// evaluation observe one consistent committed state.
    pub fn snapshot_query_filtered(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_with(transaction, table, predicate_bytes)
    }

    fn query_filtered_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut result = Vec::new();
        for entry in table
            .iter()
            .map_err(|error| WorkerError::Storage(error.to_string()))?
        {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_bytes = value.value();
            // Empty predicate matches everything (matches Dart's `FilterGroup`).
            if predicate.test_bytes(row_bytes) {
                result.push((key.value().to_vec(), row_bytes.to_vec()));
            }
        }
        Ok(result)
    }

    pub fn commit_sequence(&self) -> u64 {
        self.commit_sequence
    }

    /// Compacts the database file using redb's supported in-place compaction
    /// path (two-phase commits + maximum file shrink). Requires exclusive
    /// access: no open MVCC snapshots and a writable database. Readers that
    /// start *during* compaction observe consistent old snapshots; writes
    /// continue after it at the next LSN.
    pub fn compact(&mut self) -> Result<bool, WorkerError> {
        if self.read_only {
            return Err(WorkerError::InvalidOperation(
                "database is read-only; compaction is not allowed".into(),
            ));
        }
        if !self.snapshots.is_empty() {
            return Err(WorkerError::InvalidOperation(format!(
                "compaction requires no open MVCC snapshots; {} snapshot(s) are still active",
                self.snapshots.len()
            )));
        }
        match &mut self.database {
            WorkerDatabase::ReadWrite(database) => database.compact().map_err(|error| {
                use redb::CompactionError::*;
                match &error {
                    TransactionInProgress
                    | PersistentSavepointExists
                    | EphemeralSavepointExists => WorkerError::InvalidOperation(format!(
                        "compaction could not start: {error}"
                    )),
                    _ => WorkerError::Storage(format!("compaction failed: {error}")),
                }
            }),
            WorkerDatabase::ReadOnly(_) => unreachable!("read-only worker rejected above"),
        }
    }

    /// Reports physical (file) and logical (payload) size plus health counters
    /// (Workstream 5). Logical size iterates every table once in a consistent
    /// read snapshot.
    pub fn storage_stats(&self) -> Result<StorageStats, WorkerError> {
        let physical_bytes = std::fs::metadata(&self.path)
            .map(|metadata| metadata.len())
            .unwrap_or(0);
        let transaction = self.begin_read()?;
        let raw_names: Vec<String> = transaction
            .list_tables()
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|table| table.name().to_owned())
            .collect();
        let mut logical_bytes: u64 = 0;
        let mut table_count: u64 = 0;
        for name in raw_names {
            let definition = BytesTable::new(Box::leak(name.clone().into_boxed_str()));
            let Ok(table) = transaction.open_table(definition) else {
                continue;
            };
            table_count += 1;
            let Ok(iter) = table.iter() else {
                continue;
            };
            for entry in iter.flatten() {
                let (key, value) = entry;
                logical_bytes += key.value().len() as u64 + value.value().len() as u64;
            }
        }
        Ok(StorageStats {
            physical_bytes,
            logical_bytes,
            table_count,
            open_snapshots: self.snapshots.len() as u64,
            commit_sequence: self.commit_sequence,
        })
    }

    pub fn tables(&self) -> Result<Vec<String>, WorkerError> {
        let transaction = self.begin_read()?;
        let tables = transaction
            .list_tables()
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|table| {
                table
                    .name()
                    .strip_prefix(TABLE_PREFIX)
                    .unwrap_or(table.name())
                    .to_owned()
            })
            .collect();
        Ok(tables)
    }
}

fn map_open_error(error: DatabaseError, path: &str) -> WorkerError {
    match error {
        DatabaseError::DatabaseAlreadyOpen => WorkerError::DatabaseLocked(format!(
            "database at {path} is already open; wait for the owner to close it and retry"
        )),
        other => WorkerError::Storage(format!("could not open database at {path}: {other}")),
    }
}

fn table_definition(name: &str) -> BytesTable {
    let full_name = format!("{TABLE_PREFIX}{name}");
    TableDefinition::new(Box::leak(full_name.into_boxed_str()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("gecko-{label}-{nonce}.redb"))
    }

    fn op(kind: OpKind, key: Option<Vec<u8>>, value: Option<Vec<u8>>) -> Op {
        Op {
            kind,
            table: "items".into(),
            key,
            value,
            start: None,
            end: None,
        }
    }

    #[test]
    fn batch_put_get_delete_and_range() {
        let path = temp_path("worker");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let sequence = worker
            .apply_batch(&[
                op(OpKind::Put, Some(vec![2]), Some(vec![20])),
                op(OpKind::Put, Some(vec![1]), Some(vec![10])),
            ])
            .unwrap();
        assert_eq!(sequence, 1);
        assert_eq!(worker.get("items", &[1]).unwrap(), Some(vec![10]));
        assert_eq!(
            worker.range_scan("items", Some(&[1]), Some(&[2])).unwrap(),
            vec![(vec![1], vec![10]), (vec![2], vec![20])]
        );
        worker
            .apply_batch(&[op(OpKind::Delete, Some(vec![1]), None)])
            .unwrap();
        assert_eq!(worker.get("items", &[1]).unwrap(), None);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn malformed_write_operation_is_rejected_before_commit() {
        let path = temp_path("invalid");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let result = worker.apply_batch(&[op(OpKind::Put, Some(vec![1]), None)]);
        assert!(matches!(result, Err(WorkerError::InvalidOperation(_))));
        assert_eq!(worker.commit_sequence(), 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn clear_and_delete_range_are_atomic_operations() {
        let path = temp_path("range");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker
            .apply_batch(&[
                op(OpKind::Put, Some(vec![1]), Some(vec![1])),
                op(OpKind::Put, Some(vec![2]), Some(vec![2])),
                op(OpKind::Put, Some(vec![3]), Some(vec![3])),
            ])
            .unwrap();
        worker
            .apply_batch(&[Op {
                kind: OpKind::DeleteRange,
                table: "items".into(),
                key: None,
                value: None,
                start: Some(vec![1]),
                end: Some(vec![2]),
            }])
            .unwrap();
        assert_eq!(
            worker.range_scan("items", None, None).unwrap(),
            vec![(vec![3], vec![3])]
        );
        worker
            .apply_batch(&[Op {
                kind: OpKind::Clear,
                table: "items".into(),
                key: None,
                value: None,
                start: None,
                end: None,
            }])
            .unwrap();
        assert!(worker.range_scan("items", None, None).unwrap().is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn snapshots_are_point_in_time_across_write_commits() {
        let path = temp_path("mvcc");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker
            .apply_batch(&[
                op(OpKind::Put, Some(vec![1]), Some(vec![10])),
                op(OpKind::Put, Some(vec![2]), Some(vec![20])),
            ])
            .unwrap();

        // Snapshot taken now must observe the pre-write state forever.
        let snapshot = worker.create_snapshot().unwrap();
        worker
            .apply_batch(&[
                op(OpKind::Put, Some(vec![1]), Some(vec![11])),
                op(OpKind::Put, Some(vec![3]), Some(vec![30])),
            ])
            .unwrap();

        assert_eq!(
            worker.snapshot_get(snapshot, "items", &[1]).unwrap(),
            Some(vec![10]),
            "the old snapshot must still see the pre-write value"
        );
        assert_eq!(
            worker.snapshot_get(snapshot, "items", &[3]).unwrap(),
            None,
            "the old snapshot must not see keys written after it was taken"
        );
        assert_eq!(
            worker
                .snapshot_range_scan(snapshot, "items", None, None)
                .unwrap(),
            vec![(vec![1], vec![10]), (vec![2], vec![20])]
        );
        assert_eq!(
            worker
                .snapshot_range_scan(snapshot, "items", Some(&[2]), Some(&[2]))
                .unwrap(),
            vec![(vec![2], vec![20])]
        );

        // A fresh snapshot observes the new state.
        let fresh = worker.create_snapshot().unwrap();
        assert_eq!(
            worker.snapshot_get(fresh, "items", &[1]).unwrap(),
            Some(vec![11])
        );
        assert_eq!(
            worker.snapshot_get(fresh, "items", &[3]).unwrap(),
            Some(vec![30])
        );

        // Dropping the snapshot makes it unusable (typed error), and dropping
        // an unknown id is idempotent.
        worker.drop_snapshot(snapshot);
        assert!(matches!(
            worker.snapshot_get(snapshot, "items", &[1]),
            Err(WorkerError::InvalidOperation(_))
        ));
        worker.drop_snapshot(999);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn snapshot_range_scan_missing_table_is_empty() {
        let path = temp_path("mvcc-empty");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let snapshot = worker.create_snapshot().unwrap();
        assert!(worker
            .snapshot_range_scan(snapshot, "absent", None, None)
            .unwrap()
            .is_empty());
        assert_eq!(worker.snapshot_get(snapshot, "absent", &[1]).unwrap(), None);
        worker.drop_snapshot(snapshot);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn storage_stats_report_physical_and_logical_sizes() {
        let path = temp_path("stats");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Write payloads with known total logical bytes.
        worker
            .apply_batch(&[
                op(OpKind::Put, Some(vec![1]), Some(vec![10, 11, 12])),
                op(OpKind::Put, Some(vec![2]), Some(vec![20, 21])),
            ])
            .unwrap();
        let stats = worker.storage_stats().unwrap();
        assert!(stats.physical_bytes > 0);
        // logical = keys (1+1) + values (3+2) = 7 (plus any reserved metadata
        // tables like the LSN row, so >= 7).
        assert!(stats.logical_bytes >= 7);
        assert!(stats.physical_bytes >= stats.logical_bytes);
        assert!(stats.table_count >= 1);
        assert_eq!(stats.open_snapshots, 0);
        assert_eq!(stats.commit_sequence, 1);
        // Physical file on disk matches the report.
        assert_eq!(
            std::fs::metadata(&path).unwrap().len(),
            stats.physical_bytes
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn compaction_reclaims_space_and_preserves_data() {
        let path = temp_path("compact");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Fill enough data that compaction has something to reclaim after
        // deletion. Values get overwritten repeatedly to churn pages.
        let mut value = Vec::with_capacity(4096);
        value.extend(std::iter::repeat_n(0xAB, 4096));
        for round in 0..40 {
            let mut batch = Vec::new();
            for i in 0..40 {
                let key = vec![round, i];
                batch.push(Op {
                    kind: OpKind::Put,
                    table: "items".into(),
                    key: Some(key),
                    value: Some(value.clone()),
                    start: None,
                    end: None,
                });
            }
            worker.apply_batch(&batch).unwrap();
        }
        let before = worker.storage_stats().unwrap();
        assert!(before.logical_bytes > 0);

        // Delete everything to create reclaimable space.
        worker
            .apply_batch(&[Op {
                kind: OpKind::Clear,
                table: "items".into(),
                key: None,
                value: None,
                start: None,
                end: None,
            }])
            .unwrap();

        let compacted = worker.compact().unwrap();
        // Compaction should make progress (or at least not error); after it,
        // reads still work and the physical size is <= the pre-compaction size.
        let after = worker.storage_stats().unwrap();
        assert!(after.physical_bytes <= before.physical_bytes);
        assert!(worker.range_scan("items", None, None).unwrap().is_empty());
        // LSN continuity: the next write commits at the next sequence.
        worker
            .apply_batch(&[op(OpKind::Put, Some(vec![9]), Some(vec![99]))])
            .unwrap();
        assert_eq!(
            worker.range_scan("items", None, None).unwrap(),
            vec![(vec![9], vec![99])]
        );
        let _ = compacted;
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn compaction_rejects_open_snapshots_and_read_only() {
        let path = temp_path("compact-guard");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker
            .apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![1]))])
            .unwrap();
        let snapshot = worker.create_snapshot().unwrap();
        assert!(matches!(
            worker.compact(),
            Err(WorkerError::InvalidOperation(_))
        ));
        worker.drop_snapshot(snapshot);
        assert!(worker.compact().is_ok());

        // Read-only databases refuse compaction.
        let ro_path = temp_path("compact-ro");
        let mut ro = RedbWorker::open(&ro_path, false).unwrap();
        ro.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![1]))])
            .unwrap();
        drop(ro);
        let ro = RedbWorker::open(&ro_path, true).unwrap();
        let mut ro = ro;
        assert!(matches!(
            ro.compact(),
            Err(WorkerError::InvalidOperation(_))
        ));
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(ro_path);
    }

    #[test]
    fn query_filtered_returns_only_matching_rows() {
        use crate::predicate::{self, Filter};
        use crate::value_codec::{RowValue, TAG_BOOL, TAG_INT64, TAG_MAP, TAG_STRING};

        // Minimal row map encoder: 0x07 | u32(count) | (key string | value)…
        fn row(entries: &[(&str, Vec<u8>)]) -> Vec<u8> {
            let mut out = vec![TAG_MAP];
            out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
            for (k, v) in entries {
                out.push(TAG_STRING);
                let kb = k.as_bytes();
                out.extend_from_slice(&(kb.len() as u32).to_be_bytes());
                out.extend_from_slice(kb);
                out.extend_from_slice(v);
            }
            out
        }
        fn int64(n: i64) -> Vec<u8> {
            let mut out = vec![TAG_INT64];
            out.extend_from_slice(&n.to_be_bytes());
            out
        }
        fn string(s: &str) -> Vec<u8> {
            let mut out = vec![TAG_STRING];
            let b = s.as_bytes();
            out.extend_from_slice(&(b.len() as u32).to_be_bytes());
            out.extend_from_slice(b);
            out
        }

        let path = temp_path("qf");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Seed 4 rows: g0/g0/g1/g1, ages 10/20/30/40.
        let rows = [
            (
                b"k0".to_vec(),
                row(&[("g", string("g0")), ("age", int64(10))]),
            ),
            (
                b"k1".to_vec(),
                row(&[("g", string("g0")), ("age", int64(20))]),
            ),
            (
                b"k2".to_vec(),
                row(&[("g", string("g1")), ("age", int64(30))]),
            ),
            (
                b"k3".to_vec(),
                row(&[("g", string("g1")), ("age", int64(40))]),
            ),
        ];
        let ops: Vec<Op> = rows
            .iter()
            .map(|(k, v)| Op {
                kind: OpKind::Put,
                table: "items".into(),
                key: Some(k.clone()),
                value: Some(v.clone()),
                start: None,
                end: None,
            })
            .collect();
        worker.apply_batch(&ops).unwrap();

        // Predicate: g == "g0" AND age >= 15 → only k1 (g0, age 20).
        let pred_bytes = predicate::encode_predicate(&[
            Filter::Equals {
                field: "g".into(),
                value: RowValue::String("g0".into()),
            },
            Filter::Range {
                field: "age".into(),
                min: Some(RowValue::Int64(15)),
                max: None,
            },
        ]);
        let matched = worker.query_filtered("items", &pred_bytes).unwrap();
        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].0, b"k1");

        // Empty predicate matches all 4.
        let all = worker
            .query_filtered("items", &predicate::encode_predicate(&[]))
            .unwrap();
        assert_eq!(all.len(), 4);

        // A missing table is an empty result, never an error.
        let missing = worker.query_filtered("nope", &pred_bytes).unwrap();
        assert!(missing.is_empty());
        let _ = (TAG_BOOL,); // suppress unused import noise
        let _ = std::fs::remove_file(path);
    }
}
