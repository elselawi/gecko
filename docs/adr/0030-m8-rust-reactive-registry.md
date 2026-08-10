---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0030: M8 — Rust-owned reactive registry

## Context

M8's goal: a write updates only the live result sets it can affect, and the update
cost does not grow with the size of the watched collections.

A provisional Dart implementation (ADR-0029 v1, commit `acb02c9`) landed first. It
locked the reactive lifecycle contract — per-batch coalescing, emission ordering,
cancellation, backpressure, replay — produced the done-when benchmark
(`benchmark/m8_reactivity.dart`) and the single-hop `RawBackend.getMany` primitive,
and its behavioral tests (`m8_reactivity_test.dart`) pin the observable contract.
But it executes the reactive computation in Dart: each watch keeps a
`MaterializedRows` cache, re-tests changed keys against predicates in Dart
(`FilterGroup.test`), and maintains sort order with Dart comparators. That violates
the thin-client rule (plan.md §0): Dart may author and orchestrate; **Rust computes.**

This ADR supersedes ADR-0029's "Dart owns invalidation in M8" decision. The
provisional implementation is a lifecycle-lock stepping stone, not the destination;
its Dart invalidation code is deleted by this milestone.

## Decision

A **non-durable reactive registry lives in the Rust worker**. Live watches register a
query with the worker; on every committed batch the worker re-evaluates only the
changed keys against each registration, maintains the materialized result set, and
returns one delta per affected registration in the same `apply_batch` response.
Dart forwards deltas to `Stream`s and renders them through `fromRow` — it no longer
evaluates predicates, orders rows, or maintains result sets.

### Registry model

- A registration is `(id, table, kind, predicate, sort_specs)` where
  - `kind ∈ { watchAll, watchAllDiff, query }` (all unbounded; windowed limit/offset
    queries keep documented Dart full re-evaluation because a window can reorder);
  - `predicate` is the existing encoded predicate bytes (`encodePredicate`);
  - `sort_specs` are the existing encoded sort bytes (`encodeSortSpecs`).
- The registry is **not durable**: it holds no table in redb, nothing is recovered on
  reopen, and registrations die with the worker. This matches "no second persistence
  system" and avoids recovery semantics entirely.
- Result sets are maintained as a byte-key-ordered `BTreeMap<key, row>`; sorted
  registrations additionally keep a comparator-ordered `Vec<ByteEntry>` with
  binary-search insert/remove (the Rust sort comparator, same rules as
  `query_sorted`).

### Per-batch evaluation

`apply_batch_with_indexes` collects the affected `(table, key)` pairs (and cleared
tables) while applying ops, then — in the same write transaction, before commit —
evaluates each affected key against every registration on that table:

- point-read the current row bytes (the write txn observes the new state);
- `predicate.test_bytes` decides join/leave/update;
- the result set is updated and the delta `(added, updated, removed, snapshot,
  unchanged)` is computed; `removed` carries the old row bytes, `unchanged` is true
  when nothing observable changed (idempotent writes; used to suppress
  `watchAllDiff` no-op emissions).

`apply_batch` returns `{ sequence, deltas }` in one FRB hop; the engine forwards each
delta to a broadcast `liveDeltas` stream at the same point it publishes the change
feed, so delta order matches the existing change-bus order (the write gate already
defines completion order; the reactive ordering contract is unchanged).

### Lifecycle

- Dart `StreamController.onListen` calls `registerLiveQuery(table, predicateBytes,
  sortBytes, kind)` → worker computes the initial result set (one read transaction,
  reusing the predicate/sort machinery) and returns `(id, initial)`; the stream emits
  the initial snapshot, then subscribes to `liveDeltas` and forwards deltas for its
  `id`. Registration and the listener attachment happen in one synchronous block, so
  no delta can be missed (the worker serializes register/apply).
- `onCancel` calls `unregisterLiveQuery(id)` and cancels the delta subscription.
- Coalescing (one delta per registration per batch), ordering, cancellation,
  backpressure (bounded liveDeltas delivery mirrors ChangeBus), and replay
  (resubscribe + current-state emission) are unchanged from ADR-0029 v1.

### Public API additions

- `RawBackend.applyBatch` returns `ApplyBatchResult { affected, deltas }` instead of
  just the affected set (additive field set; low-level backend contract).
- `RawBackend.registerLiveQuery(...) / unregisterLiveQuery(id)` (implemented by
  `NativeRawBackend`; the shared dispatch + Web JSON protocol get the same cases).
- `RawEngine` exposes `liveDeltas` and the register/unregister delegates.
- The public reactive surface (`watchAll`, `watchAllDiff`, `watch()`,
  `CollectionDiff`, `ChangeSet`, `Change`) is **unchanged**; the API snapshot is
  regenerated for the additive raw-backend methods.

## Consequences

- **No Dart predicate evaluation or result-set maintenance remains**: `MaterializedRows`,
  `_applyChanges`, `_applyDiffChanges`, `_applyQueryChanges`,
  `_upsertSorted`/`_lowerBound`/`_indexOfKey`, and the Dart diff computation are
  deleted. Dart maps worker deltas through `fromRow` only.
- **Done-when**: with N live filtered queries and a single-row write, update cost is
  flat vs collection size (10k vs 50k) and flat vs N; `scannedRows == 0`.
  `benchmark/m8_reactivity.dart` and `m8_reactivity_test.dart` pass unchanged.
- Ordering parity with `getAll()`/unsorted `findAll()` (byte-key) and comparator order
  for sorted queries is preserved — now guaranteed by the worker.
- The registry is per-worker memory; multiple databases each own their registry.
- Rust owns the new computation, so Rust unit tests cover register/unregister,
  join/leave/update/delete, whole-table clears, sorted insertion, coalescing, and
  idempotent-write suppression.

## Alternatives considered

- **Keep invalidation in Dart (ADR-0029 v1)** — rejected: violates the thin-client
  rule; Dart executes predicate/sort/diff semantics.
- **Rust primitive that only re-tests changed keys; Dart keeps the cache** (M8
  "option B") — rejected by maintainers in favor of full Rust ownership of result-set
  maintenance and diff computation.
- **Durable reactive state** — rejected: nothing to recover; a registry that dies with
  the worker is strictly simpler.
