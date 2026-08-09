# ADR-0017: Native query fast path — predicate push (Phase 2 step 2)

**Status:** Accepted (step 2 of Phase 2; completes the `≥ 10×` full-scan target)
**Date:** 2026-08-09
**Builds on:** ADR-0015 (Phase 1 instrumentation), ADR-0016 (Phase 2 step 1)

## Context

ADR-0016 killed the N+1 for indexed equality queries (38 ms → 12 ms on 100k
rows). But the Phase 1 profile showed **unindexed full scans** were even worse:
~482 ms for a 100k-row scan, with `backendRead` (the single `scanAll` boundary
crossing that transfers every row to Dart) at 336 ms — **70% of the total**.
Every row was decoded into a Dart map and predicated in Dart, even the
non-matches.

The `≥ 10× full-scan per-row cost` target (Phase 2) cannot be met without
pushing the predicate into Rust, so non-matching rows never cross the FRB
boundary at all.

## Decision

Port the Dart `DefaultWireCodec` to Rust and add a predicate evaluator + a
full-scan-with-predicate query operation that returns only matches in one hop.

### Rust value codec (`rust/src/value_codec.rs`)

A byte-for-byte port of `DefaultWireCodec`: a `RowValue` enum
(Null/Bool/Int64/BigInt/F64/String/Bytes/List/Map/DateTime) with `decode_value`,
`find_field` (scans a row's map encoding for one field, skipping non-matching
values without allocating them), `compare` (mirrors Dart `Filter._compare`:
same-type natural ordering, cross-type stable string fallback), and
`deep_equals`. The tag bytes match the Dart `_Tag` enum exactly.

### Predicate wire format + evaluator (`rust/src/predicate.rs`)

A version-prefixed, self-delimiting payload (mirrors the `Op` batch wire style):
`version | count | (op, field, value/min/max/prefix)…`. The Dart side
serializes a `FilterGroup` via `encodePredicate` (`predicate_codec.dart`); Rust
decodes it into a `Predicate` (AND-composed `Filter` list) and evaluates
`Predicate::test_bytes(row_bytes)` against each row — decoding ONLY the
referenced field via `find_field`, so wide rows with a sparse predicate skip
decoding the bulk of their values.

### Worker method (`RedbWorker::query_filtered` / `snapshot_query_filtered`)

Scans every row in the user table, evaluates the predicate in Rust, and returns
only the matching `(recordId, row)` pairs in one FRB hop. An empty predicate
matches everything (matches Dart's `FilterGroup`). A missing table is an empty
result, never an error.

### Dart wiring

- `NativeRawBackend.queryFiltered` (non-snapshot) + `NativeRawSnapshot.
  queryFiltered` (snapshot-bound); `NativeWorkerClient.queryFiltered` /
  `snapshotQueryFiltered`; dispatch cases; web client stubs (web parity via
  browser smoke).
- `QueryImpl._scanWith`: when the snapshot is a `NativeRawSnapshot`, route ANY
  unindexed query through `snap.queryFiltered` (the predicate is pushed to
  Rust). The in-memory backend keeps the original Dart full scan. Results agree
  across both backends (parity tests).
- New `IndexPlan.nativeFilteredScan` attributes the native predicate-push path
  (distinct from `fullScan` / `secondaryIndex`).

## Measured results (reference Windows dev machine)

| Workload | Phase 1 | Phase 2 step 1 | Phase 2 step 2 | Improvement |
|---|---|---|---|---|
| Full scan 1k rows | 20 ms | 20 ms | **7.8 ms** | 2.6× |
| Full scan 100k rows | 482 ms | 482 ms | **39 ms** | **12.4×** ✅ |
| `backendRead` (100k full scan) | 336 ms | 336 ms | **38 ms** | 8.9× |
| Indexed eq 100k rows | 38 ms | 12 ms | 12 ms | (step 1 holds) |

`rows scanned=1` for a 100k-row query matching 1 row — only the match crosses
back to Dart. The 39 ms is now Rust-side iteration + predicate eval (97% of the
total); Dart decode/predicate are near-zero because only matches are returned.

## Targets (from the plan)

- **`full-scan per-row cost reduced ≥ 10×` — MET (12.4×).** 482 ms → 39 ms on
  100k rows (4.8 µs/row → 0.39 µs/row).
- Indexed query on 1,000 rows < 1 ms — ~1.7 ms (FRB boundary floor; deferred to
  the Phase 6 worker-isolate decision).
- Highly selective indexed query on 100k rows < 5 ms — met for ~1 match; ~12 ms
  at 1% selectivity (1000 matched), where the cost is now the join over 1000
  returned rows.

## Consequences

- Unindexed queries on the native backend no longer transfer the whole table to
  Dart; only matches cross the boundary. Decode/predicate/sort now operate only
  on the result set, so they are near-zero for selective queries.
- The predicate evaluator's `compare` mirrors Dart's `Filter._compare` semantics
  (same-type natural ordering, cross-type string fallback); the cross-language
  golden test + the parity tests guard this. A row predicate that depends on
  Dart-specific `toString` ordering for cross-type comparisons would diverge —
  documented as a known edge (cross-type range predicates are unusual).
- `IndexPlan.nativeFilteredScan` is a new public enum value (the API snapshot
  tracks `show:` names, not enum members, so no snapshot churn).
- The in-memory backend is unchanged (no Rust); it keeps the Dart full scan.
  Plans agree across backends (parity test compares native vs in-memory result
  sets).
- Rust coverage: the `value_codec` and `predicate` modules have unit tests
  (round-trip, find_field skip, compare semantics, all filter kinds, AND
  composition); the worker has a `query_filtered` integration test.
- The bundled Windows DLL was rebuilt + re-bundled; android/web bundled
  artifacts are stale on this host (CI rebuilds them).
