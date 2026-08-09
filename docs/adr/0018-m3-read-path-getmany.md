# ADR-0018: M3 read-path completion — getMany + aggregate pushdown

**Status:** Accepted
**Date:** 2026-08-09
**Builds on:** ADR-0015 (Phase 1 instrumentation), ADR-0016 (Phase 2 step 1
indexed fast path), ADR-0017 (Phase 2 step 2 predicate push)

## Context

After ADR-0016/0017, only `findAll()` routed through the native fast path
(`query_indexed` for indexed-eq, `query_filtered` for unindexed predicate
push). Three silent gaps remained:

1. **Bypassed read paths.** `iterate()` (and, via `_streamUnsorted`, the
   candidate-id per-key loop) still did a Dart scan + `_group.test` on native,
   missing the M2 predicate-push win entirely — a correctness-parity and perf
   gap. `count()` / `distinct()` materialized every matching row in Dart
   before aggregating, paying full decode + transfer for an answer that needs
   none of the row payload.
2. **Relationship N+1.** `RelationshipManager._childRowsFrom` did one
   `snap.read` per child id (the exact pattern ADR-0016 killed for indexed
   queries, but still present in eager-loading).
3. **No batched point-read.** There was no way to fetch N keys in one Rust
   call — the building block M4–M7 need for batched reads.

Additionally the plan listed **projection** (field-selective decode) as an M3
step. It is **not** in M3's done-when, and it requires a new public `select`
surface on `Query` whose output type differs from `T` — a design decision that
deserves its own deliberation. It is therefore **deferred** here (see
Consequences).

## Decision

### 1. Route every read path through the native fast path

`QueryImpl.iterate()` now delegates to `_scan()` (which opens a snapshot and
routes through `_scanWith`), so indexed-eq uses `query_indexed` and unindexed
queries use `query_filtered` on native. The old `_streamUnsorted` (per-id
`snap.read` loop + Dart `_group.test`) is deleted. `first()` / `findPage()` /
`cursor()` already went through `_scanWith` and are unchanged.

### 2. Aggregate pushdown in Rust

Two new `RedbWorker` operations evaluate the predicate **in Rust** and never
transfer matching rows:

- `query_filtered_count` / `snapshot_query_filtered_count` → returns only a
  `u64` count (stream-scan + `test_bytes`, no row materialization).
- `query_filtered_distinct` / `snapshot_query_filtered_distinct` → for each
  matching row, emits only the **encoded bytes of one field** (via the new
  `value_codec::find_field_range`, which returns the `(start, end)` byte range
  of a field's value so we slice instead of decode). Rows missing the field
  are omitted (a missing field is not a distinct value — matches Dart
  `distinct()`). The Rust side does **not** dedup; the Dart caller decodes the
  self-delimiting value bytes and dedups with a `Set`, exactly like the old
  path.

`QueryImpl.count()` / `QueryImpl.distinct()` use these on native for queries
with no index-usable equality probe (`_nativeEqProbe == null`), and keep the
existing `_scanWith` path otherwise (indexed-eq results are already small and
joined in one hop). The in-memory backend keeps its Dart loops (it has no
Rust).

### 3. `getMany` — public batched point-read

- **Rust:** `RedbWorker::get_many` / `snapshot_get_many` fetch N keys in ONE
  read transaction, returning `(key, value)` pairs for keys that exist (absent
  keys omitted; missing table → empty, never an error).
- **Raw layer:** `RawSnapshot.getMany(table, keys)` is added to the interface
  with a per-key default; `NativeRawSnapshot` overrides it with the single
  native hop; `_MemSnapshot` / `_EncryptedSnapshot` use the default.
- **Public API:** `Collection.getMany(List<Object?> ids)` returns rows in input
  order, skipping absent ids. Inside a transaction it observes the staged
  overlay (per-key `readRaw`; transactions are the rare path and must see
  uncommitted writes). Outside, the native backend does one `get_many` call;
  in-memory uses the per-key fallback.
- **Relationships:** `RelationshipManager._childRowsFrom` (indexed FK path)
  now batches the candidate ids through `snap.getMany` — one boundary crossing
  instead of one per child. The FK re-check is retained because the in-memory
  index may be stale relative to the snapshot in edge cases.

### 4. Wire plumbing

All new operations are FRB-exposed (`api.rs`), generated into
`NativeWorker`, dispatched via `native_dispatch.dart` (isolate + web worker
share the dispatch, so web parity rides the same path), and wrapped on
`NativeRawBackend` / `NativeRawSnapshot` + `NativeWorkerClient`.

## Consequences

**Easier:**
- Every native read path now uses the Rust fast path — no silent Dart-scan
  fallback on native (parity risk closed).
- `count()` on a 100k-row unindexed query transfers zero rows instead of all
  of them; `distinct(field)` transfers one value per row instead of whole rows.
- `getMany` kills the relationship N+1 and gives M4/M7 the batched-read
  primitive they build on.

**Riskier / tracked:**
- **Projection (M3 step 4) is deferred.** The M3 done-when (public+tested
  `getMany`, read paths on the native path, relationship loads via `getMany`,
  parity tests) does not include it, and it needs a public `select(fields)` on
  `Query` whose output is a projected row (not `T`) — a public API design
  decision. It can be picked up with M4 (which already touches the query
  payload for sort/limit). No wire-format change is implied either way (the
  projection spec would be a new FRB argument, not a persisted format).
- The distinct pushdown transfers value bytes per matching row (undeduped) so
  a 100k-row distinct still moves 100k small values; a future Rust-side
  dedup/hash-set could reduce that further if profiling shows it hot.

**Coverage note:** the aggregate pushdown branches are exercised by
`m3_read_path_test.dart` on both backends; the `find_field_range` + Rust
aggregate tests live in `rust/src/worker.rs` / `value_codec.rs`.

## Verification

- `packages/gecko_db/test/m3_read_path_test.dart` — 14 tests × (in-memory +
  native): `iterate` parity + plan, `count`/`distinct` parity + native
  aggregate plan, `first`/`findPage`, `getMany` (order, absent, empty, txn
  overlay), relationship children via the batched path (no full-scan).
- Full suite: 508 tests green (494 → 508). Rust: 49 unit tests green.
