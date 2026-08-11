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

use redb::{ReadTransaction, TableError, WriteTransaction, ReadableTable};

use crate::predicate::{ decode_predicate, Predicate };
use crate::sort_spec::{ decode_sort_specs, SortSpec, SortSpecs };
use crate::value_codec;
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
    predicate: Predicate,
    specs: SortSpecs,
    /// Byte-key-ordered materialized result set (key bytes → row bytes).
    rows: std::collections::BTreeMap<Vec<u8>, Vec<u8>>,
    /// Comparator-ordered list for sorted registrations (None when unsorted).
    sorted: Option<Vec<ByteEntry>>,
}

impl LiveQuery {
    fn matches(&self, row_bytes: &[u8]) -> bool {
        self.predicate.test_bytes(row_bytes)
    }

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

fn insert_sorted(list: &mut Vec<ByteEntry>, key: Vec<u8>, row: Vec<u8>, specs: &[SortSpec]) {
    let entry = (key, row);
    let at = lower_bound(list, &entry, specs);
    list.insert(at, entry);
}

/// Replaces [key] in the sorted list (when present) and re-inserts it at the
/// comparator position.
fn upsert_sorted(
    list: &mut Vec<ByteEntry>,
    key: &[u8],
    row: &[u8],
    was_present: bool,
    specs: &[SortSpec],
) {
    if was_present {
        if let Some(i) = list.iter().position(|entry| entry.0 == key) {
            list.remove(i);
        }
    }
    insert_sorted(list, key.to_vec(), row.to_vec(), specs);
}

fn remove_sorted(list: &mut Vec<ByteEntry>, key: &[u8]) {
    if let Some(i) = list.iter().position(|entry| entry.0 == key) {
        list.remove(i);
    }
}

fn read_key(
    txn: &WriteTransaction,
    table: &str,
    key: &[u8]
) -> Result<Option<Vec<u8>>, WorkerError> {
    let t = match txn.open_table(table_definition(table)) {
        Ok(t) => t,
        Err(TableError::TableDoesNotExist(_)) => return Ok(None),
        Err(error) => return Err(WorkerError::Storage(error.to_string())),
    };
    let found = t.get(key).map_err(|error| WorkerError::Storage(error.to_string()))?;
    Ok(found.map(|value| value.value().to_vec()))
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
    ) -> Result<(u64, Vec<ByteEntry>), WorkerError> {
        let predicate = decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let specs = decode_sort_specs(sort_bytes).map_err(WorkerError::Wire)?;
        let id = self.next_id;
        self.next_id += 1;
        let mut rows = std::collections::BTreeMap::new();
        let mut sorted: Option<Vec<ByteEntry>> = if specs.is_empty() { None } else { Some(Vec::new()) };
        match txn.open_table(table_definition(table)) {
            Ok(t) => {
                for entry in t
                    .iter()
                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                {
                    let (key, value) = entry
                        .map_err(|error| WorkerError::Storage(error.to_string()))?;
                    let row = value.value().to_vec();
                    if !predicate.test_bytes(&row) {
                        continue;
                    }
                    let key_bytes = key.value().to_vec();
                    rows.insert(key_bytes.clone(), row.clone());
                    if let Some(list) = sorted.as_mut() {
                        insert_sorted(list, key_bytes, row, &specs.specs);
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
                predicate,
                specs,
                rows,
                sorted,
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
    /// delta per registration. [affected] is the `(table, key)` pairs changed by
    /// put/delete/delete-range ops; [cleared] lists tables removed wholesale.
    pub fn apply(
        &mut self,
        txn: &WriteTransaction,
        affected: &[(String, Vec<u8>)],
        cleared: &[String],
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
            deltas.push(self.apply_one(txn, id, affected, cleared)?);
        }
        Ok(deltas)
    }

    fn apply_one(
        &mut self,
        txn: &WriteTransaction,
        id: u64,
        affected: &[(String, Vec<u8>)],
        cleared: &[String],
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
        for (change_table, key) in affected {
            if change_table != &table {
                continue;
            }
            let current = read_key(txn, &table, key)?;
            let was_present = query.rows.contains_key(key);
            let matches = current
                .as_deref()
                .map(|row| query.matches(row))
                .unwrap_or(false);
            let key_bytes = key.clone();
            if matches {
                let row = current.expect("matches implies present");
                if was_present {
                    let old = query.rows.get(&key_bytes).expect("was_present row exists");
                    if *old != row {
                        updated.push((key_bytes.clone(), row.clone()));
                    }
                } else {
                    added.push((key_bytes.clone(), row.clone()));
                }
                query.rows.insert(key_bytes.clone(), row.clone());
                if let Some(list) = query.sorted.as_mut() {
                    upsert_sorted(list, &key_bytes, &row, was_present, &query.specs.specs);
                }
            } else if was_present {
                let old = query.rows.remove(&key_bytes).expect("was_present row exists");
                removed.push((key_bytes.clone(), old));
                if let Some(list) = query.sorted.as_mut() {
                    remove_sorted(list, &key_bytes);
                }
            }
        }
        let snapshot = query.snapshot();
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
