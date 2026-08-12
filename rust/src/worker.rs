//! File-backed redb worker core.
//!
//! This module is deliberately independent of flutter_rust_bridge. It owns one
//! `redb::Database` handle and applies each batch in exactly one write
//! transaction. FRB/native bindings can expose this worker without changing its
//! atomicity or error behavior.

use redb::{
    backends::FileBackend,
    Database,
    DatabaseError,
    ReadOnlyDatabase,
    ReadTransaction,
    ReadableDatabase,
    ReadableTable,
    ReadableTableMetadata,
    Table,
    TableDefinition,
    TableHandle,
    WriteTransaction,
};
use std::collections::{ BTreeMap, BTreeSet, HashMap, HashSet };
use std::fs::OpenOptions;
use std::path::{ Path, PathBuf };
use std::sync::{ Mutex, OnceLock };

use crate::counters::AtomicCounters;
pub use crate::counters::WorkCounters;
use crate::crypto_storage::EncryptingStorageBackend;
use crate::wire::{ Op, OpKind, WireError };

const TABLE_PREFIX: &str = "__gecko_user_";

pub(crate) type BytesTable = TableDefinition<'static, &'static [u8], &'static [u8]>;
/// One open mutable table handle inside a single write transaction. Handles
/// are cached per batch so a large batch opens each table at most once.
type WriteTableCache<'txn> = HashMap<String, Table<'txn, &'static [u8], &'static [u8]>>;
pub type ByteEntry = (Vec<u8>, Vec<u8>);

/// Process-global interner for full table names (`__gecko_user_<name>` and
/// the reserved `__gecko_*` tables). Every unique name is leaked exactly once
/// and shared by every `table_definition` call site (reads, writes, indexes,
/// registry, stats). Memory is bounded by the number of distinct tables ever
/// referenced and never grows with operation count. `Mutex` contention is
/// negligible: the critical section is one short-string hash lookup.
static TABLE_NAME_CACHE: OnceLock<Mutex<HashSet<&'static str>>> = OnceLock::new();

/// Leaks [full_name] once and returns the shared `'static` copy; repeated
/// calls for the same name return the existing allocation.
fn intern_table_name(full_name: String) -> &'static str {
    let cache = TABLE_NAME_CACHE.get_or_init(|| Mutex::new(HashSet::new()));
    let mut guard = cache.lock().expect("table-name intern lock");
    if let Some(existing) = guard.get(full_name.as_str()).copied() {
        return existing;
    }
    let leaked: &'static str = Box::leak(full_name.into_boxed_str());
    guard.insert(leaked);
    leaked
}

/// one group of child rows sharing the same foreign-key value (parent
/// id). The worker classifies matching child rows by FK so Dart receives
/// pre-grouped candidates instead of re-decoding each row's FK field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupedChildEntries {
    /// The encoded foreign-key value (the parent id bytes).
    pub parent_id: Vec<u8>,
    /// Child rows in row-key order whose FK equals [parent_id].
    pub entries: Vec<ByteEntry>,
}

/// the outcome of one committed batch — the worker sequence plus
/// one [`crate::registry::RegistryDelta`] per touched live registration.
#[derive(Debug, Clone)]
pub struct ApplyBatchOutcome {
    pub sequence: u64,
    pub deltas: Vec<crate::registry::RegistryDelta>,
    /// Positional previous values requested by the caller. A null entry means
    /// the key was absent immediately before that operation.
    pub previous_values: Vec<Option<Vec<u8>>>,
    /// Every primary key actually removed by delete-range or clear, grouped by
    /// operation order. The Dart adapter uses these to report affected keys
    /// without a separate pre-write snapshot scan.
    pub removed_keys: Vec<(String, Vec<u8>)>,
}

/// Dart-authored metadata completed inside the same Rust write transaction as
/// its associated data operation.
#[derive(Debug, Clone)]
pub struct PreparedChangeTemplate {
    pub operation_index: usize,
    pub ordinal: u64,
    pub sync_state_key: Vec<u8>,
    pub record_template: Vec<u8>,
    pub fill_previous_version: bool,
}

/// Storage-level size/health report
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
    KeyNotFound(String),
    DatabaseLocked(String),
}

impl std::fmt::Display for WorkerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Storage(message) => write!(f, "storage error: {message}"),
            Self::Wire(message) => write!(f, "wire error: {message}"),
            Self::InvalidOperation(message) => write!(f, "invalid operation: {message}"),
            Self::KeyNotFound(message) => write!(f, "key not found: {message}"),
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
    #[cfg_attr(target_arch = "wasm32", allow(dead_code))] ReadOnly(ReadOnlyDatabase),
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
    /// live-query registry Non-durable; dies with the worker.
    registry: crate::registry::LiveRegistry,
    /// Session-scoped composite durable-index declarations (table → ordered
    /// field lists). Sent once per session by the Dart facade; `apply_batch`
    /// merges them with the flat per-batch `index_definitions` so composite
    /// keys are maintained atomically with the rows they index.
    composite_index_plan: HashMap<String, Vec<Vec<String>>>,
    /// Physical-work counters; only touched while enabled (zero-cost off).
    counters: AtomicCounters,
}

/// A candidate row held by the top-K sort heap: the record key, the raw row
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
                if
                    left < len &&
                    (self.cmp)(&self.items[left], &self.items[largest]) ==
                        std::cmp::Ordering::Greater
                {
                    largest = left;
                }
                if
                    right < len &&
                    (self.cmp)(&self.items[right], &self.items[largest]) ==
                        std::cmp::Ordering::Greater
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
                if
                    left < len &&
                    (self.cmp)(&self.items[left], &self.items[largest]) ==
                        std::cmp::Ordering::Greater
                {
                    largest = left;
                }
                if
                    right < len &&
                    (self.cmp)(&self.items[right], &self.items[largest]) ==
                        std::cmp::Ordering::Greater
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
        Some(l) => offset.saturating_add(l).min(len) as usize,
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
    specs: &[crate::sort_spec::SortSpec]
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
                    ReadOnlyDatabase::open(&path).map_err(|error|
                        map_open_error(error, &path_display)
                    )?
                )
            } else {
                WorkerDatabase::ReadWrite(
                    Database::create(&path).map_err(|error| map_open_error(error, &path_display))?
                )
            };
            let commit_sequence = load_commit_sequence(&database)?;
            Ok(Self {
                database,
                path: path_buf,
                commit_sequence,
                read_only,
                snapshots: HashMap::new(),
                next_snapshot_id: 0,
                registry: crate::registry::LiveRegistry::new(),
                composite_index_plan: HashMap::new(),
                counters: AtomicCounters::default(),
            })
        }
    }

    /// Opens a database over an OPFS sync-access handle (wasm32 only). See the
    /// module-level docs on `crate::opfs` for the acquisition protocol.
    ///
    /// there is no in-memory or `:memory:` mode. Every supported web
    /// store is an OPFS file, so the worker must have an OPFS sync-access
    /// handle registered for the path before opening.
    #[cfg(target_arch = "wasm32")]
    fn open_wasm_opfs(path: &Path, read_only: bool) -> Result<Self, WorkerError> {
        let path_display = path.display().to_string();
        let handle = crate::opfs
            ::take_handle_for_path(&path_display)
            .ok_or_else(|| {
                WorkerError::InvalidOperation(
                    format!(
                        "no OPFS sync-access handle registered for {path_display}; \
                 the web worker must acquire and register it before opening"
                    )
                )
            })?;
        let backend = crate::opfs::WasmOpfsBackend::new(handle, path_display.clone());
        let database = Database::builder()
            .create_with_backend(backend)
            .map_err(|error| map_open_error(error, &path_display))?;
        let database = WorkerDatabase::ReadWrite(database);
        let commit_sequence = load_commit_sequence(&database)?;
        Ok(Self {
            database,
            path: path.to_path_buf(),
            commit_sequence,
            read_only,
            snapshots: HashMap::new(),
            next_snapshot_id: 0,
            registry: crate::registry::LiveRegistry::new(),
            composite_index_plan: HashMap::new(),
            counters: AtomicCounters::default(),
        })
    }

    /// Creates or opens an *encrypted* database Every physical
    /// page is AES-256-GCM authenticated under [key] (32 bytes). The key is
    /// held only in this worker's memory and never written to disk. Only
    /// read-write mode is supported for encrypted files.
    pub fn open_encrypted(
        path: impl AsRef<Path>,
        key: &[u8],
        key_gen: u8
    ) -> Result<Self, WorkerError> {
        let path_display = path.as_ref().display().to_string();
        let path_buf = path.as_ref().to_path_buf();
        if key.len() != 32 {
            return Err(
                WorkerError::InvalidOperation(
                    "encryption key must be exactly 32 bytes (AES-256)".into()
                )
            );
        }
        let mut key_bytes = [0u8; 32];
        key_bytes.copy_from_slice(key);
        // Resolve any interrupted rotation before opening so the file is
        // consistent under whichever key the caller holds.
        crate::crypto_storage
            ::recover_rotation(path.as_ref(), key_gen)
            .map_err(|error| {
                WorkerError::Storage(
                    format!("rotation recovery failed for {path_display}: {error}")
                )
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
            Box::new(
                FileBackend::new(file).map_err(|error| {
                    WorkerError::Storage(
                        format!("could not initialize file backend for {path_display}: {error}")
                    )
                })?
            ),
            key_bytes,
            key_gen
        );
        let database = Database::builder()
            .create_with_backend(backend)
            .map_err(|error| map_open_error(error, &path_display))?;
        let database = WorkerDatabase::ReadWrite(database);
        let commit_sequence = load_commit_sequence(&database)?;
        Ok(Self {
            database,
            path: path_buf,
            commit_sequence,
            read_only: false,
            snapshots: HashMap::new(),
            next_snapshot_id: 0,
            registry: crate::registry::LiveRegistry::new(),
            composite_index_plan: HashMap::new(),
            counters: AtomicCounters::default(),
        })
    }

    fn begin_read(&self) -> Result<ReadTransaction, WorkerError> {
        match &self.database {
            WorkerDatabase::ReadWrite(database) =>
                database.begin_read().map_err(|error| WorkerError::Storage(error.to_string())),
            WorkerDatabase::ReadOnly(database) =>
                database.begin_read().map_err(|error| WorkerError::Storage(error.to_string())),
        }
    }

    /// Starts recording physical-work counters. No-op-safe: counters already
    /// enabled stay enabled. Draining happens via [Self::take_counters].
    pub fn enable_counters(&self) {
        self.counters.set_enabled(true);
    }

    /// Stops recording and resets all counters to zero.
    pub fn disable_counters(&self) {
        self.counters.set_enabled(false);
    }

    /// Snapshots the physical-work counters accumulated since the last call
    /// and resets them to zero. Works whether or not counters are enabled
    /// (returns a zeroed snapshot when disabled).
    pub fn take_counters(&self) -> WorkCounters {
        self.counters.snapshot_take()
    }

    /// Whether physical-work counters are currently being recorded.
    pub fn counters_enabled(&self) -> bool {
        self.counters.is_enabled()
    }

    /// Applies an operation batch without user index declarations. This is
    /// retained for Rust-level generic batch callers and tests.
    pub fn apply_batch(&mut self, operations: &[Op]) -> Result<u64, WorkerError> {
        self.apply_batch_with_indexes(operations, &[])
    }

    /// Applies an entire operation batch in exactly one write transaction.
    ///
    /// [index_definitions] contains the native collection declarations known
    /// to the Dart facade. Rust derives the old and new field payloads from
    /// encoded primary rows and updates `__gecko_index` before committing the
    /// same transaction. The operation wire format remains unchanged.
    pub fn apply_batch_with_indexes(
        &mut self,
        operations: &[Op],
        index_definitions: &[(String, Vec<String>)]
    ) -> Result<u64, WorkerError> {
        self.apply_batch_reactive(operations, index_definitions).map(|result| result.sequence)
    }

    /// applies a batch and also evaluates every touched live
    /// registration, returning the worker sequence plus one
    /// [`crate::registry::RegistryDelta`] per registration. The reactive
    /// registry is updated in the same write transaction the batch commits in.
    pub fn apply_batch_reactive(
        &mut self,
        operations: &[Op],
        index_definitions: &[(String, Vec<String>)]
    ) -> Result<ApplyBatchOutcome, WorkerError> {
        self.apply_batch_impl(operations, index_definitions, 0, &[], &[], &[], true)
    }

    /// /like [Self::apply_batch_reactive], but also prunes the
    /// pending-sync change log in the same transaction when the batch touched
    /// it and [change_log_max_entries] (0 = disabled) is exceeded.
    pub fn apply_batch_reactive_with_retention(
        &mut self,
        operations: &[Op],
        index_definitions: &[(String, Vec<String>)],
        change_log_max_entries: u64
    ) -> Result<ApplyBatchOutcome, WorkerError> {
        self.apply_batch_impl(
            operations,
            index_definitions,
            change_log_max_entries,
            &[],
            &[],
            &[],
            true
        )
    }

    /// Applies a prepared batch. The operation wire format remains unchanged;
    /// the additional positional metadata is supplied beside it so old web
    /// and native artifacts can continue to decode ordinary batches.
    pub fn apply_prepared_batch(
        &mut self,
        operations: &[Op],
        index_definitions: &[(String, Vec<String>)],
        change_log_max_entries: u64,
        previous_operation_indexes: &[usize],
        put_modes: &[(usize, u8)],
        change_templates: &[PreparedChangeTemplate]
    ) -> Result<ApplyBatchOutcome, WorkerError> {
        self.apply_batch_impl(
            operations,
            index_definitions,
            change_log_max_entries,
            previous_operation_indexes,
            put_modes,
            change_templates,
            false
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn apply_batch_impl(
        &mut self,
        operations: &[Op],
        index_definitions: &[(String, Vec<String>)],
        change_log_max_entries: u64,
        previous_operation_indexes: &[usize],
        put_modes: &[(usize, u8)],
        change_templates: &[PreparedChangeTemplate],
        legacy_metadata: bool
    ) -> Result<ApplyBatchOutcome, WorkerError> {
        if self.read_only {
            return Err(
                WorkerError::InvalidOperation(
                    "database is read-only; writes are not allowed".into()
                )
            );
        }
        let transaction = match &self.database {
            WorkerDatabase::ReadWrite(database) =>
                database.begin_write().map_err(|error| WorkerError::Storage(error.to_string()))?,
            WorkerDatabase::ReadOnly(_) => unreachable!("read-only worker rejected above"),
        };

        // Validate all operation shapes before allocating metadata. A
        // malformed batch must not create an otherwise empty metadata table or
        // consume a sequence number before redb rolls the transaction back.
        validate_write_operations(operations)?;

        // Allocate the durable sequence inside this write transaction. The
        // metadata row is read and written before any caller operations so a
        // failed batch rolls the sequence back together with the data. The
        // maintenance marker is deliberately sequence-neutral: it is an
        // internal state marker, not a database mutation visible to sync.
        let sequence_neutral =
            legacy_metadata &&
            !operations.is_empty() &&
            operations.iter().all(|operation| { operation.table == "__gecko_maintenance" });
        let sequence = if sequence_neutral {
            self.commit_sequence
        } else {
            next_sequence_in_write_transaction(&transaction, self.commit_sequence)?
        };
        if !sequence_neutral {
            let mut sync_meta = transaction
                .open_table(table_definition("__gecko_sync_meta"))
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            let lsn_key = lsn_key();
            let lsn_value = lsn_value(sequence);
            sync_meta
                .insert(lsn_key.as_slice(), lsn_value.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            drop(sync_meta);
        }

        let change_log_touched =
            !change_templates.is_empty() ||
            operations.iter().any(|operation| operation.table == "__gecko_change_log");

        // Pre-build the operation-index → previous-value slot map once so the
        // hot loop never performs an O(n) scan per operation.
        let mut previous_slots: HashMap<usize, usize> =
            HashMap::with_capacity(previous_operation_indexes.len());
        for (slot, index) in previous_operation_indexes.iter().enumerate() {
            previous_slots.insert(*index, slot);
        }

        // Per-batch transaction table-handle cache: every user table plus the
        // change-log/sync-state metadata tables open at most once per batch,
        // instead of once per operation.
        let mut handles: WriteTableCache<'_> = HashMap::new();

        // Durable-index table, opened lazily at most once per batch. Kept as a
        // separate local (not in `handles`) so index maintenance can borrow it
        // mutably while a user table from `handles` is still being scanned.
        let mut index_table: Option<Table<'_, &'static [u8], &'static [u8]>> = None;
        // Per-index-entry presence counts (`__gecko_index_meta`), opened
        // lazily at most once per batch, same borrow discipline as the index.
        let mut meta_table: Option<Table<'_, &'static [u8], &'static [u8]>> = None;

        // Pre-index index definitions by table and pre-encode the stable
        // key prefixes (single-field AND session-scoped composite entries) so
        // per-op index maintenance is O(1).
        let index_plan = IndexPlan::build(index_definitions, &self.composite_index_plan);

        // Scratch reused for every durable-index key built in this batch.
        let mut index_scratch: Vec<u8> = Vec::new();

        let put_mode_by_index: HashMap<usize, u8> = put_modes.iter().cloned().collect();

        // collect the affected (table, key) pairs and wholesale-cleared
        // tables so the reactive registry can re-evaluate them before commit.
        // The registry consumes each affected key's POST-COMMIT value (built
        // here, once, shared across registrations) instead of re-reading the
        // tree per key per registration.
        let mut affected: Vec<(String, Vec<u8>)> = Vec::new();
        let mut cleared: Vec<String> = Vec::new();
        let mut removed_keys: Vec<(String, Vec<u8>)> = Vec::new();
        let mut previous_values = vec![None; previous_operation_indexes.len()];
        let registry_active = !self.registry.is_empty();
        let mut changed: std::collections::HashMap<
            String,
            std::collections::HashMap<Vec<u8>, Option<Vec<u8>>>
        > = std::collections::HashMap::new();

        for (operation_index, operation) in operations.iter().enumerate() {
            match operation.kind {
                OpKind::Put => {
                    let key = operation.key.as_deref().expect("validated put key");
                    let value = operation.value.as_deref().expect("validated put value");
                    let mode = put_mode_by_index.get(&operation_index).copied().unwrap_or(0);
                    // Scope the user-table borrow so index maintenance can take
                    // the cached index handle right after.
                    let previous = {
                        let table =
                            open_write_table(&mut handles, &transaction, &operation.table, &self.counters)?;
                        match mode {
                            // Plain upsert: a single `insert` returns the
                            // previous value, so one lookup replaces the old
                            // get-then-insert pair.
                            0 => {
                                crate::work_count!(self, previous_value_reads, 1);
                                table
                                    .insert(key, value)
                                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                                    .map(|row| row.value().to_vec())
                            }
                            // insertOnly: the key must not exist. The read is
                            // authoritative and a failed check never touches
                            // the tree.
                            1 => {
                                crate::work_count!(self, previous_value_reads, 1);
                                let present = table
                                    .get(key)
                                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                                    .is_some();
                                if present {
                                    return Err(
                                        WorkerError::InvalidOperation(
                                            format!(
                                                "insertOnly: key already exists in \\\"{}\\\"",
                                                operation.table
                                            )
                                        )
                                    );
                                }
                                table
                                    .insert(key, value)
                                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                                    .map(|row| row.value().to_vec())
                            }
                            // updateOnly: the key must exist.
                            2 => {
                                crate::work_count!(self, previous_value_reads, 2);
                                let absent = table
                                    .get(key)
                                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                                    .is_none();
                                if absent {
                                    return Err(
                                        WorkerError::KeyNotFound(
                                            format!(
                                                "updateOnly: key does not exist in \\\"{}\\\"",
                                                operation.table
                                            )
                                        )
                                    );
                                }
                                table
                                    .insert(key, value)
                                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                                    .map(|row| row.value().to_vec())
                            }
                            _ => {
                                return Err(
                                    WorkerError::InvalidOperation("unknown raw put mode".into())
                                );
                            }
                        }
                    };
                    if let Some(slot) = previous_slots.get(&operation_index) {
                        previous_values[*slot] = previous.clone();
                    }
                    maintain_durable_index(
                        &transaction,
                        &mut index_table,
                        &mut meta_table,
                        &index_plan,
                        &operation.table,
                        key,
                        previous.as_deref(),
                        Some(value),
                        &mut index_scratch,
                        &self.counters
                    )?;
                    crate::work_count!(self, rows_written, 1);
                    affected.push((operation.table.clone(), key.to_vec()));
                    if registry_active {
                        changed
                            .entry(operation.table.clone())
                            .or_default()
                            .insert(key.to_vec(), Some(value.to_vec()));
                    }
                    write_prepared_templates(
                        &transaction,
                        &mut handles,
                        operation_index,
                        previous.as_deref(),
                        sequence,
                        change_templates,
                        &self.counters
                    )?;
                }
                OpKind::Delete => {
                    let key = operation.key.as_deref().expect("validated delete key");
                    let previous = {
                        let table =
                            open_write_table(&mut handles, &transaction, &operation.table, &self.counters)?;
                        crate::work_count!(self, previous_value_reads, 1);
                        table
                            .remove(key)
                            .map_err(|error| WorkerError::Storage(error.to_string()))?
                            .map(|row| row.value().to_vec())
                    };
                    if let Some(slot) = previous_slots.get(&operation_index) {
                        previous_values[*slot] = previous.clone();
                    }
                    maintain_durable_index(
                        &transaction,
                        &mut index_table,
                        &mut meta_table,
                        &index_plan,
                        &operation.table,
                        key,
                        previous.as_deref(),
                        None,
                        &mut index_scratch,
                        &self.counters
                    )?;
                    crate::work_count!(self, rows_written, 1);
                    affected.push((operation.table.clone(), key.to_vec()));
                    if registry_active {
                        changed
                            .entry(operation.table.clone())
                            .or_default()
                            .insert(key.to_vec(), None);
                    }
                    write_prepared_templates(
                        &transaction,
                        &mut handles,
                        operation_index,
                        previous.as_deref(),
                        sequence,
                        change_templates,
                        &self.counters
                    )?;
                }
                OpKind::DeleteRange => {
                    let start = operation.start.as_deref().expect("validated range start");
                    let end = operation.end.as_deref().expect("validated range end");
                    // Stream the range once: maintain the durable index from
                    // the old row bytes and collect only the keys required for
                    // affected-key reporting. Values are never materialized, so
                    // a wide delete cannot build a process-sized (key, value)
                    // vector.
                    let mut keys: Vec<Vec<u8>> = Vec::new();
                    {
                        let table = open_write_table(
                            &mut handles,
                            &transaction,
                            &operation.table,
                            &self.counters
                        )?;
                        let range = table
                            .range(start..=end)
                            .map_err(|error| WorkerError::Storage(error.to_string()))?;
                        for entry in range {
                            let (key, value) =
                                entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                            crate::work_count!(self, primary_rows_visited, 1);
                            maintain_durable_index(
                                &transaction,
                                &mut index_table,
                                &mut meta_table,
                                &index_plan,
                                &operation.table,
                                key.value(),
                                Some(value.value()),
                                None,
                                &mut index_scratch,
                                &self.counters
                            )?;
                            keys.push(key.value().to_vec());
                        }
                    }
                    enforce_delete_memory_policy(&keys)?;
                    crate::work_count!(self, rows_written, keys.len() as u64);
                    {
                        let table = open_write_table(
                            &mut handles,
                            &transaction,
                            &operation.table,
                            &self.counters
                        )?;
                        for key in &keys {
                            table
                                .remove(key.as_slice())
                                .map_err(|error| WorkerError::Storage(error.to_string()))?;
                        }
                    }
                    for key in keys {
                        removed_keys.push((operation.table.clone(), key.clone()));
                        affected.push((operation.table.clone(), key.clone()));
                        if registry_active {
                            changed
                                .entry(operation.table.clone())
                                .or_default()
                                .insert(key, None);
                        }
                    }
                }
                OpKind::Clear => {
                    // Same streaming shape as DeleteRange but over the whole
                    // table: index maintenance sees the old row bytes while
                    // only keys are collected for reporting.
                    let mut keys: Vec<Vec<u8>> = Vec::new();
                    {
                        let table = open_write_table(
                            &mut handles,
                            &transaction,
                            &operation.table,
                            &self.counters
                        )?;
                        let iter = table
                            .iter()
                            .map_err(|error| WorkerError::Storage(error.to_string()))?;
                        for entry in iter {
                            let (key, value) =
                                entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                            crate::work_count!(self, primary_rows_visited, 1);
                            maintain_durable_index(
                                &transaction,
                                &mut index_table,
                                &mut meta_table,
                                &index_plan,
                                &operation.table,
                                key.value(),
                                Some(value.value()),
                                None,
                                &mut index_scratch,
                                &self.counters
                            )?;
                            keys.push(key.value().to_vec());
                        }
                    }
                    enforce_delete_memory_policy(&keys)?;
                    crate::work_count!(self, rows_written, keys.len() as u64);
                    {
                        let table = open_write_table(
                            &mut handles,
                            &transaction,
                            &operation.table,
                            &self.counters
                        )?;
                        for key in &keys {
                            table
                                .remove(key.as_slice())
                                .map_err(|error| WorkerError::Storage(error.to_string()))?;
                        }
                    }
                    for key in keys {
                        removed_keys.push((operation.table.clone(), key));
                    }
                    cleared.push(operation.table.clone());
                }
                OpKind::Get | OpKind::RangeScan => {
                    return Err(
                        WorkerError::InvalidOperation(
                            "read operations cannot be committed in a write batch".into()
                        )
                    );
                }
            }
        }

        // re-evaluate every touched live registration in the same write
        // transaction (the registry reads the just-applied state), then commit.
        // prune the pending-sync change log in the same transaction when
        // the batch grew it and a retention limit is configured.
        // Drop every cached table handle before the pruning and registry
        // phases: redb allows only one open handle per table per write
        // transaction, and both phases open tables through their own handles.
        // Dropping a handle inside an uncommitted transaction is a no-op for
        // durability — rollback still undoes everything on error.
        drop(handles);
        drop(index_table);
        drop(meta_table);
        if change_log_max_entries > 0 && change_log_touched {
            prune_change_log(&transaction, change_log_max_entries, &self.counters)?;
        }
        // Deduplicate affected (table, key) pairs in batch order so the
        // registry evaluates each key once against its final post-commit
        // value (repeated keys arrive in one batch; last state wins).
        if registry_active {
            let mut seen: std::collections::HashSet<(String, Vec<u8>)> =
                std::collections::HashSet::with_capacity(affected.len());
            affected.retain(|(table, key)| seen.insert((table.clone(), key.clone())));
        }
        let deltas = self.registry.apply(&affected, &changed, &cleared, &self.counters)?;
        transaction.commit().map_err(|error| WorkerError::Storage(error.to_string()))?;
        if !sequence_neutral {
            self.commit_sequence = sequence;
        }
        crate::work_count!(self, batches_applied, 1);
        Ok(ApplyBatchOutcome {
            sequence,
            deltas,
            previous_values,
            removed_keys,
        })
    }

    /// registers a live query with the worker and materializes
    /// its initial result set from one consistent read transaction. Returns
    /// `(registration id, initial snapshot in result order)`.
    pub fn register_live_query(
        &mut self,
        table: &str,
        predicate_bytes: &[u8],
        sort_bytes: &[u8],
        kind: u8
    ) -> Result<(u64, Vec<ByteEntry>), WorkerError> {
        let kind_value = crate::registry::LiveQueryKind
            ::from_u8(kind)
            .ok_or_else(|| {
                WorkerError::InvalidOperation(format!("unknown live-query kind {kind}"))
            })?;
        let transaction = self.begin_read()?;
        self.registry.register(
            &transaction,
            table,
            predicate_bytes,
            sort_bytes,
            kind_value,
        )
    }

    /// removes a live-query registration (idempotent).
    pub fn unregister_live_query(&mut self, id: u64) {
        self.registry.unregister(id);
    }

    /// Aggregates the pending local changes from the
    /// sync-state table: only DIRTY records whose origin is not `remoteSync`,
    /// ordered by `localMutationId`. Returns `(key, record bytes)` pairs; Dart
    /// decodes them into the public `PendingChange` model. Each sync-state key
    /// holds exactly one record, so no per-(collection, recordId) dedup is
    /// needed — the aggregation, filter, and sort execute here, not in Dart.
    pub fn pending_changes(&self) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        let state = match transaction.open_table(table_definition("__gecko_sync_state")) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut rows: Vec<(Vec<u8>, Vec<u8>, u64)> = Vec::new();
        for entry in state.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row = entry.1.value();
            if !change_record_dirty(row) {
                continue;
            }
            let origin = match crate::value_codec::find_field(row, "origin") {
                Ok(Some(crate::value_codec::RowValue::String(s))) => s,
                _ => String::new(),
            };
            if origin == "remoteSync" {
                continue;
            }
            let lsn = change_record_mutation_id(row);
            rows.push((entry.0.value().to_vec(), row.to_vec(), lsn));
        }
        rows.sort_by_key(|(_, _, lsn)| *lsn);
        Ok(
            rows
                .into_iter()
                .map(|(key, row, _)| (key, row))
                .collect()
        )
    }

    /// Number of active live-query registrations (diagnostics).
    pub fn live_query_count(&self) -> usize {
        self.registry.len()
    }

    /// Filters the sync-state table to the records matching [matchers] in
    /// Rust: only the matching `(key, record)` pairs cross the boundary,
    /// instead of a full-table scan + decode in Dart. Each matcher is
    /// `0x00 | u32_be(rid_len) | recordId_bytes` (match on recordId alone) or
    /// `0x01 | u32_be(col_len) | collection_bytes | u32_be(rid_len) |
    /// recordId_bytes` (match on collection AND recordId — a `RecordRef`).
    /// Comparison is byte-exact against the encoded fields, mirroring Dart's
    /// `_matches` semantics (an id and a recordId must be the same wire value).
    /// A missing table yields an empty result, never an error.
    pub fn sync_state_matching(
        &self,
        matchers: &[Vec<u8>]
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        if matchers.is_empty() {
            return Ok(Vec::new());
        }
        let transaction = self.begin_read()?;
        let state = match transaction.open_table(table_definition("__gecko_sync_state")) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for entry in state.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row = entry.1.value();
            if sync_state_matches(row, matchers) {
                result.push((entry.0.value().to_vec(), row.to_vec()));
            }
        }
        Ok(result)
    }

    /// Range-filtered `changesSince(lastSeq)`: scans the change log in Rust
    /// and returns only the `(key, record)` pairs whose `localMutationId`
    /// exceeds [seq]. Dart previously scanned the whole log, decoded every
    /// record, and filtered; now only the required records cross the
    /// boundary. A missing table yields an empty result.
    pub fn changes_since(&self, seq: u64) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        let log = match transaction.open_table(table_definition("__gecko_change_log")) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for entry in log.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row = entry.1.value();
            if change_record_mutation_id(row) > seq {
                result.push((entry.0.value().to_vec(), row.to_vec()));
            }
        }
        Ok(result)
    }

    /// Scans the attachment catalog and returns the metadata entries whose
    /// parent row no longer exists — the `orphaned()` scan + one-parent-lookup
    /// per attachment now runs inside one Rust read transaction instead of a
    /// Dart full scan plus N point reads. Returns `(attachmentKey, meta)`
    /// pairs for orphans. A missing table yields an empty result.
    pub fn orphaned_attachments(&self) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        let catalog = match transaction.open_table(table_definition("__gecko_attachments")) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for entry in catalog.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let meta = entry.1.value();
            let parent_collection = match crate::value_codec::find_field_bytes(meta, "parentCollection") {
                Ok(Some(bytes)) => bytes.to_vec(),
                _ => continue,
            };
            let parent_id = match crate::value_codec::find_field_bytes(meta, "parentId") {
                Ok(Some(bytes)) => bytes.to_vec(),
                _ => continue,
            };
            let Some(parent_table_name) = decode_string_value(&parent_collection) else {
                continue;
            };
            let parent_table = match transaction.open_table(table_definition(&parent_table_name)) {
                Ok(t) => t,
                Err(redb::TableError::TableDoesNotExist(_)) => {
                    // Parent table absent → the parent cannot exist → orphan.
                    result.push((entry.0.value().to_vec(), meta.to_vec()));
                    continue;
                }
                Err(error) => {
                    return Err(WorkerError::Storage(error.to_string()));
                }
            };
            let exists = parent_table
                .get(parent_id.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .is_some();
            if !exists {
                result.push((entry.0.value().to_vec(), meta.to_vec()));
            }
        }
        Ok(result)
    }

    /// Reads one key using a consistent read transaction.
    pub fn get(&self, table: &str, key: &[u8]) -> Result<Option<Vec<u8>>, WorkerError> {
        let transaction = self.begin_read()?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(None);
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let value = table
            .get(key)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|value| value.value().to_vec());
        if let Some(row) = &value {
            crate::work_count!(self, rows_returned, 1);
            crate::work_count!(self, bytes_returned, row.len() as u64);
        }
        Ok(value)
    }

    /// batched point-read — fetches N keys in ONE read transaction,
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
        keys: &[&[u8]]
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.get_many_with(transaction, table, keys)
    }

    fn get_many_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        keys: &[&[u8]]
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        if keys.is_empty() {
            return Ok(Vec::new());
        }
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::with_capacity(keys.len());
        for key in keys {
            if
                let Some(value) = user_table
                    .get(*key)
                    .map_err(|error| WorkerError::Storage(error.to_string()))?
            {
                result.push((key.to_vec(), value.value().to_vec()));
            }
            // Absent keys are silently omitted; the durable contract is that
            // only existing rows appear in the result.
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// Reads a sorted inclusive range using one consistent snapshot.
    pub fn range_scan(
        &self,
        table: &str,
        start: Option<&[u8]>,
        end: Option<&[u8]>
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        let table = match transaction.open_table(table_definition(table)) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        let iterator = match (start, end) {
            (Some(start), Some(end)) =>
                table.range(start..=end).map_err(|error| WorkerError::Storage(error.to_string()))?,
            (Some(start), None) =>
                table.range(start..).map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, Some(end)) =>
                table.range(..=end).map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, None) => table.iter().map_err(|error| WorkerError::Storage(error.to_string()))?,
        };
        for entry in iterator {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            result.push((key.value().to_vec(), value.value().to_vec()));
        }
        crate::work_count!(self, primary_rows_visited, result.len() as u64);
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// Creates a point-in-time MVCC snapshot: a held redb read transaction
    /// that observes exactly the committed state at creation time, even after
    /// later write transactions commit. Returns an opaque id for the caller.
    ///
    /// A hard cap bounds how many open snapshots can pin MVCC versions at
    /// once; a leaked snapshot (a caller that never disposes) can no longer
    /// block compaction indefinitely — beyond the cap, creation fails with a
    /// typed error instead of silently pinning more versions.
    pub fn create_snapshot(&mut self) -> Result<u64, WorkerError> {
        if self.snapshots.len() >= MAX_OPEN_SNAPSHOTS {
            return Err(
                WorkerError::InvalidOperation(format!(
                    "too many open snapshots (max {MAX_OPEN_SNAPSHOTS}); a caller is leaking snapshot handles"
                ))
            );
        }
        let transaction = self.begin_read()?;
        let id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        self.snapshots.insert(id, transaction);
        crate::work_count!(self, snapshots_created, 1);
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
        key: &[u8]
    ) -> Result<Option<Vec<u8>>, WorkerError> {
        let transaction = self.snapshot_transaction(id)?;
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(None);
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let value = table
            .get(key)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|value| value.value().to_vec());
        if let Some(row) = &value {
            crate::work_count!(self, rows_returned, 1);
            crate::work_count!(self, bytes_returned, row.len() as u64);
        }
        Ok(value)
    }

    /// Scans a sorted inclusive range through a previously created snapshot.
    pub fn snapshot_range_scan(
        &self,
        id: u64,
        table: &str,
        start: Option<&[u8]>,
        end: Option<&[u8]>
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(id)?;
        let table = match transaction.open_table(table_definition(table)) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        let iterator = match (start, end) {
            (Some(start), Some(end)) =>
                table.range(start..=end).map_err(|error| WorkerError::Storage(error.to_string()))?,
            (Some(start), None) =>
                table.range(start..).map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, Some(end)) =>
                table.range(..=end).map_err(|error| WorkerError::Storage(error.to_string()))?,
            (None, None) => table.iter().map_err(|error| WorkerError::Storage(error.to_string()))?,
        };
        for entry in iterator {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            result.push((key.value().to_vec(), value.value().to_vec()));
        }
        crate::work_count!(self, primary_rows_visited, result.len() as u64);
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// Releases a snapshot. Idempotent: unknown ids are ignored.
    pub fn drop_snapshot(&mut self, id: u64) {
        self.snapshots.remove(&id);
    }

    /// Session-scoped composite durable-index declaration: [indexes] is the
    /// ordered field list of each composite index on [table]. Composite keys
    /// are `[table, f1, v1, f2, v2, ..., recordId]`, so a compound predicate
    /// whose eq filters cover a composite prefix (plus a range/prefix on the
    /// trailing field) is answered by ONE ordered index scan instead of N
    /// single-field ranges + set intersection. The plan is merged into every
    /// subsequent `apply_batch` (and `repair_index`) so maintenance stays
    /// atomic with the rows it indexes.
    pub fn set_composite_indexes(&mut self, table: &str, indexes: &[Vec<String>]) {
        if table == "__gecko_index" {
            return;
        }
        self.composite_index_plan
            .insert(
                table.to_string(),
                indexes.iter().filter(|index| !index.is_empty()).cloned().collect(),
            );
    }

    /// verifies and repairs all durable-index entries for [table] in Rust.
    /// The caller supplies the declared indexed fields (single-field entries);
    /// session-scoped composite declarations are consulted in addition.
    /// Primary rows are the source of truth and the repair is committed
    /// atomically with no Dart row materialization. Index values are the
    /// encoded primary record keys. Presence counts in `__gecko_index_meta`
    /// are rebuilt for every repaired entry (single-field and composite).
    pub fn repair_index(&mut self, table: &str, fields: &[String]) -> Result<(), WorkerError> {
        if self.read_only {
            return Err(
                WorkerError::InvalidOperation(
                    "database is read-only; index repair is not allowed".into()
                )
            );
        }
        let composites: Vec<Vec<String>> = self
            .composite_index_plan
            .get(table)
            .cloned()
            .unwrap_or_default();
        // The entry prefixes this repair owns: single-field declarations plus
        // composite declarations. Used to count presence and to clear stale
        // meta rows for this table.
        let mut entry_prefixes: Vec<Vec<u8>> = Vec::new();
        for field in fields {
            entry_prefixes.push(index_key_prefix(table, std::slice::from_ref(field)));
        }
        for composite in &composites {
            entry_prefixes.push(index_key_prefix(table, composite));
        }
        let transaction = self.begin_read()?;
        let primary_def = table_definition(table);
        let primary = match transaction.open_table(primary_def) {
            Ok(table) => table,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut expected = BTreeMap::<Vec<u8>, Vec<u8>>::new();
        for entry in primary.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (record_key, row_value) = entry.map_err(|error|
                WorkerError::Storage(error.to_string())
            )?;
            let record_key = record_key.value().to_vec();
            let row_bytes = row_value.value();
            for field in fields {
                let Some((start, end)) = crate::value_codec
                    ::find_field_range(row_bytes, field)
                    .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                    continue;
                };
                expected.insert(
                    durable_index_key(table, field, &row_bytes[start..end], &record_key),
                    record_key.clone()
                );
            }
            for composite in &composites {
                let Some(values) =
                    extract_field_slices(Some(row_bytes), composite)?
                else {
                    continue;
                };
                let field_refs: Vec<&str> = composite.iter().map(|f| f.as_str()).collect();
                expected.insert(
                    durable_index_key_multi(table, &field_refs, &values, &record_key),
                    record_key.clone()
                );
            }
        }
        drop(transaction);

        let transaction = self.begin_read()?;
        let index_def = table_definition("__gecko_index");
        let mut current = BTreeMap::<Vec<u8>, Vec<u8>>::new();
        if let Ok(index) = transaction.open_table(index_def) {
            for entry in index.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
                let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                let key_bytes = key.value().to_vec();
                if durable_index_table(&key_bytes).as_deref() == Some(table) {
                    current.insert(key_bytes, value.value().to_vec());
                }
            }
        }
        drop(transaction);
        if current == expected {
            return Ok(());
        }

        let transaction = match &self.database {
            WorkerDatabase::ReadWrite(database) =>
                database.begin_write().map_err(|error| WorkerError::Storage(error.to_string()))?,
            WorkerDatabase::ReadOnly(_) => unreachable!("read-only worker rejected above"),
        };
        let mut index = transaction
            .open_table(index_def)
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        for key in current.keys().filter(|key| !expected.contains_key(*key)) {
            index.remove(key.as_slice()).map_err(|error| WorkerError::Storage(error.to_string()))?;
        }
        for (key, value) in expected {
            index
                .insert(key.as_slice(), value.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
        }
        drop(index);
        // Rebuild the presence counts for every entry this repair owns, and
        // clear stale meta rows for the table.
        let mut meta = transaction
            .open_table(table_definition("__gecko_index_meta"))
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        {
            let mut stale = Vec::new();
            if let Ok(iter) = meta.iter() {
                for entry in iter {
                    let (key, _) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                    if durable_index_table(key.value()).as_deref() == Some(table) {
                        stale.push(key.value().to_vec());
                    }
                }
            }
            for key in stale {
                meta
                    .remove(key.as_slice())
                    .map_err(|error| WorkerError::Storage(error.to_string()))?;
            }
        }
        let mut counts: HashMap<Vec<u8>, i64> = HashMap::new();
        {
            let index = transaction
                .open_table(index_def)
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            for entry in index.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
                let (key, _) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                let key_bytes = key.value();
                if durable_index_table(key_bytes).as_deref() != Some(table) {
                    continue;
                }
                for prefix in &entry_prefixes {
                    if key_bytes.starts_with(prefix.as_slice()) {
                        *counts.entry(prefix.clone()).or_insert(0) += 1;
                        break;
                    }
                }
            }
        }
        for (prefix, count) in counts {
            if count <= 0 {
                continue;
            }
            let mut value = vec![crate::value_codec::TAG_INT64];
            value.extend_from_slice(&count.to_be_bytes());
            meta
                .insert(prefix.as_slice(), value.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
        }
        drop(meta);
        transaction.commit().map_err(|error| WorkerError::Storage(error.to_string()))?;
        Ok(())
    }

    /// native query fast path: range-scans the durable `__gecko_index`
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
        end: &[u8]
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
        end: &[u8]
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
        end: &[u8]
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        // Collect the index entries' VALUES (the user-table row keys) in
        // ascending index-key order.
        let row_keys: Vec<Vec<u8>> = index_table
            .range(start..=end)
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .filter_map(|entry| entry.ok().map(|(_, value)| value.value().to_vec()))
            .collect();
        crate::work_count!(self, index_entries_visited, row_keys.len() as u64);
        crate::work_count!(self, candidate_keys_allocated, row_keys.len() as u64);
        if row_keys.is_empty() {
            return Ok(Vec::new());
        }
        // Join back to the user table in the same read transaction.
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::with_capacity(row_keys.len());
        for row_key in row_keys {
            crate::work_count!(self, primary_rows_fetched, 1);
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
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// scans one or more durable-index ranges, intersects their candidate
    /// row keys, and re-evaluates the complete predicate in Rust. Range and
    /// prefix filters use broad `(table, field)` bounds because the v1 row
    /// codec is not generally order-preserving (notably for negative numbers
    /// and length-prefixed strings). The durable index narrows the candidate
    /// set; [predicate_bytes] remains the semantic source of truth.
    /// intersects multiple durable-index candidate ranges, applies an early
    /// window, and re-evaluates the complete predicate in Rust unless
    /// [covered] (Priority 5): when [covered] is true the predicate's filters
    /// are all proven by the index bounds, so the per-row recheck is skipped.
    /// Candidate intersection is smaller-first and streaming, and the planner
    /// falls back to a full filtered scan when the index cannot narrow.
    #[allow(clippy::too_many_arguments)]
    pub fn query_indexed_multi(
        &self,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_multi_with(
            &transaction,
            table,
            index_table,
            ranges,
            predicate_bytes,
            covered,
            limit,
            offset
        )
    }

    /// Snapshot-bound variant of [Self::query_indexed_multi].
    #[allow(clippy::too_many_arguments)]
    pub fn snapshot_query_indexed_multi(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_multi_with(
            transaction,
            table,
            index_table,
            ranges,
            predicate_bytes,
            covered,
            limit,
            offset
        )
    }

    /// counts matching rows from durable-index candidates without
    /// transferring primary rows to Dart. The complete predicate is still
    /// rechecked against each candidate row unless [covered] (Priority 5).
    #[allow(clippy::too_many_arguments)]
    pub fn snapshot_query_indexed_count(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        covered: bool
    ) -> Result<u64, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_count_with(
            transaction,
            table,
            index_table,
            ranges,
            predicate_bytes,
            covered
        )
    }

    /// Direct indexed count using one worker-owned read transaction.
    #[allow(clippy::too_many_arguments)]
    pub fn query_indexed_count(
        &self,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        covered: bool
    ) -> Result<u64, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_count_with(
            &transaction,
            table,
            index_table,
            ranges,
            predicate_bytes,
            covered
        )
    }

    /// emits only the requested field bytes from durable-index
    /// candidates. Dart performs the final decode and insertion-order dedup.
    /// The complete predicate is rechecked unless [covered] (Priority 5).
    #[allow(clippy::too_many_arguments)]
    pub fn snapshot_query_indexed_distinct(
        &self,
        snapshot: u64,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        field: &str,
        covered: bool
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_distinct_with(
            transaction,
            table,
            index_table,
            ranges,
            predicate_bytes,
            field,
            covered
        )
    }

    /// Direct indexed distinct extraction using a worker-owned read
    /// transaction.
    #[allow(clippy::too_many_arguments)]
    pub fn query_indexed_distinct(
        &self,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        field: &str,
        covered: bool
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_distinct_with(
            &transaction,
            table,
            index_table,
            ranges,
            predicate_bytes,
            field,
            covered
        )
    }

    fn indexed_candidate_keys_with(
        &self,
        transaction: &ReadTransaction,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)]
    ) -> Result<BTreeSet<Vec<u8>>, WorkerError> {
        if ranges.is_empty() {
            return Ok(BTreeSet::new());
        }
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(BTreeSet::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        // Smaller-first streaming intersection (Priority 5): scan every range
        // once, seed with the smallest candidate set, and membership-check the
        // remaining ranges against it (O(total) instead of N full-set
        // intersections). The result is sorted for deterministic iteration.
        let mut sets: Vec<(Vec<Vec<u8>>, u64)> = Vec::with_capacity(ranges.len());
        for (start, end) in ranges {
            let keys: Vec<Vec<u8>> = index_table
                .range(start.as_slice()..=end.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .filter_map(|entry| entry.ok().map(|(_, value)| value.value().to_vec()))
                .collect();
            let span = keys.len() as u64;
            crate::work_count!(self, index_entries_visited, span);
            sets.push((keys, span));
        }
        sets.sort_by_key(|(_, len)| *len);
        let mut candidates: std::collections::HashSet<Vec<u8>> = sets[0].0.iter().cloned().collect();
        for (keys, _) in &sets[1..] {
            if candidates.is_empty() {
                break;
            }
            let mut next = std::collections::HashSet::with_capacity(
                candidates.len().min(keys.len())
            );
            for key in keys {
                if candidates.contains(key) {
                    next.insert(key.clone());
                }
            }
            candidates = next;
        }
        let final_candidates: BTreeSet<Vec<u8>> = candidates.into_iter().collect();
        crate::work_count!(self, candidate_keys_allocated, final_candidates.len() as u64);
        Ok(final_candidates)
    }

    fn query_indexed_count_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        covered: bool
    ) -> Result<u64, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let candidates = self.indexed_candidate_keys_with(transaction, index_table, ranges)?;
        let user_table = match transaction.open_table(table_definition(table)) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(0);
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut count = 0;
        for row_key in candidates {
            crate::work_count!(self, primary_rows_fetched, 1);
            let Some(value) = user_table
                .get(row_key.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            if !covered {
                crate::work_count!(self, predicate_evaluations, 1);
                if !predicate.test_bytes_with_scratch(value.value(), &mut predicate_scratch) {
                    continue;
                }
            }
            count += 1;
        }
        Ok(count)
    }

    #[allow(clippy::too_many_arguments)]
    fn query_indexed_distinct_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        field: &str,
        covered: bool
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let candidates = self.indexed_candidate_keys_with(transaction, index_table, ranges)?;
        let user_table = match transaction.open_table(table_definition(table)) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for row_key in candidates {
            crate::work_count!(self, primary_rows_fetched, 1);
            let Some(value) = user_table
                .get(row_key.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            let row_bytes = value.value();
            if !covered {
                crate::work_count!(self, predicate_evaluations, 1);
                if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                    continue;
                }
            }
            let Some((start, end)) = crate::value_codec
                ::find_field_range(row_bytes, field)
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            result.push(row_bytes[start..end].to_vec());
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        Ok(result)
    }

    /// reads one parent row and extracts the child foreign-key value in
    /// the same snapshot, returning no row materialization for a missing key.
    pub fn snapshot_relationship_parent(
        &self,
        snapshot: u64,
        child_table: &str,
        child_key: &[u8],
        parent_table: &str,
        foreign_key_field: &str
    ) -> Result<Option<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        let child = match transaction.open_table(table_definition(child_table)) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(None);
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let Some(child_value) = child
            .get(child_key)
            .map_err(|error| WorkerError::Storage(error.to_string()))? else {
            return Ok(None);
        };
        let child_bytes = child_value.value();
        let Some((start, end)) = crate::value_codec
            ::find_field_range(child_bytes, foreign_key_field)
            .map_err(|error| WorkerError::Storage(error.to_string()))? else {
            return Ok(None);
        };
        let parent_key = child_bytes[start..end].to_vec();
        let parent = match transaction.open_table(table_definition(parent_table)) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(None);
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let Some(parent_value) = parent
            .get(parent_key.as_slice())
            .map_err(|error| WorkerError::Storage(error.to_string()))? else {
            return Ok(None);
        };
        Ok(Some((parent_key, parent_value.value().to_vec())))
    }

    /// /returns child rows whose foreign key matches any requested
    /// parent ID, **grouped by FK value in Rust**. Indexed callers supply
    /// durable index ranges; unindexed callers supply the complete predicate
    /// and Rust evaluates it here. Grouping removes the Dart-side re-decode
    /// and classification of every candidate row.
    #[allow(clippy::too_many_arguments)]
    pub fn snapshot_relationship_children(
        &self,
        snapshot: u64,
        child_table: &str,
        foreign_key_field: &str,
        parent_ids: &[Vec<u8>],
        index_table: &str,
        index_ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8]
    ) -> Result<Vec<GroupedChildEntries>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let user_table = match transaction.open_table(table_definition(child_table)) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut candidates = if index_ranges.is_empty() {
            user_table
                .iter()
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .map(|entry| {
                    entry
                        .map(|(key, _)| key.value().to_vec())
                        .map_err(|error| WorkerError::Storage(error.to_string()))
                })
                .collect::<Result<BTreeSet<_>, WorkerError>>()?
        } else {
            let index_table = match transaction.open_table(table_definition(index_table)) {
                Ok(t) => t,
                Err(redb::TableError::TableDoesNotExist(_)) => {
                    return Ok(Vec::new());
                }
                Err(error) => {
                    return Err(WorkerError::Storage(error.to_string()));
                }
            };
            let mut union = BTreeSet::new();
            for (start, end) in index_ranges {
                for entry in index_table
                    .range(start.as_slice()..=end.as_slice())
                    .map_err(|error| WorkerError::Storage(error.to_string()))? {
                    let (_, value) = entry.map_err(|error|
                        WorkerError::Storage(error.to_string())
                    )?;
                    union.insert(value.value().to_vec());
                }
            }
            union
        };
        if !parent_ids.is_empty() {
            let wanted = parent_ids.iter().cloned().collect::<BTreeSet<_>>();
            let mut matching = BTreeSet::new();
            for key in &candidates {
                let Some(value) = user_table
                    .get(key.as_slice())
                    .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                    continue;
                };
                let Some((start, end)) = crate::value_codec
                    ::find_field_range(value.value(), foreign_key_field)
                    .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                    continue;
                };
                if wanted.contains(&value.value()[start..end]) {
                    matching.insert(key.clone());
                }
            }
            candidates = matching;
        }
        // Group matching rows by their encoded FK value. The BTreeMap keeps
        // groups in FK-byte order and rows within a group in row-key order
        // (candidates is a sorted BTreeSet), matching the order Dart's eager
        // loader previously preserved when it bucketed rows itself.
        let mut groups: BTreeMap<Vec<u8>, Vec<ByteEntry>> = BTreeMap::new();
        for row_key in candidates {
            let Some(value) = user_table
                .get(row_key.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            let row_bytes = value.value();
            if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                continue;
            }
            let Some((start, end)) = crate::value_codec
                ::find_field_range(row_bytes, foreign_key_field)
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            groups
                .entry(row_bytes[start..end].to_vec())
                .or_default()
                .push((row_key, row_bytes.to_vec()));
        }
        Ok(
            groups
                .into_iter()
                .map(|(parent_id, entries)| GroupedChildEntries { parent_id, entries })
                .collect()
        )
    }

    /// returns join IDs from a reserved many-to-many table while the
    /// entire scan remains inside one worker-owned snapshot.
    pub fn snapshot_relationship_join_ids(
        &self,
        snapshot: u64,
        join_table: &str,
        field: &str,
        wanted_id: &[u8]
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        let table = match transaction.open_table(table_definition(join_table)) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for entry in table.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row = value.value();
            let Some((start, end)) = crate::value_codec
                ::find_field_range(row, field)
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            if row[start..end] == *wanted_id {
                let other = if field == "left" { "right" } else { "left" };
                let Some((other_start, other_end)) = crate::value_codec
                    ::find_field_range(row, other)
                    .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                    continue;
                };
                result.push(row[other_start..other_end].to_vec());
            }
            let _ = key;
        }
        Ok(result)
    }

    #[allow(clippy::too_many_arguments)]
    fn query_indexed_multi_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        index_table: &str,
        ranges: &[(Vec<u8>, Vec<u8>)],
        predicate_bytes: &[u8],
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        if ranges.is_empty() {
            return Ok(Vec::new());
        }
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        // Scan every range once, recording each candidate span (Priority 5
        // planner observability: index entries visited vs candidates).
        let mut sets: Vec<(Vec<Vec<u8>>, u64)> = Vec::with_capacity(ranges.len());
        for (start, end) in ranges {
            let keys: Vec<Vec<u8>> = index_table
                .range(start.as_slice()..=end.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .filter_map(|entry| entry.ok().map(|(_, value)| value.value().to_vec()))
                .collect();
            let span = keys.len() as u64;
            crate::work_count!(self, index_entries_visited, span);
            sets.push((keys, span));
        }
        // Smaller-first: seed with the smallest candidate set so every later
        // intersection works over the smallest possible intermediate set.
        sets.sort_by_key(|(_, len)| *len);

        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        // Planner cost decision: if the smallest candidate span already
        // exceeds the whole user table, the index cannot narrow — a full scan
        // with the pushed predicate is strictly cheaper.
        let user_len = user_table
            .len()
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        if sets[0].1 > user_len {
            let mut entries = match limit {
                Some(l) => self.query_filtered_limited_with(
                    transaction,
                    table,
                    predicate_bytes,
                    Some(l),
                    offset
                )?,
                None => self.query_filtered_with(transaction, table, predicate_bytes)?,
            };
            if limit.is_none() && offset > 0 {
                let start_idx = (offset as usize).min(entries.len());
                return Ok(entries.split_off(start_idx));
            }
            return Ok(entries);
        }
        // Streaming intersection: membership-check every later range's keys
        // against the current candidate set (the order no longer matters
        // because the seed is the smallest set; each scan is independent).
        let mut candidates: std::collections::HashSet<Vec<u8>> =
            sets[0].0.iter().cloned().collect();
        for (keys, _) in &sets[1..] {
            if candidates.is_empty() {
                break;
            }
            let mut next = std::collections::HashSet::with_capacity(
                candidates.len().min(keys.len())
            );
            for key in keys {
                if candidates.contains(key) {
                    next.insert(key.clone());
                }
            }
            candidates = next;
        }
        crate::work_count!(self, candidate_keys_allocated, candidates.len() as u64);
        if candidates.is_empty() {
            return Ok(Vec::new());
        }
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        // Deterministic output: record-key ascending (the same order the
        // previous BTreeSet-based implementation produced).
        let mut sorted_keys: Vec<Vec<u8>> = candidates.into_iter().collect();
        sorted_keys.sort();
        let mut result = Vec::new();
        for row_key in sorted_keys {
            crate::work_count!(self, primary_rows_fetched, 1);
            let Some(value) = user_table
                .get(row_key.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))? else {
                continue;
            };
            let row_bytes = value.value();
            if !covered {
                crate::work_count!(self, predicate_evaluations, 1);
                if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                    continue;
                }
            }
            result.push((row_key, row_bytes.to_vec()));
            if let Some(want) = want {
                if (result.len() as u64) >= want {
                    break;
                }
            }
        }
        if offset > 0 {
            let start_idx = (offset as usize).min(result.len());
            result = result.split_off(start_idx);
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// step 2: full-scan with a pushed predicate. Scans every row in
    /// [table], evaluates [predicate] against each row's encoded bytes IN RUST
    /// (decoding only the referenced fields via `find_field`), and returns
    /// only the matching `(recordId, row)` pairs in ONE hop. Non-matching
    /// rows are never decoded in Dart — the dominant saving for unindexed
    /// queries (the profile showed `scanAll` transferring the whole
    /// table dominated 70% of a 100k-row full scan).
    ///
    /// [predicate_bytes] is the Dart-serialized `Predicate` wire payload
    /// (version-prefixed AND-composed filter list, see `predicate.rs`).
    pub fn query_filtered(
        &self,
        table: &str,
        predicate_bytes: &[u8]
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
        predicate_bytes: &[u8]
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_with(transaction, table, predicate_bytes)
    }

    fn query_filtered_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8]
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for entry in table.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_bytes = value.value();
            // Empty predicate matches everything (matches Dart's `FilterGroup`).
            crate::work_count!(self, primary_rows_visited, 1);
            crate::work_count!(self, predicate_evaluations, 1);
            if predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                result.push((key.value().to_vec(), row_bytes.to_vec()));
            }
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// aggregate pushdown — counts matching rows WITHOUT transferring
    /// them. Scans [table], evaluates [predicate_bytes] against each row's
    /// bytes IN RUST, and returns only the matching count in one hop. A
    /// `count()` query no longer pays the decode + transfer cost of every
    /// matching row.
    pub fn query_filtered_count(
        &self,
        table: &str,
        predicate_bytes: &[u8]
    ) -> Result<u64, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_filtered_count_with(&transaction, table, predicate_bytes)
    }

    /// Snapshot-bound variant of [Self::query_filtered_count].
    pub fn snapshot_query_filtered_count(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8]
    ) -> Result<u64, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_count_with(transaction, table, predicate_bytes)
    }

    fn query_filtered_count_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8]
    ) -> Result<u64, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(0);
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut count: u64 = 0;
        for entry in table.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (_, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            crate::work_count!(self, primary_rows_visited, 1);
            crate::work_count!(self, predicate_evaluations, 1);
            if predicate.test_bytes_with_scratch(value.value(), &mut predicate_scratch) {
                count += 1;
            }
        }
        Ok(count)
    }

    /// aggregate pushdown — emits only the bytes of [field] for each
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
        field: &str
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
        field: &str
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_filtered_distinct_with(transaction, table, predicate_bytes, field)
    }

    fn query_filtered_distinct_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        field: &str
    ) -> Result<Vec<Vec<u8>>, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let mut result = Vec::new();
        for entry in table.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (_, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_bytes = value.value();
            crate::work_count!(self, primary_rows_visited, 1);
            crate::work_count!(self, predicate_evaluations, 1);
            if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                continue;
            }
            // Locate [field] within the row's encoded bytes and emit the
            // value's bytes verbatim (the slice starting at the value's tag
            // byte, self-delimiting under the codec). Use find_field_offset so
            // we slice instead of allocating the decoded value.
            let range = crate::value_codec
                ::find_field_range(row_bytes, field)
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            let Some((start, end)) = range else {
                continue;
            };
            result.push(row_bytes[start..end].to_vec());
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        Ok(result)
    }

    // ── early LIMIT/OFFSET + indexed/top-K sorting ──────────────────────

    /// full-scan with a pushed predicate and an early LIMIT/OFFSET —
    /// skips the first [offset] matches and returns at most [limit] of the
    /// rest, stopping the scan as soon as the window is filled. Non-matching
    /// rows are never decoded in Dart, and (unlike [Self::query_filtered])
    /// matching rows beyond the window are never transferred.
    pub fn query_filtered_limited(
        &self,
        table: &str,
        predicate_bytes: &[u8],
        limit: Option<u64>,
        offset: u64
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
        offset: u64
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
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        let mut result = Vec::new();
        for entry in table.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            crate::work_count!(self, primary_rows_visited, 1);
            crate::work_count!(self, predicate_evaluations, 1);
            if !predicate.test_bytes_with_scratch(value.value(), &mut predicate_scratch) {
                continue;
            }
            result.push((key.value().to_vec(), value.value().to_vec()));
            if let Some(want) = want {
                if (result.len() as u64) >= want {
                    break;
                }
            }
        }
        if offset > 0 {
            let start = (offset as usize).min(result.len());
            result = result.split_off(start);
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// index-served eq query with an early LIMIT/OFFSET. Streams the
    /// durable-index range `[start..=end]` in index-key order, joins each
    /// entry back to its row, applies [predicate_bytes] (unless [covered],
    /// Priority 5 — the index bounds prove every filter, so the recheck is
    /// skipped), and stops once the window is filled.
    #[allow(clippy::too_many_arguments)]
    pub fn query_indexed_limited(
        &self,
        table: &str,
        index_table: &str,
        start: &[u8],
        end: &[u8],
        predicate_bytes: &[u8],
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_indexed_limited_with(
            &transaction,
            table,
            index_table,
            start,
            end,
            predicate_bytes,
            covered,
            limit,
            offset
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
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_indexed_limited_with(
            transaction,
            table,
            index_table,
            start,
            end,
            predicate_bytes,
            covered,
            limit,
            offset
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
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        let mut result = Vec::new();
        for entry in index_table
            .range(start..=end)
            .map_err(|error| WorkerError::Storage(error.to_string()))? {
            crate::work_count!(self, index_entries_visited, 1);
            let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_key = entry.1.value();
            crate::work_count!(self, primary_rows_fetched, 1);
            let Some(row_bytes) = user_table
                .get(row_key)
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .map(|v| v.value().to_vec()) else {
                continue;
            };
            if !covered {
                crate::work_count!(self, predicate_evaluations, 1);
                if !predicate.test_bytes_with_scratch(&row_bytes, &mut predicate_scratch) {
                    continue;
                }
            }
            result.push((row_key.to_vec(), row_bytes));
            if let Some(want) = want {
                if (result.len() as u64) >= want {
                    break;
                }
            }
        }
        if offset > 0 {
            let start_idx = (offset as usize).min(result.len());
            result = result.split_off(start_idx);
        }
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// full-scan + top-K sort. Scans every row in [table], evaluates
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
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.begin_read()?;
        self.query_sorted_with(&transaction, table, predicate_bytes, sort_spec_bytes, limit, offset)
    }

    /// Snapshot-bound variant of [Self::query_sorted].
    pub fn snapshot_query_sorted(
        &self,
        snapshot: u64,
        table: &str,
        predicate_bytes: &[u8],
        sort_spec_bytes: &[u8],
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        let transaction = self.snapshot_transaction(snapshot)?;
        self.query_sorted_with(transaction, table, predicate_bytes, sort_spec_bytes, limit, offset)
    }

    fn query_sorted_with(
        &self,
        transaction: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        sort_spec_bytes: &[u8],
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        use crate::sort_spec::decode_sort_specs;
        use crate::value_codec::RowValue;
        let specs = decode_sort_specs(sort_spec_bytes).map_err(WorkerError::Wire)?;
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let definition = table_definition(table);
        let table = match transaction.open_table(definition) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        if specs.is_empty() {
            return Ok(Vec::new());
        }
        let cap = limit.map(|l| offset.saturating_add(l) as usize).unwrap_or(usize::MAX);
        let mut heap = TopK::new(cap, |a: &SortCandidate, b: &SortCandidate| {
            // ties break by record key bytes (matching the durable-index
            // order and the Dart `_compareDecoded` tiebreak) so every backend
            // returns the same deterministic order.
            compare_rows_from_keys(a, b, &specs.specs).then_with(|| a.key.cmp(&b.key))
        });
        for entry in table.iter().map_err(|error| WorkerError::Storage(error.to_string()))? {
            let (key, value) = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
            let row_bytes = value.value();
            crate::work_count!(self, primary_rows_visited, 1);
            crate::work_count!(self, predicate_evaluations, 1);
            if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                continue;
            }
            // Decode the sort fields from one borrowed range scan. Values are
            // still decoded individually so mixed-type sort semantics remain
            // unchanged, but map keys are walked only once.
            let sort_fields = specs
                .specs
                .iter()
                .map(|spec| spec.field.clone())
                .collect::<Vec<_>>();
            let mut ranges = vec![None; sort_fields.len()];
            crate::value_codec::find_fields_ranges(row_bytes, &sort_fields, &mut ranges)
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            let mut sort_key: Vec<Option<RowValue>> = Vec::with_capacity(specs.specs.len());
            for range in ranges {
                let found = range
                    .map(|(start, end)| crate::value_codec::decode_value(&row_bytes[start..end]))
                    .transpose()
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
        let result = slice_offset_limit(sorted, limit, offset);
        crate::work_count!(self, rows_returned, result.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            result
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
        Ok(result)
    }

    /// index-ordered early-stop sort. When a query's sort field is covered
    /// by a durable index, the composite index keys are already ordered by
    /// `(value, recordId)` — the same order Dart's stable sort of that field
    /// produces (ties always break by ascending record key). This streams the
    /// index range `[start..=end]`, joins each entry to its row, applies
    /// [predicate_bytes] (unless [covered]), and stops once the window fills
    /// — no full scan, no sort.
    ///
    /// Calling modes (the Dart side routes accordingly):
    /// - [eq_bounded] = true: `start..=end` is an equality bound on the sort
    ///   field, so every matching row's sort key is equal and index-key
    ///   (recordId) order is the stable order for BOTH directions (ties break
    ///   ascending, so [descending] does not reorder).
    /// - [eq_bounded] = false, ascending: `start..=end` covers all values;
    ///   missing-field rows sort LAST and are appended via a table scan —
    ///   skipped entirely when the presence count proves the field is
    ///   complete across the whole table.
    /// - [eq_bounded] = false, descending: missing-field rows sort FIRST and
    ///   are emitted from a table scan (unless the field is complete), then
    ///   the index is streamed in REVERSE (the reverse index iterator); each
    ///   equal-value group is reversed back to ascending record keys so the
    ///   tie-break matches the top-K path exactly.
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
        descending: bool,
        covered: bool,
        limit: Option<u64>,
        offset: u64
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
            descending,
            covered,
            limit,
            offset
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
        descending: bool,
        covered: bool,
        limit: Option<u64>,
        offset: u64
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
            descending,
            covered,
            limit,
            offset
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
        descending: bool,
        covered: bool,
        limit: Option<u64>,
        offset: u64
    ) -> Result<Vec<ByteEntry>, WorkerError> {
        use crate::value_codec::find_field;
        let predicate = crate::predicate
            ::decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let mut predicate_scratch = predicate.scratch();
        let index_def = table_definition(index_table);
        let index_table = match transaction.open_table(index_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                // No durable index yet: the ordered result for the non-eq
                // mode is every matching row in recordId order. Fall back to
                // the full top-K sort (handles missing-field placement for
                // both directions).
                if eq_bounded {
                    return Ok(Vec::new());
                }
                let fallback_spec = crate::sort_spec::encode_sort_specs(
                    &[
                        crate::sort_spec::SortSpec {
                            field: sort_field.to_string(),
                            descending,
                        },
                    ]
                );
                return self.query_sorted_with(
                    transaction,
                    table,
                    predicate_bytes,
                    &fallback_spec,
                    limit,
                    offset
                );
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let user_def = table_definition(table);
        let user_table = match transaction.open_table(user_def) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(Vec::new());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let want = limit.map(|l| offset.saturating_add(l));
        if want == Some(0) {
            return Ok(Vec::new());
        }
        // Field-completeness (Priority 5): when the presence count for the
        // sort field equals the table length, no row is missing the field, so
        // the non-eq fallback scan is unnecessary.
        let user_len = user_table
            .len()
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        let sort_field_owned = sort_field.to_string();
        let sort_prefix = index_key_prefix(table, std::slice::from_ref(&sort_field_owned));
        let field_complete = eq_bounded
            || read_index_meta_count(transaction, &sort_prefix)? == user_len;

        let mut matches: Vec<ByteEntry> = Vec::new();
        let mut done = false;

        // Forward stream: values ascending, record keys ascending within a
        // value. Used for eq-bounded (both directions — all values equal, so
        // ties break ascending regardless of direction) and ascending non-eq.
        let forward = eq_bounded || !descending;
        if forward {
            for entry in index_table
                .range(start..=end)
                .map_err(|error| WorkerError::Storage(error.to_string()))? {
                if done {
                    break;
                }
                crate::work_count!(self, index_entries_visited, 1);
                let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                let row_key = entry.1.value();
                crate::work_count!(self, primary_rows_fetched, 1);
                let Some(row_bytes) = user_table
                    .get(row_key)
                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                    .map(|v| v.value().to_vec()) else {
                    continue;
                };
                if !covered {
                    crate::work_count!(self, predicate_evaluations, 1);
                    if !predicate.test_bytes_with_scratch(&row_bytes, &mut predicate_scratch) {
                        continue;
                    }
                }
                matches.push((row_key.to_vec(), row_bytes));
                if let Some(w) = want {
                    if (matches.len() as u64) >= w {
                        done = true;
                    }
                }
            }
        }

        if !eq_bounded && !descending {
            // Ascending non-eq: append missing-field rows (they sort LAST)
            // unless the field is complete. The skip set is pre-sized and the
            // scan is skipped entirely when the window already filled.
            let needs_append = !done
                && !field_complete
                && want.is_none_or(|w| (matches.len() as u64) < w);
            if needs_append {
                let mut present = std::collections::HashSet::with_capacity(matches.len());
                for m in &matches {
                    present.insert(m.0.clone());
                }
                for entry in user_table
                    .iter()
                    .map_err(|error| WorkerError::Storage(error.to_string()))? {
                    if done {
                        break;
                    }
                    let (key, value) =
                        entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                    let key_bytes = key.value().to_vec();
                    if present.contains(&key_bytes) {
                        continue;
                    }
                    let row_bytes = value.value();
                    crate::work_count!(self, primary_rows_visited, 1);
                    if !covered {
                        crate::work_count!(self, predicate_evaluations, 1);
                        if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                            continue;
                        }
                    }
                    let has_field = find_field(row_bytes, sort_field)
                        .map_err(|error| WorkerError::Storage(error.to_string()))?
                        .is_some();
                    if has_field {
                        // Has the field but no index entry — not a
                        // missing-field row; skip (should not happen when the
                        // durable index is maintained atomically).
                        continue;
                    }
                    matches.push((key_bytes, row_bytes.to_vec()));
                    if let Some(w) = want {
                        if (matches.len() as u64) >= w {
                            done = true;
                        }
                    }
                }
            }
        } else if !eq_bounded && descending {
            // Descending non-eq: missing-field rows sort FIRST, then
            // with-field rows in descending value order via the REVERSE index
            // iterator. Within an equal value the reverse stream yields record
            // keys descending; each contiguous equal-value group is reversed
            // back to ascending so the tie-break matches the top-K path.
            if !done && !field_complete {
                for entry in user_table
                    .iter()
                    .map_err(|error| WorkerError::Storage(error.to_string()))? {
                    if done {
                        break;
                    }
                    let (key, value) =
                        entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                    let key_bytes = key.value().to_vec();
                    let row_bytes = value.value();
                    crate::work_count!(self, primary_rows_visited, 1);
                    if !covered {
                        crate::work_count!(self, predicate_evaluations, 1);
                        if !predicate.test_bytes_with_scratch(row_bytes, &mut predicate_scratch) {
                            continue;
                        }
                    }
                    let has_field = find_field(row_bytes, sort_field)
                        .map_err(|error| WorkerError::Storage(error.to_string()))?
                        .is_some();
                    if has_field {
                        continue;
                    }
                    matches.push((key_bytes, row_bytes.to_vec()));
                    if let Some(w) = want {
                        if (matches.len() as u64) >= w {
                            done = true;
                        }
                    }
                }
            }
            let mut group: Vec<Vec<u8>> = Vec::new();
            let mut group_value: Option<Vec<crate::value_codec::RowValue>> = None;
            for entry in index_table
                .range(start..=end)
                .map_err(|error| WorkerError::Storage(error.to_string()))?
                .rev() {
                if done {
                    break;
                }
                crate::work_count!(self, index_entries_visited, 1);
                let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
                let value = index_key_values(entry.0.value());
                if group_value.as_ref() != value.as_ref() {
                    // Flush the previous equal-value group (key-desc in the
                    // reverse stream → reverse to key-asc).
                    group.reverse();
                    for row_key in group.drain(..) {
                        if done {
                            break;
                        }
                        crate::work_count!(self, primary_rows_fetched, 1);
                        let Some(row_bytes) = user_table
                            .get(row_key.as_slice())
                            .map_err(|error| WorkerError::Storage(error.to_string()))?
                            .map(|v| v.value().to_vec()) else {
                            continue;
                        };
                        if !covered {
                            crate::work_count!(self, predicate_evaluations, 1);
                            if !predicate.test_bytes_with_scratch(
                                &row_bytes,
                                &mut predicate_scratch
                            ) {
                                continue;
                            }
                        }
                        matches.push((row_key, row_bytes));
                        if let Some(w) = want {
                            if (matches.len() as u64) >= w {
                                done = true;
                            }
                        }
                    }
                    group_value = value;
                }
                group.push(entry.1.value().to_vec());
            }
            if !done {
                group.reverse();
                for row_key in group.drain(..) {
                    if done {
                        break;
                    }
                    crate::work_count!(self, primary_rows_fetched, 1);
                    let Some(row_bytes) = user_table
                        .get(row_key.as_slice())
                        .map_err(|error| WorkerError::Storage(error.to_string()))?
                        .map(|v| v.value().to_vec()) else {
                        continue;
                    };
                    if !covered {
                        crate::work_count!(self, predicate_evaluations, 1);
                        if !predicate.test_bytes_with_scratch(&row_bytes, &mut predicate_scratch) {
                            continue;
                        }
                    }
                    matches.push((row_key, row_bytes));
                    if let Some(w) = want {
                        if (matches.len() as u64) >= w {
                            done = true;
                        }
                    }
                }
            }
        }
        if offset > 0 {
            let start_idx = (offset as usize).min(matches.len());
            matches = matches.split_off(start_idx);
        }
        crate::work_count!(self, rows_returned, matches.len() as u64);
        crate::work_count!(
            self,
            bytes_returned,
            matches
                .iter()
                .map(|(key, value)| (key.len() + value.len()) as u64)
                .sum::<u64>()
        );
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
            return Err(
                WorkerError::InvalidOperation(
                    "database is read-only; compaction is not allowed".into()
                )
            );
        }
        if !self.snapshots.is_empty() {
            return Err(
                WorkerError::InvalidOperation(
                    format!(
                        "compaction requires no open MVCC snapshots; {} snapshot(s) are still active",
                        self.snapshots.len()
                    )
                )
            );
        }
        match &mut self.database {
            WorkerDatabase::ReadWrite(database) =>
                database.compact().map_err(Self::map_compaction_error),
            WorkerDatabase::ReadOnly(_) => unreachable!("read-only worker rejected above"),
        }
    }

    /// Maps a redb compaction failure onto the worker's error taxonomy: a write
    /// transaction (or savepoint) in progress is an `InvalidOperation` — the
    /// caller's single-writer discipline means a retry succeeds once the writer
    /// drains — while anything else is a genuine `Storage` failure.
    fn map_compaction_error(error: redb::CompactionError) -> WorkerError {
        use redb::CompactionError::*;
        match &error {
            TransactionInProgress | PersistentSavepointExists | EphemeralSavepointExists =>
                WorkerError::InvalidOperation(format!("compaction could not start: {error}")),
            _ => WorkerError::Storage(format!("compaction failed: {error}")),
        }
    }

    /// Reports physical (file) and logical (payload) size plus health counters
    /// Logical size iterates every table once in a consistent
    /// read snapshot.
    pub fn storage_stats(&self) -> Result<StorageStats, WorkerError> {
        let physical_bytes = std::fs
            ::metadata(&self.path)
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
            let definition = BytesTable::new(intern_table_name(name));
            let Ok(table) = transaction.open_table(definition) else {
                continue;
            };
            table_count += 1;
            let Ok(iter) = table.iter() else {
                continue;
            };
            for entry in iter.flatten() {
                let (key, value) = entry;
                logical_bytes += (key.value().len() as u64) + (value.value().len() as u64);
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
                table.name().strip_prefix(TABLE_PREFIX).unwrap_or(table.name()).to_owned()
            })
            .collect();
        Ok(tables)
    }
}

fn map_open_error(error: DatabaseError, path: &str) -> WorkerError {
    match error {
        DatabaseError::DatabaseAlreadyOpen =>
            WorkerError::DatabaseLocked(
                format!(
                    "database at {path} is already open; wait for the owner to close it and retry"
                )
            ),
        other => WorkerError::Storage(format!("could not open database at {path}: {other}")),
    }
}

pub(crate) fn table_definition(name: &str) -> BytesTable {
    // Interned: one leaked allocation per unique table name ever, not per
    // call — reads, writes, indexes, registry, and stats all share it, so
    // memory does not grow with operation count.
    let full_name = format!("{TABLE_PREFIX}{name}");
    TableDefinition::new(intern_table_name(full_name))
}

fn lsn_key() -> Vec<u8> {
    let mut key = vec![crate::value_codec::TAG_STRING];
    let bytes = b"lsn";
    key.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    key.extend_from_slice(bytes);
    key
}

fn lsn_value(sequence: u64) -> Vec<u8> {
    let mut value = vec![crate::value_codec::TAG_INT64];
    value.extend_from_slice(&(sequence as i64).to_be_bytes());
    value
}

fn validate_write_operations(operations: &[Op]) -> Result<(), WorkerError> {
    for operation in operations {
        match operation.kind {
            OpKind::Put if operation.key.is_none() => {
                return Err(WorkerError::InvalidOperation("put requires key".into()));
            }
            OpKind::Put if operation.value.is_none() => {
                return Err(WorkerError::InvalidOperation("put requires value".into()));
            }
            OpKind::Delete if operation.key.is_none() => {
                return Err(WorkerError::InvalidOperation("delete requires key".into()));
            }
            OpKind::DeleteRange if operation.start.is_none() => {
                return Err(WorkerError::InvalidOperation("deleteRange requires start".into()));
            }
            OpKind::DeleteRange if operation.end.is_none() => {
                return Err(WorkerError::InvalidOperation("deleteRange requires end".into()));
            }
            OpKind::Get | OpKind::RangeScan => {
                return Err(
                    WorkerError::InvalidOperation(
                        "read operations cannot be committed in a write batch".into()
                    )
                );
            }
            _ => {}
        }
    }
    Ok(())
}

fn load_commit_sequence(database: &WorkerDatabase) -> Result<u64, WorkerError> {
    let transaction = match database {
        WorkerDatabase::ReadWrite(database) =>
            database.begin_read().map_err(|error| WorkerError::Storage(error.to_string()))?,
        WorkerDatabase::ReadOnly(database) =>
            database.begin_read().map_err(|error| WorkerError::Storage(error.to_string()))?,
    };
    let meta = match transaction.open_table(table_definition("__gecko_sync_meta")) {
        Ok(meta) => meta,
        Err(redb::TableError::TableDoesNotExist(_)) => {
            return Ok(0);
        }
        Err(error) => {
            return Err(WorkerError::Storage(error.to_string()));
        }
    };
    let Some(value) = meta
        .get(lsn_key().as_slice())
        .map_err(|error| WorkerError::Storage(error.to_string()))? else {
        return Ok(0);
    };
    match
        crate::value_codec
            ::decode_value(value.value())
            .map_err(|error| WorkerError::Storage(format!("invalid persisted LSN: {error}")))?
    {
        crate::value_codec::RowValue::Int64(value) if value >= 0 => Ok(value as u64),
        _ => Err(WorkerError::Storage("invalid persisted LSN value".into())),
    }
}

fn next_sequence_in_write_transaction(
    transaction: &WriteTransaction,
    in_memory_sequence: u64
) -> Result<u64, WorkerError> {
    let meta = transaction
        .open_table(table_definition("__gecko_sync_meta"))
        .map_err(|error| WorkerError::Storage(error.to_string()))?;
    let persisted = meta
        .get(lsn_key().as_slice())
        .map_err(|error| WorkerError::Storage(error.to_string()))?
        .map(|value| value.value().to_vec());
    let persisted = persisted
        .as_deref()
        .map(crate::value_codec::decode_value)
        .transpose()
        .map_err(|error| WorkerError::Storage(format!("invalid persisted LSN: {error}")))?
        .map(|value| {
            match value {
                crate::value_codec::RowValue::Int64(value) if value >= 0 => Ok(value as u64),
                crate::value_codec::RowValue::Int64(_) => {
                    Err(WorkerError::Storage("invalid persisted LSN value".into()))
                }
                _ => Err(WorkerError::Storage("invalid persisted LSN value".into())),
            }
        })
        .transpose()?;
    Ok(persisted.unwrap_or(0).max(in_memory_sequence) + 1)
}

/// Opens (or reuses) a table handle for one write transaction. Every table
/// referenced by a batch is opened at most once; the handle stays alive in
/// [handles] for the rest of the transaction.
fn open_write_table<'a, 'txn>(
    handles: &'a mut WriteTableCache<'txn>,
    transaction: &'txn WriteTransaction,
    name: &str,
    counters: &AtomicCounters
) -> Result<&'a mut Table<'txn, &'static [u8], &'static [u8]>, WorkerError> {
    if !handles.contains_key(name) {
        let table = transaction
            .open_table(table_definition(name))
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        counters.bump(&counters.table_opens, 1);
        handles.insert(name.to_string(), table);
    }
    Ok(handles.get_mut(name).expect("inserted just above"))
}

fn write_prepared_templates<'txn>(
    transaction: &'txn WriteTransaction,
    handles: &mut WriteTableCache<'txn>,
    operation_index: usize,
    previous: Option<&[u8]>,
    sequence: u64,
    templates: &[PreparedChangeTemplate],
    counters: &AtomicCounters
) -> Result<(), WorkerError> {
    for template in templates
        .iter()
        .filter(|template| template.operation_index == operation_index) {
        let record = crate::value_codec
            ::rewrite_change_record(
                &template.record_template,
                sequence,
                template.fill_previous_version.then_some(previous)
            )
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let log_key = encode_change_log_key(sequence, template.ordinal);
        {
            let log = open_write_table(handles, transaction, "__gecko_change_log", counters)?;
            log
                .insert(log_key.as_slice(), record.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
        }
        {
            let state = open_write_table(handles, transaction, "__gecko_sync_state", counters)?;
            state
                .insert(template.sync_state_key.as_slice(), record.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
        }
    }
    Ok(())
}

/// Reads the `dirty` flag from a change-record map (encoded with the
/// DefaultWireCodec port). A missing `dirty` field defaults to true (dirty →
/// kept), matching the Dart `_recordFromMap` default.
fn change_record_dirty(row_bytes: &[u8]) -> bool {
    match crate::value_codec::find_field(row_bytes, "dirty") {
        Ok(Some(crate::value_codec::RowValue::Bool(b))) => b,
        _ => true,
    }
}

/// Reads `localMutationId` from a change-record map.
fn change_record_mutation_id(row_bytes: &[u8]) -> u64 {
    match crate::value_codec::find_field(row_bytes, "localMutationId") {
        Ok(Some(crate::value_codec::RowValue::Int64(n))) => n.max(0) as u64,
        _ => 0,
    }
}

/// Parses a `u32_be` length-prefixed slice, returning `(payload, rest)`.
fn take_u32_prefixed(mut m: &[u8]) -> Result<(&[u8], &[u8]), ()> {
    if m.len() < 4 {
        return Err(());
    }
    let len = u32::from_be_bytes([m[0], m[1], m[2], m[3]]) as usize;
    m = &m[4..];
    if m.len() < len {
        return Err(());
    }
    Ok((&m[..len], &m[len..]))
}

/// Decodes a wire-encoded string field value (e.g. `parentCollection`).
fn decode_string_value(bytes: &[u8]) -> Option<String> {
    use crate::value_codec::{RowValue, ValueReader};
    let mut reader = ValueReader::new(bytes);
    match reader.read_value() {
        Ok(RowValue::String(s)) => Some(s),
        _ => None,
    }
}

/// Whether [row] (an encoded change record) matches any of the encoded
/// [matchers] (see [`RedbWorker::sync_state_matching`] for the layout).
/// Compares the encoded `recordId` (and `collection` for a `RecordRef`
/// matcher) byte-exactly, mirroring Dart's `_matches` semantics.
fn sync_state_matches(row: &[u8], matchers: &[Vec<u8>]) -> bool {
    use crate::value_codec::find_field_bytes;
    let record_id = match find_field_bytes(row, "recordId") {
        Ok(Some(b)) => b,
        _ => return false,
    };
    let collection = match find_field_bytes(row, "collection") {
        Ok(Some(b)) => Some(b),
        _ => None,
    };
    matchers.iter().any(|m| {
        let m = &m[..];
        if m.is_empty() {
            return false;
        }
        match m[0] {
            0x00 => {
                let Ok((rid, rest)) = take_u32_prefixed(&m[1..]) else {
                    return false;
                };
                rest.is_empty() && rid == record_id
            }
            0x01 => {
                let Ok((col, m2)) = take_u32_prefixed(&m[1..]) else {
                    return false;
                };
                let Ok((rid, rest)) = take_u32_prefixed(m2) else {
                    return false;
                };
                rest.is_empty() && rid == record_id && collection == Some(col)
            }
            _ => false,
        }
    })
}

/// Encodes the persisted sync watermark key (DefaultWireCodec string
/// "watermark" stored in `__gecko_sync_meta`).
fn encode_watermark_key() -> Vec<u8> {
    let mut key = vec![crate::value_codec::TAG_STRING];
    let wm = b"watermark";
    key.extend_from_slice(&(wm.len() as u32).to_be_bytes());
    key.extend_from_slice(wm);
    key
}

/// Reads the persisted sync watermark: the highest LSN at or below which every
/// CLEAN change-log record was already pruned. Absent or malformed values read
/// as 0.
fn read_change_log_watermark(transaction: &WriteTransaction) -> Result<u64, WorkerError> {
    let meta = match transaction.open_table(table_definition("__gecko_sync_meta")) {
        Ok(t) => t,
        Err(redb::TableError::TableDoesNotExist(_)) => {
            return Ok(0);
        }
        Err(error) => {
            return Err(WorkerError::Storage(error.to_string()));
        }
    };
    let key = encode_watermark_key();
    let Some(value) = meta
        .get(key.as_slice())
        .map_err(|error| WorkerError::Storage(error.to_string()))? else {
        return Ok(0);
    };
    Ok(match crate::value_codec::decode_value(value.value()) {
        Ok(crate::value_codec::RowValue::Int64(n)) => n.max(0) as u64,
        _ => 0,
    })
}

/// Prunes the pending-sync change log in the given write
/// transaction when it exceeds [max_entries]. Only NON-DIRTY records (already
/// synced) are pruned, oldest-first (the log is keyed by `[lsn, ordinal]`, so
/// table iteration order is commit order). The sync watermark is advanced to
/// the highest pruned LSN — matching the previous Dart-side behavior, now
/// executed in the same transaction as the batch that grew the log.
///
/// Pruning is incremental: the total count is read O(1) via the table length,
/// the scan is bounded to the prunable prefix that starts at `[watermark, 0]`
/// (every clean record at or below the watermark is already gone), and the
/// scan stops as soon as `excess` clean records have been collected. Only
/// keys (never values) are materialized, bounded by the overflow.
fn prune_change_log(
    transaction: &WriteTransaction,
    max_entries: u64,
    counters: &AtomicCounters
) -> Result<(), WorkerError> {
    if max_entries == 0 {
        return Ok(());
    }
    let mut log = match transaction.open_table(table_definition("__gecko_change_log")) {
        Ok(t) => t,
        Err(redb::TableError::TableDoesNotExist(_)) => {
            return Ok(());
        }
        Err(error) => {
            return Err(WorkerError::Storage(error.to_string()));
        }
    };
    // O(1) count; when the log is within budget there is nothing to prune and
    // not a single entry is scanned.
    let total = log.len().map_err(|error| WorkerError::Storage(error.to_string()))?;
    if total <= max_entries {
        return Ok(());
    }
    let excess = total - max_entries;

    // Scan the prunable prefix only. Starting at [watermark, 0] (rather than
    // watermark + 1) also re-covers clean records that share the watermark
    // LSN when a previous prune stopped exactly at the excess boundary.
    let watermark = read_change_log_watermark(transaction)?;
    let start_key = encode_change_log_key(watermark, 0);

    let mut to_remove: Vec<Vec<u8>> = Vec::with_capacity(excess.min(1024) as usize);
    let mut highest_pruned_lsn: u64 = 0;
    let range = log
        .range(start_key.as_slice()..)
        .map_err(|error| WorkerError::Storage(error.to_string()))?;
    for entry in range {
        counters.bump(&counters.change_log_scanned, 1);
        let entry = entry.map_err(|error| WorkerError::Storage(error.to_string()))?;
        if to_remove.len() as u64 >= excess {
            break;
        }
        let row = entry.1.value();
        if !change_record_dirty(row) {
            let lsn = change_record_mutation_id(row);
            if lsn > highest_pruned_lsn {
                highest_pruned_lsn = lsn;
            }
            to_remove.push(entry.0.value().to_vec());
        }
    }
    for key in &to_remove {
        log
            .remove(key.as_slice())
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        counters.bump(&counters.change_log_pruned, 1);
    }
    if highest_pruned_lsn > 0 {
        let mut meta = match transaction.open_table(table_definition("__gecko_sync_meta")) {
            Ok(t) => t,
            Err(redb::TableError::TableDoesNotExist(_)) => {
                return Ok(());
            }
            Err(error) => {
                return Err(WorkerError::Storage(error.to_string()));
            }
        };
        let key = encode_watermark_key();
        let old = meta
            .get(key.as_slice())
            .map_err(|error| WorkerError::Storage(error.to_string()))?
            .map(|v| v.value().to_vec());
        let old_wm = old
            .as_deref()
            .and_then(|bytes| crate::value_codec::decode_value(bytes).ok())
            .and_then(|value| {
                match value {
                    crate::value_codec::RowValue::Int64(n) => Some(n.max(0) as u64),
                    _ => None,
                }
            })
            .unwrap_or(0);
        let new_wm = old_wm.max(highest_pruned_lsn);
        // Watermark value = DefaultWireCodec int64.
        let mut value = vec![crate::value_codec::TAG_INT64];
        value.extend_from_slice(&(new_wm as i64).to_be_bytes());
        meta
            .insert(key.as_slice(), value.as_slice())
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
    }
    Ok(())
}

/// Large-delete memory/backpressure policy. DeleteRange and Clear report
/// every removed primary key to the caller (affected-key reporting), so the
/// removed key set is inherently materialized. Values are streamed and never
/// materialized. This cap bounds the key materialization so a pathological
/// delete cannot allocate without limit; a delete that exceeds it fails
/// without committing, leaving the whole transaction unchanged (rollback).
const MAX_DELETE_RANGE_KEYS: u64 = 1_000_000;

/// Hard cap on concurrently open MVCC snapshots. Each held snapshot pins
/// every newer MVCC version in the file, so an unbounded leak would block
/// compaction and grow the database indefinitely. The Dart layer always
/// disposes snapshots in `try/finally`; this cap turns a hypothetical leak
/// into a typed error instead of unbounded pinning.
const MAX_OPEN_SNAPSHOTS: usize = 256;

fn enforce_delete_memory_policy(keys: &[Vec<u8>]) -> Result<(), WorkerError> {
    if keys.len() as u64 > MAX_DELETE_RANGE_KEYS {
        return Err(
            WorkerError::InvalidOperation(
                format!(
                    "delete removes {} rows, exceeding the {MAX_DELETE_RANGE_KEYS} \
                     row backpressure limit",
                    keys.len()
                )
            )
        );
    }
    Ok(())
}

/// One durable-index entry: an ordered field list (a single field for the
/// classic single-field index, or a composite) plus its precomputed encoded
/// key prefix (`[TAG_LIST, u32(2+2n), enc(table), enc(f1), enc(f2), …]` —
/// field names only, no values, no record key).
struct IndexPlanEntry {
    fields: Vec<String>,
    prefix: Vec<u8>,
}

/// Per-batch durable-index plan: O(1) field lookup per operation and the
/// stable encoded key prefix per index entry (single-field AND composite),
/// precomputed once so per-op index maintenance never re-scans
/// `index_definitions`/the composite plan or re-encodes prefixes.
struct IndexPlan {
    /// table name → index entries (single-field + composite)
    by_table: HashMap<String, Vec<IndexPlanEntry>>,
}

/// Encodes the durable-index key prefix for an index entry on [table] with
/// the ordered field list [fields] — the shared bytes of every composite key
/// for that entry (list header + table + field names, no values).
fn index_key_prefix(table: &str, fields: &[String]) -> Vec<u8> {
    use crate::value_codec::TAG_LIST;
    let mut out = vec![TAG_LIST];
    out.extend_from_slice(&((2 + 2 * fields.len()) as u32).to_be_bytes());
    out.extend_from_slice(&encode_index_string(table));
    for field in fields {
        out.extend_from_slice(&encode_index_string(field));
    }
    out
}

impl IndexPlan {
    /// Builds the plan from the flat per-batch single-field declarations
    /// [index_definitions] plus the session-scoped composite declarations
    /// [composite_plan].
    fn build(
        index_definitions: &[(String, Vec<String>)],
        composite_plan: &HashMap<String, Vec<Vec<String>>>
    ) -> Self {
        let mut by_table = HashMap::with_capacity(index_definitions.len());
        for (table, fields) in index_definitions {
            if fields.is_empty() || table == "__gecko_index" {
                continue;
            }
            let entries = fields
                .iter()
                .map(|field| {
                    let prefix = index_key_prefix(table, std::slice::from_ref(field));
                    IndexPlanEntry {
                        fields: vec![field.clone()],
                        prefix,
                    }
                })
                .collect::<Vec<_>>();
            by_table.insert(table.clone(), entries);
        }
        for (table, indexes) in composite_plan {
            if table == "__gecko_index" {
                continue;
            }
            let entries = by_table.entry(table.clone()).or_default();
            for fields in indexes {
                if fields.is_empty() {
                    continue;
                }
                let prefix = index_key_prefix(table, fields);
                entries.push(IndexPlanEntry {
                    fields: fields.clone(),
                    prefix,
                });
            }
        }
        Self { by_table }
    }
}

/// Extracts the encoded byte ranges of every [fields] field from [row],
/// returning `Some(ranges)` only when ALL fields are present (a composite
/// index entry requires every constituent field; a missing field means no
/// entry for that row version, exactly like a missing single field).
fn extract_field_slices<'a>(
    row: Option<&'a [u8]>,
    fields: &[String]
) -> Result<Option<Vec<&'a [u8]>>, WorkerError> {
    let Some(row) = row else {
        return Ok(None);
    };
    let mut ranges = vec![None; fields.len()];
    crate::value_codec::find_fields_ranges(row, fields, &mut ranges)
        .map_err(|error| WorkerError::Storage(error.to_string()))?;
    if ranges.iter().any(Option::is_none) {
        return Ok(None);
    }
    Ok(Some(
        ranges
            .into_iter()
            .map(|range| {
                let (start, end) = range.expect("all fields present");
                &row[start..end]
            })
            .collect()
    ))
}

/// Adjusts the per-index-entry presence count in `__gecko_index_meta` by
/// [delta] (used to prove a sort field is complete across the whole table,
/// which lets the index-ordered path skip its missing-field fallback scan).
/// Keyed by the entry's encoded prefix; rows with a count of zero are removed.
fn bump_index_meta<'txn>(
    meta_table: &mut Option<Table<'txn, &'static [u8], &'static [u8]>>,
    transaction: &'txn WriteTransaction,
    entry: &IndexPlanEntry,
    delta: i64,
    counters: &AtomicCounters
) -> Result<(), WorkerError> {
    if meta_table.is_none() {
        let opened = transaction
            .open_table(table_definition("__gecko_index_meta"))
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        counters.bump(&counters.table_opens, 1);
        *meta_table = Some(opened);
    }
    let meta = meta_table.as_mut().expect("opened just above");
    let current = meta
        .get(entry.prefix.as_slice())
        .map_err(|error| WorkerError::Storage(error.to_string()))?
        .map(|value| value.value().to_vec());
    let count = current
        .as_deref()
        .and_then(|bytes| crate::value_codec::decode_value(bytes).ok())
        .and_then(|value| {
            match value {
                crate::value_codec::RowValue::Int64(n) => Some(n),
                _ => None,
            }
        })
        .unwrap_or(0)
        .saturating_add(delta);
    if count <= 0 {
        meta
            .remove(entry.prefix.as_slice())
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
    } else {
        let mut value = vec![crate::value_codec::TAG_INT64];
        value.extend_from_slice(&count.to_be_bytes());
        meta
            .insert(entry.prefix.as_slice(), value.as_slice())
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
    }
    Ok(())
}

/// Maintains the durable index for one primary-row mutation. The index and
/// presence-meta tables are opened at most once per batch ([index_table] /
/// [meta_table]); old/new field values are compared as byte slices before any
/// allocation, and index keys are built in a caller-provided scratch buffer.
/// The exact encoded prefixes from [plan] (single-field AND composite)
/// preserve the index-key bytes used by query and repair code.
///
/// The argument count is inherent to the batch-maintenance contract (open
/// transaction, cached index/meta handles, plan, row identity, both row
/// versions, scratch, counters); bundling them would allocate per call on the
/// hot path.
#[allow(clippy::too_many_arguments)]
fn maintain_durable_index<'txn>(
    transaction: &'txn WriteTransaction,
    index_table: &mut Option<Table<'txn, &'static [u8], &'static [u8]>>,
    meta_table: &mut Option<Table<'txn, &'static [u8], &'static [u8]>>,
    plan: &IndexPlan,
    table: &str,
    record_key: &[u8],
    old_row: Option<&[u8]>,
    new_row: Option<&[u8]>,
    scratch: &mut Vec<u8>,
    counters: &AtomicCounters
) -> Result<(), WorkerError> {
    if table == "__gecko_index" || table == "__gecko_index_meta" {
        return Ok(());
    }
    let Some(entries) = plan.by_table.get(table) else {
        return Ok(());
    };
    if entries.is_empty() {
        return Ok(());
    }
    if index_table.is_none() {
        let opened = transaction
            .open_table(table_definition("__gecko_index"))
            .map_err(|error| WorkerError::Storage(error.to_string()))?;
        counters.bump(&counters.table_opens, 1);
        *index_table = Some(opened);
    }
    let index = index_table.as_mut().expect("opened just above");
    for entry in entries {
        let old_values = extract_field_slices(old_row, &entry.fields)?;
        let new_values = extract_field_slices(new_row, &entry.fields)?;
        // Byte-slice equality: no allocation when every indexed value is
        // unchanged (the common update-that-touches-other-fields case).
        if old_values == new_values {
            continue;
        }
        if let Some(values) = old_values {
            scratch.clear();
            scratch.extend_from_slice(&entry.prefix);
            for value in &values {
                scratch.push(crate::value_codec::TAG_ORDERED);
                crate::value_codec
                    ::push_order_encode_slice(scratch, value)
                    .map_err(|error| WorkerError::Storage(error.to_string()))?;
            }
            scratch.extend_from_slice(record_key);
            index
                .remove(scratch.as_slice())
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            counters.bump(&counters.index_maintenance_ops, 1);
            bump_index_meta(meta_table, transaction, entry, -1, counters)?;
        }
        if let Some(values) = new_values {
            scratch.clear();
            scratch.extend_from_slice(&entry.prefix);
            for value in &values {
                scratch.push(crate::value_codec::TAG_ORDERED);
                crate::value_codec
                    ::push_order_encode_slice(scratch, value)
                    .map_err(|error| WorkerError::Storage(error.to_string()))?;
            }
            scratch.extend_from_slice(record_key);
            index
                .insert(scratch.as_slice(), record_key)
                .map_err(|error| WorkerError::Storage(error.to_string()))?;
            counters.bump(&counters.index_maintenance_ops, 1);
            bump_index_meta(meta_table, transaction, entry, 1, counters)?;
        }
    }
    Ok(())
}

/// Durable-index composite key: `[TAG_LIST, u32(2+2n), enc(table),
/// enc(f1), enc(f2), …, TAG_ORDERED, ord(v1), ord(v2), …, recordKey]` — all
/// field names first, then all order-preserving values (the same layout
/// `maintain_durable_index` and the Dart bounds use, so maintenance, repair,
/// and query bounds always agree). For n=1 this is byte-identical to the
/// classic single-field key. [values] must be the raw codec-encoded field
/// bytes (one per field), which are re-encoded into the order-preserving
/// element.
fn durable_index_key_multi(
    table: &str,
    fields: &[&str],
    values: &[&[u8]],
    record_key: &[u8]
) -> Vec<u8> {
    use crate::value_codec::{ TAG_LIST, TAG_ORDERED };
    debug_assert_eq!(fields.len(), values.len());
    let mut out = vec![TAG_LIST];
    out.extend_from_slice(&((2 + 2 * fields.len()) as u32).to_be_bytes());
    out.extend_from_slice(&encode_index_string(table));
    for field in fields {
        out.extend_from_slice(&encode_index_string(field));
    }
    for value in values {
        out.push(TAG_ORDERED);
        crate::value_codec
            ::push_order_encode_slice(&mut out, value)
            .expect("index value is a valid codec-encoded field value");
    }
    out.extend_from_slice(record_key);
    out
}

fn durable_index_key(table: &str, field: &str, value: &[u8], record_key: &[u8]) -> Vec<u8> {
    durable_index_key_multi(table, &[field], &[value], record_key)
}

fn encode_index_string(value: &str) -> Vec<u8> {
    use crate::value_codec::TAG_STRING;
    let bytes = value.as_bytes();
    let mut out = vec![TAG_STRING];
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(bytes);
    out
}

fn durable_index_table(bytes: &[u8]) -> Option<String> {
    let value = crate::value_codec::decode_value(bytes).ok()?;
    let crate::value_codec::RowValue::List(values) = value else {
        return None;
    };
    match values.first() {
        Some(crate::value_codec::RowValue::String(table)) => Some(table.clone()),
        _ => None,
    }
}

/// Reads the presence count for one index entry (`__gecko_index_meta` keyed
/// by the entry's encoded prefix) in a read transaction. Absent or malformed
/// values read as 0. Used to prove a sort field is complete across the whole
/// table, which lets the index-ordered path skip its missing-field fallback.
fn read_index_meta_count(
    transaction: &ReadTransaction,
    prefix: &[u8]
) -> Result<u64, WorkerError> {
    let meta = match transaction.open_table(table_definition("__gecko_index_meta")) {
        Ok(t) => t,
        Err(redb::TableError::TableDoesNotExist(_)) => {
            return Ok(0);
        }
        Err(error) => {
            return Err(WorkerError::Storage(error.to_string()));
        }
    };
    let Some(value) = meta
        .get(prefix)
        .map_err(|error| WorkerError::Storage(error.to_string()))? else {
        return Ok(0);
    };
    Ok(match crate::value_codec::decode_value(value.value()) {
        Ok(crate::value_codec::RowValue::Int64(n)) => n.max(0) as u64,
        _ => 0,
    })
}

/// Decodes the ordered value element(s) of a durable-index composite key —
/// `[TAG_LIST, count, table, f1, f2, …, v1, v2, …, recordKey]` (field names
/// first, then values) — returning the values in field order. The trailing
/// record-key element is RAW bytes (not a codec value), so the list is parsed
/// element-by-element and the record key tail is never decoded. Used to group
/// contiguous equal-value runs when streaming the index in REVERSE for a
/// descending sort (within an equal value, the reverse stream yields record
/// keys descending, which must be reversed back to ascending to match the
/// stable tie-break).
fn index_key_values(key: &[u8]) -> Option<Vec<crate::value_codec::RowValue>> {
    use crate::value_codec::ValueReader;
    let mut r = ValueReader::new(key);
    if r.read_u8().ok()? != crate::value_codec::TAG_LIST {
        return None;
    }
    let count = r.read_u32_be().ok()? as usize;
    if count < 4 {
        return None; // table + field + value + recordKey minimum
    }
    let mut elements = Vec::with_capacity(count - 1);
    for _ in 0..(count - 1) {
        elements.push(r.read_value().ok()?);
    }
    // elements = [table, f1, f2, …, v1, v2, …]; the values occupy the
    // trailing half (n = (len-1)/2 fields, values start at index 1+n).
    let value_start = elements.len().div_ceil(2);
    Some(elements[value_start..].to_vec())
}

fn encode_change_log_key(sequence: u64, ordinal: u64) -> Vec<u8> {
    let mut out = vec![crate::value_codec::TAG_LIST];
    out.extend_from_slice(&(2u32).to_be_bytes());
    let mut seq = vec![crate::value_codec::TAG_INT64];
    seq.extend_from_slice(&(sequence as i64).to_be_bytes());
    let mut ord = vec![crate::value_codec::TAG_INT64];
    ord.extend_from_slice(&(ordinal as i64).to_be_bytes());
    out.extend_from_slice(&seq);
    out.extend_from_slice(&ord);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{ SystemTime, UNIX_EPOCH };

    fn temp_path(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
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
            .apply_batch(
                &[
                    op(OpKind::Put, Some(vec![2]), Some(vec![20])),
                    op(OpKind::Put, Some(vec![1]), Some(vec![10])),
                ]
            )
            .unwrap();
        assert_eq!(sequence, 1);
        assert_eq!(worker.get("items", &[1]).unwrap(), Some(vec![10]));
        assert_eq!(
            worker.range_scan("items", Some(&[1]), Some(&[2])).unwrap(),
            vec![(vec![1], vec![10]), (vec![2], vec![20])]
        );
        worker.apply_batch(&[op(OpKind::Delete, Some(vec![1]), None)]).unwrap();
        assert_eq!(worker.get("items", &[1]).unwrap(), None);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn prepared_batch_preserves_repeated_previous_values_and_sequence() {
        let path = temp_path("prepared-repeated");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let first = encode_test_row(&[("n", encode_test_int64(0))]);
        let second = encode_test_row(&[("n", encode_test_int64(1))]);
        let third = encode_test_row(&[("n", encode_test_int64(3))]);
        worker.apply_batch(&[op(OpKind::Put, Some(b"k".to_vec()), Some(first.clone()))]).unwrap();
        let templates = vec![
            PreparedChangeTemplate {
                operation_index: 0,
                ordinal: 0,
                sync_state_key: b"state".to_vec(),
                record_template: encode_change_record_template(0, &first),
                fill_previous_version: true,
            },
            PreparedChangeTemplate {
                operation_index: 1,
                ordinal: 1,
                sync_state_key: b"state".to_vec(),
                record_template: encode_change_record_template(0, &first),
                fill_previous_version: true,
            },
            PreparedChangeTemplate {
                operation_index: 2,
                ordinal: 2,
                sync_state_key: b"state".to_vec(),
                record_template: encode_change_record_template(0, &first),
                fill_previous_version: true,
            }
        ];
        let outcome = worker
            .apply_prepared_batch(
                &[
                    op(OpKind::Put, Some(b"k".to_vec()), Some(second.clone())),
                    op(OpKind::Delete, Some(b"k".to_vec()), None),
                    op(OpKind::Put, Some(b"k".to_vec()), Some(third.clone())),
                ],
                &[],
                0,
                &[0, 1, 2],
                &[],
                &templates
            )
            .unwrap();
        assert_eq!(outcome.sequence, 2);
        assert_eq!(outcome.previous_values, vec![Some(first.clone()), Some(second.clone()), None]);
        assert_eq!(worker.commit_sequence(), 2);
        let log = worker.range_scan("__gecko_change_log", None, None).unwrap();
        assert_eq!(log.len(), 3);
        let expected_previous = [
            Some(first),
            Some(second),
            Some(vec![crate::value_codec::TAG_NULL]),
        ];
        for (ordinal, (_, record)) in log.iter().enumerate() {
            assert_eq!(change_record_mutation_id(record), 2);
            assert_eq!(decode_change_record_previous(record), expected_previous[ordinal]);
        }
        assert_eq!(worker.get("items", b"k").unwrap(), Some(third));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn counters_are_zero_when_disabled_and_populated_when_enabled() {
        let path = temp_path("counters");
        let mut worker = RedbWorker::open(&path, false).unwrap();

        // Disabled by default: work happens, but no counter is touched.
        worker.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![10]))]).unwrap();
        let _ = worker.get("items", &[1]).unwrap();
        assert_eq!(worker.take_counters(), WorkCounters::default());

        // Enabled: writes and reads are counted and drained.
        worker.enable_counters();
        worker.apply_batch(&[op(OpKind::Put, Some(vec![2]), Some(vec![20]))]).unwrap();
        let _ = worker.get("items", &[2]).unwrap();
        let counters = worker.take_counters();
        assert_eq!(counters.batches_applied, 1);
        assert_eq!(counters.rows_written, 1);
        assert_eq!(counters.rows_returned, 1);
        assert_eq!(counters.bytes_returned, 1);

        // take_counters resets: a drain with no intervening work is all-zero.
        assert_eq!(worker.take_counters(), WorkCounters::default());

        // disable_counters resets and stops recording.
        worker.enable_counters();
        worker.apply_batch(&[op(OpKind::Put, Some(vec![3]), Some(vec![30]))]).unwrap();
        worker.disable_counters();
        assert_eq!(worker.take_counters(), WorkCounters::default());
        worker.apply_batch(&[op(OpKind::Put, Some(vec![4]), Some(vec![40]))]).unwrap();
        assert_eq!(worker.take_counters(), WorkCounters::default());

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
    fn prepared_batch_put_modes_fail_without_mutation_or_sequence() {
        let path = temp_path("put-modes");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.apply_batch(&[op(OpKind::Put, Some(b"k".to_vec()), Some(vec![1]))]).unwrap();
        let before = worker.commit_sequence();

        // insertOnly on an existing key: error, no mutation, no sequence.
        let err = worker
            .apply_prepared_batch(
                &[op(OpKind::Put, Some(b"k".to_vec()), Some(vec![2]))],
                &[],
                0,
                &[],
                &[(0, 1)],
                &[]
            )
            .unwrap_err();
        assert!(matches!(err, WorkerError::InvalidOperation(_)));
        assert_eq!(worker.commit_sequence(), before);
        assert_eq!(worker.get("items", b"k").unwrap(), Some(vec![1]));

        // updateOnly on a missing key: error, no mutation, no sequence.
        let err = worker
            .apply_prepared_batch(
                &[op(OpKind::Put, Some(b"missing".to_vec()), Some(vec![2]))],
                &[],
                0,
                &[],
                &[(0, 2)],
                &[]
            )
            .unwrap_err();
        assert!(matches!(err, WorkerError::KeyNotFound(_)));
        assert_eq!(worker.commit_sequence(), before);
        assert_eq!(worker.get("items", b"missing").unwrap(), None);

        // Successful updateOnly (mode 2) and insertOnly (mode 1) still work
        // and report the correct previous values.
        let outcome = worker
            .apply_prepared_batch(
                &[
                    op(OpKind::Put, Some(b"k".to_vec()), Some(vec![2])),
                    op(OpKind::Put, Some(b"new".to_vec()), Some(vec![3])),
                ],
                &[],
                0,
                &[0],
                &[(0, 2), (1, 1)],
                &[]
            )
            .unwrap();
        assert_eq!(outcome.sequence, before + 1);
        assert_eq!(outcome.previous_values, vec![Some(vec![1])]);
        assert_eq!(worker.get("items", b"k").unwrap(), Some(vec![2]));
        assert_eq!(worker.get("items", b"new").unwrap(), Some(vec![3]));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn write_batch_caches_table_handles_and_counts_previous_reads() {
        let path = temp_path("table-handles");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.enable_counters();
        // 10 puts across 2 tables: the per-batch handle cache must open each
        // table exactly once, and every plain upsert performs exactly one
        // previous-value read (the insert return value).
        let mut ops = Vec::new();
        for i in 0..5u8 {
            ops.push(op(OpKind::Put, Some(vec![i]), Some(vec![i + 1])));
            ops.push(op_with_table(OpKind::Put, "other", Some(vec![i]), Some(vec![i + 10])));
        }
        worker.apply_batch(&ops).unwrap();
        let counters = worker.take_counters();
        assert_eq!(counters.table_opens, 2, "each table opened once per batch");
        assert_eq!(counters.previous_value_reads, 10, "one read per upsert");
        assert_eq!(counters.rows_written, 10);

        // Repeated keys in one batch: the second put reads the first's value
        // through the same cached handle.
        worker
            .apply_batch(
                &[
                    op(OpKind::Put, Some(b"k".to_vec()), Some(vec![1])),
                    op(OpKind::Put, Some(b"k".to_vec()), Some(vec![2])),
                ]
            )
            .unwrap();
        let counters = worker.take_counters();
        assert_eq!(counters.table_opens, 1);
        assert_eq!(counters.previous_value_reads, 2);
        assert_eq!(worker.get("items", b"k").unwrap(), Some(vec![2]));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn index_maintenance_is_batched_and_reuses_scratch() {
        let path = temp_path("index-batched");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.enable_counters();
        let indexes = indexed_definition();
        let mut ops = Vec::new();
        for i in 0..4u8 {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "items",
                    Some(format!("k{i}").into_bytes()),
                    Some(
                        encode_test_row(
                            &[
                                ("age", encode_test_int64(i as i64)),
                                ("name", encode_test_string(&format!("n{i}"))),
                            ]
                        )
                    )
                )
            );
        }
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        let counters = worker.take_counters();
        // 4 puts × 2 indexed fields = 8 index maintenance ops; the user table,
        // the index table, and the presence-meta table are each opened once.
        assert_eq!(counters.index_maintenance_ops, 8);
        assert_eq!(counters.table_opens, 3);
        assert_eq!(index_value(&worker, "age", &encode_test_int64(3), b"k3"), Some(b"k3".to_vec()));
        assert_eq!(index_value(&worker, "name", &encode_test_string("n1"), b"k1"), Some(b"k1".to_vec()));

        // Update only the name of k0: the unchanged `age` slice must not touch
        // the index, so exactly one old + one new index op happen.
        worker
            .apply_batch_with_indexes(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k0".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("age", encode_test_int64(0)),
                                    ("name", encode_test_string("renamed")),
                                ]
                            )
                        )
                    ),
                ],
                &indexes
            )
            .unwrap();
        let counters = worker.take_counters();
        assert_eq!(counters.index_maintenance_ops, 2, "only the changed field touches the index");
        assert_eq!(index_value(&worker, "name", &encode_test_string("n0"), b"k0"), None);
        assert_eq!(
            index_value(&worker, "name", &encode_test_string("renamed"), b"k0"),
            Some(b"k0".to_vec())
        );
        assert_eq!(index_value(&worker, "age", &encode_test_int64(0), b"k0"), Some(b"k0".to_vec()));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn table_definition_interns_once_per_unique_name() {
        let name = format!("interned-{}", std::process::id());
        let first = table_definition(&name);
        let first_ptr = first.name() as *const str;
        // One hundred thousand calls must all return the exact same leaked
        // allocation: memory does not grow with operation count.
        for _ in 0..100_000 {
            let again = table_definition(&name);
            assert!(std::ptr::eq(again.name(), first_ptr));
        }
        // Reserved metadata names intern stably too.
        let meta = table_definition("__gecko_change_log");
        let meta_ptr = meta.name() as *const str;
        for _ in 0..1_000 {
            assert!(std::ptr::eq(table_definition("__gecko_change_log").name(), meta_ptr));
        }
    }

    #[test]
    fn delete_range_memory_policy_enforces_the_cap() {
        // The policy bounds the keys materialized for affected-key reporting;
        // at the cap + 1 it must fail, at the cap it must pass.
        let mut keys = Vec::with_capacity((MAX_DELETE_RANGE_KEYS + 1) as usize);
        for i in 0..MAX_DELETE_RANGE_KEYS + 1 {
            keys.push(vec![(i % 256) as u8]);
        }
        assert!(enforce_delete_memory_policy(&keys).is_err());
        keys.pop();
        assert!(enforce_delete_memory_policy(&keys).is_ok());
    }

    #[test]
    fn clear_and_delete_range_are_atomic_operations() {
        let path = temp_path("range");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker
            .apply_batch(
                &[
                    op(OpKind::Put, Some(vec![1]), Some(vec![1])),
                    op(OpKind::Put, Some(vec![2]), Some(vec![2])),
                    op(OpKind::Put, Some(vec![3]), Some(vec![3])),
                ]
            )
            .unwrap();
        worker
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::DeleteRange,
                        table: "items".into(),
                        key: None,
                        value: None,
                        start: Some(vec![1]),
                        end: Some(vec![2]),
                    },
                ]
            )
            .unwrap();
        assert_eq!(worker.range_scan("items", None, None).unwrap(), vec![(vec![3], vec![3])]);
        worker
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::Clear,
                        table: "items".into(),
                        key: None,
                        value: None,
                        start: None,
                        end: None,
                    },
                ]
            )
            .unwrap();
        assert!(worker.range_scan("items", None, None).unwrap().is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn snapshots_are_point_in_time_across_write_commits() {
        let path = temp_path("mvcc");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker
            .apply_batch(
                &[
                    op(OpKind::Put, Some(vec![1]), Some(vec![10])),
                    op(OpKind::Put, Some(vec![2]), Some(vec![20])),
                ]
            )
            .unwrap();

        // Snapshot taken now must observe the pre-write state forever.
        let snapshot = worker.create_snapshot().unwrap();
        worker
            .apply_batch(
                &[
                    op(OpKind::Put, Some(vec![1]), Some(vec![11])),
                    op(OpKind::Put, Some(vec![3]), Some(vec![30])),
                ]
            )
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
            worker.snapshot_range_scan(snapshot, "items", None, None).unwrap(),
            vec![(vec![1], vec![10]), (vec![2], vec![20])]
        );
        assert_eq!(
            worker.snapshot_range_scan(snapshot, "items", Some(&[2]), Some(&[2])).unwrap(),
            vec![(vec![2], vec![20])]
        );

        // A fresh snapshot observes the new state.
        let fresh = worker.create_snapshot().unwrap();
        assert_eq!(worker.snapshot_get(fresh, "items", &[1]).unwrap(), Some(vec![11]));
        assert_eq!(worker.snapshot_get(fresh, "items", &[3]).unwrap(), Some(vec![30]));

        // Dropping the snapshot makes it unusable (typed error), and dropping
        // an unknown id is idempotent.
        worker.drop_snapshot(snapshot);
        assert!(
            matches!(
                worker.snapshot_get(snapshot, "items", &[1]),
                Err(WorkerError::InvalidOperation(_))
            )
        );
        worker.drop_snapshot(999);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn snapshot_range_scan_missing_table_is_empty() {
        let path = temp_path("mvcc-empty");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let snapshot = worker.create_snapshot().unwrap();
        assert!(worker.snapshot_range_scan(snapshot, "absent", None, None).unwrap().is_empty());
        assert_eq!(worker.snapshot_get(snapshot, "absent", &[1]).unwrap(), None);
        worker.drop_snapshot(snapshot);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn create_snapshot_enforces_the_open_snapshot_cap() {
        let path = temp_path("snapshot-cap");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let mut held = Vec::new();
        for _ in 0..MAX_OPEN_SNAPSHOTS {
            held.push(worker.create_snapshot().unwrap());
        }
        // One more must fail with a typed error instead of pinning forever.
        assert!(
            matches!(
                worker.create_snapshot(),
                Err(WorkerError::InvalidOperation(_))
            ),
            "creating beyond the cap must fail with a typed error"
        );
        // Releasing one frees a slot.
        worker.drop_snapshot(held.remove(0));
        assert!(worker.create_snapshot().is_ok());
        for id in held {
            worker.drop_snapshot(id);
        }
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn storage_stats_report_physical_and_logical_sizes() {
        let path = temp_path("stats");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Write payloads with known total logical bytes.
        worker
            .apply_batch(
                &[
                    op(OpKind::Put, Some(vec![1]), Some(vec![10, 11, 12])),
                    op(OpKind::Put, Some(vec![2]), Some(vec![20, 21])),
                ]
            )
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
        assert_eq!(std::fs::metadata(&path).unwrap().len(), stats.physical_bytes);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn compaction_reclaims_space_and_preserves_data() {
        let path = temp_path("compact");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Fill enough data that compaction has something to reclaim after
        // deletion. Values get overwritten repeatedly to churn pages.
        let mut value = Vec::with_capacity(4096);
        value.extend(std::iter::repeat_n(0xab, 4096));
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
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::Clear,
                        table: "items".into(),
                        key: None,
                        value: None,
                        start: None,
                        end: None,
                    },
                ]
            )
            .unwrap();

        let compacted = worker.compact().unwrap();
        // Compaction should make progress (or at least not error); after it,
        // reads still work and the physical size is <= the pre-compaction size.
        let after = worker.storage_stats().unwrap();
        assert!(after.physical_bytes <= before.physical_bytes);
        assert!(worker.range_scan("items", None, None).unwrap().is_empty());
        // LSN continuity: the next write commits at the next sequence.
        worker.apply_batch(&[op(OpKind::Put, Some(vec![9]), Some(vec![99]))]).unwrap();
        assert_eq!(worker.range_scan("items", None, None).unwrap(), vec![(vec![9], vec![99])]);
        let _ = compacted;
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn compaction_rejects_open_snapshots_and_read_only() {
        let path = temp_path("compact-guard");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![1]))]).unwrap();
        let snapshot = worker.create_snapshot().unwrap();
        assert!(matches!(worker.compact(), Err(WorkerError::InvalidOperation(_))));
        worker.drop_snapshot(snapshot);
        assert!(worker.compact().is_ok());

        // Read-only databases refuse compaction.
        let ro_path = temp_path("compact-ro");
        let mut ro = RedbWorker::open(&ro_path, false).unwrap();
        ro.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![1]))]).unwrap();
        drop(ro);
        let ro = RedbWorker::open(&ro_path, true).unwrap();
        let mut ro = ro;
        assert!(matches!(ro.compact(), Err(WorkerError::InvalidOperation(_))));
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(ro_path);
    }

    #[test]
    fn compaction_maps_write_in_progress_to_invalid_operation() {
        use redb::{ CompactionError, StorageError };

        // A write transaction (or savepoint) in progress is an
        // InvalidOperation — the single-writer discipline means the caller
        // retries once the writer drains — never a Storage error.
        for error in [
            CompactionError::TransactionInProgress,
            CompactionError::PersistentSavepointExists,
            CompactionError::EphemeralSavepointExists,
        ] {
            let mapped = RedbWorker::map_compaction_error(error);
            assert!(
                matches!(mapped, WorkerError::InvalidOperation(ref message) if message.contains("compaction could not start")),
                "write-in-progress must map to InvalidOperation, got: {mapped:?}"
            );
        }

        // A genuine storage failure stays a Storage error.
        let io_error = CompactionError::Storage(
            StorageError::Io(std::io::Error::other("boom"))
        );
        assert!(
            matches!(RedbWorker::map_compaction_error(io_error), WorkerError::Storage(_)),
            "storage failures must stay Storage"
        );
    }

    #[test]
    fn query_filtered_returns_only_matching_rows() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::{ RowValue, TAG_BOOL, TAG_INT64, TAG_MAP, TAG_STRING };

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
                row(
                    &[
                        ("g", string("g0")),
                        ("age", int64(10)),
                    ]
                ),
            ),
            (
                b"k1".to_vec(),
                row(
                    &[
                        ("g", string("g0")),
                        ("age", int64(20)),
                    ]
                ),
            ),
            (
                b"k2".to_vec(),
                row(
                    &[
                        ("g", string("g1")),
                        ("age", int64(30)),
                    ]
                ),
            ),
            (
                b"k3".to_vec(),
                row(
                    &[
                        ("g", string("g1")),
                        ("age", int64(40)),
                    ]
                ),
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
        let pred_bytes = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "g".into(),
                    value: RowValue::String("g0".into()),
                },
                Filter::Range {
                    field: "age".into(),
                    min: Some(RowValue::Int64(15)),
                    max: None,
                },
            ]
        );
        let matched = worker.query_filtered("items", &pred_bytes).unwrap();
        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].0, b"k1");

        // Empty predicate matches all 4.
        let all = worker.query_filtered("items", &predicate::encode_predicate(&[])).unwrap();
        assert_eq!(all.len(), 4);

        // A missing table is an empty result, never an error.
        let missing = worker.query_filtered("nope", &pred_bytes).unwrap();
        assert!(missing.is_empty());
        let _ = (TAG_BOOL,); // suppress unused import noise
        let _ = std::fs::remove_file(path);
    }

    // shared row/encoder helpers used by the new aggregate + get_many
    // tests. Keeps the test rows byte-identical to the query_filtered suite.
    fn encode_test_row(entries: &[(&str, Vec<u8>)]) -> Vec<u8> {
        use crate::value_codec::{ TAG_MAP, TAG_STRING };
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

    fn encode_change_record_template(sequence: i64, previous: &[u8]) -> Vec<u8> {
        encode_test_row(
            &[
                ("localMutationId", encode_test_int64(sequence)),
                ("previousVersion", previous.to_vec()),
            ]
        )
    }

    fn decode_change_record_previous(row: &[u8]) -> Option<Vec<u8>> {
        crate::value_codec
            ::find_field_range(row, "previousVersion")
            .unwrap()
            .map(|(start, end)| row[start..end].to_vec())
    }

    fn indexed_definition() -> Vec<(String, Vec<String>)> {
        vec![("items".into(), vec!["age".into(), "name".into()])]
    }

    fn index_value(worker: &RedbWorker, field: &str, value: &[u8], id: &[u8]) -> Option<Vec<u8>> {
        worker
            .get("__gecko_index", durable_index_key("items", field, value, id).as_slice())
            .unwrap()
    }

    #[test]
    fn native_index_maintenance_put_update_missing_and_delete() {
        let path = temp_path("native-index-mutations");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let indexes = indexed_definition();
        let old = encode_test_row(
            &[
                ("age", encode_test_int64(10)),
                ("name", encode_test_string("old")),
            ]
        );
        let updated = encode_test_row(&[("age", encode_test_int64(20))]);
        worker
            .apply_batch_with_indexes(
                &[op_with_table(OpKind::Put, "items", Some(b"k1".to_vec()), Some(old.clone()))],
                &indexes
            )
            .unwrap();
        assert_eq!(
            index_value(&worker, "age", &encode_test_int64(10), b"k1"),
            Some(b"k1".to_vec())
        );
        assert_eq!(
            index_value(&worker, "name", &encode_test_string("old"), b"k1"),
            Some(b"k1".to_vec())
        );

        worker
            .apply_batch_with_indexes(
                &[op_with_table(OpKind::Put, "items", Some(b"k1".to_vec()), Some(updated))],
                &indexes
            )
            .unwrap();
        assert_eq!(index_value(&worker, "age", &encode_test_int64(10), b"k1"), None);
        assert_eq!(
            index_value(&worker, "age", &encode_test_int64(20), b"k1"),
            Some(b"k1".to_vec())
        );
        assert_eq!(index_value(&worker, "name", &encode_test_string("old"), b"k1"), None);

        worker
            .apply_batch_with_indexes(
                &[op_with_table(OpKind::Delete, "items", Some(b"k1".to_vec()), None)],
                &indexes
            )
            .unwrap();
        assert_eq!(index_value(&worker, "age", &encode_test_int64(20), b"k1"), None);
        assert_eq!(worker.get("items", b"k1").unwrap(), None);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn native_index_maintenance_bulk_is_sequential_and_atomic() {
        let path = temp_path("native-index-bulk");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let indexes = indexed_definition();
        let ops = vec![
            op_with_table(
                OpKind::Put,
                "items",
                Some(b"k1".to_vec()),
                Some(encode_test_row(&[("age", encode_test_int64(1))]))
            ),
            op_with_table(
                OpKind::Put,
                "items",
                Some(b"k1".to_vec()),
                Some(encode_test_row(&[("age", encode_test_int64(2))]))
            )
        ];
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        assert_eq!(index_value(&worker, "age", &encode_test_int64(1), b"k1"), None);
        assert_eq!(index_value(&worker, "age", &encode_test_int64(2), b"k1"), Some(b"k1".to_vec()));

        let invalid = vec![
            op_with_table(
                OpKind::Put,
                "items",
                Some(b"k2".to_vec()),
                Some(encode_test_row(&[("age", encode_test_int64(3))]))
            ),
            op_with_table(OpKind::Put, "items", Some(b"k3".to_vec()), None)
        ];
        assert!(worker.apply_batch_with_indexes(&invalid, &indexes).is_err());
        assert_eq!(worker.get("items", b"k2").unwrap(), None);
        assert_eq!(index_value(&worker, "age", &encode_test_int64(3), b"k2"), None);
        let _ = std::fs::remove_file(path);
    }

    fn op_with_table(
        kind: OpKind,
        table: &str,
        key: Option<Vec<u8>>,
        value: Option<Vec<u8>>
    ) -> Op {
        Op {
            kind,
            table: table.into(),
            key,
            value,
            start: None,
            end: None,
        }
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
                encode_test_row(
                    &[
                        ("g", encode_test_string("g0")),
                        ("age", encode_test_int64(10)),
                    ]
                ),
            ),
            (
                b"k1".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g0")),
                        ("age", encode_test_int64(20)),
                    ]
                ),
            ),
            (
                b"k2".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g1")),
                        ("age", encode_test_int64(30)),
                    ]
                ),
            ),
            (
                b"k3".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g1")),
                        ("age", encode_test_int64(40)),
                    ]
                ),
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
    fn relationship_primitives_are_snapshot_bound() {
        let path = temp_path("relationship-primitives");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let indexes = vec![("posts".into(), vec!["authorId".into()])];
        let rows = vec![
            op_with_table(
                OpKind::Put,
                "authors",
                Some(encode_test_string("a1")),
                Some(
                    encode_test_row(
                        &[
                            ("id", encode_test_string("a1")),
                            ("name", encode_test_string("A")),
                        ]
                    )
                )
            ),
            op_with_table(
                OpKind::Put,
                "posts",
                Some(encode_test_string("p1")),
                Some(
                    encode_test_row(
                        &[
                            ("id", encode_test_string("p1")),
                            ("authorId", encode_test_string("a1")),
                        ]
                    )
                )
            ),
            op_with_table(
                OpKind::Put,
                "posts",
                Some(encode_test_string("p2")),
                Some(
                    encode_test_row(
                        &[
                            ("id", encode_test_string("p2")),
                            ("authorId", encode_test_string("a1")),
                        ]
                    )
                )
            )
        ];
        worker.apply_batch_with_indexes(&rows, &indexes).unwrap();
        let snapshot = worker.create_snapshot().unwrap();

        let parent = worker
            .snapshot_relationship_parent(
                snapshot,
                "posts",
                &encode_test_string("p1"),
                "authors",
                "authorId"
            )
            .unwrap()
            .unwrap();
        assert_eq!(parent.0, encode_test_string("a1"));
        assert_eq!(
            crate::value_codec::decode_value(&parent.1).unwrap().find_field("name"),
            Some(&crate::value_codec::RowValue::String("A".into()))
        );

        let exact_full = index_key(
            "posts",
            "authorId",
            &encode_test_string("a1"),
            &encode_test_string("p1")
        );
        let record_id_bytes = encode_test_string("p1");
        let exact = exact_full[..exact_full.len() - record_id_bytes.len()].to_vec();
        let mut exact_end = exact.clone();
        let last = exact_end.pop().unwrap();
        exact_end.push(last + 1);
        let children = worker
            .snapshot_relationship_children(
                snapshot,
                "posts",
                "authorId",
                &[encode_test_string("a1")],
                "__gecko_index",
                &[(exact, exact_end)],
                &crate::predicate::encode_predicate(&[])
            )
            .unwrap();
        // grouped return — one group per FK value, rows in row-key order.
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].parent_id, encode_test_string("a1"));
        assert_eq!(children[0].entries.len(), 2);
        assert_eq!(children[0].entries[0].0, encode_test_string("p1"));
        assert_eq!(children[0].entries[1].0, encode_test_string("p2"));

        let join_rows = vec![
            op_with_table(
                OpKind::Put,
                "__gecko_join_students_courses",
                Some(vec![1]),
                Some(
                    encode_test_row(
                        &[
                            ("left", encode_test_string("s1")),
                            ("right", encode_test_string("c1")),
                        ]
                    )
                )
            ),
            op_with_table(
                OpKind::Put,
                "__gecko_join_students_courses",
                Some(vec![2]),
                Some(
                    encode_test_row(
                        &[
                            ("left", encode_test_string("s1")),
                            ("right", encode_test_string("c2")),
                        ]
                    )
                )
            )
        ];
        worker.apply_batch(&join_rows).unwrap();
        let join_snapshot = worker.create_snapshot().unwrap();
        let join_ids = worker
            .snapshot_relationship_join_ids(
                join_snapshot,
                "__gecko_join_students_courses",
                "left",
                &encode_test_string("s1")
            )
            .unwrap();
        assert_eq!(join_ids, vec![encode_test_string("c1"), encode_test_string("c2")]);
        worker.drop_snapshot(join_snapshot);

        worker
            .apply_batch_with_indexes(
                &[
                    op_with_table(
                        OpKind::Put,
                        "authors",
                        Some(encode_test_string("a1")),
                        Some(
                            encode_test_row(
                                &[
                                    ("id", encode_test_string("a1")),
                                    ("name", encode_test_string("B")),
                                ]
                            )
                        )
                    ),
                ],
                &indexes
            )
            .unwrap();
        let old_parent = worker
            .snapshot_relationship_parent(
                snapshot,
                "posts",
                &encode_test_string("p1"),
                "authors",
                "authorId"
            )
            .unwrap()
            .unwrap();
        assert_eq!(
            crate::value_codec::decode_value(&old_parent.1).unwrap().find_field("name"),
            Some(&crate::value_codec::RowValue::String("A".into()))
        );
        worker.drop_snapshot(snapshot);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn relationship_children_group_by_fk_in_rust() {
        let path = temp_path("relationship-children-group");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let indexes = vec![("posts".into(), vec!["authorId".into()])];
        let rows = vec![
            op_with_table(
                OpKind::Put,
                "authors",
                Some(encode_test_string("a1")),
                Some(encode_test_row(&[("id", encode_test_string("a1"))]))
            ),
            op_with_table(
                OpKind::Put,
                "authors",
                Some(encode_test_string("a2")),
                Some(encode_test_row(&[("id", encode_test_string("a2"))]))
            ),
            op_with_table(
                OpKind::Put,
                "posts",
                Some(encode_test_string("p1")),
                Some(
                    encode_test_row(
                        &[
                            ("id", encode_test_string("p1")),
                            ("authorId", encode_test_string("a1")),
                        ]
                    )
                )
            ),
            op_with_table(
                OpKind::Put,
                "posts",
                Some(encode_test_string("p2")),
                Some(
                    encode_test_row(
                        &[
                            ("id", encode_test_string("p2")),
                            ("authorId", encode_test_string("a1")),
                        ]
                    )
                )
            ),
            op_with_table(
                OpKind::Put,
                "posts",
                Some(encode_test_string("p3")),
                Some(
                    encode_test_row(
                        &[
                            ("id", encode_test_string("p3")),
                            ("authorId", encode_test_string("a2")),
                        ]
                    )
                )
            ),
            // Missing FK row must never join any group.
            op_with_table(
                OpKind::Put,
                "posts",
                Some(encode_test_string("p4")),
                Some(encode_test_row(&[("id", encode_test_string("p4"))]))
            )
        ];
        worker.apply_batch_with_indexes(&rows, &indexes).unwrap();
        let snapshot = worker.create_snapshot().unwrap();

        let exact_a1 = index_key(
            "posts",
            "authorId",
            &encode_test_string("a1"),
            &encode_test_string("p1")
        );
        let record_id_a1 = encode_test_string("p1");
        let start_a1 = exact_a1[..exact_a1.len() - record_id_a1.len()].to_vec();
        let mut end_a1 = start_a1.clone();
        let last_a1 = end_a1.pop().unwrap();
        end_a1.push(last_a1 + 1);

        let exact_a2 = index_key(
            "posts",
            "authorId",
            &encode_test_string("a2"),
            &encode_test_string("p3")
        );
        let record_id_a2 = encode_test_string("p3");
        let start_a2 = exact_a2[..exact_a2.len() - record_id_a2.len()].to_vec();
        let mut end_a2 = start_a2.clone();
        let last_a2 = end_a2.pop().unwrap();
        end_a2.push(last_a2 + 1);

        // Indexed path, two parent ids: one group per parent, rows in row-key
        // order, groups in FK-byte order.
        let groups = worker
            .snapshot_relationship_children(
                snapshot,
                "posts",
                "authorId",
                &[encode_test_string("a1"), encode_test_string("a2")],
                "__gecko_index",
                &[
                    (start_a1, end_a1),
                    (start_a2, end_a2),
                ],
                &crate::predicate::encode_predicate(&[])
            )
            .unwrap();
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].parent_id, encode_test_string("a1"));
        assert_eq!(groups[0].entries.len(), 2);
        assert_eq!(groups[0].entries[0].0, encode_test_string("p1"));
        assert_eq!(groups[0].entries[1].0, encode_test_string("p2"));
        assert_eq!(groups[1].parent_id, encode_test_string("a2"));
        assert_eq!(groups[1].entries.len(), 1);
        assert_eq!(groups[1].entries[0].0, encode_test_string("p3"));

        // Unindexed path (predicate-driven): grouping classifies by FK in
        // Rust; the row without an FK field is excluded.
        let all = worker
            .snapshot_relationship_children(
                snapshot,
                "posts",
                "authorId",
                &[],
                "__gecko_index",
                &[],
                &crate::predicate::encode_predicate(&[])
            )
            .unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].parent_id, encode_test_string("a1"));
        assert_eq!(all[0].entries.len(), 2);
        assert_eq!(all[1].parent_id, encode_test_string("a2"));
        assert_eq!(all[1].entries.len(), 1);
        assert_eq!(all[1].entries[0].0, encode_test_string("p3"));

        worker.drop_snapshot(snapshot);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_filtered_count_counts_matches_without_transfer() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, mut worker) = seed_aggregate_fixture("qfc");
        // g == "g0" AND age >= 15 → 1 row (k1).
        let pred = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "g".into(),
                    value: RowValue::String("g0".into()),
                },
                Filter::Range {
                    field: "age".into(),
                    min: Some(RowValue::Int64(15)),
                    max: None,
                },
            ]
        );
        assert_eq!(worker.query_filtered_count("items", &pred).unwrap(), 1);

        // g == "g1" → 2 rows (k2, k3).
        let g1 = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "g".into(),
                    value: RowValue::String("g1".into()),
                },
            ]
        );
        assert_eq!(worker.query_filtered_count("items", &g1).unwrap(), 2);

        // Empty predicate matches all 4.
        assert_eq!(
            worker.query_filtered_count("items", &predicate::encode_predicate(&[])).unwrap(),
            4
        );
        // A missing table counts as zero, never an error.
        assert_eq!(worker.query_filtered_count("nope", &pred).unwrap(), 0);

        // Snapshot-bound variant agrees with the live count.
        let snap = worker.create_snapshot().unwrap();
        assert_eq!(worker.snapshot_query_filtered_count(snap, "items", &g1).unwrap(), 2);
        worker.drop_snapshot(snap);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_filtered_distinct_emits_only_field_bytes() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::{ self, RowValue };
        let (path, mut worker) = seed_aggregate_fixture("qfd");
        // Distinct `g` across all rows → {g0, g1}. The distinct pushdown
        // emits the encoded value bytes per matching row; check the decoded
        // set is exactly {g0, g1} and is unsorted (the caller dedups).
        let empty_pred = predicate::encode_predicate(&[]);
        let field_bytes = worker.query_filtered_distinct("items", &empty_pred, "g").unwrap();
        // contract: the pushdown emits the field's bytes for EACH
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
                RowValue::String("g1".into())
            ]
        );

        // Distinct `age` for g0 → {10, 20}.
        let g0_pred = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "g".into(),
                    value: RowValue::String("g0".into()),
                },
            ]
        );
        let age_bytes = worker.query_filtered_distinct("items", &g0_pred, "age").unwrap();
        // g0 has 2 rows (ages 10, 20) — both emitted, undeduped.
        let mut ages: Vec<i64> = age_bytes
            .iter()
            .map(|b| {
                match value_codec::decode_value(b).unwrap() {
                    RowValue::Int64(n) => n,
                    _ => panic!("expected int64"),
                }
            })
            .collect();
        ages.sort();
        assert_eq!(ages, vec![10, 20]);

        // A row missing the requested field is omitted from the stream (a
        // missing field is not a distinct value). Seed a row without `g`.
        let no_g_row = encode_test_row(&[("age", encode_test_int64(99))]);
        worker
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::Put,
                        table: "items".into(),
                        key: Some(b"k4".to_vec()),
                        value: Some(no_g_row),
                        start: None,
                        end: None,
                    },
                ]
            )
            .unwrap();
        // Distinct `g` now still emits 5 byte slices (4 with g + the
        // missing-field row is skipped), verifying the missing-field skip.
        let after_missing = worker.query_filtered_distinct("items", &empty_pred, "g").unwrap();
        assert_eq!(after_missing.len(), 4, "missing-field row skipped, 4 rows with g remain");

        // A missing table is an empty result, never an error.
        let missing_table = worker.query_filtered_distinct("nope", &empty_pred, "g").unwrap();
        assert!(missing_table.is_empty());
        let _ = std::fs::remove_file(path);
    }

    // ── early limit/offset + sorted + index-ordered ────────────────────

    /// The durable-index composite key `encode([table, field, value, recordId])`
    /// (a 4-element codec list) for the test table.
    fn index_key(table: &str, field: &str, value: &[u8], record_id: &[u8]) -> Vec<u8> {
        durable_index_key(table, field, value, record_id)
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
                let row = encode_test_row(
                    &[
                        ("age", age.clone()),
                        ("nick", encode_test_string("g0")),
                    ]
                );
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
        // Also index nick so tests can intersect two different fields.
        for k in [b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()] {
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
            &[crate::value_codec::TAG_NULL]
        );
        // strip two trailing null tag bytes to get the shared 2-element prefix
        let prefix = full[0..full.len() - 2].to_vec();
        let mut end = prefix.clone();
        let mut i = end.len() - 1;
        while i > 0 && end[i] == 0xff {
            end.pop();
            i -= 1;
        }
        let last = end.pop().unwrap();
        end.push(last + 1);
        (prefix, end)
    }

    /// Tight lower/upper bounds for `min <= field <= max` using the
    /// order-preserving value element (Priority 5): the start is the index
    /// key for [min] without its recordId, the end is the incremented key for
    /// [max] without its recordId. A scan over `start..=end` visits exactly
    /// the entries whose field value falls in `[min, max]`.
    fn ordered_range_bounds(
        table: &str,
        field: &str,
        min: &[u8],
        max: &[u8]
    ) -> (Vec<u8>, Vec<u8>) {
        let min_key = index_key(table, field, min, &[crate::value_codec::TAG_NULL]);
        let start = min_key[..min_key.len() - 1].to_vec();
        let max_key = index_key(table, field, max, &[crate::value_codec::TAG_NULL]);
        let mut end = max_key[..max_key.len() - 1].to_vec();
        let last = end.pop().unwrap();
        end.push(last + 1);
        (start, end)
    }

    /// Tight bounds for the string-prefix `field startsWith prefix` using the
    /// escaped-terminator string element (Priority 5): the escaped prefix
    /// bytes WITHOUT the terminator form a contiguous range containing exactly
    /// the strings that start with [prefix].
    fn ordered_prefix_bounds(table: &str, field: &str, prefix: &str) -> (Vec<u8>, Vec<u8>) {
        use crate::value_codec::{ TAG_LIST, TAG_ORDERED };
        let mut start = vec![TAG_LIST];
        start.extend_from_slice(&(4u32).to_be_bytes());
        start.extend_from_slice(&encode_test_string(table));
        start.extend_from_slice(&encode_test_string(field));
        start.push(TAG_ORDERED);
        start.push(0x06); // ORD_STRING
        for &b in prefix.as_bytes() {
            if b == 0x00 {
                start.extend_from_slice(&[0x00, 0x01]);
            } else {
                start.push(b);
            }
        }
        // No terminator: longer strings that extend the prefix stay inside.
        let mut end = start.clone();
        let last = end.pop().unwrap();
        end.push(last + 1);
        (start, end)
    }

    #[test]
    fn repair_index_rebuilds_durable_entries_from_primary_rows() {
        let (path, mut worker) = seed_indexed_age_fixture("repair-index");
        let (start, end) = age_field_bounds();
        let before = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        assert_eq!(before.len(), 4);
        worker
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::Delete,
                        table: "__gecko_index".into(),
                        key: Some(index_key("items", "age", &encode_test_int64(20), b"k1")),
                        value: None,
                        start: None,
                        end: None,
                    },
                ]
            )
            .unwrap();
        assert_eq!(worker.query_indexed("items", "__gecko_index", &start, &end).unwrap().len(), 3);
        worker.repair_index("items", &["age".to_string()]).unwrap();
        let after = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        assert_eq!(after.len(), 4);
        assert!(after.iter().any(|entry| entry.0 == b"k1"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_filtered_limited_skips_and_stops_early() {
        use crate::predicate::{ self, Filter };
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
        let g0 = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "g".into(),
                    value: RowValue::String("g0".into()),
                },
            ]
        );
        let one = worker.query_filtered_limited("items", &g0, Some(1), 0).unwrap();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].0, b"k0");
        // Missing table → empty.
        assert!(
            worker
                .query_filtered_limited("nope", &predicate::encode_predicate(&[]), Some(1), 0)
                .unwrap()
                .is_empty()
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_sorted_topk_matches_dart_order() {
        use crate::sort_spec::{ encode_sort_specs, SortSpec };
        let (path, worker) = seed_indexed_age_fixture("qsorted");
        let empty_pred = crate::predicate::encode_predicate(&[]);
        // Sort ascending by age: k0(10), k1(20), k2(30), k3(40), then k4(missing).
        let asc = encode_sort_specs(
            &[
                SortSpec {
                    field: "age".into(),
                    descending: false,
                },
            ]
        );
        let got = worker.query_sorted("items", &empty_pred, &asc, Some(5), 0).unwrap();
        let keys: Vec<&[u8]> = got
            .iter()
            .map(|e| e.0.as_slice())
            .collect();
        assert_eq!(keys, vec![&b"k0"[..], &b"k1"[..], &b"k2"[..], &b"k3"[..], &b"k4"[..]]);
        // limit 2 → k0, k1; offset 2 → k2, k3.
        let lim = worker.query_sorted("items", &empty_pred, &asc, Some(2), 0).unwrap();
        assert_eq!(lim.len(), 2);
        assert_eq!(lim[0].0, b"k0");
        assert_eq!(lim[1].0, b"k1");
        let off = worker.query_sorted("items", &empty_pred, &asc, Some(2), 2).unwrap();
        assert_eq!(off[0].0, b"k2");
        assert_eq!(off[1].0, b"k3");
        // Descending: missing (k4) FIRST, then 40, 30, 20, 10.
        let desc = encode_sort_specs(
            &[
                SortSpec {
                    field: "age".into(),
                    descending: true,
                },
            ]
        );
        let d = worker.query_sorted("items", &empty_pred, &desc, Some(5), 0).unwrap();
        let dkeys: Vec<&[u8]> = d
            .iter()
            .map(|e| e.0.as_slice())
            .collect();
        assert_eq!(dkeys, vec![&b"k4"[..], &b"k3"[..], &b"k2"[..], &b"k1"[..], &b"k0"[..]]);
        // Predicate filter: age > 15 → k1,k2,k3 sorted asc (k4 has no age → filtered out).
        let gt15 = crate::predicate::encode_predicate(
            &[
                crate::predicate::Filter::Range {
                    field: "age".into(),
                    min: Some(crate::value_codec::RowValue::Int64(16)),
                    max: None,
                },
            ]
        );
        let g = worker.query_sorted("items", &gt15, &asc, Some(5), 0).unwrap();
        let gkeys: Vec<&[u8]> = g
            .iter()
            .map(|e| e.0.as_slice())
            .collect();
        assert_eq!(gkeys, vec![&b"k1"[..], &b"k2"[..], &b"k3"[..]]);
        // limit 0 → empty.
        assert!(worker.query_sorted("items", &empty_pred, &asc, Some(0), 0).unwrap().is_empty());
        // Missing table → empty.
        assert!(worker.query_sorted("nope", &empty_pred, &asc, Some(1), 0).unwrap().is_empty());
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
                false,
                false,
                Some(5),
                0
            )
            .unwrap();
        let keys: Vec<&[u8]> = got
            .iter()
            .map(|e| e.0.as_slice())
            .collect();
        assert_eq!(keys, vec![&b"k0"[..], &b"k1"[..], &b"k2"[..], &b"k3"[..], &b"k4"[..]]);
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
                false,
                false,
                Some(2),
                0
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
                false,
                false,
                Some(2),
                2
            )
            .unwrap();
        assert_eq!(off[0].0, b"k2");
        assert_eq!(off[1].0, b"k3");
        // unbounded (limit None) sorted queries must ALSO append the
        // missing-field row (the index stream alone would drop it).
        let all = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                false,
                false,
                None,
                0
            )
            .unwrap();
        let keys: Vec<&[u8]> = all
            .iter()
            .map(|e| e.0.as_slice())
            .collect();
        assert_eq!(keys, vec![&b"k0"[..], &b"k1"[..], &b"k2"[..], &b"k3"[..], &b"k4"[..]]);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn indexed_range_scan_visits_only_matching_entries() {
        let (path, worker) = seed_indexed_age_fixture("qrange-sel");
        worker.enable_counters();
        // Tight bounds for age in [15, 35]: only k1 (20) and k2 (30) match.
        let (start, end) = ordered_range_bounds(
            "items",
            "age",
            &encode_test_int64(15),
            &encode_test_int64(35)
        );
        let got = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        let mut keys: Vec<Vec<u8>> = got.iter().map(|e| e.0.clone()).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![b"k1".to_vec(), b"k2".to_vec()],
            "tight range returns exactly the matching rows"
        );
        let counters = worker.take_counters();
        assert_eq!(
            counters.index_entries_visited, 2,
            "the order-preserving element makes the range scan exactly selective"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn indexed_range_scan_with_negative_bounds_is_tight() {
        let path = temp_path("qrange-neg");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let ages = [-100i64, -5, -1, 0, 10, 40];
        let mut ops = Vec::new();
        for (i, age) in ages.iter().enumerate() {
            let k = format!("k{i}").into_bytes();
            let row = encode_test_row(&[("age", encode_test_int64(*age))]);
            ops.push(Op {
                kind: OpKind::Put,
                table: "items".into(),
                key: Some(k.clone()),
                value: Some(row),
                start: None,
                end: None,
            });
            ops.push(Op {
                kind: OpKind::Put,
                table: "__gecko_index".into(),
                key: Some(index_key("items", "age", &encode_test_int64(*age), &k)),
                value: Some(k),
                start: None,
                end: None,
            });
        }
        worker.apply_batch(&ops).unwrap();
        worker.enable_counters();
        // [-5, 0] with negative bounds: the sign-flipped encoding must make
        // the scan exactly selective (v1 big-endian two's complement sorted
        // negatives AFTER positives, so the old broad field span was needed).
        let (start, end) = ordered_range_bounds(
            "items",
            "age",
            &encode_test_int64(-5),
            &encode_test_int64(0)
        );
        let got = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        let mut keys: Vec<Vec<u8>> = got.iter().map(|e| e.0.clone()).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()],
            "negative bounds still return exactly the matching rows"
        );
        let counters = worker.take_counters();
        assert_eq!(counters.index_entries_visited, 3, "exactly selective over negatives");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn indexed_prefix_scan_visits_only_matching_entries() {
        let path = temp_path("qprefix-sel");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let nicks = ["g0", "g1", "g10", "g12", "g2", "g", "h1"];
        let mut ops = Vec::new();
        for (i, nick) in nicks.iter().enumerate() {
            let k = format!("k{i}").into_bytes();
            let row = encode_test_row(&[("nick", encode_test_string(nick))]);
            ops.push(Op {
                kind: OpKind::Put,
                table: "items".into(),
                key: Some(k.clone()),
                value: Some(row),
                start: None,
                end: None,
            });
            ops.push(Op {
                kind: OpKind::Put,
                table: "__gecko_index".into(),
                key: Some(index_key("items", "nick", &encode_test_string(nick), &k)),
                value: Some(k),
                start: None,
                end: None,
            });
        }
        worker.apply_batch(&ops).unwrap();
        worker.enable_counters();
        // Prefix "g1" matches exactly {"g1", "g10", "g12"} (k1, k2, k3).
        let (start, end) = ordered_prefix_bounds("items", "nick", "g1");
        let got = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        let mut keys: Vec<Vec<u8>> = got.iter().map(|e| e.0.clone()).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()],
            "a semantic string prefix is a contiguous index range"
        );
        let counters = worker.take_counters();
        assert_eq!(
            counters.index_entries_visited, 3,
            "the escaped-terminator encoding makes the prefix scan exactly selective"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_streams_negative_ints_in_semantic_order() {
        let path = temp_path("qordered-neg");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let ages = [-100i64, -5, -1, 0, 10];
        let mut ops = Vec::new();
        for (i, age) in ages.iter().enumerate() {
            let k = format!("k{i}").into_bytes();
            let row = encode_test_row(&[("age", encode_test_int64(*age))]);
            ops.push(Op {
                kind: OpKind::Put,
                table: "items".into(),
                key: Some(k.clone()),
                value: Some(row),
                start: None,
                end: None,
            });
            ops.push(Op {
                kind: OpKind::Put,
                table: "__gecko_index".into(),
                key: Some(index_key("items", "age", &encode_test_int64(*age), &k)),
                value: Some(k),
                start: None,
                end: None,
            });
        }
        worker.apply_batch(&ops).unwrap();
        let empty_pred = crate::predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        let got = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                false,
                false,
                None,
                0
            )
            .unwrap();
        // Every row carries `age`, so nothing is appended; the stream order
        // must be the semantic order (v1 two's-complement big-endian would
        // have put the negatives after the positives).
        let keys: Vec<Vec<u8>> = got.iter().map(|e| e.0.clone()).collect();
        assert_eq!(
            keys,
            vec![
                b"k0".to_vec(),
                b"k1".to_vec(),
                b"k2".to_vec(),
                b"k3".to_vec(),
                b"k4".to_vec(),
            ],
            "index stream is in true ascending semantic order"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_multi_intersects_and_rechecks_predicate() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, worker) = seed_indexed_age_fixture("qmulti");
        let age_bounds = age_field_bounds();
        let nick_full = index_key(
            "items",
            "nick",
            &[crate::value_codec::TAG_NULL],
            &[crate::value_codec::TAG_NULL]
        );
        let nick_start = nick_full[..nick_full.len() - 2].to_vec();
        let mut nick_end = nick_start.clone();
        let last = nick_end.pop().unwrap();
        nick_end.push(last + 1);
        let predicate = predicate::encode_predicate(
            &[
                Filter::Range {
                    field: "age".into(),
                    min: Some(RowValue::Int64(15)),
                    max: Some(RowValue::Int64(35)),
                },
                Filter::Equals {
                    field: "nick".into(),
                    value: RowValue::String("g0".into()),
                },
            ]
        );
        let got = worker
            .query_indexed_multi(
                "items",
                "__gecko_index",
                &[age_bounds, (nick_start, nick_end)],
                &predicate,
                false,
                None,
                0
            )
            .unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].0, b"k1");
        assert_eq!(got[1].0, b"k2");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_limited_windows_an_eq_bound() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, worker) = seed_indexed_age_fixture("qil");
        // Eq bound for age == 20 (only k1).
        let mut full = index_key(
            "items",
            "age",
            &encode_test_int64(20),
            &[crate::value_codec::TAG_NULL]
        );
        full.pop(); // strip trailing null → shared prefix
        let mut end = full.clone();
        let mut i = end.len() - 1;
        while i > 0 && end[i] == 0xff {
            end.pop();
            i -= 1;
        }
        let last = end.pop().unwrap();
        end.push(last + 1);
        let eq_pred = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "age".into(),
                    value: RowValue::Int64(20),
                },
            ]
        );
        // Sanity: the plain join over the same bounds must find k1.
        let joined = worker.query_indexed("items", "__gecko_index", &full, &end).unwrap();
        assert_eq!(joined.len(), 1, "index bounds must reach the age=20 entry");
        assert_eq!(joined[0].0, b"k1");
        let got = worker
            .query_indexed_limited("items", "__gecko_index", &full, &end, &eq_pred, false, Some(10), 0)
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, b"k1");
        // limit 0 → empty.
        assert!(
            worker
                .query_indexed_limited("items", "__gecko_index", &full, &end, &eq_pred, false, Some(0), 0)
                .unwrap()
                .is_empty()
        );
        let _ = std::fs::remove_file(path);
    }

    // --- Rust-owned reactive registry --

    /// Seeds `items` with g0/g0/g1/g1 rows (ages 10/20/30/40).
    fn seed_registry_fixture(label: &str) -> (std::path::PathBuf, RedbWorker) {
        let path = temp_path(label);
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let rows = [
            ("k0", "g0", 10i64),
            ("k1", "g0", 20i64),
            ("k2", "g1", 30i64),
            ("k3", "g1", 40i64),
        ];
        for (k, g, age) in rows {
            worker
                .apply_batch(
                    &[
                        op_with_table(
                            OpKind::Put,
                            "items",
                            Some(k.as_bytes().to_vec()),
                            Some(
                                encode_test_row(
                                    &[
                                        ("g", encode_test_string(g)),
                                        ("age", encode_test_int64(age)),
                                    ]
                                )
                            )
                        ),
                    ]
                )
                .unwrap();
        }
        (path, worker)
    }

    fn g0_predicate() -> Vec<u8> {
        use crate::predicate::{ encode_predicate, Filter };
        use crate::value_codec::RowValue;
        encode_predicate(
            &[
                Filter::Equals {
                    field: "g".into(),
                    value: RowValue::String("g0".into()),
                },
            ]
        )
    }

    fn age_ascending_sort() -> Vec<u8> {
        use crate::sort_spec::{ encode_sort_specs, SortSpec };
        encode_sort_specs(&[SortSpec { field: "age".into(), descending: false }])
    }

    /// `version(1) + count(0)` — an empty predicate/sort payload (matches
    /// everything / no ordering), exactly as the Dart encoder serializes it.
    fn no_filters() -> Vec<u8> {
        vec![1, 0]
    }

    #[test]
    fn live_registry_filtered_query_tracks_join_leave_update() {
        let (path, mut worker) = seed_registry_fixture("registry-query");
        let (id, initial) = worker
            .register_live_query("items", &g0_predicate(), &no_filters(), 2)
            .unwrap();
        assert_eq!(id, 0);
        // Initial result set: k0, k1 (byte-key order).
        assert_eq!(initial.len(), 2);
        assert_eq!(initial[0].0, b"k0");
        assert_eq!(initial[1].0, b"k1");

        // k2 (g1) flips to g0 → joins; k1 (g0) flips to g1 → leaves; k0 (g0)
        // keeps g0 but its age changes → updated.
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k2".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(31)),
                                ]
                            )
                        )
                    ),
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k1".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g1")),
                                    ("age", encode_test_int64(21)),
                                ]
                            )
                        )
                    ),
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k0".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(11)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert_eq!(result.deltas.len(), 1);
        let delta = &result.deltas[0];
        assert_eq!(delta.id, id);
        assert_eq!(
            delta.added,
            vec![(
                b"k2".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g0")),
                        ("age", encode_test_int64(31)),
                    ]
                ),
            )]
        );
        assert_eq!(
            delta.removed,
            vec![(
                b"k1".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g0")),
                        ("age", encode_test_int64(20)),
                    ]
                ),
            )]
        );
        assert_eq!(
            delta.updated,
            vec![(
                b"k0".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g0")),
                        ("age", encode_test_int64(11)),
                    ]
                ),
            )]
        );
        assert!(!delta.unchanged);
        // Snapshot = k0 (updated), k2 (joined) in byte-key order.
        assert_eq!(delta.snapshot.len(), 2);
        assert_eq!(delta.snapshot[0].0, b"k0");
        assert_eq!(delta.snapshot[1].0, b"k2");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn live_registry_watch_all_returns_full_snapshot_per_batch() {
        let (path, mut worker) = seed_registry_fixture("registry-watchall");
        let (id, initial) = worker
            .register_live_query("items", &no_filters(), &no_filters(), 0)
            .unwrap();
        assert_eq!(initial.len(), 4);
        // Byte-key order: k0..k3.
        assert_eq!(
            initial
                .iter()
                .map(|e| e.0.clone())
                .collect::<Vec<_>>(),
            vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()]
        );
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k9".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(99)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert_eq!(result.deltas.len(), 1);
        let delta = &result.deltas[0];
        assert_eq!(delta.id, id);
        assert_eq!(
            delta.added,
            vec![(
                b"k9".to_vec(),
                encode_test_row(
                    &[
                        ("g", encode_test_string("g0")),
                        ("age", encode_test_int64(99)),
                    ]
                ),
            )]
        );
        assert_eq!(delta.snapshot.len(), 5);
        assert_eq!(delta.snapshot[4].0, b"k9");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn live_registry_sorted_query_inserts_at_comparator_position() {
        let (path, mut worker) = seed_registry_fixture("registry-sorted");
        let (id, initial) = worker
            .register_live_query("items", &no_filters(), &age_ascending_sort(), 2)
            .unwrap();
        // Ascending age: k0(10), k1(20), k2(30), k3(40).
        assert_eq!(
            initial
                .iter()
                .map(|e| e.0.clone())
                .collect::<Vec<_>>(),
            vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()]
        );
        // k0's age drops to 99 → moves to the end.
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k0".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(99)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert_eq!(result.deltas.len(), 1);
        let delta = &result.deltas[0];
        assert_eq!(delta.id, id);
        // Reordered snapshot: k1, k2, k3, k0.
        assert_eq!(
            delta.snapshot
                .iter()
                .map(|e| e.0.clone())
                .collect::<Vec<_>>(),
            vec![b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec(), b"k0".to_vec()]
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn live_registry_whole_table_clear_resets_to_empty() {
        let (path, mut worker) = seed_registry_fixture("registry-clear");
        let (id, _) = worker
            .register_live_query("items", &g0_predicate(), &no_filters(), 1)
            .unwrap();
        let result = worker
            .apply_batch_reactive(&[op_with_table(OpKind::Clear, "items", None, None)], &[])
            .unwrap();
        assert_eq!(result.deltas.len(), 1);
        let delta = &result.deltas[0];
        assert_eq!(delta.id, id);
        // Both g0 rows leave with their previous values; snapshot is empty.
        assert_eq!(delta.removed.len(), 2);
        assert!(delta.snapshot.is_empty());
        assert!(!delta.unchanged);
        // A subsequent write sees an empty registry result set.
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k5".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(5)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert_eq!(result.deltas[0].added.len(), 1);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn live_registry_idempotent_write_is_unchanged() {
        let (path, mut worker) = seed_registry_fixture("registry-idempotent");
        // kind 0 (watchAll): keeps the full snapshot on every delta, so the
        // unchanged-write assertion below also checks the snapshot.
        let (_, _) = worker
            .register_live_query("items", &g0_predicate(), &no_filters(), 0)
            .unwrap();
        // Same value for k0 → nothing observable changes.
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k0".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(10)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert_eq!(result.deltas.len(), 1);
        assert!(result.deltas[0].unchanged);
        assert!(result.deltas[0].added.is_empty());
        assert!(result.deltas[0].updated.is_empty());
        assert!(result.deltas[0].removed.is_empty());
        // Snapshot still reflects the full matching set.
        assert_eq!(result.deltas[0].snapshot.len(), 2);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn live_registry_coalesces_a_batch_into_one_delta() {
        let (path, mut worker) = seed_registry_fixture("registry-coalesce");
        let (id, _) = worker
            .register_live_query("items", &g0_predicate(), &no_filters(), 2)
            .unwrap();
        // One batch touching 3 g0 rows → exactly one delta.
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k0".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(1)),
                                ]
                            )
                        )
                    ),
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k1".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(2)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert_eq!(result.deltas.len(), 1);
        assert_eq!(result.deltas[0].id, id);
        assert_eq!(result.deltas[0].updated.len(), 2);
        // Registrations on an unrelated table are untouched.
        worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "other",
                        Some(b"x".to_vec()),
                        Some(encode_test_row(&[("g", encode_test_string("g0"))]))
                    ),
                ],
                &[]
            )
            .unwrap();
        let result = worker
            .apply_batch_reactive(
                &[op_with_table(OpKind::Put, "other", Some(b"y".to_vec()), Some(vec![1]))],
                &[]
            )
            .unwrap();
        assert!(result.deltas.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn live_registry_unregister_stops_deltas() {
        let (path, mut worker) = seed_registry_fixture("registry-unregister");
        let (id, _) = worker
            .register_live_query("items", &g0_predicate(), &no_filters(), 2)
            .unwrap();
        worker.unregister_live_query(id);
        assert_eq!(worker.live_query_count(), 0);
        let result = worker
            .apply_batch_reactive(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k0".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("g", encode_test_string("g0")),
                                    ("age", encode_test_int64(1)),
                                ]
                            )
                        )
                    ),
                ],
                &[]
            )
            .unwrap();
        assert!(result.deltas.is_empty());
        // Unregister is idempotent.
        worker.unregister_live_query(id);
        let _ = std::fs::remove_file(path);
    }

    // --- change-log pruning in the Rust commit path ---

    /// Production change-log key for the given LSN at ordinal 0 (the same
    /// `[lsn, ordinal]` list encoding `encode_change_log_key` produces).
    fn encode_log_key(lsn: u64) -> Vec<u8> {
        encode_change_log_key(lsn, 0)
    }

    /// Production change-log key for the given `[lsn, ordinal]` pair.
    fn encode_log_key_ordinal(lsn: u64, ordinal: u64) -> Vec<u8> {
        encode_change_log_key(lsn, ordinal)
    }

    fn encode_change_record(dirty: bool, lsn: u64) -> Vec<u8> {
        let mut dirty_bytes = vec![crate::value_codec::TAG_BOOL];
        dirty_bytes.push(if dirty { 1 } else { 0 });
        let mut id_bytes = vec![crate::value_codec::TAG_INT64];
        id_bytes.extend_from_slice(&(lsn as i64).to_be_bytes());
        encode_test_row(
            &[
                ("dirty", dirty_bytes),
                ("localMutationId", id_bytes),
            ]
        )
    }

    fn watermark_key() -> Vec<u8> {
        let mut key = vec![crate::value_codec::TAG_STRING];
        let wm = b"watermark";
        key.extend_from_slice(&(wm.len() as u32).to_be_bytes());
        key.extend_from_slice(wm);
        key
    }

    fn watermark_value(n: u64) -> Vec<u8> {
        let mut out = vec![crate::value_codec::TAG_INT64];
        out.extend_from_slice(&(n as i64).to_be_bytes());
        out
    }

    #[test]
    fn change_log_pruning_keeps_dirty_records_and_advances_watermark() {
        let path = temp_path("prune");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Watermark already at 3 implies lsns 1..2 were pruned earlier, so the
        // log holds 3 non-dirty records (lsn 3..5) + 2 dirty records (lsn 6,7).
        let mut seed = Vec::new();
        for lsn in 3..=5u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(false, lsn))
                )
            );
        }
        for lsn in 6..=7u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(true, lsn))
                )
            );
        }
        seed.push(
            op_with_table(
                OpKind::Put,
                "__gecko_sync_meta",
                Some(watermark_key()),
                Some(watermark_value(3))
            )
        );
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();

        // Retention 3: a change-log-touching batch makes count 6 → excess 3,
        // so the 3 oldest NON-DIRTY records (lsn 3..5) are pruned from the
        // prunable prefix (which starts at [watermark, 0] = [3, 0]) and the
        // watermark advances to max(3, 5) = 5.
        let result = worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(8)),
                        Some(encode_change_record(true, 8))
                    ),
                ],
                &[],
                3
            )
            .unwrap();
        assert!(result.deltas.is_empty());
        for lsn in 3..=5u64 {
            assert_eq!(
                worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap(),
                None,
                "non-dirty lsn {lsn} should be pruned"
            );
        }
        // Dirty records (6,7,8) survive.
        assert!(worker.get("__gecko_change_log", &encode_log_key(6)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key(7)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key(8)).unwrap().is_some());
        // Watermark advanced to 5.
        let wm = worker.get("__gecko_sync_meta", &watermark_key()).unwrap();
        assert_eq!(
            crate::value_codec::decode_value(&wm.unwrap()).ok(),
            Some(crate::value_codec::RowValue::Int64(5))
        );

        // A batch that does NOT touch the change log must not prune.
        worker
            .apply_batch_reactive_with_retention(
                &[op_with_table(OpKind::Put, "items", Some(b"k1".to_vec()), Some(vec![1]))],
                &[],
                1
            )
            .unwrap();
        assert!(worker.get("__gecko_change_log", &encode_log_key(6)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key(7)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key(8)).unwrap().is_some());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn change_log_pruning_under_and_at_limit_scans_nothing() {
        let path = temp_path("prune-under-at");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let mut seed = Vec::new();
        for lsn in 1..=4u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(false, lsn))
                )
            );
        }
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();
        worker.enable_counters();

        // Under the limit: nothing pruned, and the O(1) length check means
        // zero entries are scanned.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(5)),
                        Some(encode_change_record(false, 5))
                    ),
                ],
                &[],
                10
            )
            .unwrap();
        for lsn in 1..=5u64 {
            assert!(worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap().is_some());
        }
        let counters = worker.take_counters();
        assert_eq!(counters.change_log_scanned, 0, "under-limit prune must scan nothing");
        assert_eq!(counters.change_log_pruned, 0);

        // Exactly at the limit: still nothing to prune, nothing scanned.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(6)),
                        Some(encode_change_record(false, 6))
                    ),
                ],
                &[],
                6
            )
            .unwrap();
        for lsn in 1..=6u64 {
            assert!(worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap().is_some());
        }
        let counters = worker.take_counters();
        assert_eq!(counters.change_log_scanned, 0, "at-limit prune must scan nothing");
        assert_eq!(counters.change_log_pruned, 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn change_log_pruning_all_dirty_over_limit_keeps_everything() {
        let path = temp_path("prune-all-dirty");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let mut seed = Vec::new();
        for lsn in 1..=8u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(true, lsn))
                )
            );
        }
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();
        worker.enable_counters();
        // Over the limit but every record is dirty: nothing is pruned and the
        // watermark stays absent.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(9)),
                        Some(encode_change_record(true, 9))
                    ),
                ],
                &[],
                4
            )
            .unwrap();
        for lsn in 1..=9u64 {
            assert!(worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap().is_some());
        }
        let counters = worker.take_counters();
        assert_eq!(counters.change_log_pruned, 0);
        assert_eq!(worker.get("__gecko_sync_meta", &watermark_key()).unwrap(), None);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn change_log_pruning_same_lsn_ordinals_are_incrementally_covered() {
        let path = temp_path("prune-same-lsn");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Two clean records at the same LSN (ordinals 0 and 1) plus one clean
        // record at the next LSN.
        let seed = vec![
            op_with_table(
                OpKind::Put,
                "__gecko_change_log",
                Some(encode_log_key_ordinal(5, 0)),
                Some(encode_change_record(false, 5))
            ),
            op_with_table(
                OpKind::Put,
                "__gecko_change_log",
                Some(encode_log_key_ordinal(5, 1)),
                Some(encode_change_record(false, 5))
            ),
            op_with_table(
                OpKind::Put,
                "__gecko_change_log",
                Some(encode_log_key_ordinal(6, 0)),
                Some(encode_change_record(false, 6))
            ),
        ];
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();

        // Retention 3: adding [6,1] makes len 4 → excess 1. The first prune
        // removes only [5, 0] and advances the watermark to 5 even though
        // [5, 1] is still clean and shares that LSN.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key_ordinal(6, 1)),
                        Some(encode_change_record(false, 6))
                    ),
                ],
                &[],
                3
            )
            .unwrap();
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key_ordinal(5, 0)).unwrap(), None);
        assert!(worker.get("__gecko_change_log", &encode_log_key_ordinal(5, 1)).unwrap().is_some());
        let wm = worker.get("__gecko_sync_meta", &watermark_key()).unwrap();
        assert_eq!(
            crate::value_codec::decode_value(&wm.unwrap()).ok(),
            Some(crate::value_codec::RowValue::Int64(5))
        );

        // The next prune must still find [5, 1] even though it shares the
        // watermark LSN — the incremental scan starts at [watermark, 0], which
        // re-covers the boundary LSN.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key_ordinal(7, 0)),
                        Some(encode_change_record(false, 7))
                    ),
                ],
                &[],
                3
            )
            .unwrap();
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key_ordinal(5, 1)).unwrap(), None);
        assert!(worker.get("__gecko_change_log", &encode_log_key_ordinal(6, 0)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key_ordinal(6, 1)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key_ordinal(7, 0)).unwrap().is_some());

        // A third prune advances past LSN 5 once no clean record shares it.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key_ordinal(8, 0)),
                        Some(encode_change_record(false, 8))
                    ),
                ],
                &[],
                3
            )
            .unwrap();
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key_ordinal(6, 0)).unwrap(), None);
        assert!(worker.get("__gecko_change_log", &encode_log_key_ordinal(6, 1)).unwrap().is_some());
        assert!(worker.get("__gecko_change_log", &encode_log_key_ordinal(7, 0)).unwrap().is_some());
        let wm = worker.get("__gecko_sync_meta", &watermark_key()).unwrap();
        assert_eq!(
            crate::value_codec::decode_value(&wm.unwrap()).ok(),
            Some(crate::value_codec::RowValue::Int64(6))
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn change_log_pruning_reopens_and_resumes_from_watermark() {
        let path = temp_path("prune-reopen");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let mut seed = Vec::new();
        for lsn in 1..=6u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(false, lsn))
                )
            );
        }
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();
        // Retention 4: adding a dirty [7] makes len 7 → excess 3, pruning the
        // 3 oldest clean records (lsns 1..3) and advancing the watermark to 3.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(7)),
                        Some(encode_change_record(true, 7))
                    ),
                ],
                &[],
                4
            )
            .unwrap();
        for lsn in 1..=3u64 {
            assert_eq!(
                worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap(),
                None,
                "lsn {lsn} should be pruned"
            );
        }
        drop(worker);

        // Reopen: the watermark must be restored, and the next prune must only
        // scan from [3, 0], pruning lsn 4 to return to the limit.
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let wm = worker.get("__gecko_sync_meta", &watermark_key()).unwrap();
        assert_eq!(
            crate::value_codec::decode_value(&wm.unwrap()).ok(),
            Some(crate::value_codec::RowValue::Int64(3))
        );
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(8)),
                        Some(encode_change_record(true, 8))
                    ),
                ],
                &[],
                4
            )
            .unwrap();
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key(3)).unwrap(), None);
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key(4)).unwrap(), None);
        for lsn in 5..=8u64 {
            assert!(worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap().is_some());
        }
        let wm = worker.get("__gecko_sync_meta", &watermark_key()).unwrap();
        assert_eq!(
            crate::value_codec::decode_value(&wm.unwrap()).ok(),
            Some(crate::value_codec::RowValue::Int64(4))
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn change_log_pruning_does_not_rescan_pruned_region() {
        let path = temp_path("prune-no-rescan");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let mut seed = Vec::new();
        for lsn in 1..=20u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(false, lsn))
                )
            );
        }
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();
        // First prune: retention 10 over 20 clean + 1 dirty → excess 11,
        // pruning lsns 1..11 and advancing the watermark to 11.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(21)),
                        Some(encode_change_record(true, 21))
                    ),
                ],
                &[],
                10
            )
            .unwrap();
        worker.enable_counters();
        // Second prune: retention 10, adding dirty [22] makes len 11 → excess
        // 1. The scan starts at [11, 0] and prunes [12, 0]; the 11 already-
        // pruned records below the watermark are never revisited.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(22)),
                        Some(encode_change_record(true, 22))
                    ),
                ],
                &[],
                10
            )
            .unwrap();
        let counters = worker.take_counters();
        assert_eq!(counters.change_log_pruned, 1);
        // Far fewer entries scanned than the 20+ records that ever existed;
        // a full-log scan would visit every live record.
        assert!(counters.change_log_scanned <= 2, "scanned {}", counters.change_log_scanned);
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key(11)).unwrap(), None);
        assert_eq!(worker.get("__gecko_change_log", &encode_log_key(12)).unwrap(), None);
        assert!(worker.get("__gecko_change_log", &encode_log_key(13)).unwrap().is_some());
        let _ = std::fs::remove_file(path);
    }

    fn encode_change_record_with_origin(dirty: bool, lsn: u64, origin: &str) -> Vec<u8> {
        let mut dirty_bytes = vec![crate::value_codec::TAG_BOOL];
        dirty_bytes.push(if dirty { 1 } else { 0 });
        let mut id_bytes = vec![crate::value_codec::TAG_INT64];
        id_bytes.extend_from_slice(&(lsn as i64).to_be_bytes());
        encode_test_row(
            &[
                ("dirty", dirty_bytes),
                ("localMutationId", id_bytes),
                ("origin", encode_test_string(origin)),
            ]
        )
    }

    /// A change record with the sync-matching fields (`collection`,
    /// `recordId`) plus the local-mutation fields.
    fn encode_sync_record(
        lsn: u64,
        collection: &str,
        record_id: &str
    ) -> Vec<u8> {
        let mut id_bytes = vec![crate::value_codec::TAG_INT64];
        id_bytes.extend_from_slice(&(lsn as i64).to_be_bytes());
        encode_test_row(
            &[
                ("localMutationId", id_bytes),
                ("collection", encode_test_string(collection)),
                ("recordId", encode_test_string(record_id)),
            ]
        )
    }

    /// A matcher for a plain id (match on recordId only).
    fn plain_id_matcher(record_id: &str) -> Vec<u8> {
        let mut out = vec![0x00];
        let rid = encode_test_string(record_id);
        out.extend_from_slice(&(rid.len() as u32).to_be_bytes());
        out.extend_from_slice(&rid);
        out
    }

    /// A matcher for a (collection, recordId) RecordRef.
    fn record_ref_matcher(collection: &str, record_id: &str) -> Vec<u8> {
        let mut out = vec![0x01];
        let col = encode_test_string(collection);
        out.extend_from_slice(&(col.len() as u32).to_be_bytes());
        out.extend_from_slice(&col);
        let rid = encode_test_string(record_id);
        out.extend_from_slice(&(rid.len() as u32).to_be_bytes());
        out.extend_from_slice(&rid);
        out
    }

    /// An attachment metadata row with a parent reference.
    fn encode_attachment_meta(parent_collection: &str, parent_id: &str) -> Vec<u8> {
        encode_test_row(
            &[
                ("parentCollection", encode_test_string(parent_collection)),
                ("parentId", encode_test_string(parent_id)),
            ]
        )
    }

    #[test]
    fn pending_changes_aggregates_dirty_local_records_sorted() {
        let path = temp_path("pending-sync");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let rows: Vec<(&[u8], bool, &str, u64)> = vec![
            (b"a", true, "user", 10),
            (b"b", true, "remoteSync", 20),
            (b"c", false, "user", 30),
            (b"d", true, "user", 5)
        ];
        let mut ops = Vec::new();
        for (key, dirty, origin, lsn) in rows {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_sync_state",
                    Some(key.to_vec()),
                    Some(encode_change_record_with_origin(dirty, lsn, origin))
                )
            );
        }
        worker.apply_batch(&ops).unwrap();
        let got = worker.pending_changes().unwrap();
        // Only dirty + non-remote records qualify: a (lsn 10) and d (lsn 5);
        // sorted by localMutationId → d, a.
        let keys: Vec<&[u8]> = got
            .iter()
            .map(|e| e.0.as_slice())
            .collect();
        assert_eq!(keys, vec![&b"d"[..], &b"a"[..]]);
        // A missing sync-state table yields an empty result, never an error.
        assert!(worker.pending_changes().is_ok());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn sync_state_matching_filters_by_plain_id_and_record_ref() {
        let path = temp_path("sync-matching");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Sync-state rows: items/a1, items/b2, users/u1.
        for (key, lsn, collection, record_id) in [
            (b"k1".to_vec(), 1, "items", "a1"),
            (b"k2".to_vec(), 2, "items", "b2"),
            (b"k3".to_vec(), 3, "users", "u1"),
        ] {
            worker
                .apply_batch(&[op_with_table(
                    OpKind::Put,
                    "__gecko_sync_state",
                    Some(key),
                    Some(encode_sync_record(lsn, collection, record_id)),
                )])
                .unwrap();
        }
        // Match plain id "a1" + RecordRef (users, u1); "b2" must not match.
        let matchers = vec![plain_id_matcher("a1"), record_ref_matcher("users", "u1")];
        let got = worker.sync_state_matching(&matchers).unwrap();
        let mut keys: Vec<&[u8]> = got.iter().map(|e| e.0.as_slice()).collect();
        keys.sort();
        assert_eq!(keys, vec![&b"k1"[..], &b"k3"[..]]);
        for (key, _) in &got {
            let row = worker
                .get("__gecko_sync_state", key)
                .unwrap()
                .unwrap();
            let matches = sync_state_matches(&row, &matchers);
            assert!(matches, "returned row {key:?} must match");
        }
        // Empty matchers → no boundary work.
        assert!(worker.sync_state_matching(&[]).unwrap().is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn changes_since_filters_records_by_sequence() {
        let path = temp_path("changes-since");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        for (key, lsn) in [(b"c1".to_vec(), 1), (b"c2".to_vec(), 2), (b"c5".to_vec(), 5), (b"c10".to_vec(), 10)] {
            worker
                .apply_batch(&[op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(key),
                    Some(encode_sync_record(lsn, "items", "ignored")),
                )])
                .unwrap();
        }
        let got = worker.changes_since(3).unwrap();
        let mut keys: Vec<&[u8]> = got.iter().map(|e| e.0.as_slice()).collect();
        keys.sort();
        assert_eq!(keys, vec![&b"c10"[..], &b"c5"[..]]);
        // A missing change-log table yields an empty result.
        let empty = RedbWorker::open(temp_path("changes-since-empty"), false).unwrap();
        assert!(empty.changes_since(0).unwrap().is_empty());
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(temp_path("changes-since-empty"));
    }

    #[test]
    fn orphaned_attachments_returns_rows_with_missing_parents() {
        let path = temp_path("orphans");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // A live parent row in "items".
        worker
            .apply_batch(&[op_with_table(
                OpKind::Put,
                "items",
                Some(encode_test_string("p1")),
                Some(encode_test_row(&[])),
            )])
            .unwrap();
        // Attachment catalog: one with a live parent, two orphans (missing
        // parent id, and missing parent table).
        for (key, collection, pid) in [
            (b"att1".to_vec(), "items", "p1"),
            (b"att2".to_vec(), "items", "gone"),
            (b"att3".to_vec(), "absent_table", "p1"),
        ] {
            worker
                .apply_batch(&[op_with_table(
                    OpKind::Put,
                    "__gecko_attachments",
                    Some(key),
                    Some(encode_attachment_meta(collection, pid)),
                )])
                .unwrap();
        }
        let orphans = worker.orphaned_attachments().unwrap();
        let mut keys: Vec<&[u8]> = orphans.iter().map(|e| e.0.as_slice()).collect();
        keys.sort();
        assert_eq!(keys, vec![&b"att2"[..], &b"att3"[..]]);
        // A missing attachment table yields an empty result.
        let empty = RedbWorker::open(temp_path("orphans-empty"), false).unwrap();
        assert!(empty.orphaned_attachments().unwrap().is_empty());
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(temp_path("orphans-empty"));
    }

    // ── TopK + slice_offset_limit unit edges ──────────────────────────────

    fn candidate(key: u8, row: u8) -> SortCandidate {
        SortCandidate {
            key: vec![key],
            row: vec![row],
            sort_key: Vec::new(),
        }
    }

    #[test]
    fn topk_cap_zero_is_a_noop() {
        let mut heap = TopK::new(0, |a: &i64, b: &i64| a.cmp(b));
        heap.push(1);
        heap.push(2);
        assert!(heap.into_sorted().is_empty());
    }

    #[test]
    fn topk_cap_plus_one_keeps_the_smallest_cap() {
        let mut heap = TopK::new(3, |a: &i64, b: &i64| a.cmp(b));
        for v in [5, 1, 3, 2, 4] {
            heap.push(v);
        }
        assert_eq!(heap.into_sorted(), vec![1, 2, 3]);
    }

    #[test]
    fn topk_ties_keep_the_incumbent() {
        // Only a strictly-Less item replaces the root; an Equal one does not,
        // so the incumbent (first inserted) survives a tie.
        let mut heap = TopK::new(2, |a: &(u8, i64), b: &(u8, i64)| a.1.cmp(&b.1));
        heap.push((1, 7));
        heap.push((2, 7));
        heap.push((3, 5)); // 5 < 7 → replaces a 7
        let sorted = heap.into_sorted();
        assert_eq!(sorted.len(), 2);
        assert_eq!(sorted[0].1, 5);
        assert_eq!(sorted[1].1, 7);
        // Duplicate keys are kept as a multiset.
        let mut dup = TopK::new(4, |a: &i64, b: &i64| a.cmp(b));
        for v in [2, 2, 2] {
            dup.push(v);
        }
        assert_eq!(dup.into_sorted(), vec![2, 2, 2]);
    }

    #[test]
    fn topk_unsorted_input_yields_ascending_output() {
        let mut heap = TopK::new(4, |a: &i64, b: &i64| a.cmp(b));
        for v in [9, 1, 7, 3] {
            heap.push(v);
        }
        assert_eq!(heap.into_sorted(), vec![1, 3, 7, 9]);
    }

    #[test]
    fn topk_property_keeps_the_cap_smallest_with_duplicates() {
        // Deterministic xorshift64 PRNG (no rand dependency): every round the
        // result must be exactly the `cap` smallest input values (as a sorted
        // multiset — duplicates are exercised heavily by the mod-1000 domain),
        // in ascending order. The documented tie rule (only strictly-Less
        // replaces the root) preserves the multiset of the K smallest values
        // even when Equal keys collide.
        let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
        let mut next = move || {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            state.wrapping_mul(0x2545_f491_4f6c_dd1d)
        };
        for round in 0..20 {
            let cap = 1 + ((next() % 32) as usize);
            let count = 50 + ((next() % 200) as usize);
            let values: Vec<i64> = (0..count).map(|_| (next() % 1000) as i64).collect();

            let mut heap = TopK::new(cap, |a: &i64, b: &i64| a.cmp(b));
            for v in &values {
                heap.push(*v);
            }
            let sorted = heap.into_sorted();
            assert_eq!(sorted.len(), cap.min(count), "round {round}");

            // Ascending output.
            for window in sorted.windows(2) {
                assert!(window[0] <= window[1], "round {round}: not ascending");
            }

            // The multiset must be exactly the cap smallest input values.
            let mut expected: Vec<i64> = values.clone();
            expected.sort_unstable();
            expected.truncate(cap.min(count));
            assert_eq!(sorted, expected, "round {round} cap={cap}");
        }
    }

    #[test]
    fn slice_offset_limit_clamps_out_of_range_windows() {
        fn rows() -> Vec<SortCandidate> {
            vec![candidate(1, 1), candidate(2, 2), candidate(3, 3), candidate(4, 4)]
        }
        // offset == len → empty.
        assert!(slice_offset_limit(rows(), None, 4).is_empty());
        // offset > len → empty.
        assert!(slice_offset_limit(rows(), None, 10).is_empty());
        // offset + limit saturates past the end → remaining rows.
        let got = slice_offset_limit(rows(), Some(10), 2);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].0, vec![3]);
        assert_eq!(got[1].0, vec![4]);
        // offset 1, limit 2 → rows 2,3.
        let got = slice_offset_limit(rows(), Some(2), 1);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].0, vec![2]);
        assert_eq!(got[1].0, vec![3]);
        // No limit → everything after the offset.
        let got = slice_offset_limit(rows(), None, 1);
        assert_eq!(got.len(), 3);
    }

    // ── open / open_encrypted edges ───────────────────────────────────────

    #[test]
    fn open_second_handle_is_database_locked_and_reopen_after_close_works() {
        let path = temp_path("open-twice");
        let worker1 = RedbWorker::open(&path, false).unwrap();
        let err = match RedbWorker::open(&path, false) {
            Err(error) => error,
            Ok(_) => panic!("second open must fail"),
        };
        assert!(matches!(err, WorkerError::DatabaseLocked(_)), "got: {err:?}");
        drop(worker1);
        let worker2 = RedbWorker::open(&path, false).unwrap();
        drop(worker2);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn open_invalid_path_is_a_storage_error() {
        let bogus = std::env
            ::temp_dir()
            .join("gecko-no-such-dir-")
            .join(
                format!(
                    "db-{}.redb",
                    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
                )
            );
        let err = match RedbWorker::open(&bogus, false) {
            Err(error) => error,
            Ok(_) => panic!("opening a path in a missing directory must fail"),
        };
        assert!(matches!(err, WorkerError::Storage(_)), "got: {err:?}");
    }

    #[test]
    fn open_encrypted_rejects_wrong_length_key_and_wrong_key_reopen() {
        let path = temp_path("open-enc");
        // Wrong length key → InvalidOperation, no file created.
        let err = match RedbWorker::open_encrypted(&path, &[0u8; 31], 1) {
            Err(error) => error,
            Ok(_) => panic!("31-byte key must be rejected"),
        };
        assert!(matches!(err, WorkerError::InvalidOperation(_)), "got: {err:?}");
        let err = match RedbWorker::open_encrypted(&path, &[0u8; 33], 1) {
            Err(error) => error,
            Ok(_) => panic!("33-byte key must be rejected"),
        };
        assert!(matches!(err, WorkerError::InvalidOperation(_)));
        {
            let mut worker = RedbWorker::open_encrypted(&path, &[7u8; 32], 1).unwrap();
            worker.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![10]))]).unwrap();
            assert_eq!(worker.get("items", &[1]).unwrap(), Some(vec![10]));
        }
        // Wrong key → storage/decryption error on reopen.
        let err = match RedbWorker::open_encrypted(&path, &[8u8; 32], 1) {
            Err(error) => error,
            Ok(_) => panic!("wrong key must fail to reopen"),
        };
        assert!(matches!(err, WorkerError::Storage(_)), "got: {err:?}");
        // Correct key reopens and reads the data.
        let worker = RedbWorker::open_encrypted(&path, &[7u8; 32], 1).unwrap();
        assert_eq!(worker.get("items", &[1]).unwrap(), Some(vec![10]));
        let _ = std::fs::remove_file(path);
    }

    // ── apply_batch validation matrix ─────────────────────────────────────

    #[test]
    fn apply_batch_rejects_read_ops_and_missing_bounds() {
        let path = temp_path("apply-matrix");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Get inside a write batch → InvalidOperation.
        let err = worker.apply_batch(&[op(OpKind::Get, Some(vec![1]), None)]);
        assert!(matches!(err, Err(WorkerError::InvalidOperation(_))));
        // RangeScan inside a write batch → InvalidOperation.
        let err = worker.apply_batch(
            &[
                Op {
                    kind: OpKind::RangeScan,
                    table: "items".into(),
                    key: None,
                    value: None,
                    start: Some(vec![1]),
                    end: Some(vec![2]),
                },
            ]
        );
        assert!(matches!(err, Err(WorkerError::InvalidOperation(_))));
        // DeleteRange without bounds → InvalidOperation.
        let err = worker.apply_batch(
            &[
                Op {
                    kind: OpKind::DeleteRange,
                    table: "items".into(),
                    key: None,
                    value: None,
                    start: None,
                    end: None,
                },
            ]
        );
        assert!(matches!(err, Err(WorkerError::InvalidOperation(_))));
        // Delete without a key → InvalidOperation.
        let err = worker.apply_batch(&[op(OpKind::Delete, None, None)]);
        assert!(matches!(err, Err(WorkerError::InvalidOperation(_))));
        // No batch committed: sequence stays 0.
        assert_eq!(worker.commit_sequence(), 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn read_only_worker_rejects_all_writes_but_reads_work() {
        let path = temp_path("ro-writes");
        {
            let mut writer = RedbWorker::open(&path, false).unwrap();
            writer.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![10]))]).unwrap();
        }
        let mut ro = RedbWorker::open(&path, true).unwrap();
        // Every write kind is rejected.
        assert!(
            matches!(
                ro.apply_batch(&[op(OpKind::Put, Some(vec![2]), Some(vec![20]))]),
                Err(WorkerError::InvalidOperation(_))
            )
        );
        assert!(
            matches!(
                ro.apply_batch(&[op(OpKind::Delete, Some(vec![1]), None)]),
                Err(WorkerError::InvalidOperation(_))
            )
        );
        assert!(
            matches!(
                ro.apply_batch(
                    &[
                        Op {
                            kind: OpKind::Clear,
                            table: "items".into(),
                            key: None,
                            value: None,
                            start: None,
                            end: None,
                        },
                    ]
                ),
                Err(WorkerError::InvalidOperation(_))
            )
        );
        // Reads still work.
        assert_eq!(ro.get("items", &[1]).unwrap(), Some(vec![10]));
        assert_eq!(ro.range_scan("items", None, None).unwrap().len(), 1);
        let _ = std::fs::remove_file(path);
    }

    // ── get_many / range_scan / repair_index edges ────────────────────────

    #[test]
    fn get_many_duplicate_keys_return_one_row_per_occurrence() {
        let (path, worker) = seed_aggregate_fixture("getmany-dup");
        let keys: Vec<&[u8]> = vec![b"k1", b"k1", b"kX", b"k1"];
        let got = worker.get_many("items", &keys).unwrap();
        // k1 appears once per input occurrence; kX is omitted.
        assert_eq!(got.len(), 3);
        assert!(got.iter().all(|entry| entry.0 == b"k1"));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn range_scan_inverted_bounds_is_empty() {
        let (path, worker) = seed_aggregate_fixture("rscan-inv");
        // start > end → empty, never an error.
        let got = worker.range_scan("items", Some(&[9]), Some(&[1])).unwrap();
        assert!(got.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn repair_index_consistent_is_noop_and_read_only_rejected() {
        let (path, mut worker) = seed_indexed_age_fixture("repair-noop");
        let seq = worker.commit_sequence();
        // Consistent → no write transaction, sequence unchanged.
        worker.repair_index("items", &["age".to_string()]).unwrap();
        assert_eq!(worker.commit_sequence(), seq);
        // Missing primary table → Ok, no-op.
        worker.repair_index("absent", &["age".to_string()]).unwrap();
        assert_eq!(worker.commit_sequence(), seq);
        drop(worker);
        // Read-only rejects repair.
        let ro = RedbWorker::open(&path, true).unwrap();
        let mut ro = ro;
        assert!(
            matches!(
                ro.repair_index("items", &["age".to_string()]),
                Err(WorkerError::InvalidOperation(_))
            )
        );
        let _ = std::fs::remove_file(path);
    }

    // ── query_indexed / multi / sorted / ordered edges ────────────────────

    #[test]
    fn query_indexed_skips_orphaned_entries_and_drift_recheck_wins() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, mut worker) = seed_indexed_age_fixture("qidx-orphan");
        // Orphaned entry: the index points at a primary key that does not
        // exist → silently skipped by the join.
        worker
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::Put,
                        table: "__gecko_index".into(),
                        key: Some(index_key("items", "age", &encode_test_int64(35), b"kX")),
                        value: Some(b"kX".to_vec()),
                        start: None,
                        end: None,
                    },
                ]
            )
            .unwrap();
        let (start, end) = age_field_bounds();
        let got = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        assert!(!got.iter().any(|entry| entry.0 == b"kX"));

        // Drift: overwrite k1's primary age (21) without touching the index
        // (which still says 20). The predicate recheck in query_indexed_multi
        // must win over the stale index entry.
        worker
            .apply_batch(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k1".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("age", encode_test_int64(21)),
                                    ("nick", encode_test_string("g0")),
                                ]
                            )
                        )
                    ),
                ]
            )
            .unwrap();
        let pred20 = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "age".into(),
                    value: RowValue::Int64(20),
                },
            ]
        );
        let got = worker
            .query_indexed_multi(
                "items",
                "__gecko_index",
                &[(start.clone(), end.clone())],
                &pred20,
                false,
                None,
                0
            )
            .unwrap();
        assert!(!got.iter().any(|entry| entry.0 == b"k1"), "drift must fail the recheck");
        let pred21 = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "age".into(),
                    value: RowValue::Int64(21),
                },
            ]
        );
        let got = worker
            .query_indexed_multi(
                "items",
                "__gecko_index",
                &[(start, end)],
                &pred21,
                false,
                None,
                0
            )
            .unwrap();
        assert!(
            got.iter().any(|entry| entry.0 == b"k1"),
            "drift recheck must admit the new value"
        );
        let _ = std::fs::remove_file(path);
    }

    /// Equality-bound range for `(table, field, value)` in index-key space.
    fn eq_bounds(table: &str, field: &str, value: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let mut full = index_key(table, field, value, &[crate::value_codec::TAG_NULL]);
        full.pop(); // strip trailing null → shared prefix
        let mut end = full.clone();
        let mut i = end.len() - 1;
        while i > 0 && end[i] == 0xff {
            end.pop();
            i -= 1;
        }
        let last = end.pop().unwrap();
        end.push(last + 1);
        (full, end)
    }

    #[test]
    fn query_indexed_multi_empty_and_disjoint_ranges_are_empty() {
        use crate::predicate::{ self };
        let (path, worker) = seed_indexed_age_fixture("qmulti-edge");
        let empty_pred = predicate::encode_predicate(&[]);
        // Empty ranges → empty result.
        let got = worker
            .query_indexed_multi("items", "__gecko_index", &[], &empty_pred, false, None, 0)
            .unwrap();
        assert!(got.is_empty());
        // Disjoint equality ranges (age == 10 only k0; age == 30 only k2) →
        // the intersection is empty and the scan exits early.
        let (a0, a1) = eq_bounds("items", "age", &encode_test_int64(10));
        let (b0, b1) = eq_bounds("items", "age", &encode_test_int64(30));
        let got = worker
            .query_indexed_multi(
                "items",
                "__gecko_index",
                &[
                    (a0, a1),
                    (b0, b1),
                ],
                &empty_pred,
                false,
                None,
                0
            )
            .unwrap();
        assert!(got.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_sorted_with_empty_specs_is_empty_not_all_rows() {
        use crate::predicate::{ self };
        let (path, worker) = seed_aggregate_fixture("qs-empty");
        // Empty sort specs → empty result (NOT every row, per worker.rs).
        let got = worker
            .query_sorted("items", &predicate::encode_predicate(&[]), &[1, 0], Some(10), 0)
            .unwrap();
        assert!(got.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_missing_index_table_fallbacks() {
        use crate::predicate::{ self };
        let (path, worker) = seed_indexed_age_fixture("qio-missing");
        let empty_pred = predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        // Missing index table + eq_bounded → empty.
        let got = worker
            .query_indexed_ordered(
                "items",
                "nope_index",
                &start,
                &end,
                &empty_pred,
                "age",
                true,
                false,
                false,
                Some(10),
                0
            )
            .unwrap();
        assert!(got.is_empty());
        // Missing index table + not eq_bounded → falls back to the full
        // top-K sort: k0..k3 ascending by age, then the missing-field k4.
        let got = worker
            .query_indexed_ordered(
                "items",
                "nope_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                false,
                false,
                Some(10),
                0
            )
            .unwrap();
        let keys: Vec<&[u8]> = got
            .iter()
            .map(|entry| entry.0.as_slice())
            .collect();
        assert_eq!(keys, vec![&b"k0"[..], &b"k1"[..], &b"k2"[..], &b"k3"[..], &b"k4"[..]]);
        let _ = std::fs::remove_file(path);
    }

    // ── Priority 5: covers-skip, reverse iterator, planner, composites ─────

    /// Exact bounds for a composite `(f1 == v1, f2 == v2, …)` equality scan:
    /// the shared prefix + ordered elements, upper-bounded by the incremented
    /// last byte.
    fn composite_eq_bounds(
        table: &str,
        fields: &[&str],
        values: &[&[u8]]
    ) -> (Vec<u8>, Vec<u8>) {
        let owned: Vec<String> = fields.iter().map(|f| f.to_string()).collect();
        let mut start = index_key_prefix(table, &owned);
        for value in values {
            start.push(crate::value_codec::TAG_ORDERED);
            crate::value_codec::push_order_encode_slice(&mut start, value).unwrap();
        }
        let mut end = start.clone();
        let last = end.pop().unwrap();
        end.push(last + 1);
        (start, end)
    }

    /// Seeds `items` with `(age, name)` rows THROUGH index maintenance (so
    /// `__gecko_index_meta` counts are maintained), with an `age` index.
    fn seed_indexed_age_through_maintenance(label: &str) -> (std::path::PathBuf, RedbWorker) {
        let path = temp_path(label);
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let indexes = vec![("items".to_string(), vec!["age".to_string()])];
        let mut ops = Vec::new();
        for i in 0..4u8 {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "items",
                    Some(format!("k{i}").into_bytes()),
                    Some(
                        encode_test_row(
                            &[
                                ("age", encode_test_int64((i as i64 + 1) * 10)),
                                ("name", encode_test_string(&format!("n{i}"))),
                            ]
                        )
                    )
                )
            );
        }
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        (path, worker)
    }

    #[test]
    fn query_indexed_covered_skips_predicate_recheck() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, worker) = seed_indexed_age_fixture("qcov");
        worker.enable_counters();
        // EXACT eq bounds + a predicate the index proves → covered, so no row
        // is fetched-and-rechecked (the index entry itself is authoritative).
        let (start, end) = eq_bounds("items", "age", &encode_test_int64(20));
        let pred = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "age".into(),
                    value: RowValue::Int64(20),
                },
            ]
        );
        let got = worker
            .query_indexed_multi("items", "__gecko_index", &[(start, end)], &pred, true, None, 0)
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, b"k1");
        let counters = worker.take_counters();
        assert_eq!(
            counters.predicate_evaluations, 0,
            "a covered query must skip the per-row predicate recheck"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_uncovered_rechecks_and_drift_still_fails() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, mut worker) = seed_indexed_age_fixture("qcove-un");
        // Drift: overwrite k1's age to 21 without touching the index (which
        // still says 20). With covered=false the recheck wins and the stale
        // entry is rejected.
        worker
            .apply_batch(
                &[
                    op_with_table(
                        OpKind::Put,
                        "items",
                        Some(b"k1".to_vec()),
                        Some(
                            encode_test_row(
                                &[
                                    ("age", encode_test_int64(21)),
                                    ("nick", encode_test_string("g0")),
                                ]
                            )
                        )
                    ),
                ]
            )
            .unwrap();
        let (start, end) = eq_bounds("items", "age", &encode_test_int64(20));
        let pred20 = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "age".into(),
                    value: RowValue::Int64(20),
                },
            ]
        );
        let got = worker
            .query_indexed_multi("items", "__gecko_index", &[(start, end)], &pred20, false, None, 0)
            .unwrap();
        assert!(
            !got.iter().any(|entry| entry.0 == b"k1"),
            "drift must fail the recheck when the query is not covered"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_multi_planner_falls_back_to_scan_when_index_cannot_narrow() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let (path, mut worker) = seed_indexed_age_fixture("qplan");
        worker.enable_counters();
        // Add TWO orphaned index entries so the broad age span has MORE
        // entries than the user table has rows → the index cannot narrow →
        // the planner falls back to a full filtered scan.
        for (age, orphan) in [(99i64, b"kX".as_slice()), (100i64, b"kY".as_slice())] {
            worker
                .apply_batch(
                    &[
                        Op {
                            kind: OpKind::Put,
                            table: "__gecko_index".into(),
                            key: Some(index_key("items", "age", &encode_test_int64(age), orphan)),
                            value: Some(orphan.to_vec()),
                            start: None,
                            end: None,
                        },
                    ]
                )
                .unwrap();
        }
        let (start, end) = age_field_bounds();
        let pred = predicate::encode_predicate(
            &[
                Filter::Range {
                    field: "age".into(),
                    min: Some(RowValue::Int64(10)),
                    max: Some(RowValue::Int64(40)),
                },
            ]
        );
        let got = worker
            .query_indexed_multi("items", "__gecko_index", &[(start, end)], &pred, false, None, 0)
            .unwrap();
        // The full scan finds k0..k3 (ages 10..40); the orphans are never
        // materialized and the range predicate is the source of truth.
        let mut keys: Vec<Vec<u8>> = got.iter().map(|e| e.0.clone()).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()],
            "planner fallback must return the semantically matching rows"
        );
        let counters = worker.take_counters();
        assert_eq!(
            counters.candidate_keys_allocated, 0,
            "fallback must not materialize candidate sets"
        );
        assert_eq!(
            counters.primary_rows_visited, 5,
            "fallback must scan the user table once (k0..k4)"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_descending_streams_reverse_with_missing_first() {
        use crate::predicate::{ self };
        let (path, worker) = seed_indexed_age_fixture("qdesc");
        let empty_pred = predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        // DESC without an eq bound: missing-field k4 sorts FIRST, then values
        // descending (k3=40, k2=30, k1=20, k0=10) via the reverse iterator.
        let got = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                true,
                false,
                None,
                0
            )
            .unwrap();
        let keys: Vec<&[u8]> = got
            .iter()
            .map(|entry| entry.0.as_slice())
            .collect();
        assert_eq!(
            keys,
            vec![&b"k4"[..], &b"k3"[..], &b"k2"[..], &b"k1"[..], &b"k0"[..]],
            "descending must put missing rows first then values in reverse"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_descending_ties_break_by_ascending_key() {
        use crate::predicate::{ self };
        let path = temp_path("qdesc-ties");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // Two rows share age=20 (k1, k0 in index order); ties must break by
        // ascending record key even though the stream is reversed.
        let indexes = vec![("items".to_string(), vec!["age".to_string()])];
        let rows = [
            (b"k1".to_vec(), 20i64, "n1"),
            (b"k0".to_vec(), 20i64, "n0"),
            (b"k2".to_vec(), 30i64, "n2"),
        ];
        let mut ops = Vec::new();
        for (key, age, name) in rows {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "items",
                    Some(key),
                    Some(
                        encode_test_row(
                            &[
                                ("age", encode_test_int64(age)),
                                ("name", encode_test_string(name)),
                            ]
                        )
                    )
                )
            );
        }
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        let empty_pred = predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        let got = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                true,
                false,
                None,
                0
            )
            .unwrap();
        let keys: Vec<Vec<u8>> = got.iter().map(|entry| entry.0.clone()).collect();
        // Values descending: 30 (k2) then 20; the age=20 tie is key-ascending
        // (k0 before k1) to match the stable top-K contract.
        assert_eq!(
            keys,
            vec![b"k2".to_vec(), b"k0".to_vec(), b"k1".to_vec()],
            "descending ties must break by ascending record key"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_complete_field_skips_fallback_scan() {
        use crate::predicate::{ self };
        let (path, worker) = seed_indexed_age_through_maintenance("qcomplete");
        worker.enable_counters();
        let empty_pred = predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        // Every row carries age (meta count == table len), so the ascending
        // non-eq path must NOT run the missing-field fallback scan.
        let got = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                false,
                false,
                None,
                0
            )
            .unwrap();
        let keys: Vec<Vec<u8>> = got.iter().map(|entry| entry.0.clone()).collect();
        assert_eq!(
            keys,
            vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()],
            "all rows carry age → stream order is the full semantic order"
        );
        let counters = worker.take_counters();
        assert_eq!(
            counters.primary_rows_visited, 0,
            "a complete sort field must skip the missing-field fallback scan"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_ordered_incomplete_field_still_appends() {
        use crate::predicate::{ self };
        let (path, worker) = seed_indexed_age_fixture("qincomplete");
        worker.enable_counters();
        let empty_pred = predicate::encode_predicate(&[]);
        let (start, end) = age_field_bounds();
        // The fixture has a missing-age row (k4) and its index entries were
        // seeded directly (meta count 0), so the append scan must run.
        let got = worker
            .query_indexed_ordered(
                "items",
                "__gecko_index",
                &start,
                &end,
                &empty_pred,
                "age",
                false,
                false,
                false,
                None,
                0
            )
            .unwrap();
        let keys: Vec<Vec<u8>> = got.iter().map(|entry| entry.0.clone()).collect();
        assert_eq!(
            keys,
            vec![
                b"k0".to_vec(),
                b"k1".to_vec(),
                b"k2".to_vec(),
                b"k3".to_vec(),
                b"k4".to_vec(),
            ],
            "missing-field k4 must be appended when the field is not complete"
        );
        let counters = worker.take_counters();
        assert_eq!(
            counters.primary_rows_visited, 1,
            "only the missing-field row (k4) reaches the append scan — the \
             pre-sized present-set skips the already-matched rows"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn query_indexed_multi_early_stops_with_window() {
        use crate::predicate::{ self, Filter };
        use crate::value_codec::RowValue;
        let path = temp_path("qmulti-window");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let indexes = vec![("items".to_string(), vec!["nick".to_string()])];
        let mut ops = Vec::new();
        for i in 0..100u16 {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "items",
                    Some(format!("r{i}").into_bytes()),
                    Some(
                        encode_test_row(
                            &[("nick", encode_test_string(&format!("g{}", i % 5)))]
                        )
                    )
                )
            );
        }
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        worker.enable_counters();
        // Exact nick == g1 bounds: 20 candidate rows; the window (limit 5)
        // must stop the row fetch after 5 matches.
        let (start, end) = eq_bounds("items", "nick", &encode_test_string("g1"));
        let pred = predicate::encode_predicate(
            &[
                Filter::Equals {
                    field: "nick".into(),
                    value: RowValue::String("g1".into()),
                },
            ]
        );
        let got = worker
            .query_indexed_multi("items", "__gecko_index", &[(start, end)], &pred, true, Some(5), 0)
            .unwrap();
        assert_eq!(got.len(), 5);
        let counters = worker.take_counters();
        // The candidate span is the exact nick==g1 set (20 entries), but the
        // window stops the ROW FETCH after 5 matches — no point reads beyond
        // the page.
        assert_eq!(counters.index_entries_visited, 20);
        assert_eq!(counters.primary_rows_fetched, 5);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn composite_index_maintenance_query_and_repair() {
        let path = temp_path("composite");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.set_composite_indexes(
            "items",
            &[vec!["age".to_string(), "name".to_string()]]
        );
        let indexes = vec![("items".to_string(), vec!["age".to_string()])];
        let mut ops = Vec::new();
        for i in 0..4u8 {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "items",
                    Some(format!("k{i}").into_bytes()),
                    Some(
                        encode_test_row(
                            &[
                                ("age", encode_test_int64((i as i64 + 1) * 10)),
                                ("name", encode_test_string(&format!("n{i}"))),
                            ]
                        )
                    )
                )
            );
        }
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        // The composite key for (age=20, name=n1) exists and joins to k1.
        let (start, end) = composite_eq_bounds(
            "items",
            &["age", "name"],
            &[&encode_test_int64(20), &encode_test_string("n1")]
        );
        let got = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, b"k1");
        // A different composite value (age=30, name=n2 → k2) is outside the
        // (age=20, name=n1) bounds and inside its own exact bounds.
        let (s2, e2) = composite_eq_bounds(
            "items",
            &["age", "name"],
            &[&encode_test_int64(30), &encode_test_string("n2")]
        );
        let got2 = worker.query_indexed("items", "__gecko_index", &s2, &e2).unwrap();
        assert_eq!(got2.len(), 1);
        assert_eq!(got2[0].0, b"k2");

        // Repair rebuilds a removed composite entry from the primary rows.
        let composite_key = durable_index_key_multi(
            "items",
            &["age", "name"],
            &[&encode_test_int64(30), &encode_test_string("n2")],
            b"k2"
        );
        worker
            .apply_batch(
                &[
                    Op {
                        kind: OpKind::Delete,
                        table: "__gecko_index".into(),
                        key: Some(composite_key),
                        value: None,
                        start: None,
                        end: None,
                    },
                ]
            )
            .unwrap();
        worker.repair_index("items", &["age".to_string()]).unwrap();
        let (s3, e3) = composite_eq_bounds(
            "items",
            &["age", "name"],
            &[&encode_test_int64(30), &encode_test_string("n2")]
        );
        let got3 = worker.query_indexed("items", "__gecko_index", &s3, &e3).unwrap();
        assert_eq!(got3.len(), 1, "repair must restore the composite entry");
        assert_eq!(got3[0].0, b"k2");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn composite_index_range_on_trailing_field_is_selective() {
        let path = temp_path("composite-range");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.set_composite_indexes(
            "items",
            &[vec!["age".to_string(), "name".to_string()]]
        );
        let indexes = vec![("items".to_string(), vec!["age".to_string()])];
        let mut ops = Vec::new();
        for i in 0..6u8 {
            ops.push(
                op_with_table(
                    OpKind::Put,
                    "items",
                    Some(format!("k{i}").into_bytes()),
                    Some(
                        encode_test_row(
                            &[
                                ("age", encode_test_int64(30)),
                                ("name", encode_test_string(&format!("n{i}"))),
                            ]
                        )
                    )
                )
            );
        }
        worker.apply_batch_with_indexes(&ops, &indexes).unwrap();
        worker.enable_counters();
        // age == 30 AND name in [n1, n3]: a tight composite range → exactly
        // k1, k2, k3.
        let owned: Vec<String> = ["age", "name"].iter().map(|f| f.to_string()).collect();
        let mut start = index_key_prefix("items", &owned);
        start.push(crate::value_codec::TAG_ORDERED);
        crate::value_codec::push_order_encode_slice(&mut start, &encode_test_int64(30)).unwrap();
        start.push(crate::value_codec::TAG_ORDERED);
        crate::value_codec::push_order_encode_slice(&mut start, &encode_test_string("n1")).unwrap();
        let mut end = index_key_prefix("items", &owned);
        end.push(crate::value_codec::TAG_ORDERED);
        crate::value_codec::push_order_encode_slice(&mut end, &encode_test_int64(30)).unwrap();
        end.push(crate::value_codec::TAG_ORDERED);
        crate::value_codec::push_order_encode_slice(&mut end, &encode_test_string("n3")).unwrap();
        let last = end.pop().unwrap();
        end.push(last + 1);
        let got = worker.query_indexed("items", "__gecko_index", &start, &end).unwrap();
        let mut keys: Vec<Vec<u8>> = got.iter().map(|e| e.0.clone()).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()],
            "a composite (eq, range) bound must be exactly selective"
        );
        let counters = worker.take_counters();
        assert_eq!(counters.index_entries_visited, 3, "tight composite range visits only matches");
        let _ = std::fs::remove_file(path);
    }

    // ── tables / pending-changes / prune edges ────────────────────────────

    #[test]
    fn tables_strips_user_prefix_only() {
        let path = temp_path("tables");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        worker.apply_batch(&[op(OpKind::Put, Some(vec![1]), Some(vec![1]))]).unwrap();
        worker
            .apply_batch(&[op_with_table(OpKind::Put, "users", Some(vec![1]), Some(vec![1]))])
            .unwrap();
        // A reserved metadata table keeps its __gecko_ prefix.
        worker
            .apply_batch(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(1)),
                        Some(encode_change_record(true, 1))
                    ),
                ]
            )
            .unwrap();
        let tables = worker.tables().unwrap();
        assert!(tables.contains(&"items".to_string()));
        assert!(tables.contains(&"users".to_string()));
        assert!(tables.contains(&"__gecko_change_log".to_string()));
        // The internal prefix never leaks.
        assert!(!tables.iter().any(|name| name.contains("__gecko_user_")));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn prune_change_log_retention_zero_disables_pruning() {
        let path = temp_path("prune-zero");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        let mut seed = Vec::new();
        for lsn in 1..=5u64 {
            seed.push(
                op_with_table(
                    OpKind::Put,
                    "__gecko_change_log",
                    Some(encode_log_key(lsn)),
                    Some(encode_change_record(false, lsn))
                )
            );
        }
        worker.apply_batch_with_indexes(&seed, &[]).unwrap();
        // Retention 0 = disabled: even with 5 non-dirty records + 1 new one,
        // nothing is pruned.
        worker
            .apply_batch_reactive_with_retention(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_change_log",
                        Some(encode_log_key(6)),
                        Some(encode_change_record(true, 6))
                    ),
                ],
                &[],
                0
            )
            .unwrap();
        for lsn in 1..=6u64 {
            assert!(
                worker.get("__gecko_change_log", &encode_log_key(lsn)).unwrap().is_some(),
                "lsn {lsn} must survive with retention 0"
            );
        }
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn pending_changes_missing_dirty_defaults_to_kept() {
        let path = temp_path("pending-defaults");
        let mut worker = RedbWorker::open(&path, false).unwrap();
        // A record WITHOUT a `dirty` field defaults to dirty → kept.
        let mut id_bytes = vec![crate::value_codec::TAG_INT64];
        id_bytes.extend_from_slice(&(42i64).to_be_bytes());
        let no_dirty = encode_test_row(
            &[
                ("localMutationId", id_bytes),
                ("origin", encode_test_string("user")),
            ]
        );
        // A record WITHOUT localMutationId sorts as lsn 0.
        let mut no_id = vec![crate::value_codec::TAG_BOOL];
        no_id.push(1);
        let no_lsn = encode_test_row(
            &[
                ("dirty", no_id),
                ("origin", encode_test_string("user")),
            ]
        );
        worker
            .apply_batch(
                &[
                    op_with_table(
                        OpKind::Put,
                        "__gecko_sync_state",
                        Some(b"a".to_vec()),
                        Some(no_dirty)
                    ),
                    op_with_table(
                        OpKind::Put,
                        "__gecko_sync_state",
                        Some(b"b".to_vec()),
                        Some(no_lsn)
                    ),
                ]
            )
            .unwrap();
        let got = worker.pending_changes().unwrap();
        assert_eq!(got.len(), 2);
        // b (lsn 0) sorts before a (lsn 42).
        assert_eq!(got[0].0, b"b");
        assert_eq!(got[1].0, b"a");
        let _ = std::fs::remove_file(path);
    }
}
