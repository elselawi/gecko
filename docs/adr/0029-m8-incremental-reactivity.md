---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0029: M8 incremental reactivity

## Context

Reactive streams re-evaluate their full result on every relevant batch:

- `collection.watchAll()` re-runs `getAll()` (a full table scan + decode);
- `collection.watchAllDiff()` re-runs `getAll()` and diffs from scratch;
- `query.where(...).watch()` re-runs `findAll()` (a full backend scan).

With N live filtered queries, a single-row write therefore costs N full scans —
the per-write cost grows with the size of the watched collections. M8's goal is
to update only the result sets a batch can affect, without a full re-scan.

M7's change-metadata handoff already delivers, per committed batch, the changed
row keys plus batch metadata (`Change(table, key, kind, sequence)`). No Rust
query registry or persistent reactive state exists (ADR-0026), and M8 keeps
reactive lifecycle Dart-owned.

## Decision

1. **Incremental materialized result sets.** Each live watch maintains a cached
   materialized result and, on a coalesced batch, applies only the affected
   rows via point reads — never a full re-scan of the watched table.

   - `watchAll()` / `watchAllDiff()` keep a `SplayTreeMap<ByteKey, row>` cache
     ordered byte-wise (the documented order of `getAll()`).
   - `query.where(...).watch()` keeps a cache of matching rows; each changed key
     is point-read once per batch, re-tested against the filter, and
     added/updated/removed in the cache. Unsorted queries keep byte-key order
     (matching `findAll()`); sorted queries insert at the comparator position.
   - Limited/offset queries (windowed) keep full re-evaluation: a window can
     reorder arbitrarily under a write, so incremental maintenance is not
     well-defined for them. This is documented on the stream.

2. **One consistent read transaction per batch for incremental reads.** The
   affected keys are read together in ONE batched native call
   (`RawBackend.getMany`, added by this ADR): a single Rust read transaction
   covers all of a batch's keys (one MVCC view, one FRB boundary crossing).
   This preserves the coalesced single-event-per-batch contract while keeping
   the per-batch update cost at a single worker round trip (an explicit
   snapshot create/read/drop would cost three).

3. **Changed-value reads are point reads, not metadata blobs.** The public
   `Change` contract is unchanged (table/key/kind/sequence). Watchers re-encode
   the changed key and read the current row from the store; this keeps the wire
   handoff minimal and the API stable.

4. **Registration/lifecycle stays per-subscription.** Each `StreamController`
   registers on `onListen` and unregisters on `onCancel` (through the existing
   change-bus subscription). Identity is the watched (table, key), table, or
   query. No cross-watch deduplication in M8; each watch is self-contained.
   Backpressure (`ChangeBusOverflowError`, bounded delivery) is unchanged;
   replay is unchanged (resubscribe + current-state emission).

5. **Dart owns invalidation computation in M8.** Pure candidate computation
   may move to Rust only after the lifecycle contract is locked and measured;
   this ADR leaves that open as a later step.

## Consequences

- A single-row write against N live filtered queries costs N × (point reads for
  the changed keys) — independent of the watched collection size, satisfying
  M8's done-when criterion.
- `scannedRows` diagnostics no longer grow with watch-only updates, making the
  improvement observable and testable.
- Ordering parity with `getAll()` / unsorted `findAll()` is preserved exactly
  (byte-key order); sorted reactive queries insert at comparator position.
- Watch correctness now depends on the per-batch point reads being consistent;
  a single Rust read transaction covering the batch's keys provides that (all
  keys of one batch observe one committed state).
- The full-set `watchAll`/`watchAllDiff` emission is O(collection) by API
  contract (they deliver a complete list/diff snapshot); the incremental work
  is the bounded point-read batch, which is independent of collection size.
- Reactive streams remain Dart-owned; no Rust query registry is introduced.
