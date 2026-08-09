---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0008: Durable Secondary Indexes, Range-Index Support, and the Snapshot-Bound Cursor

## Context

Workstream 3 ("Durable indexes and relationship integration") requires indexes
to move into the same atomic storage path as primary records, queries to serve
ranges from indexes rather than full scans, a defined cursor contract for
concurrent pagination, and relationship helpers wired to indexes with reactive
relationship queries.

Before this ADR, secondary indexes were purely in-memory (`SecondaryIndex`
maintained by the typed collection) and only served equality and string-prefix
lookups; `range()` always fell back to a full table scan, and cursor pagination
(`findPage`) captured a fresh snapshot per page.

## Decision

1. **Durable indexes.** A reserved `__gecko_index` table stores one entry per
   (table, field, value, recordId), keyed by a codec-encoded composite list so
   byte order groups by table → field → value → recordId. `_TxnImpl` appends
   index maintenance ops to the exact same redb write transaction as the
   primary record (index/data atomicity by construction). On collection-open,
   `_rebuildIndex` rebuilds the in-memory index from the primary table, verifies
   the durable table against the primary-derived key set, and repairs any drift
   in one atomic backend batch. A per-table rebuild guard coalesces concurrent
   opens.
2. **Range-index support.** Equality/prefix-indexed fields are also
   range-capable: `SecondaryIndex` maintains a sorted value map per field
   (`SplayTreeMap` under the shared `compareFieldValues` order), and
   `lookupRange` serves inclusive min/max lookups in O(log n + k). `QueryImpl`
   intersects equality, range, and prefix candidates through the index and only
   falls back to a full scan when no index covers any filter (observable via
   `lastPlan` and the engine scan counter).
3. **Snapshot-bound cursor.** `Query.cursor()` returns a `QueryCursor<T>` that
   captures one MVCC snapshot at creation and paginates that frozen view, so
   concurrent inserts/updates/deletes never duplicate or drop records across
   pages. `dispose()` releases the snapshot.
4. **Relationship integration.** `RelationshipManager` takes an `indexLookup`
   so FK lookups (`children`, cascades) use the child collection's index when
   the foreign-key field is indexed. `deleteWithBehavior` is the single
   transaction coordinator: it collects cascade/restrict/set-null/hook and
   many-to-many join-cleanup ops inside `commitBatch` (one write transaction,
   one MVCC snapshot, LSN + change-feed events). Reactive relationship queries
   (`watchChildren`, `watchParent`, `watchJoinIds`) re-emit on either side;
   `addJoin`/`removeJoin` publish a synthetic event on the parent collection
   because join rows live in a reserved table the public feed filters out.

## Consequences

- Indexes survive restart, are repaired atomically on open, and can never be
  silently ahead of or behind the primary table.
- `range()` on an indexed field avoids a full scan (the benchmark gap from
  Workstream 2's query analysis); unindexed ranges still full-scan.
- `QueryCursor` is a new public API member (ADR-gated like any contract
  change); it materializes the ordered matching set once (O(result) memory) in
  exchange for the strong snapshot-bound contract.
- The coordinator gives relationship deletes real LSN/change-feed semantics,
  but relationship-driven deletes are not written as change-log records (only
  the user-visible feed); that metadata gap is tracked for a later workstream.
- `watchJoinIds` re-emits on parent/child changes (join mutations publish a
  synthetic parent event), so N:M reactivity is correct at the cost of a
  re-query on those changes.
