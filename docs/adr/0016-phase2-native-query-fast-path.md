# ADR-0016: Native query fast path over the durable index (Phase 2 step 1)

**Status:** Accepted (step 1 of Phase 2; steps 2–5 remain)
**Date:** 2026-08-09
**Builds on:** ADR-0008 (durable `__gecko_index`), ADR-0015 (Phase 1 instrumentation)

## Context

ADR-0015's query-path profile showed that an indexed equality query on 100k
rows spent **88% of its time in `backendRead` (33.5 ms)** performing 1000
per-id `snap.read` calls — one boundary crossing per candidate id. This is the
classic N+1: the durable `__gecko_index` table exists in Rust exactly to avoid
decoding rows that cannot match, but the Dart query path
(`QueryImpl._scanWith`) only used it to rebuild/validate an in-memory
`SecondaryIndex` at open time, then did N point reads through the snapshot to
fetch each matched row.

The Phase 1 boundary benchmark (ADR-0015) also showed the FRB boundary floor
is ~18–19 µs per call, so 1000 calls is ~18–33 ms of pure crossing overhead —
almost the entire `backendRead` cost.

## Decision

Add a Rust-side query operation that traverses the durable index and joins
back to the rows **in one FRB hop**, collapsing the N+1 into a single
boundary crossing.

### Rust

`RedbWorker::query_indexed(table, index_table, start, end)` and its
snapshot-bound variant `snapshot_query_indexed`:
- Range-scan the `__gecko_index` table for keys in `[start..=end]` (redb's
  native inclusive range over raw byte keys).
- Collect each index entry's **value** — which is the user-table row key
  (the durable index stores `encode(recordId)` as the value, identical bytes
  to the user-table row key).
- Read each matched row from the user table **in the same read transaction**,
  preserving index-key order (ascending by the indexed value).
- Return `Vec<(recordId, row)>` in one hop. A missing user-table row (index
  drift) is silently skipped — the durable index is maintained atomically
  with the data, so this is a defensive fallback, not a normal path.

Exposed via FRB as `NativeWorker.queryIndexed` / `snapshotQueryIndexed`.

### Bounds

The durable index key is `encode([table, field, value, recordId])` — a
`DefaultWireCodec` 4-element list encoded as
`0x06 | u32(4) | table | field | value | recordId`. Every key for a fixed
`(table, field, value)` triple shares the byte prefix
`0x06 00 00 00 04 | table | field | value`, so an equality lookup is a
contiguous lexicographic range. `eqBounds(table, field, value)` (in
`lib/src/query/durable_index_bounds.dart`) computes the inclusive
`[start, end]` bounds by encoding `[table, field, value, null]` (null = 0x00
tag, the smallest 4th element), stripping the trailing null byte to form the
lower bound, and incrementing the last byte (with carry on 0xFF) for the
upper bound. Rust never needs to understand the value codec — Dart constructs
the bounds.

### Dart wiring

- `NativeWorkerClient.queryIndexed` / `snapshotQueryIndexed` +
  `dispatchNativeWorker` cases + the web client stubs (web parity, validated
  by browser smoke).
- `NativeRawBackend.queryIndexed` (non-snapshot, opens its own read txn) and
  `NativeRawSnapshot.queryIndexed` (snapshot-consistent). The
  `_NativeSnapshot` class is now public as `NativeRawSnapshot` so the query
  engine can detect the capability via `snap is NativeRawSnapshot`.
- `QueryImpl._scanWith`: when the snapshot is a `NativeRawSnapshot` AND the
  query is a single equality filter covered by the index, build the eq bounds
  and call `snap.queryIndexed` instead of the per-id point-read loop.
  Multi-eq, range, and prefix filters fall back to the existing Dart per-id
  path (step 5 extends the fast path to them).

### Scope (step 1 only)

This ADR covers the **indexed equality** fast path. Step 2 (push the
predicate to Rust for unindexed full scans) requires a Rust port of
`DefaultWireCodec` + the predicate evaluator and is deferred. Steps 5–6
extend the indexed fast path to range/prefix/multi-eq filters.

## Measured results (reference Windows dev machine)

| Workload | Phase 1 | Phase 2 step 1 | Improvement |
|---|---|---|---|
| Indexed eq, 1k rows (10 matched) | 1.6 ms | ~1.7 ms | parity (already fast) |
| Indexed eq, 100k rows (1000 matched) | 38.2 ms | **12.1 ms** | **3.2×** |
| `backendRead` (100k indexed) | 33.5 ms | **4.6 ms** | **7.4×** (N+1 eliminated) |

Full-scan per-row cost is unchanged (step 2 not done): ~4.6–7 µs/row on 100k
rows, dominated by the single `scanAll` boundary crossing that transfers all
rows.

## Targets (from the plan)

- Indexed query on 1,000 rows < 1 ms — **~1.7 ms** (close; floor is the FRB
  boundary crossing `isolateRoundTrip ~53 µs` + `queryIndexed` hop). Hitting
  <1 ms would require removing the worker isolate (Phase 6 decision) or a
  sub-millisecond FRB fast path; deferred.
- Highly selective indexed query on 100k rows < 5 ms — **12 ms for 1000
  matched (1% selective)**; a truly highly-selective query (≈10 matches) is
  well under 5 ms. The 1000-match case spends ~5 ms in `backendRead` (the
  join over 1000 rows) + ~1.5 ms in Dart decode/predicate.
- Full-scan per-row cost reduced ≥ 10× — **not yet** (step 2).

## Consequences

- Indexed equality queries on the native backend no longer pay the N+1; the
  dominant cost is now the single `queryIndexed` hop + Dart decode of only
  the matched rows. Decode/predicate are now a visible share (was drowned by
  backendRead) — Phase 3's field-level decode will address them.
- Public API additions: `NativeRawSnapshot` (was `_NativeSnapshot`), the
  `queryIndexed` methods on `NativeRawBackend` / `NativeRawSnapshot`, and the
  `eqBounds` helper. The API snapshot gains `NativeRawSnapshot`; the method
  additions don't churn the snapshot (it tracks `show:` names, not members).
- The in-memory backend is unchanged (no durable index, no Rust); it keeps
  the Dart per-id path. Plans agree across backends (parity test).
- Web parity: the web client + worker dispatch carry the new ops; live
  validated by the browser smoke suite (not the VM test runner).
- The bundled Windows DLL was rebuilt + re-bundled (`tool/build_artifacts.dart
  build windows-x64` + `bundle`); android/web bundled artifacts are stale on
  this host (CI rebuilds them).
