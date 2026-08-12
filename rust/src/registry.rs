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
use std::sync::Arc;

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
    specs: Arc<SortSpecs>,
    /// Windowed live-query bounds (Item 8): `limit` = max rows emitted
    /// (None = unbounded), `offset` = rows skipped before the window. The
    /// registry still maintains the FULL matching set incrementally; the
    /// emitted snapshot and diff are window-relative, so a change outside the
    /// window never re-runs the query or forces a full Dart re-evaluation.
    limit: Option<u64>,
    offset: u64,
    /// The last emitted window (key, row), used to diff the next window so a
    /// row that shifts across the window boundary is reported as
    /// removed/added rather than as a stale in-window update.
    prev_window: Vec<ByteEntry>,
    /// Byte-key-ordered materialized result set (key bytes → row bytes).
    rows: std::collections::BTreeMap<Vec<u8>, Vec<u8>>,
    /// Comparator-ordered tree for sorted registrations (None when unsorted):
    /// a [SortedKey]-keyed BTreeMap gives O(log n) ordered insert/remove
    /// without shifting a Vec or rewriting every later position.
    sorted: Option<std::collections::BTreeMap<SortedKey, Vec<u8>>>,
    /// Record key → its current [SortedKey] (None when unsorted). Locates the
    /// old sort key of an updated row in O(1) so the tree remove is O(log n).
    sorted_keys: HashMap<Vec<u8>, SortedKey>,
}

/// The comparator key of one row under a registration's sort specs: the
/// decoded sort values (`None` = the field is missing) plus the record-key
/// tiebreak. Values are stored DECODED once at insert time, so a tree keyed
/// by [SortedKey] orders rows exactly like `compare_entry` (which decodes on
/// every comparison) while keeping ordered insert/remove O(log n).
#[derive(Clone)]
struct SortedKey {
    specs: Arc<SortSpecs>,
    values: Vec<Option<value_codec::RowValue>>,
    record_key: Vec<u8>,
}

/// Decodes the sort values of [row] into a [SortedKey] (missing field → None,
/// explicit null → Some(Null), mirroring `compare_entry`'s `find_field`).
fn decode_sort_key(row: &[u8], record_key: &[u8], specs: &Arc<SortSpecs>) -> SortedKey {
    let values = specs
        .specs
        .iter()
        .map(|spec| value_codec::find_field(row, &spec.field).ok().flatten())
        .collect();
    SortedKey {
        specs: Arc::clone(specs),
        values,
        record_key: record_key.to_vec(),
    }
}

impl PartialEq for SortedKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for SortedKey {}
impl PartialOrd for SortedKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for SortedKey {
    fn cmp(&self, other: &Self) -> Ordering {
        // Exactly mirrors `compare_entry`/`sort_spec::compare_rows`: missing
        // fields sort last ascending / first descending, explicit null is a
        // present value, and the record key is the deterministic tiebreak.
        for ((spec, a), b) in self
            .specs
            .specs
            .iter()
            .zip(self.values.iter())
            .zip(other.values.iter())
        {
            match (a, b) {
                (Some(x), Some(y)) => {
                    let c = value_codec::sort_compare(x, y);
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
        self.record_key.cmp(&other.record_key)
    }
}

impl LiveQuery {
    /// True when this registration emits a windowed slice (`limit` set or a
    /// non-zero `offset`) rather than the full matching set.
    fn windowed(&self) -> bool {
        self.limit.is_some() || self.offset > 0
    }

    /// The full current result set in order.
    fn snapshot(&self) -> Vec<ByteEntry> {
        match &self.sorted {
            Some(tree) => tree
                .iter()
                .map(|(key, row)| (key.record_key.clone(), row.clone()))
                .collect(),
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
/// deterministic total order (the same tiebreak as `query_sorted`). Retained
/// as the reference for [SortedKey]'s `Ord`, which mirrors it exactly.
#[allow(dead_code)]
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

/// Inserts [row] into the sorted tree under [sort_key], recording the
/// record-key → sort-key mapping so an update locates and removes the old key
/// in O(log n).
fn insert_sorted(
    tree: &mut std::collections::BTreeMap<SortedKey, Vec<u8>>,
    sorted_keys: &mut HashMap<Vec<u8>, SortedKey>,
    sort_key: SortedKey,
    row: Vec<u8>,
) {
    sorted_keys.insert(sort_key.record_key.clone(), sort_key.clone());
    tree.insert(sort_key, row);
}

/// Replaces [key]'s sorted entry with the new [row]: removes the old sort key
/// (O(log n)) and inserts the freshly decoded one (O(log n)).
fn upsert_sorted(
    tree: &mut std::collections::BTreeMap<SortedKey, Vec<u8>>,
    sorted_keys: &mut HashMap<Vec<u8>, SortedKey>,
    key: &[u8],
    row: &[u8],
    was_present: bool,
    specs: &Arc<SortSpecs>,
) {
    if was_present {
        remove_sorted(tree, sorted_keys, key);
    }
    let sort_key = decode_sort_key(row, key, specs);
    insert_sorted(tree, sorted_keys, sort_key, row.to_vec());
}

/// Removes [record_key]'s entry from the sorted tree in O(log n).
fn remove_sorted(
    tree: &mut std::collections::BTreeMap<SortedKey, Vec<u8>>,
    sorted_keys: &mut HashMap<Vec<u8>, SortedKey>,
    record_key: &[u8],
) {
    if let Some(sort_key) = sorted_keys.remove(record_key) {
        tree.remove(&sort_key);
    }
}

/// The ordered slice `[offset, offset + limit)` of a byte-key-ordered result
/// set (unsorted registrations). Iterates only the rows the window needs.
fn window_from_rows(
    rows: &std::collections::BTreeMap<Vec<u8>, Vec<u8>>,
    offset: u64,
    limit: Option<u64>,
) -> Vec<ByteEntry> {
    let take = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    rows.iter()
        .skip(offset as usize)
        .take(take)
        .map(|(key, row)| (key.clone(), row.clone()))
        .collect()
}

/// The ordered slice `[offset, offset + limit)` of a comparator-ordered
/// result set (sorted registrations). Iterates only the rows the window needs.
fn window_from_sorted(
    tree: &std::collections::BTreeMap<SortedKey, Vec<u8>>,
    offset: u64,
    limit: Option<u64>,
) -> Vec<ByteEntry> {
    let take = limit.map(|l| l as usize).unwrap_or(usize::MAX);
    tree.iter()
        .skip(offset as usize)
        .take(take)
        .map(|(key, row)| (key.record_key.clone(), row.clone()))
        .collect()
}

/// The current window `[offset, offset + limit)` of [query]'s ordered result.
fn current_window(query: &LiveQuery) -> Vec<ByteEntry> {
    match &query.sorted {
        Some(tree) => window_from_sorted(tree, query.offset, query.limit),
        None => window_from_rows(&query.rows, query.offset, query.limit),
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
    /// consistent read transaction. Returns `(id, initial snapshot)`. For
    /// windowed registrations ([limit] is Some) the initial snapshot is the
    /// ordered slice `[offset, offset + limit)`; the full matching set is
    /// still maintained internally so later windows stay correct incrementally.
    #[allow(clippy::too_many_arguments)]
    pub fn register(
        &mut self,
        txn: &ReadTransaction,
        table: &str,
        predicate_bytes: &[u8],
        sort_bytes: &[u8],
        kind: LiveQueryKind,
        limit: Option<u64>,
        offset: u64,
    ) -> Result<(u64, Vec<ByteEntry>), WorkerError> {
        let predicate = decode_predicate(predicate_bytes)
            .map_err(|error| WorkerError::Wire(error.to_string()))?;
        let specs = Arc::new(decode_sort_specs(sort_bytes).map_err(WorkerError::Wire)?);
        let id = self.next_id;
        self.next_id += 1;
        let mut rows = std::collections::BTreeMap::new();
        let has_specs = !specs.specs.is_empty();
        let mut sorted: Option<std::collections::BTreeMap<SortedKey, Vec<u8>>> =
            if has_specs { Some(Default::default()) } else { None };
        let mut sorted_keys: HashMap<Vec<u8>, SortedKey> = HashMap::new();
        // Accepted (key, row) pairs collected before the single sort pass so
        // registration is O(n log n), not O(n²) per-row binary insert.
        let mut accepted: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
        // One predicate scratch buffer reused for the whole scan.
        let mut predicate_scratch = predicate.scratch();
        match txn.open_table(table_definition(table)) {
            Ok(t) => {
                for entry in t
                    .iter()
                    .map_err(|error| WorkerError::Storage(error.to_string()))?
                {
                    let (key, value) = entry
                        .map_err(|error| WorkerError::Storage(error.to_string()))?;
                    let row = value.value().to_vec();
                    if !predicate.test_bytes_with_scratch(&row, &mut predicate_scratch) {
                        continue;
                    }
                    let key_bytes = key.value().to_vec();
                    rows.insert(key_bytes.clone(), row.clone());
                    accepted.push((key_bytes, row));
                }
            }
            Err(TableError::TableDoesNotExist(_)) => {}
            Err(error) => return Err(WorkerError::Storage(error.to_string())),
        }
        // Decode every accepted row's sort key, sort ONCE, then build the
        // ordered tree and the record-key → sort-key map in one pass.
        if let Some(tree) = sorted.as_mut() {
            let mut keys: Vec<SortedKey> = accepted
                .iter()
                .map(|(key, row)| decode_sort_key(row, key, &specs))
                .collect();
            keys.sort();
            for sort_key in keys {
                let row = rows
                    .get(&sort_key.record_key)
                    .expect("accepted row inserted above")
                    .clone();
                sorted_keys.insert(sort_key.record_key.clone(), sort_key.clone());
                tree.insert(sort_key, row);
            }
        }
        // Initial snapshot: the window slice for windowed registrations,
        // otherwise the full ordered set.
        let windowed = limit.is_some() || offset > 0;
        let initial = match &sorted {
            Some(tree) => {
                if windowed {
                    window_from_sorted(tree, offset, limit)
                } else {
                    tree.iter()
                        .map(|(key, row)| (key.record_key.clone(), row.clone()))
                        .collect()
                }
            }
            None => {
                if windowed {
                    window_from_rows(&rows, offset, limit)
                } else {
                    rows.iter()
                        .map(|(key, row)| (key.clone(), row.clone()))
                        .collect()
                }
            }
        };
        self.queries.insert(
            id,
            LiveQuery {
                table: table.to_string(),
                kind,
                predicate_scratch: predicate.scratch(),
                predicate,
                specs,
                limit,
                offset,
                prev_window: initial.clone(),
                rows,
                sorted,
                sorted_keys,
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
        // Deduplicate touched table names first, then collect registration ids
        // ONCE per table — a batch touching K keys in one table never walks
        // that table's registration list K times.
        let mut affected_tables: Vec<&str> = Vec::new();
        let mut table_seen = std::collections::HashSet::new();
        for (table, _) in affected {
            if table_seen.insert(table.as_str()) {
                affected_tables.push(table.as_str());
            }
        }
        for table in affected_tables {
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

        // Whole-table clear: every current row leaves. For a windowed
        // registration only the window (the rows that were actually emitted)
        // leaves the observable result; the full-set clear is implicit.
        if cleared.contains(&table) {
            let removed = if query.windowed() {
                std::mem::take(&mut query.prev_window)
            } else {
                query.snapshot()
            };
            query.rows.clear();
            if let Some(tree) = query.sorted.as_mut() {
                tree.clear();
            }
            query.sorted_keys.clear();
            query.prev_window.clear();
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
                if let Some(tree) = query.sorted.as_mut() {
                    upsert_sorted(
                        tree,
                        &mut query.sorted_keys,
                        &key_bytes,
                        &row,
                        was_present,
                        &query.specs,
                    );
                }
            } else if was_present {
                let old = query.rows.remove(&key_bytes).expect("was_present row exists");
                removed.push((key_bytes.clone(), old));
                counters.bump(&counters.registry_rows_removed, 1);
                if let Some(tree) = query.sorted.as_mut() {
                    remove_sorted(
                        tree,
                        &mut query.sorted_keys,
                        &key_bytes,
                    );
                }
            }
        }

        // Windowed registrations report the WINDOW-relative diff: compare the
        // previously emitted window against the current slice. A row that
        // shifts across the boundary is removed/added (not a stale update),
        // and a change outside the window is invisible. The snapshot is the
        // window itself, so the emitted list is always `[offset, offset+limit)`.
        if query.windowed() {
            let old_window = std::mem::take(&mut query.prev_window);
            let new_window = current_window(query);
            let mut old_keys = std::collections::HashSet::new();
            for (key, _) in &old_window {
                old_keys.insert(key.clone());
            }
            let mut new_keys = std::collections::HashSet::new();
            for (key, _) in &new_window {
                new_keys.insert(key.clone());
            }
            let mut added_window = Vec::new();
            let mut updated_window = Vec::new();
            for (key, row) in &new_window {
                if old_keys.contains(key) {
                    let old_row = old_window
                        .iter()
                        .find(|(k, _)| k == key)
                        .expect("old window key present");
                    if old_row.1 != *row {
                        updated_window.push((key.clone(), row.clone()));
                    }
                } else {
                    added_window.push((key.clone(), row.clone()));
                }
            }
            let mut removed_window = Vec::new();
            for (key, row) in &old_window {
                if !new_keys.contains(key) {
                    removed_window.push((key.clone(), row.clone()));
                }
            }
            counters.bump(&counters.registry_rows_added, added_window.len() as u64);
            counters.bump(&counters.registry_rows_removed, removed_window.len() as u64);
            let unchanged =
                added_window.is_empty() && updated_window.is_empty() && removed_window.is_empty();
            query.prev_window = new_window.clone();
            let snapshot = if query.kind == LiveQueryKind::WatchAllDiff {
                Vec::new()
            } else {
                new_window
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
            return Ok(RegistryDelta {
                id,
                added: added_window,
                updated: updated_window,
                removed: removed_window,
                snapshot,
                unchanged,
            });
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
        let (id0, initial0) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
        let (id1, initial1) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, initial) = registry.register(&txn, "absent", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let err = registry.register(&txn, "items", &bad, &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap_err();
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
        let err = registry.register(&txn, "items", &no_filters(), &bad, LiveQueryKind::WatchAll, None, 0).unwrap_err();
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
        let (_, all) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
        let keys: Vec<Vec<u8>> = all.iter().map(|e| e.0.clone()).collect();
        assert_eq!(keys, vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()]);
        // Sorted by age ascending: k0(10), k1(20), k2(30), k3(40).
        let (_, sorted) = registry.register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::WatchAll, None, 0).unwrap();
        let skeys: Vec<Vec<u8>> = sorted.iter().map(|e| e.0.clone()).collect();
        assert_eq!(skeys, vec![b"k0".to_vec(), b"k1".to_vec(), b"k2".to_vec(), b"k3".to_vec()]);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn register_windowed_returns_the_offset_limit_slice() {
        let (path, db) = seed_db("reg-window");
        let txn = db.begin_read().unwrap();
        let mut registry = LiveRegistry::new();
        // Unsorted byte-key window [k1, k2] (offset 1, limit 2).
        let (_, window) = registry
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::Query, Some(2), 1)
            .unwrap();
        let keys: Vec<Vec<u8>> = window.iter().map(|e| e.0.clone()).collect();
        assert_eq!(keys, vec![b"k1".to_vec(), b"k2".to_vec()]);
        // Sorted-by-age window [k1(20), k2(30)] (offset 1, limit 2).
        let (_, sorted_window) = registry
            .register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::Query, Some(2), 1)
            .unwrap();
        let skeys: Vec<Vec<u8>> = sorted_window.iter().map(|e| e.0.clone()).collect();
        assert_eq!(skeys, vec![b"k1".to_vec(), b"k2".to_vec()]);
        // A limit larger than the set returns everything from the offset.
        let (_, tail) = registry
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::Query, Some(100), 2)
            .unwrap();
        let tkeys: Vec<Vec<u8>> = tail.iter().map(|e| e.0.clone()).collect();
        assert_eq!(tkeys, vec![b"k2".to_vec(), b"k3".to_vec()]);
        drop(txn);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_windowed_diffs_are_window_relative() {
        let (path, db) = seed_db("reg-window-apply");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (_, initial) = registry
            .register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::Query, Some(2), 0)
            .unwrap();
        drop(txn);
        let keys: Vec<Vec<u8>> = initial.iter().map(|e| e.0.clone()).collect();
        assert_eq!(keys, vec![b"k0".to_vec(), b"k1".to_vec()]);

        // A row outside the window changes but stays outside: the window is
        // unchanged and the delta reports nothing (unchanged = true).
        put(&db, "items", b"k3", &encode_row(&[("g", encode_string("g1")), ("age", encode_int64(50))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k3".to_vec())], &[]);
        assert_eq!(deltas.len(), 1);
        assert!(deltas[0].unchanged, "outside-window change is invisible");
        assert_eq!(deltas[0].added.len(), 0);
        assert_eq!(deltas[0].removed.len(), 0);
        let skeys: Vec<Vec<u8>> = deltas[0].snapshot.iter().map(|e| e.0.clone()).collect();
        assert_eq!(skeys, vec![b"k0".to_vec(), b"k1".to_vec()]);

        // k2's age drops to 5: it enters the window at the front and k1 leaves
        // (a boundary crossing must be reported as add/remove, not an update).
        put(&db, "items", b"k2", &encode_row(&[("g", encode_string("g1")), ("age", encode_int64(5))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k2".to_vec())], &[]);
        let delta = &deltas[0];
        let added: Vec<Vec<u8>> = delta.added.iter().map(|e| e.0.clone()).collect();
        let removed: Vec<Vec<u8>> = delta.removed.iter().map(|e| e.0.clone()).collect();
        assert_eq!(added, vec![b"k2".to_vec()]);
        assert_eq!(removed, vec![b"k1".to_vec()]);
        assert_eq!(delta.updated.len(), 0);
        let skeys: Vec<Vec<u8>> = delta.snapshot.iter().map(|e| e.0.clone()).collect();
        assert_eq!(skeys, vec![b"k2".to_vec(), b"k0".to_vec()]);

        // A window row's value changes in place (still in the window) → update.
        put(&db, "items", b"k2", &encode_row(&[("g", encode_string("g1")), ("age", encode_int64(6))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k2".to_vec())], &[]);
        let delta = &deltas[0];
        assert_eq!(delta.updated.len(), 1);
        assert_eq!(delta.added.len(), 0);
        assert_eq!(delta.removed.len(), 0);
        let skeys: Vec<Vec<u8>> = delta.snapshot.iter().map(|e| e.0.clone()).collect();
        assert_eq!(skeys, vec![b"k2".to_vec(), b"k0".to_vec()]);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn apply_windowed_clear_removes_only_the_emitted_window() {
        let (path, db) = seed_db("reg-window-clear");
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (_, initial) = registry
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::Query, Some(2), 1)
            .unwrap();
        drop(txn);
        let keys: Vec<Vec<u8>> = initial.iter().map(|e| e.0.clone()).collect();
        assert_eq!(keys, vec![b"k1".to_vec(), b"k2".to_vec()]);

        let deltas = apply_batch(&db, &mut registry, &[], &["items".to_string()]);
        let delta = &deltas[0];
        let removed: Vec<Vec<u8>> = delta.removed.iter().map(|e| e.0.clone()).collect();
        assert_eq!(removed, vec![b"k1".to_vec(), b"k2".to_vec()]);
        assert!(delta.snapshot.is_empty());
        let _ = std::fs::remove_file(path);
    }

    // ── apply / apply_one ──────────────────────────────────────────────────
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

    /// Builds the post-commit value map the registry consumes: for every
    /// affected (table, key), the current row bytes (None when absent), read
    /// once from [txn] — replacing the registry's own per-key re-reads.

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

    fn delete(db: &Database, table: &str, key: &[u8]) {
        let txn = db.begin_write().unwrap();
        {
            let mut t = txn.open_table(table_definition(table)).unwrap();
            t.remove(key).unwrap();
        }
        txn.commit().unwrap();
    }

    #[test]
    fn sorted_registration_scales_and_repositions_at_scale() {
        let path = temp_path("reg-scale");
        let db = Database::create(&path).unwrap();
        // Seed 10k rows with `age` 0..10000 inserted in REVERSE so the
        // registration must sort the accepted set once.
        {
            let txn = db.begin_write().unwrap();
            {
                let mut t = txn.open_table(table_definition("items")).unwrap();
                for i in (0..10000u64).rev() {
                    let key = format!("k{i:05}");
                    t.insert(
                        key.as_bytes(),
                        encode_row(&[("age", encode_int64(i as i64))]).as_slice(),
                    )
                    .unwrap();
                }
            }
            txn.commit().unwrap();
        }
        let mut registry = LiveRegistry::new();
        let txn = db.begin_read().unwrap();
        let (id, initial) = registry
            .register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::Query, None, 0)
            .unwrap();
        drop(txn);
        assert_eq!(id, 0);
        assert_eq!(initial.len(), 10000);
        assert_eq!(initial[0].0, b"k00000", "ascending order starts at 0");
        assert_eq!(initial[9999].0, b"k09999", "ascending order ends at 9999");

        // Reposition: give k05000 age -1 so it moves to the front (tree
        // remove + reinsert, O(log n)).
        put(&db, "items", b"k05000", &encode_row(&[("age", encode_int64(-1))]));
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k05000".to_vec())], &[]);
        assert_eq!(deltas.len(), 1);
        let delta = &deltas[0];
        assert_eq!(delta.updated.len(), 1);
        assert_eq!(delta.snapshot.len(), 10000);
        assert_eq!(delta.snapshot[0].0, b"k05000", "repositioned row is first");

        // Remove a row from the middle: order stays intact after the tree
        // remove.
        delete(&db, "items", b"k03000");
        let deltas = apply_batch(&db, &mut registry, &[("items".into(), b"k03000".to_vec())], &[]);
        let delta = &deltas[0];
        assert_eq!(delta.removed.len(), 1);
        assert_eq!(delta.snapshot.len(), 9999);
        let ages: Vec<i64> = delta
            .snapshot
            .iter()
            .map(|(_, row)| match value_codec::find_field(row, "age") {
                Ok(Some(value_codec::RowValue::Int64(n))) => n,
                _ => panic!("age field"),
            })
            .collect();
        assert!(ages.windows(2).all(|w| w[0] <= w[1]), "order preserved after remove");
        let _ = std::fs::remove_file(path);
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
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, _) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, _) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, _) = registry.register(&txn, "items", &g0_predicate(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAllDiff, None, 0)
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
            .register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0)
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
        let (id, _) = registry.register(&txn, "items", &no_filters(), &age_ascending_sort(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        let (id, _) = registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
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
        registry.register(&txn, "items", &no_filters(), &no_filters(), LiveQueryKind::WatchAll, None, 0).unwrap();
        drop(txn);
        assert_eq!(registry.len(), 1);
        // A "restarted" registry (a fresh instance over the same db) sees no
        // registrations — the registry holds no redb table.
        let restarted = LiveRegistry::new();
        assert!(restarted.is_empty());
        let _ = std::fs::remove_file(path);
    }
}
