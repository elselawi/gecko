//! Rust-owned reactive registry 
//!
//! Live watches (`watchAll`, `watchAllDiff`, unbounded `query.watch`) register a
//! query with the worker. On every committed batch the worker re-evaluates only
//! the changed keys against each registration, maintains the materialized result
//! set, and returns one delta per affected registration — the reactive
//! computation (predicate evaluation, result-set maintenance, diff computation)
//! executes here, not in Dart.
//!
//! The registry is deliberately **non-durable**: it holds no redb table, nothing
//! is recovered on reopen, and registrations die with the worker. Result sets are
//! maintained byte-key-ordered; sorted registrations additionally keep a
//! comparator-ordered vector with binary-search insert/remove.

use std::cmp::Ordering;
use std::collections::HashMap;

use redb::{ ReadTransaction, TableError, ReadableTable };

use crate::predicate::{ decode_predicate, Predicate };
use crate::sort_spec::{ decode_sort_specs, SortSpec, SortSpecs };
use crate::value_codec;
use crate::counters::AtomicCounters;
use crate::worker::{ table_definition, ByteEntry, WorkerError };

/// The kind of live result a registration maintains.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum LiveQueryKind {
    /// `collection.watchAll()` — full set, emits every relevant batch.
    WatchAll = 0,
    /// `collection.watchAllDiff()` — full set + per-batch diff; suppresses
    /// emissions when nothing observable changed.
    WatchAllDiff = 1,
    /// `query.where(...).watch()` — filtered (optionally sorted) set.
    Query = 2,
}

impl LiveQueryKind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::WatchAll,
            1 => Self::WatchAllDiff,
            2 => Self::Query,
            _ => return None,
        })
    }
}

/// One per-registration delta produced by a committed batch.
#[derive(Debug, Clone, PartialEq)]
pub struct RegistryDelta {
    pub id: u64,
    /// Rows that joined the result set this batch (key, row).
    pub added: Vec<ByteEntry>,
    /// Rows whose value changed but that stayed in the result set.
    pub updated: Vec<ByteEntry>,
    /// Rows that left the result set (key, previous row bytes).
    pub removed: Vec<ByteEntry>,
    /// The full current result set in order (byte-key or comparator order).
    pub snapshot: Vec<ByteEntry>,
    /// True when nothing observable changed (idempotent writes); the
    /// `watchAllDiff` stream suppresses no-op emissions.
    pub unchanged: bool,
}

struct LiveQuery {
    table: String,
    /// The registration kind (drives snapshot materialization: watchAllDiff
    /// consumers receive the diff and skip the redundant full-snapshot clone).
    kind: LiveQueryKind,
    predicate: Predicate,
    predicate_scratch: crate::predicate::PredicateScratch,
    specs: SortSpecs,
    /// Byte-key-ordered materialized result set (key bytes → row bytes).
    rows: std::collections::BTreeMap<Vec<u8>, Vec<u8>>,
    /// Comparator-ordered list for sorted registrations (None when unsorted).
    sorted: Option<Vec<ByteEntry>>,
    /// Key → position in [sorted] (None when unsorted). Locates a key in the
    /// sorted list in O(1) instead of the previous linear scan.
    sorted_index: std::collections::HashMap<Vec<u8>, usize>,
}

impl LiveQuery {
    /// The full current result set in order.
    fn snapshot(&self) -> Vec<ByteEntry> {
        match &self.sorted {
            Some(list) => list.clone(),
            None => self
                .rows
                .iter()
                .map(|(key, row)| (key.clone(), row.clone()))
                .collect(),
        }
    }
}

/// Compares two entries by [specs] (missing fields sort last ascending / first
/// descending, matching `sort_spec::compare_rows`), then by key bytes for a
/// deterministic total order (the same tiebreak as `query_sorted`).
fn compare_entry(a: &ByteEntry, b: &ByteEntry, specs: &[SortSpec]) -> Ordering {
    for spec in specs {
        let a_value = value_codec::find_field(&a.1, &spec.field).ok().flatten();
        let b_value = value_codec::find_field(&b.1, &spec.field).ok().flatten();
        match (a_value, b_value) {
            (Some(x), Some(y)) => {
                let c = value_codec::sort_compare(&x, &y);
                if c != Ordering::Equal {
                    return if spec.descending { c.reverse() } else { c };
                }
            }
            (Some(_), None) => {
                return if spec.descending {
                    Ordering::Greater
                } else {
                    Ordering::Less
                };
            }
            (None, Some(_)) => {
                return if spec.descending {
                    Ordering::Less
                } else {
                    Ordering::Greater
                };
            }
            (None, None) => {}
        }
    }
    a.0.cmp(&b.0)
}

/// First index at which [item] would sort under [specs].
fn lower_bound(list: &[ByteEntry], item: &ByteEntry, specs: &[SortSpec]) -> usize {
    let mut lo = 0;
    let mut hi = list.len();
    while lo < hi {
        let mid = (lo + hi) / 2;
        if compare_entry(&list[mid], item, specs) == Ordering::Less {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo
}

fn insert_sorted(
    list: &mut Vec<ByteEntry>,
    index: &mut std::collections::HashMap<Vec<u8>, usize>,
    key: Vec<u8>,
    row: Vec<u8>,
    specs: &[SortSpec],
) {
    let entry = (key, row);
    let at = lower_bound(list, &entry, specs);
    // Bump every existing index at or after the insertion point.
    for pos in index.values_mut() {
        if *pos >= at {
            *pos += 1;
        }
    }
    list.insert(at, entry);
    index.insert(list[at].0.clone(), at);
}

/// Replaces [key] in the sorted list (when present) and re-inserts it at the
/// comparator position. [index] locates the key in O(1).
fn upsert_sorted(
    list: &mut Vec<ByteEntry>,
    index: &mut std::collections::HashMap<Vec<u8>, usize>,
    key: &[u8],
    row: &[u8],
    was_present: bool,
    specs: &[SortSpec],
) {
    if was_present {
        remove_sorted(list, index, key);
    }
    insert_sorted(list, index, key.to_vec(), row.to_vec(), specs);
}

fn remove_sorted(
    list: &mut Vec<ByteEntry>,
    index: &mut std::collections::HashMap<Vec<u8>, usize>,
    key: &[u8],
) {
    if let Some(i) = index.remove(key) {
        list.remove(i);
        for pos in index.values_mut() {
            if *pos > i {
                *pos -= 1;
            }
        }
    }
}

/// The live-query registry owned by one worker.
pub struct LiveRegistry {
    queries: HashMap<u64, LiveQuery>,
    by_table: HashMap<String, Vec<u64>>,
    next_id: u64,
}

impl LiveRegistry {
    pub fn new() -> Self {
        Self {
            queries: HashMap::new(),
            by_table: HashMap::new(),
            next_id: 0,
        }
    }

    /// Number of active registrations (diagnostics).
    pub fn len(&self) -> usize {
        self.queries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.queries.is_empty()
    }

    /// Registers a live query, materializing its initial result set from one
    /// consistent read transaction. Returns `(id, initial snapshot)`.
    pub fn register(
        &mut self,
        txn: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        sort_bytes: &[u8],
        kind: LiveQueryKind,
    ) -> Result<(u64, Vec<ByteEntry>), WorkerError> {
        let predicate = decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let specs = decode_sort_specs(sort_bytes).map_err(WorkerError::Wire)?;
        let id = self.next_id;
        self.next_id += 1;
        let mut rows = std::collections::BTreeMap::new();
        let mut sorted: Option<Vec<ByteEntry>> = if specs.is_empty() { None } else { Some(Vec::new()) };
        let mut sorted_index: std::collections::HashMap<Vec<u8>, usize> =
            std::collections::HashMap::new();
        match txn.open_table(table_definition(table)) {
            Ok(t) => {
                for entry in t
                    .iter()
                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                {
                    let (key, value) = entry
                        .map_err(|error| WorkerError::Storage(error.to_string()))?;
                    let row = value.value().to_vec();
                    let mut predicate_scratch = predicate.scratch();
                    if !predicate.test_bytes_with_scratch(&row, &mut predicate_scratch) {
                        continue;
                    }
                    let key_bytes = key.value().to_vec();
                    rows.insert(key_bytes.clone(), row.clone());
                    if let Some(list) = sorted.as_mut() {
                        insert_sorted(list, &mut sorted_index, key_bytes, row, &specs.specs);
                    }
                }
            }
            Err(TableError::TableDoesNotExist(_)) => {}
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        }
        let initial = match &sorted {
            Some(list) => list.clone(),
            None => rows
                .iter()
                .map(|(key, row)| (key.clone(), row.clone()))
                .collect(),
        };
        self.queries.insert(
            id,
            LiveQuery {
                table: table.to_string(),
                kind,
                predicate_scratch: predicate.scratch(),
                predicate,
                specs,
                rows,
                sorted,
                sorted_index,
            },
        );
        self.by_table.entry(table.to_string()).or_default().push(id);
        Ok((id, initial))
    }

    /// Removes a registration (idempotent).
    pub fn unregister(&mut self, id: u64) {
        if let Some(query) = self.queries.remove(&id) {
            if let Some(ids) = self.by_table.get_mut(&query.table) {
                ids.retain(|existing| *existing != id);
                if ids.is_empty() {
                    self.by_table.remove(&query.table);
                }
            }
        }
    }

    /// Applies one committed batch to every touched registration, returning one
    /// delta per registration. [affected] is the deduplicated `(table, key)`
    /// pairs changed by put/delete/delete-range ops (batch order); [changed]
    /// carries each affected key's post-commit value (`Some(row)` for a put,
    /// `None` for a delete/delete-range), so the registry never re-reads the
    /// tree — one shared map serves every registration. [cleared] lists tables
    /// removed wholesale.
    pub fn apply(
        &mut self,
        affected: &[(String, Vec<u8>)],
        changed: &HashMap<String, HashMap<Vec<u8>, Option<Vec<u8>>>>,
        cleared: &[String],
        counters: &AtomicCounters,
    ) -> Result<Vec<RegistryDelta>, WorkerError> {
        if self.queries.is_empty() {
            return Ok(Vec::new());
        }
        let mut touched: Vec<u64> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for (table, _) in affected {
            if let Some(ids) = self.by_table.get(table) {
                for id in ids {
                    if seen.insert(*id) {
                        touched.push(*id);
                    }
                }
            }
        }
        for table in cleared {
            if let Some(ids) = self.by_table.get(table) {
                for id in ids {
                    if seen.insert(*id) {
                        touched.push(*id);
                    }
                }
            }
        }
        touched.sort_unstable();
        let mut deltas = Vec::with_capacity(touched.len());
        for id in touched {
            deltas.push(self.apply_one(id, affected, changed, cleared, counters)?);
        }
        Ok(deltas)
    }

    fn apply_one(
        &mut self,
        id: u64,
        affected: &[(String, Vec<u8>)],
        changed: &HashMap<String, HashMap<Vec<u8>, Option<Vec<u8>>>>,
        cleared: &[String],
        counters: &AtomicCounters,
    ) -> Result<RegistryDelta, WorkerError> {
        let table = self.queries.get(&id).expect("touched id exists").table.clone();
        let query = self.queries.get_mut(&id).expect("touched id exists");

        // Whole-table clear: every current row leaves.
        if cleared.contains(&table) {
            let removed = query.snapshot();
            query.rows.clear();
            if let Some(list) = query.sorted.as_mut() {
                list.clear();
            }
            query.sorted_index.clear();
            counters.bump(&counters.registry_rows_removed, removed.len() as u64);
            counters.bump(&counters.registry_rows_cloned, removed.len() as u64);
            counters.bump(
                &counters.registry_snapshot_bytes,
                removed
                    .iter()
                    .map(|(key, row)| (key.len() + row.len()) as u64)
                    .sum::<u64>(),
            );
            let unchanged = removed.is_empty();
            return Ok(RegistryDelta {
                id,
                added: Vec::new(),
                updated: Vec::new(),
                removed,
                snapshot: Vec::new(),
                unchanged,
            });
        }

        let mut added = Vec::new();
        let mut updated = Vec::new();
        let mut removed = Vec::new();
        let table_changed = changed.get(&table);
        for (change_table, key) in affected {
            if change_table != &table {
                continue;
            }
            // Post-commit value supplied by the writer (never re-read): Some
            // for a put, None for a delete/delete-range.
            let current: Option<&Vec<u8>> = table_changed
                .and_then(|m| m.get(key))
                .and_then(|value| value.as_ref());
            let was_present = query.rows.contains_key(key);
            let matches = current
                .map(|row| {
                    query.predicate.test_bytes_with_scratch(
                        row,
                        &mut query.predicate_scratch,
                    )
                })
                .unwrap_or(false);
            let key_bytes = key.clone();
            if matches {
                let row = current.expect("matches implies present").clone();
                if was_present {
                    let old = query.rows.get(&key_bytes).expect("was_present row exists");
                    if *old != row {
                        updated.push((key_bytes.clone(), row.clone()));
                        counters.bump(&counters.registry_rows_updated, 1);
                    }
                } else {
                    added.push((key_bytes.clone(), row.clone()));
                    counters.bump(&counters.registry_rows_added, 1);
                }
                query.rows.insert(key_bytes.clone(), row.clone());
                if let Some(list) = query.sorted.as_mut() {
                    upsert_sorted(
                        list,
                        &mut query.sorted_index,
                        &key_bytes,
                        &row,
                        was_present,
                        &query.specs.specs,
                    );
                }
            } else if was_present {
                let old = query.rows.remove(&key_bytes).expect("was_present row exists");
                removed.push((key_bytes.clone(), old));
                counters.bump(&counters.registry_rows_removed, 1);
                if let Some(list) = query.sorted.as_mut() {
                    remove_sorted(list, &mut query.sorted_index, &key_bytes);
                }
            }
        }
        // WatchAllDiff consumers receive the diff (added/updated/removed);
        // the full snapshot is redundant for them, so its clone/transfer/decode
        // is skipped (Dart maintains its own incremental snapshot).
        let snapshot = if query.kind == LiveQueryKind::WatchAllDiff {
            Vec::new()
        } else {
            query.snapshot()
        };
        if !snapshot.is_empty() {
            counters.bump(&counters.registry_rows_cloned, snapshot.len() as u64);
            counters.bump(
                &counters.registry_snapshot_bytes,
                snapshot
                    .iter()
                    .map(|(key, row)| (key.len() + row.len()) as u64)
                    .sum::<u64>(),
            );
        }
        let unchanged = added.is_empty() && updated.is_empty() && removed.is_empty();
        Ok(RegistryDelta {
            id,
            added,
            updated,
            removed,
            snapshot,
            unchanged,
        })
    }
}

impl Default for LiveRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use redb::{Database, ReadableDatabase, ReadableTable};
    use std::time::{SystemTime, UNIX_EPOCH};

    // ── helpers ────────────────────────────────────────────────────────────

    fn temp_path(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        std::env::temp_dir().join(format!("gecko-registry-{label}-{nonce}.redb"))
    }

    fn encode_string(s: &str) -> Vec<u8> {
        let mut out = vec![value_codec::TAG_STRING];
        let bytes = s.as_bytes();
        out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        out.extend_from_slice(bytes);
        out
    }

    fn encode_int64(n: i64) -> Vec<u8> {
        let mut out = vec![value_codec::TAG_INT64];
        out.extend_from_slice(&n.to_be_bytes());
        out
    }

    fn encode_row(entries: &[(&str, Vec<u8>)]) -> Vec<u8> {
        let mut out = vec![value_codec::TAG_MAP];
        out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
        for (k, v) in entries {
            out.extend_from_slice(&encode_string(k));
            out.extend_from_slice(v);
        }
        out
    }

    /// Opens a database seeded with `items`: k0(g0,age10) k1(g0,age20)
    /// k2(g1,age30) k3(g1,age40). Returns (path, db).
    fn seed_db(label: &str) -> (std::path::PathBuf, Database) {
        let path = temp_path(label);
        let db = Database::create(&path).unwrap();
        let txn = db.begin_write().unwrap();
        {
            let mut table = txn.open_table(table_definition("items")).unwrap();
            table
                .insert(b"k0".as_slice(), encode_row(&[("g", encode_string("g0")), ("age", encode_int64(10))]).as_slice())
                .unwrap();
            table
                .insert(b"k1".as_slice(), encode_row(&[("g", encode_string("g0")), ("age", encode_int64(20))]).as_slice())
                .unwrap();
            table
                .insert(b"k2".as_slice(), encode_row(&[("g", encode_string("g1")), ("age", encode_int64(30))]).as_slice())
                .unwrap();
            table
                .insert(b"k3".as_slice(), encode_row(&[("g", encode_string("g1")), ("age", encode_int64(40))]).as_slice())
                .unwrap();
        }
        txn.commit().unwrap();
        (path, db)
    }

    fn g0_predicate() -> Vec<u8> {
        crate::predicate::encode_predicate(
            &[
                crate::predicate::Filter::Equals {
                    field: "g".into(),
                    value: crate::value_codec::RowValue::String("g0".into()),
                },
            ]
        )
    }

    fn age_ascending_sort() -> Vec<u8> {
        crate::sort_spec::encode_sort_specs(
            &[
                crate::sort_spec::SortSpec {
                    field: "age".into(),
                    descending: false,
                },
            ]
        )
    }

    fn no_filters() -> Vec<u8> {
        vec![1, 0]
    }

    // ── LiveQueryKind::from_u8 ─────────────────────────────────────────────

    #[test]
    fn live_query_kind_from_u8_accepts_0_1_2() {
        assert_eq!(LiveQueryKind::from_u8(0), Some(LiveQueryKind::WatchAll));
        assert_eq!(LiveQueryKind::from_u8(1), Some(LiveQueryKind::WatchAllDiff));
        assert_eq!(LiveQueryKind::from_u8(2), Some(LiveQueryKind::Query));
    }

    #[test]
    fn live_query_kind_from_u8_rejects_other_bytes() {
        assert_eq!(LiveQueryKind::from_u8(3), None);
        assert_eq!(LiveQueryKind::from_u8(255), None);
        assert_eq!(LiveQueryKind::from_u8(128), None);
    }

    // ── register ───────────────────────────────────────────────────────────

    #[test]
    fn register_assigns_sequential_ids_and_filters_rows() {
        let (path, db) = seed_db("reg-seq");
        let txn = db.begin_read().unwrap();
        let mut registry = LiveRegistry::new();
        let (id0, initial0) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        let (id1, initial1) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        assert_eq!(id0, 0);
        assert_eq!(id1, 1);
        // Only g0 rows (k0, k1) match; byte-key order.
        assert_eq!(initial0.len(), 2);
        assert_eq!(initial0[0].0, b"k0");
        assert_eq!(initial0[1].0, b"k1");
        assert_eq!(initial1, initial0);
        assert_eq!(registry.len(), 2);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn register_missing_table_yields_empty_initial_set() {
        let (path, db) = seed_db("reg-missing");
        let txn = db.begin_read().unwrap();
        let mut registry = LiveRegistry::new();
        let (id, initial) = registry.register(&txn, "absent", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        assert_eq!(id, 0);
        assert!(initial.is_empty());
        // Registered anyway (a future clear/put on that table still applies).
        assert_eq!(registry.len(), 1);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn register_rejects_malformed_predicate_bytes() {
        let (path, db) = seed_db("reg-badpred");
        let txn = db.begin_read().unwrap();
        let mut registry = LiveRegistry::new();
        // version 9 — unsupported.
        let bad = vec![9, 0];
        let err = registry.register(&txn, "items", &bad, &no_filters(), LiveQueryKind::WatchAll).unwrap_err();
        assert!(matches!(err, WorkerError::Wire(_)), "expected Wire error, got {err:?}");
        // Nothing was registered.
        assert_eq!(registry.len(), 0);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn register_rejects_malformed_sort_bytes() {
        let (path, db) = seed_db("reg-badsort");
        let txn = db.begin_read().unwrap();
        let mut registry = LiveRegistry::new();
        let bad = vec![9, 0];
        let err = registry.register(&txn, "items", &no_filters(), &bad, LiveQueryKind::WatchAll).unwrap_err();
        assert!(matches!(err, WorkerError::Wire(_)), "expected Wire error, got {err:?}");
        assert_eq!(registry.len(), 0);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn register_unsorted_returns_byte_key_order_sorted_returns_comparator_order() {
        let (path, db) = seed_db("reg-order");
        let txn = db.begin_read().unwrap();
        let mut registry = LiveRegistry::new();
        // Unsorted watch-all: byte-key order k0..k3.
        let (_, all) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        let keys: Vec<Vec<u8>> = all.iter().map(|e| e.0.clone()).collect();
        assert_eq!(keys, vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()]);
        // Sorted by age ascending: k0(10), k1(20), k2(30), k3(40).
        let (_, sorted) = registry.register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::WatchAll).unwrap();
        let skeys: Vec<Vec<u8>> = sorted.iter().map(|e| e.0.clone()).collect();
        assert_eq!(skeys, vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()]);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    // ── apply / apply_one ──────────────────────────────────────────────────

    /// Builds the post-commit value map the registry now consumes: for every
    /// affected (table, key), the current row bytes (None when absent), read
    /// once from [txn] — replacing the registry's own per-key re-reads.
    fn changed_map(
        txn: &redb::WriteTransaction,
        affected: &[(String, Vec<u8>)],
    ) -> HashMap<String, HashMap<Vec<u8>, Option<Vec<u8>>>> {
        let mut changed: HashMap<String, HashMap<Vec<u8>, Option<Vec<u8>>>> = HashMap::new();
        for (table, key) in affected {
            // Scope the table + guard so the cloned row bytes own their data.
            let value = match txn.open_table(table_definition(table)) {
                Ok(t) => match t.get(key.as_slice()) {
                    Ok(Some(guard)) => Some(guard.value().to_vec()),
                    _ => None,
                },
                Err(_) => None,
            };
            changed
                .entry(table.clone())
                .or_default()
                .insert(key.clone(), value);
        }
        changed
    }

    /// Applies a batch directly through the registry (unit level): builds the
    /// post-commit value map from a write transaction, then calls
    /// `registry.apply` in the same transaction.
    fn apply_batch(
        db: &Database,
        registry: &mut LiveRegistry,
        affected: &[(String, Vec<u8>)],
        cleared: &[String],
    ) -> Vec<RegistryDelta> {
        let txn = db.begin_write().unwrap();
        let changed = changed_map(&txn, affected);
        let deltas = registry.apply(affected, &changed, cleared, &AtomicCounters::default()).unwrap();
        txn.commit().unwrap();
        deltas
    }

    fn put(db: &Database, table: &str, key: &[u8], row: &[u8]) {
        let txn = db.begin_write().unwrap();
        {
            let mut t = txn.open_table(table_definition(table)).unwrap();
            t.insert(key, row).unwrap();
        }
        txn.commit().unwrap();
    }

    #[test]
    fn apply_with_no_registrations_is_empty() {
        let (path, db) = seed_db("apply-none");
        let mut registry = LiveRegistry::new();
        let deltas = apply_batch(
            &db,
            &mut registry,
            &[("items".into(), b"k0".to_vec())],
            &[],
        );
        assert!(deltas.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_one_duplicate_affected_keys_last_state_wins() {
        let (path, db) = seed_db("apply-dup");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        // k0 appears twice: g0 → g1 (removed), then g1 → g0 (re-added).
        // The registry only sees the final state once; last state wins.
        let g1 = encode_row(&[("g", encode_string("g1")), ("age", encode_int64(99))]);
        let g0 = encode_row(&[("g", encode_string("g0")), ("age", encode_int64(99))]);
        let wtxn = db.begin_write().unwrap();
        {
            let mut t = wtxn.open_table(table_definition("items")).unwrap();
            t.insert(b"k0".as_slice(), g1.as_slice()).unwrap();
            t.insert(b"k0".as_slice(), g0.as_slice()).unwrap();
        }
        let changed = changed_map(&wtxn, &[("items".into(), b"k0".to_vec())]);
        let deltas = registry
            .apply(
                &[("items".into(), b"k0".to_vec())],
                &changed,
                &[],
                &AtomicCounters::default(),
            )
            .unwrap();
        wtxn.commit().unwrap();
        assert_eq!(deltas.len(), 1);
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        // k0 is in the set with the final value → updated (was present with a
        // different value), not removed.
        assert!(delta.removed.is_empty());
        assert_eq!(delta.updated.len(), 1);
        assert_eq!(delta.updated[0].0, b"k0");
        assert_eq!(delta.updated[0].1, g0);
        assert_eq!(delta.snapshot.len(), 4);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_one_key_join_adds_new_matching_row() {
        let (path, db) = seed_db("apply-join");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        // k4 joins as g0.
        put(&db, "items", b"k4", &encode_row(&[("g", encode_string("g0")), ("age", encode_int64(50))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k4".to_vec())], &[]);
        assert_eq!(deltas.len(), 1);
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        assert_eq!(delta.added.len(), 1);
        assert_eq!(delta.added[0].0, b"k4");
        assert!(!delta.unchanged);
        assert_eq!(delta.snapshot.len(), 3);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_one_same_value_put_is_unchanged() {
        let (path, db) = seed_db("apply-unchanged");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        // Rewrite k0 with the identical row → no observable delta.
        put(&db, "items", b"k0", &encode_row(&[("g", encode_string("g0")), ("age", encode_int64(10))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k0".to_vec())], &[]);
        assert_eq!(deltas.len(), 1);
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        assert!(delta.unchanged);
        assert!(delta.added.is_empty());
        assert!(delta.updated.is_empty());
        assert!(delta.removed.is_empty());
        // Snapshot still holds the full matching set.
        assert_eq!(delta.snapshot.len(), 2);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_one_match_status_flips_produce_added_and_removed() {
        let (path, db) = seed_db("apply-flip");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        // k0: g0 → g1 (matching→non-matching → removed with previous row).
        let k0_g1 = encode_row(&[("g", encode_string("g1")), ("age", encode_int64(10))]);
        // k2: g1 → g0 (non-matching→matching → added).
        let k2_g0 = encode_row(&[("g", encode_string("g0")), ("age", encode_int64(30))]);
        let wtxn = db.begin_write().unwrap();
        {
            let mut t = wtxn.open_table(table_definition("items")).unwrap();
            t.insert(b"k0".as_slice(), k0_g1.as_slice()).unwrap();
            t.insert(b"k2".as_slice(), k2_g0.as_slice()).unwrap();
        }
        let affected = vec![
            ("items".into(), b"k0".to_vec()),
            ("items".into(), b"k2".to_vec()),
        ];
        let changed = changed_map(&wtxn, &affected);
        let deltas = registry
            .apply(&affected, &changed, &[], &AtomicCounters::default())
            .unwrap();
        wtxn.commit().unwrap();
        assert_eq!(deltas.len(), 1);
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        // removed carries the PREVIOUS row value for k0 (g0/10).
        assert_eq!(
            delta.removed,
            vec![(
                b"k0".to_vec(),
                encode_row(&[("g", encode_string("g0")), ("age", encode_int64(10))]),
            )]
        );
        // added carries the new row value for k2.
        assert_eq!(delta.added, vec![(b"k2".to_vec(), k2_g0)]);
        assert!(delta.updated.is_empty());
        // Snapshot: k1 (g0) + k2 (g0), byte-key order.
        assert_eq!(delta.snapshot.len(), 2);
        assert_eq!(delta.snapshot[0].0, b"k1");
        assert_eq!(delta.snapshot[1].0, b"k2");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_one_delete_moves_row_to_removed() {
        let (path, db) = seed_db("apply-del");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        // Delete k1 via an affected-key entry with no current row.
        let wtxn = db.begin_write().unwrap();
        {
            let mut t = wtxn.open_table(table_definition("items")).unwrap();
            t.remove(b"k1".as_slice()).unwrap();
        }
        let changed = changed_map(&wtxn, &[("items".into(), b"k1".to_vec())]);
        let deltas = registry
            .apply(
                &[("items".into(), b"k1".to_vec())],
                &changed,
                &[],
                &AtomicCounters::default(),
            )
            .unwrap();
        wtxn.commit().unwrap();
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        assert_eq!(delta.removed.len(), 1);
        assert_eq!(delta.removed[0].0, b"k1");
        assert_eq!(delta.removed[0].1, encode_row(&[("g", encode_string("g0")), ("age", encode_int64(20))]));
        assert_eq!(delta.snapshot.len(), 3);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_one_whole_table_clear_removes_every_row() {
        let (path, db) = seed_db("apply-clear");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        let wtxn = db.begin_write().unwrap();
        {
            let mut t = wtxn.open_table(table_definition("items")).unwrap();
            let keys: Vec<Vec<u8>> = t.iter().unwrap().map(|e| e.unwrap().0.value().to_vec()).collect();
            for k in keys {
                t.remove(k.as_slice()).unwrap();
            }
        }
        let changed = changed_map(&wtxn, &[]);
        let deltas = registry
            .apply(&[], &changed, &["items".into()], &AtomicCounters::default())
            .unwrap();
        wtxn.commit().unwrap();
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        assert_eq!(delta.removed.len(), 4);
        assert!(delta.added.is_empty());
        assert!(delta.updated.is_empty());
        assert!(delta.snapshot.is_empty());
        assert!(!delta.unchanged);
        // Clearing an already-empty table is unchanged.
        let wtxn2 = db.begin_write().unwrap();
        let changed2 = changed_map(&wtxn2, &[]);
        let deltas2 = registry
            .apply(&[], &changed2, &["items".into()], &AtomicCounters::default())
            .unwrap();
        wtxn2.commit().unwrap();
        assert!(deltas2[0].unchanged);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn watch_all_diff_delta_skips_the_full_snapshot() {
        let (path, db) = seed_db("diff-snapshot");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAllDiff)
            .unwrap();
        drop(txn);
        // A put joining the set: the diff must carry the added row but NOT the
        // full snapshot (Dart maintains its own incremental snapshot).
        put(&db, "items", b"k4", &encode_row(&[("g", encode_string("g0")), ("age", encode_int64(50))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k4".to_vec())], &[]);
        assert_eq!(deltas.len(), 1);
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        assert_eq!(delta.added.len(), 1);
        assert_eq!(delta.added[0].0, b"k4");
        assert!(delta.snapshot.is_empty(), "watchAllDiff must not clone the full snapshot");
        assert!(!delta.unchanged);
        // The same delta shape for a watchAll registration DOES carry the full
        // snapshot (its consumers need it).
        let mut watch_all = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (wid, _) = watch_all
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll)
            .unwrap();
        drop(txn);
        let deltas = apply_batch(&db, &mut watch_all, &[("items".into(), b"k4".to_vec())], &[]);
        assert_eq!(deltas.len(), 1);
        assert_eq!(deltas[0].id, wid);
        assert_eq!(deltas[0].snapshot.len(), 5, "watchAll keeps the full snapshot");
        let _ = std::fs::remove_file(path);
    }

    // ── sorted registrations ───────────────────────────────────────────────

    #[test]
    fn sorted_registration_updates_reposition_and_breaks_ties_by_key() {
        let (path, db) = seed_db("sorted-repos");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        // k0 age 10 → 99: moves to the end (k1,k2,k3,k0).
        put(&db, "items", b"k0", &encode_row(&[("g", encode_string("g0")), ("age", encode_int64(99))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k0".to_vec())], &[]);
        let delta = &deltas[0];
        assert_eq!(delta.id, id);
        let keys: Vec<Vec<u8>> = delta.snapshot.iter().map(|e| e.0.clone()).collect();
        assert_eq!(keys, vec![b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec(), b"k0".to_vec()]);

        // Ties: give k1 and k2 the same age; key bytes break the tie (k1 < k2).
        put(&db, "items", b"k1", &encode_row(&[("g", encode_string("g0")), ("age", encode_int64(50))]));
        put(&db, "items", b"k2", &encode_row(&[("g", encode_string("g1")), ("age", encode_int64(50))]));
        let deltas = apply_batch(
            &db,
            &mut registry,
            &[("items".into(), b"k1".to_vec()), ("items".into(), b"k2".to_vec())],
            &[],
        );
        let keys: Vec<Vec<u8>> = deltas[0].snapshot.iter().map(|e| e.0.clone()).collect();
        // ages: k3=40, k1=50, k2=50 (tie → key order), k0=99.
        assert_eq!(keys, vec![b"k3".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k0".to_vec()]);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn unregister_is_idempotent_and_stops_deltas() {
        let (path, db) = seed_db("unreg");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        assert_eq!(registry.len(), 1);
        registry.unregister(id);
        assert!(registry.is_empty());
        // Idempotent.
        registry.unregister(id);
        registry.unregister(999);
        assert!(registry.is_empty());
        // Deltas stop.
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k0".to_vec())], &[]);
        assert!(deltas.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn registry_is_non_durable_across_instances() {
        let (path, db) = seed_db("nondur");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll).unwrap();
        drop(txn);
        assert_eq!(registry.len(), 1);
        // A "restarted" registry (a fresh instance over the same db) sees no
        // registrations — the registry holds no redb table.
        let restarted = LiveRegistry::new();
        assert!(restarted.is_empty());
        let _ = std::fs::remove_file(path);
    }
}
