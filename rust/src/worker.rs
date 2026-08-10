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
use std::collections::{BTreeSet, HashMap};
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

/// A candidate row held by the M4 top-K sort heap: the record key, the raw row
/// bytes, and the precomputed sort-key tuple (one `Option<RowValue>` per sort
/// spec — `None` = the row lacks that field, which sorts last for ascending /
/// first for descending, exactly like Dart `compareRows`).
struct SortCandidate {
    key: Vec<u8>,
    row: Vec<u8>,
    sort_key: Vec<Option<crate::value_codec::RowValue>>,
}

/// A bounded max-heap (ordered by [cmp]) that keeps the K smallest items under
/// [cmp] without materializing the full candidate set. Root is the current
/// maximum; a new item only replaces the root when it compares smaller.
struct TopK<T, C: Fn(&T, &T) -> std::cmp::Ordering> {
    cap: usize,
    items: Vec<T>,
    cmp: C,
}

impl<T, C: Fn(&T, &T) -> std::cmp::Ordering> TopK<T, C> {
    fn new(cap: usize, cmp: C) -> Self {
        TopK {
            cap,
            items: Vec::with_capacity(cap.min(1024)),
            cmp,
        }
    }

    fn push(&mut self, item: T) {
        if self.cap == 0 {
            return;
        }
        if self.items.len() < self.cap {
            self.items.push(item);
            let mut i = self.items.len() - 1;
            while i > 0 {
                let parent = (i - 1) / 2;
                if (self.cmp)(&self.items[i], &self.items[parent]) == std::cmp::Ordering::Greater {
                    self.items.swap(i, parent);
                    i = parent;
                } else {
                    break;
                }
            }
            return;
        }
        // Heap is full: replace the root if the new item is smaller.
        if (self.cmp)(&item, &self.items[0]) == std::cmp::Ordering::Less {
            self.items[0] = item;
            let len = self.items.len();
            let mut i = 0;
            loop {
                let left = 2 * i + 1;
                let right = 2 * i + 2;
                let mut largest = i;
                if left < len
                    && (self.cmp)(&self.items[left], &self.items[largest])
                        == std::cmp::Ordering::Greater
                {
                    largest = left;
                }
                if right < len
                    && (self.cmp)(&self.items[right], &self.items[largest])
                        == std::cmp::Ordering::Greater
                {
                    largest = right;
                }
                if largest == i {
                    break;
                }
                self.items.swap(i, largest);
                i = largest;
            }
        }
    }

    /// Consumes the heap, returning the items in ascending comparator order.
    fn into_sorted(mut self) -> Vec<T> {
        let mut out = Vec::with_capacity(self.items.len());
        while self.items.len() > 1 {
            // Move the current max (root) to the end, pop it, then restore the
            // heap invariant for the new root.
            let last = self.items.len() - 1;
            self.items.swap(0, last);
            let max = self.items.pop().expect("len > 1");
            out.push(max);
            let len = self.items.len();
            let mut i = 0;
            loop {
                let left = 2 * i + 1;
                let right = 2 * i + 2;
                let mut largest = i;
                if left < len
                    && (self.cmp)(&self.items[left], &self.items[largest])
                        == std::cmp::Ordering::Greater
                {
                    largest = left;
                }
                if right < len
                    && (self.cmp)(&self.items[right], &self.items[largest])
                        == std::cmp::Ordering::Greater
                {
                    largest = right;
                }
                if largest == i {
                    break;
                }
                self.items.swap(i, largest);
                i = largest;
            }
        }
        if let Some(last_item) = self.items.pop() {
            out.push(last_item);
        }
        out.reverse();
        out
    }
}

/// Applies `(offset, limit)` to a fully-collected ordered result: skips the
/// first [offset] rows and keeps the next [limit] (or all remaining when
/// [limit] is None). Clamps out-of-range windows (matches Dart's slice).
fn slice_offset_limit(rows: Vec<SortCandidate>, limit: Option<u64>, offset: u64) -> Vec<ByteEntry> {
    let len = rows.len() as u64;
    let start = offset.min(len) as usize;
    let end = match limit {
        Some(l) => (offset.saturating_add(l)).min(len) as usize,
        None => len as usize,
    };
    rows[start..end]
        .iter()
        .map(|c| (c.key.clone(), c.row.clone()))
        .collect()
}

/// Compares two [SortCandidate]s by their precomputed sort-key tuples under
/// [specs] — the same missing-field/descending rules as
/// `sort_spec::compare_rows`, but over the extracted per-field values.
fn compare_rows_from_keys(
    a: &SortCandidate,
    b: &SortCandidate,
    specs: &[crate::sort_spec::SortSpec],
) -> std::cmp::Ordering {
    for (i, spec) in specs.iter().enumerate() {
        match (&a.sort_key[i], &b.sort_key[i]) {
            (Some(x), Some(y)) => {
                let c = crate::value_codec::sort_compare(x, y);
                if c != std::cmp::Ordering::Equal {
                    return if spec.descending { c.reverse() } else { c };
                }
            }
            (Some(_), None) => {
                return if spec.descending {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Less
                };
            }
            (None, Some(_)) => {
                return if spec.descending {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                };
            }
            (None, None) => {}
        }
    }
    std::cmp::Ordering::Equal
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

    /// M3: batched point-read — fetches N keys in ONE read transaction,
    /// returning `(key, value)` pairs for keys that exist. Keys whose row is
    /// absent are omitted (the caller can compute the missing set if it
    /// needs). A missing table is an empty result, never an error. This kills
    /// the relationship N+1: callers that previously did one `get` per child
    /// id now do one `get_many` for the whole batch.
    pub fn get_many(&self, table: &str, keys: &[&[u8]]) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.get_many_with(&transaction, table, keys)
    }

    /// Snapshot-bound variant of [Self::get_many]: all reads observe one
    /// consistent committed state.
    pub fn snapshot_get_many(
        &self,
        snapshot: u64,
        table: &str,
        keys: &[&[u8]],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.get_many_with(transaction, table, keys)
    }

    fn get_many_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        keys: &[&[u8]],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        if keys.is_empty() {
            return Ok(Vec::new());
        }
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut result = Vec::with_capacity(keys.len());
        for key in keys {
            if let Some(value) = user_table
                .get(*key)
                .map_err(|error| WorkerError::Storage(error.to_string()))?
            {
                result.push((key.to_vec(), value.value().to_vec()));
            }
            // Absent keys are silently omitted; the durable contract is that
            // only existing rows appear in the result.
        }
        Ok(result)
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

    /// M5: scans one or more durable-index ranges, intersects their candidate
    /// row keys, and re-evaluates the complete predicate in Rust. Range and
    /// prefix filters use broad `(table, field)` bounds because the v1 row
    /// codec is not generally order-preserving (notably for negative numbers
    /// and length-prefixed strings). The durable index narrows the candidate
    /// set; [predicate_bytes] remains the semantic source of truth.
    pub fn query_indexed_multi(
        &self,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_multi_with(&transaction, table, index_table, ranges, predicate_bytes)
    }

    /// Snapshot-bound variant of [Self::query_indexed_multi].
    pub fn snapshot_query_indexed_multi(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_multi_with(transaction, table, index_table, ranges, predicate_bytes)
    }

    fn query_indexed_multi_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        if ranges.is_empty() {
            return Ok(Vec::new());
        }
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };

        // A BTreeSet gives deterministic candidate order and makes each
        // intersection independent of hash iteration order.
        let mut candidates: Option<BTreeSet<Vec<u8>>> = None;
        for (start, end) in ranges {
            let keys = index_table
                .range(start.as_slice()..=end.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .filter_map(|entry| entry.ok().map(|(_, value)| value.value().to_vec()))
                .collect::<BTreeSet<_>>();
            candidates = Some(match candidates {
                None => keys,
                Some(previous) => previous.intersection(&keys).cloned().collect(),
            });
            if candidates.as_ref().is_some_and(BTreeSet::is_empty) {
                return Ok(Vec::new());
            }
        }

        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut result = Vec::new();
        for row_key in candidates.unwrap_or_default() {
            let Some(value) = user_table
                .get(row_key.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?
            else {
                continue;
            };
            let row_bytes = value.value();
            if predicate.test_bytes(row_bytes) {
                result.push((row_key, row_bytes.to_vec()));
            }
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

    /// M3: aggregate pushdown — counts matching rows WITHOUT transferring
    /// them. Scans [table], evaluates [predicate_bytes] against each row's
    /// bytes IN RUST, and returns only the matching count in one hop. A
    /// `count()` query no longer pays the decode + transfer cost of every
    /// matching row.
    pub fn query_filtered_count(
        &self,
        table: &str,
        predicate_bytes: &[u8],
    ) -> Result<u64, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_filtered_count_with(&transaction, table, predicate_bytes)
    }

    /// Snapshot-bound variant of [Self::query_filtered_count].
    pub fn snapshot_query_filtered_count(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8],
    ) -> Result<u64, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_count_with(transaction, table, predicate_bytes)
    }

    fn query_filtered_count_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
    ) -> Result<u64, WorkerError> {
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(0),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let mut count: u64 = 0;
        for entry in table
            .iter()
            .map_err(|error| WorkerError::Storage(error.to_string()))?
        {
            let (_, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            if predicate.test_bytes(value.value()) {
                count += 1;
            }
        }
        Ok(count)
    }

    /// M3: aggregate pushdown — emits only the bytes of [field] for each
    /// matching row, so a `distinct(field)` query transfers one value per row
    /// instead of the whole row. Returns the raw encoded `RowValue` bytes
    /// (the same bytes `find_field` would read the value into); the Dart side
    /// decodes and dedups them. Rows where [field] is absent are omitted (a
    /// missing field is not a distinct value — matches Dart `distinct()`,
    /// which only adds `row[field]` when present).
    pub fn query_filtered_distinct(
        &self,
        table: &str,
        predicate_bytes: &[u8],
        field: &str,
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_filtered_distinct_with(&transaction, table, predicate_bytes, field)
    }

    /// Snapshot-bound variant of [Self::query_filtered_distinct].
    pub fn snapshot_query_filtered_distinct(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8],
        field: &str,
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_distinct_with(transaction, table, predicate_bytes, field)
    }

    fn query_filtered_distinct_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        field: &str,
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
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
            let (_, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_bytes = value.value();
            if !predicate.test_bytes(row_bytes) {
                continue;
            }
            // Locate [field] within the row's encoded bytes and emit the
            // value's bytes verbatim (the slice starting at the value's tag
            // byte, self-delimiting under the codec). Use find_field_offset so
            // we slice instead of allocating the decoded value.
            let range = crate::value_codec::find_field_range(row_bytes, field)
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            let Some((start, end)) = range else {
                continue;
            };
            result.push(row_bytes[start..end].to_vec());
        }
        Ok(result)
    }

    // ── M4: early LIMIT/OFFSET + indexed/top-K sorting ──────────────────────

    /// M4: full-scan with a pushed predicate and an early LIMIT/OFFSET —
    /// skips the first [offset] matches and returns at most [limit] of the
    /// rest, stopping the scan as soon as the window is filled. Non-matching
    /// rows are never decoded in Dart, and (unlike [Self::query_filtered])
    /// matching rows beyond the window are never transferred.
    pub fn query_filtered_limited(
        &self,
        table: &str,
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_filtered_limited_with(&transaction, table, predicate_bytes, limit, offset)
    }

    /// Snapshot-bound variant of [Self::query_filtered_limited].
    pub fn snapshot_query_filtered_limited(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_limited_with(transaction, table, predicate_bytes, limit, offset)
    }

    fn query_filtered_limited_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        let mut result = Vec::new();
        for entry in table
            .iter()
            .map_err(|error| WorkerError::Storage(error.to_string()))?
        {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            if !predicate.test_bytes(value.value()) {
                continue;
            }
            result.push((key.value().to_vec(), value.value().to_vec()));
            if let Some(want) = want {
                if result.len() as u64 >= want {
                    break;
                }
            }
        }
        if offset > 0 {
            let start = (offset as usize).min(result.len());
            result = result.split_off(start);
        }
        Ok(result)
    }

    /// M4: index-served eq query with an early LIMIT/OFFSET. Streams the
    /// durable-index range `[start..=end]` in index-key order, joins each
    /// entry back to its row, applies [predicate_bytes] (the full filter set,
    /// so early-stop is correct even with additional filters), and stops once
    /// the window is filled.
    #[allow(clippy::too_many_arguments)]
    pub fn query_indexed_limited(
        &self,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_limited_with(
            &transaction,
            table,
            index_table,
            start,
            end,
            predicate_bytes,
            limit,
            offset,
        )
    }

    /// Snapshot-bound variant of [Self::query_indexed_limited].
    #[allow(clippy::too_many_arguments)]
    pub fn snapshot_query_indexed_limited(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_limited_with(
            transaction,
            table,
            index_table,
            start,
            end,
            predicate_bytes,
            limit,
            offset,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn query_indexed_limited_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        let mut result = Vec::new();
        for entry in index_table
            .range(start..=end)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
        {
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_key = entry.1.value();
            let Some(row_bytes) = user_table
                .get(row_key)
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .map(|v| v.value().to_vec())
            else {
                continue;
            };
            if !predicate.test_bytes(&row_bytes) {
                continue;
            }
            result.push((row_key.to_vec(), row_bytes));
            if let Some(want) = want {
                if result.len() as u64 >= want {
                    break;
                }
            }
        }
        if offset > 0 {
            let start_idx = (offset as usize).min(result.len());
            result = result.split_off(start_idx);
        }
        Ok(result)
    }

    /// M4: full-scan + top-K sort. Scans every row in [table], evaluates
    /// [predicate_bytes], and keeps only the `offset + limit` smallest rows
    /// under the [sort_spec_bytes] ordering (a port of Dart `compareRows`),
    /// then returns the `[offset, offset+limit)` window in sorted order. The
    /// full candidate set is never materialized or transferred — only the
    /// window crosses the boundary. Handles multi-field sorts, ascending and
    /// descending, and missing-field placement (last for ascending, first for
    /// descending), exactly like Dart.
    pub fn query_sorted(
        &self,
        table: &str,
        predicate_bytes: &[u8],
        sort_spec_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_sorted_with(
            &transaction,
            table,
            predicate_bytes,
            sort_spec_bytes,
            limit,
            offset,
        )
    }

    /// Snapshot-bound variant of [Self::query_sorted].
    pub fn snapshot_query_sorted(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8],
        sort_spec_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_sorted_with(
            transaction,
            table,
            predicate_bytes,
            sort_spec_bytes,
            limit,
            offset,
        )
    }

    fn query_sorted_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        sort_spec_bytes: &[u8],
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        use crate::sort_spec::decode_sort_specs;
        use crate::value_codec::RowValue;
        let specs = decode_sort_specs(sort_spec_bytes).map_err(WorkerError::Wire)?;
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        if specs.is_empty() {
            return Ok(Vec::new());
        }
        let cap = limit
            .map(|l| offset.saturating_add(l) as usize)
            .unwrap_or(usize::MAX);
        let mut heap = TopK::new(cap, |a: &SortCandidate, b: &SortCandidate| {
            // M4: ties break by record key bytes (matching the durable-index
            // order and the Dart `_compareDecoded` tiebreak) so every backend
            // returns the same deterministic order.
            compare_rows_from_keys(a, b, &specs.specs).then_with(|| a.key.cmp(&b.key))
        });
        for entry in table
            .iter()
            .map_err(|error| WorkerError::Storage(error.to_string()))?
        {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_bytes = value.value();
            if !predicate.test_bytes(row_bytes) {
                continue;
            }
            // Decode ONLY the sort fields via find_field (no full row decode).
            let mut sort_key: Vec<Option<RowValue>> = Vec::with_capacity(specs.specs.len());
            for spec in &specs.specs {
                let found = crate::value_codec::find_field(row_bytes, &spec.field)
                    .map_err(|error| WorkerError::Storage(error.to_string()))?;
                sort_key.push(found);
            }
            heap.push(SortCandidate {
                key: key.value().to_vec(),
                row: row_bytes.to_vec(),
                sort_key,
            });
        }
        let sorted = heap.into_sorted();
        Ok(slice_offset_limit(sorted, limit, offset))
    }

    /// M4: index-ordered early-stop sort. When a query's sort field is covered
    /// by a single-field durable index, the composite index keys are already
    /// ordered by `(value, recordId)` — the same order Dart's stable sort of
    /// that field produces. This streams the index range `[start..=end]`,
    /// joins each entry to its row, applies [predicate_bytes], and stops once
    /// `offset + limit` matches are collected — no full scan, no sort.
    ///
    /// Two calling modes (the Dart side routes accordingly):
    /// - [eq_bounded] = true: `start..=end` is an equality bound on the sort
    ///   field, so every matching row's sort key is equal and index-key order
    ///   (recordId) is exactly the stable Dart order for both directions.
    /// - [eq_bounded] = false: `start..=end` covers all values of [sort_field]
    ///   (ascending order only). Rows missing the field sort LAST for
    ///   ascending; if the index stream is exhausted before the window fills,
    ///   a table scan appends the missing-field matching rows (stable order).
    ///   Descending without an eq bound is NOT routed here (caller uses
    ///   [Self::query_sorted], which handles missing-first correctly).
    #[allow(clippy::too_many_arguments)]
    pub fn query_indexed_ordered(
        &self,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        sort_field: &str,
        eq_bounded: bool,
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_ordered_with(
            &transaction,
            table,
            index_table,
            start,
            end,
            predicate_bytes,
            sort_field,
            eq_bounded,
            limit,
            offset,
        )
    }

    /// Snapshot-bound variant of [Self::query_indexed_ordered].
    #[allow(clippy::too_many_arguments)]
    pub fn snapshot_query_indexed_ordered(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        sort_field: &str,
        eq_bounded: bool,
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_ordered_with(
            transaction,
            table,
            index_table,
            start,
            end,
            predicate_bytes,
            sort_field,
            eq_bounded,
            limit,
            offset,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn query_indexed_ordered_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        sort_field: &str,
        eq_bounded: bool,
        limit: Option<u64>,
        offset: u64,
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        use crate::value_codec::find_field;
        let predicate = crate::predicate::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                // No durable index yet (e.g. an empty index table): the
                // ordered result for the non-eq mode is every matching row in
                // recordId order (they all lack index entries). Fall back to
                // the full top-K sort, which is correct in all cases.
                if eq_bounded {
                    return Ok(Vec::new());
                }
                let fallback_spec =
                    crate::sort_spec::encode_sort_specs(&[crate::sort_spec::SortSpec {
                        field: sort_field.to_string(),
                        descending: false,
                    }]);
                return self.query_sorted_with(
                    transaction,
                    table,
                    predicate_bytes,
                    &fallback_spec,
                    limit,
                    offset,
                );
            }
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => return Ok(Vec::new()),
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        };
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        let mut matches: Vec<ByteEntry> = Vec::new();
        let mut matched_keys: Vec<Vec<u8>> = Vec::new();
        for entry in index_table
            .range(start..=end)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
        {
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_key = entry.1.value();
            let Some(row_bytes) = user_table
                .get(row_key)
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .map(|v| v.value().to_vec())
            else {
                continue;
            };
            if !predicate.test_bytes(&row_bytes) {
                continue;
            }
            matched_keys.push(row_key.to_vec());
            matches.push((row_key.to_vec(), row_bytes));
            if let Some(want) = want {
                if matches.len() as u64 >= want {
                    break;
                }
            }
        }
        // Non-eq mode: if the index stream did not fill the window, the rows
        // missing `sort_field` (which sort LAST for ascending) must be
        // appended. They are found with a table scan (stable recordId order,
        // matching Dart's stable sort of ties). In eq-bounded mode every
        // matching row carries the sort field, so no append is needed.
        let needs_append = !eq_bounded && want.is_some_and(|w| (matches.len() as u64) < w);
        if needs_append {
            let mut present = std::collections::HashSet::new();
            for k in &matched_keys {
                present.insert(k.clone());
            }
            for entry in user_table
                .iter()
                .map_err(|error| WorkerError::Storage(error.to_string()))?
            {
                let (key, value) =
                    entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                let key_bytes = key.value().to_vec();
                if present.contains(&key_bytes) {
                    continue;
                }
                let row_bytes = value.value();
                if !predicate.test_bytes(row_bytes) {
                    continue;
                }
                let has_field = find_field(row_bytes, sort_field)
                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                    .is_some();
                if has_field {
                    // The row carries the field but has no index entry — not a
                    // missing-field row; skip (should not happen when the
                    // durable index is maintained atomically).
                    continue;
                }
                matches.push((key_bytes, row_bytes.to_vec()));
                if let Some(want) = want {
                    if matches.len() as u64 >= want {
                        break;
                    }
                }
            }
        }
        if offset > 0 {
            let start_idx = (offset as usize).min(matches.len());
            matches = matches.split_off(start_idx);
        }
        Ok(matches)
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

    // M3: shared row/encoder helpers used by the new aggregate + get_many
    // tests. Keeps the test rows byte-identical to the query_filtered suite.
    fn encode_test_row(entries: &[(&str, Vec<u8>)]) -> Vec<u8> {
        use crate::value_codec::{TAG_MAP, TAG_STRING};
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
    fn encode_test_int64(n: i64) -> Vec<u8> {
        use crate::value_codec::TAG_INT64;
        let mut out = vec![TAG_INT64];
        out.extend_from_slice(&n.to_be_bytes());
        out
    }
    fn encode_test_string(s: &str) -> Vec<u8> {
        use crate::value_codec::TAG_STRING;
        let mut out = vec![TAG_STRING];
        let b = s.as_bytes();
        out.extend_from_slice(&(b.len() as u32).to_be_bytes());
        out.extend_from_slice(b);
        out
    }
    // Seeds the same 4 rows used by `query_filtered_returns_only_matching_rows`
    // (g0/g0/g1/g1, ages 10/20/30/40) into `items` and returns the file path
    // so the caller can clean up.
    fn seed_aggregate_fixture(label: &str) -> (std::path::PathBuf, RedbWorker) {
        let path = temp_path(label);
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let rows = [
            (
                b"k0".to_vec(),
                encode_test_row(&[
                    ("g", encode_test_string("g0")),
                    ("age", encode_test_int64(10)),
                ]),
            ),
            (
                b"k1".to_vec(),
                encode_test_row(&[
                    ("g", encode_test_string("g0")),
                    ("age", encode_test_int64(20)),
                ]),
            ),
            (
                b"k2".to_vec(),
                encode_test_row(&[
                    ("g", encode_test_string("g1")),
                    ("age", encode_test_int64(30)),
                ]),
            ),
            (
                b"k3".to_vec(),
                encode_test_row(&[
                    ("g", encode_test_string("g1")),
                    ("age", encode_test_int64(40)),
                ]),
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
        (path, worker)
    }

    #[test]
    fn get_many_returns_existing_rows_and_omits_absent() {
        let (path, mut worker) = seed_aggregate_fixture("getmany");
        // k1 and k3 exist; kX is absent; an empty keys list is a no-op.
        let keys: Vec<&[u8]> = vec![b"k1", b"kX", b"k3"];
        let got = worker.get_many("items", &keys).unwrap();
        assert_eq!(got.len(), 2);
        // Only existing rows appear, in input order.
        assert_eq!(got[0].0, b"k1");
        assert_eq!(got[1].0, b"k3");

        // An empty keys list returns an empty result.
        let empty = worker.get_many("items", &[]).unwrap();
        assert!(empty.is_empty());
        // A missing table is an empty result, never an error.
        let missing_table = worker.get_many("nope", &[b"k1"]).unwrap();
        assert!(missing_table.is_empty());

        // Snapshot-bound variant observes the same state.
        let snap = worker.create_snapshot().unwrap();
        let snap_got = worker.snapshot_get_many(snap, "items", &keys).unwrap();
        assert_eq!(snap_got.len(), 2);
        worker.drop_snapshot(snap);

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_filtered_count_counts_matches_without_transfer() {
        use crate::predicate::{self, Filter};
        use crate::value_codec::RowValue;
        let (path, mut worker) = seed_aggregate_fixture("qfc");
        // g == "g0" AND age >= 15 → 1 row (k1).
        let pred = predicate::encode_predicate(&[
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
        assert_eq!(worker.query_filtered_count("items", &pred).unwrap(), 1);

        // g == "g1" → 2 rows (k2, k3).
        let g1 = predicate::encode_predicate(&[Filter::Equals {
            field: "g".into(),
            value: RowValue::String("g1".into()),
        }]);
        assert_eq!(worker.query_filtered_count("items", &g1).unwrap(), 2);

        // Empty predicate matches all 4.
        assert_eq!(
            worker
                .query_filtered_count("items", &predicate::encode_predicate(&[]))
                .unwrap(),
            4
        );
        // A missing table counts as zero, never an error.
        assert_eq!(worker.query_filtered_count("nope", &pred).unwrap(), 0);

        // Snapshot-bound variant agrees with the live count.
        let snap = worker.create_snapshot().unwrap();
        assert_eq!(
            worker
                .snapshot_query_filtered_count(snap, "items", &g1)
                .unwrap(),
            2
        );
        worker.drop_snapshot(snap);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_filtered_distinct_emits_only_field_bytes() {
        use crate::predicate::{self, Filter};
        use crate::value_codec::{self, RowValue};
        let (path, mut worker) = seed_aggregate_fixture("qfd");
        // Distinct `g` across all rows → {g0, g1}. The distinct pushdown
        // emits the encoded value bytes per matching row; check the decoded
        // set is exactly {g0, g1} and is unsorted (the caller dedups).
        let empty_pred = predicate::encode_predicate(&[]);
        let field_bytes = worker
            .query_filtered_distinct("items", &empty_pred, "g")
            .unwrap();
        // M3 contract: the pushdown emits the field's bytes for EACH
        // matching row (NOT deduped) — the Dart caller dedups. With 4 seeded
        // rows that all have `g`, we get 4 byte slices that decode to
        // g0/g0/g1/g1.
        let values: Vec<RowValue> = field_bytes
            .iter()
            .map(|b| value_codec::decode_value(b).unwrap())
            .collect();
        assert_eq!(
            values,
            vec![
                RowValue::String("g0".into()),
                RowValue::String("g0".into()),
                RowValue::String("g1".into()),
                RowValue::String("g1".into()),
            ]
        );

        // Distinct `age` for g0 → {10, 20}.
        let g0_pred = predicate::encode_predicate(&[Filter::Equals {
            field: "g".into(),
            value: RowValue::String("g0".into()),
        }]);
        let age_bytes = worker
            .query_filtered_distinct("items", &g0_pred, "age")
            .unwrap();
        // g0 has 2 rows (ages 10, 20) — both emitted, undeduped.
        let mut ages: Vec<i64> = age_bytes
            .iter()
            .map(|b| match value_codec::decode_value(b).unwrap() {
                RowValue::Int64(n) => n,
                _ => panic!("expected int64"),
            })
            .collect();
        ages.sort();
        assert_eq!(ages, vec![10, 20]);

        // A row missing the requested field is omitted from the stream (a
        // missing field is not a distinct value). Seed a row without `g`.
        let no_g_row = encode_test_row(&[("age", encode_test_int64(99))]);
        worker
            .apply_batch(&[Op {
                kind: OpKind::Put,
                table: "items".into(),
                key: Some(b"k4".to_vec()),
                value: Some(no_g_row),
                start: None,
                end: None,
            }])
            .unwrap();
        // Distinct `g` now still emits 5 byte slices (4 with g + the
        // missing-field row is skipped), verifying the missing-field skip.
        let after_missing = worker
            .query_filtered_distinct("items", &empty_pred, "g")
            .unwrap();
        assert_eq!(
            after_missing.len(),
            4,
            "missing-field row skipped, 4 rows with g remain"
        );

        // A missing table is an empty result, never an error.
        let missing_table = worker
            .query_filtered_distinct("nope", &empty_pred, "g")
            .unwrap();
        assert!(missing_table.is_empty());
        let _ = std::fs::remove_file(path);
    }

    // ── M4: early limit/offset + sorted + index-ordered ────────────────────

    /// The durable-index composite key `encode([table, field, value, recordId])`
    /// (a 4-element codec list) for the test table.
    fn index_key(table: &str, field: &str, value: &[u8], record_id: &[u8]) -> Vec<u8> {
        use crate::value_codec::TAG_LIST;
        let mut out = vec![TAG_LIST];
        out.extend_from_slice(&4u32.to_be_bytes());
        out.extend_from_slice(&encode_test_string(table));
        out.extend_from_slice(&encode_test_string(field));
        out.extend_from_slice(value);
        out.extend_from_slice(record_id);
        out
    }

    /// Seeds rows with an `age` field (values 10..=40 step 10 on k0..k3) plus
    /// one row without `age` (k4), and a durable `__gecko_index` entry for the
    /// `age` field of every row that has it. Returns the file path.
    fn seed_indexed_age_fixture(label: &str) -> (std::path::PathBuf, RedbWorker) {
        let path = temp_path(label);
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // (key, age-value bytes, row bytes)
        let rows: Vec<(Vec<u8>, Vec<u8>, Vec<u8>)> = [
            (b"k0".to_vec(), encode_test_int64(10)),
            (b"k1".to_vec(), encode_test_int64(20)),
            (b"k2".to_vec(), encode_test_int64(30)),
            (b"k3".to_vec(), encode_test_int64(40)),
        ]
        .iter()
        .map(|(k, age)| {
            let row = encode_test_row(&[("age", age.clone()), ("nick", encode_test_string("g0"))]);
            (k.clone(), age.clone(), row)
        })
        .collect();
        // k4 has a nick but NO age (missing-field row).
        let missing_row = encode_test_row(&[("nick", encode_test_string("g1"))]);
        let mut ops: Vec<Op> = rows
            .iter()
            .map(|(k, _, v)| Op {
                kind: OpKind::Put,
                table: "items".into(),
                key: Some(k.clone()),
                value: Some(v.clone()),
                start: None,
                end: None,
            })
            .collect();
        ops.push(Op {
            kind: OpKind::Put,
            table: "items".into(),
            key: Some(b"k4".to_vec()),
            value: Some(missing_row),
            start: None,
            end: None,
        });
        // Durable index entries for `age` on k0..k3: key = [items, age, value, id].
        for (k, age, _) in &rows {
            ops.push(Op {
                kind: OpKind::Put,
                table: "__gecko_index".into(),
                key: Some(index_key("items", "age", age, k)),
                value: Some(k.clone()),
                start: None,
                end: None,
            });
        }
        // Also index nick so M5 tests can intersect two different fields.
        for k in [
            b"k0".to_vec(),
            b"k1".to_vec(),
            b"k2".to_vec(),
            b"k3".to_vec(),
        ] {
            ops.push(Op {
                kind: OpKind::Put,
                table: "__gecko_index".into(),
                key: Some(index_key("items", "nick", &encode_test_string("g0"), &k)),
                value: Some(k),
                start: None,
                end: None,
            });
        }
        ops.push(Op {
            kind: OpKind::Put,
            table: "__gecko_index".into(),
            key: Some(index_key("items", "nick", &encode_test_string("g1"), b"k4")),
            value: Some(b"k4".to_vec()),
            start: None,
            end: None,
        });
        worker.apply_batch(&ops).unwrap();
        (path, worker)
    }

    /// Field bounds for all `age` entries of `items` (the 4-element prefix
    /// `0x06 | u32(4) | encode("items") | encode("age")`, upper-bounded by the
    /// incremented last byte).
    fn age_field_bounds() -> (Vec<u8>, Vec<u8>) {
        let full = index_key(
            "items",
            "age",
            &[crate::value_codec::TAG_NULL],
            &[crate::value_codec::TAG_NULL],
        );
        // strip two trailing null tag bytes to get the shared 2-element prefix
        let prefix = full[0..full.len() - 2].to_vec();
        let mut end = prefix.clone();
        let mut i = end.len() - 1;
        while i > 0 && end[i] == 0xFF {
            end.pop();
            i -= 1;
        }
        let last = end.pop().unwrap();
        end.push(last + 1);
        (prefix, end)
    }

    #[test]
    fn query_filtered_limited_skips_and_stops_early() {
        use crate::predicate::{self, Filter};
        use crate::value_codec::RowValue;
        let (path, worker) = seed_aggregate_fixture("qfl");
        // Empty predicate; limit 2, offset 1 → k1, k2 (skip k0, take 2).
        let got = worker
            .query_filtered_limited("items", &predicate::encode_predicate(&[]), Some(2), 1)
            .unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].0, b"k1");
        assert_eq!(got[1].0, b"k2");
        // No limit → all 4.
        let all = worker
            .query_filtered_limited("items", &predicate::encode_predicate(&[]), None, 0)
            .unwrap();
        assert_eq!(all.len(), 4);
        // Offset beyond the result set → empty.
        let beyond = worker
            .query_filtered_limited("items", &predicate::encode_predicate(&[]), Some(2), 10)
            .unwrap();
        assert!(beyond.is_empty());
        // With a predicate: g0 → k0,k1; limit 1 → k0.
        let g0 = predicate::encode_predicate(&[Filter::Equals {
            field: "g".into(),
            value: RowValue::String("g0".into()),
        }]);
        let one = worker
            .query_filtered_limited("items", &g0, Some(1), 0)
            .unwrap();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].0, b"k0");
        // Missing table → empty.
        assert!(worker
            .query_filtered_limited("nope", &predicate::encode_predicate(&[]), Some(1), 0)
            .unwrap()
            .is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_sorted_topk_matches_dart_order() {
        use crate::sort_spec::{encode_sort_specs, SortSpec};
        let (path, worker) = seed_indexed_age_fixture("qsorted");
        let empty_pred = crate::predicate::encode_predicate(&[]);
        // Sort ascending by age: k0(10), k1(20), k2(30), k3(40), then k4(missing).
        let asc = encode_sort_specs(&[SortSpec {
            field: "age".into(),
            descending: false,
        }]);
        let got = worker
            .query_sorted("items", &empty_pred, &asc, Some(5), 0)
            .unwrap();
        let keys: Vec<&[u8]> = got.iter().map(|e| e.0.as_slice()).collect();
        assert_eq!(
            keys,
            vec![&b"k0"[..], &b"k1"[..], &b"k2"[..], &b"k3"[..], &b"k4"[..]]
        );
        // limit 2 → k0, k1; offset 2 → k2, k3.
        let lim = worker
            .query_sorted("items", &empty_pred, &asc, Some(2), 0)
            .unwrap();
        assert_eq!(lim.len(), 2);
        assert_eq!(lim[0].0, b"k0");
        assert_eq!(lim[1].0, b"k1");
        let off = worker
            .query_sorted("items", &empty_pred, &asc, Some(2), 2)
            .unwrap();
        assert_eq!(off[0].0, b"k2");
        assert_eq!(off[1].0, b"k3");
        // Descending: missing (k4) FIRST, then 40, 30, 20, 10.
        let desc = encode_sort_specs(&[SortSpec {
            field: "age".into(),
            descending: true,
        }]);
        let d = worker
            .query_sorted("items", &empty_pred, &desc, Some(5), 0)
            .unwrap();
        let dkeys: Vec<&[u8]> = d.iter().map(|e| e.0.as_slice()).collect();
        assert_eq!(
            dkeys,
            vec![&b"k4"[..], &b"k3"[..], &b"k2"[..], &b"k1"[..], &b"k0"[..]]
        );
        // Predicate filter: age > 15 → k1,k2,k3 sorted asc (k4 has no age → filtered out).
        let gt15 = crate::predicate::encode_predicate(&[crate::predicate::Filter::Range {
            field: "age".into(),
            min: Some(crate::value_codec::RowValue::Int64(16)),
            max: None,
        }]);
        let g = worker
            .query_sorted("items", &gt15, &asc, Some(5), 0)
            .unwrap();
        let gkeys: Vec<&[u8]> = g.iter().map(|e| e.0.as_slice()).collect();
        assert_eq!(gkeys, vec![&b"k1"[..], &b"k2"[..], &b"k3"[..]]);
        // limit 0 → empty.
        assert!(worker
            .query_sorted("items", &empty_pred, &asc, Some(0), 0)
            .unwrap()
            .is_empty());
        // Missing table → empty.
        assert!(worker
            .query_sorted("nope", &empty_pred, &asc, Some(1), 0)
            .unwrap()
            .is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_streams_early_and_appends_missing() {
        let (path, worker) = seed_indexed_age_fixture("qio");
        let empty_pred = crate::predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        // Ascending, no eq bound: index order k0..k3, then missing k4 appended.
        let got = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                Some(5),
                0,
            )
            .unwrap();
        let keys: Vec<&[u8]> = got.iter().map(|e| e.0.as_slice()).collect();
        assert_eq!(
            keys,
            vec![&b"k0"[..], &b"k1"[..], &b"k2"[..], &b"k3"[..], &b"k4"[..]]
        );
        // Early-stop: limit 2 → k0, k1 (no missing append needed).
        let lim = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                Some(2),
                0,
            )
            .unwrap();
        assert_eq!(lim.len(), 2);
        assert_eq!(lim[0].0, b"k0");
        assert_eq!(lim[1].0, b"k1");
        // Offset 2 → k2, k3.
        let off = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                Some(2),
                2,
            )
            .unwrap();
        assert_eq!(off[0].0, b"k2");
        assert_eq!(off[1].0, b"k3");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_multi_intersects_and_rechecks_predicate() {
        use crate::predicate::{self, Filter};
        use crate::value_codec::RowValue;
        let (path, worker) = seed_indexed_age_fixture("qmulti");
        let age_bounds = age_field_bounds();
        let nick_full = index_key(
            "items",
            "nick",
            &[crate::value_codec::TAG_NULL],
            &[crate::value_codec::TAG_NULL],
        );
        let nick_start = nick_full[..nick_full.len() - 2].to_vec();
        let mut nick_end = nick_start.clone();
        let last = nick_end.pop().unwrap();
        nick_end.push(last + 1);
        let predicate = predicate::encode_predicate(&[
            Filter::Range {
                field: "age".into(),
                min: Some(RowValue::Int64(15)),
                max: Some(RowValue::Int64(35)),
            },
            Filter::Equals {
                field: "nick".into(),
                value: RowValue::String("g0".into()),
            },
        ]);
        let got = worker
            .query_indexed_multi(
                "items",
                "__gecko_index",
                &[age_bounds, (nick_start, nick_end)],
                &predicate,
            )
            .unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].0, b"k1");
        assert_eq!(got[1].0, b"k2");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_limited_windows_an_eq_bound() {
        use crate::predicate::{self, Filter};
        use crate::value_codec::RowValue;
        let (path, worker) = seed_indexed_age_fixture("qil");
        // Eq bound for age == 20 (only k1).
        let mut full = index_key(
            "items",
            "age",
            &encode_test_int64(20),
            &[crate::value_codec::TAG_NULL],
        );
        full.pop(); // strip trailing null → shared prefix
        let mut end = full.clone();
        let mut i = end.len() - 1;
        while i > 0 && end[i] == 0xFF {
            end.pop();
            i -= 1;
        }
        let last = end.pop().unwrap();
        end.push(last + 1);
        let eq_pred = predicate::encode_predicate(&[Filter::Equals {
            field: "age".into(),
            value: RowValue::Int64(20),
        }]);
        // Sanity: the plain M2 join over the same bounds must find k1.
        let joined = worker
            .query_indexed("items", "__gecko_index", &full, &end)
            .unwrap();
        assert_eq!(joined.len(), 1, "index bounds must reach the age=20 entry");
        assert_eq!(joined[0].0, b"k1");
        let got = worker
            .query_indexed_limited("items", "__gecko_index", &full, &end, &eq_pred, Some(10), 0)
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, b"k1");
        // limit 0 → empty.
        assert!(worker
            .query_indexed_limited("items", "__gecko_index", &full, &end, &eq_pred, Some(0), 0,)
            .unwrap()
            .is_empty());
        let _ = std::fs::remove_file(path);
    }
}
