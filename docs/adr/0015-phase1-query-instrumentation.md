# ADR-0015: Per-stage query instrumentation (Phase 1)

**Status:** Accepted
**Date:** 2026-08-09
**Supersedes/Grows:** ADR-0010 (compaction/maintenance/diagnostics — adds a
per-stage breakdown to the existing slow-query record)

## Context

Phase 0–13 shipped a complete engine, but the read/query path was never
profiled end-to-end. The Phase 13 baseline (`benchmark/baseline.json`)
reported headline numbers (unindexed full scan ≈ 110 µs/row, indexed eq ≈
1 ms on 1k rows) without saying *where* that time goes. The Phase 1
appendix (the current roadmap) makes measurement a hard prerequisite: "know
where time goes before changing anything", and asks for (a) a layer-by-layer
boundary benchmark and (b) per-stage timers in the query path, before any
optimization in Phase 2.

The query path (`lib/src/query/query_impl.dart`) runs entirely in Dart:
every scanned row is decoded into a Dart map, copied again, and predicated
in Dart. The boundary crossings (caller isolate → worker isolate → FRB →
Rust → redb) are invisible from a Dart-side `Stopwatch` wrapped around
`findAll()`, so a per-stage breakdown is the only way to attribute cost to
the planner, the index lookup, the backend read, the decode, the map copy,
the predicate, the model conversion, or the sort.

## Decision

1. **Boundary micro-benchmark** (`benchmark/boundary.dart`) measures eight
   layers in order — `dartCall`, `isolateRoundTrip`, `frbCall`, `rustNoop`,
   `redbGetMiss`, `redbGetHit`, `rawGetCold`, `rawGetHot` — on the native
   file backend, with a direct `NativeWorker` (FRB-only, no worker isolate)
   opened against a read-only copy so the FRB seam can be measured in
   isolation. Output is a table and `--json`; it is **not** consumed by
   `tool/perf_gate.dart` (it is a breakdown, not a regression gate —
   `benchmark/bench.dart` remains the regression gate).

2. **Per-stage query timers** are added to the existing opt-in diagnostics
   surface: a new public `QueryStageTimings` (8 stage fields in µs +
   `rowsScanned`/`rowsMatched` counts) is carried on `SlowQueryRecord.timings`
   and populated only when `DatabaseConfig.slowQueryThresholdMicros > 0`.
   The stages are exactly the 8 named in the Phase 1 appendix:
   `plan → indexLookup → backendRead → decode → mapCopy → predicate →
   model → sort`. Stages that do not run (e.g. `sort` on an unsorted query,
   `indexLookup` when no index is defined) are 0 and pay no timing
   overhead; the whole accumulator is `null` when timing is disabled, so
   the disabled path is unchanged from Phase 0.

3. **Query-path profiler** (`benchmark/query_profile.dart`) seeds 1k and
   100k rows on a native DB and prints the per-stage split for an unindexed
   full-scan query and an indexed equality query, so the split is recorded
   against the headline bench numbers.

4. **`NativeRawBackend.commitSequenceProbe()`** is a public perf
   instrumentation accessor that runs a worker-isolate round trip with
   trivial Rust work (returns the commit LSN), isolating the isolate/port +
   FRB marshalling cost. It is consistent with the existing `workerAlive` /
   `workerIsolateName` / `storageStats()` diagnostics surface. The public
   API snapshot's `show:` list gains `QueryStageTimings`; the accessor adds
   a method to an already-exported class (the snapshot tracks only
   `show:` names, not members, so no snapshot churn beyond the new type).

## Measured results (reference Windows dev machine)

### Boundary (`benchmark/boundary.dart`)

| stage | per-op | meaning |
|---|---|---|
| dartCall | ~1 µs | event-loop + Future floor |
| rustNoop | ~19 µs | FRB floor (Rust counter read) |
| redbGetHit | ~18 µs | redb point get ≈ noise floor of FRB |
| frbCall | ~26 µs | FRB + Rust string build (handshake) |
| isolateRoundTrip | ~53 µs | +28 µs isolate/port marshalling over FRB-only |
| rawGetCold | ~99 µs | cold: opens a fresh MVCC snapshot per call |
| rawGetHot | ~0.6 µs | LRU cache hit |

**Finding:** the FRB boundary floor (~18–19 µs) dwarfs redb's own get (~0.4 µs
delta), and `rawGetCold` opens a per-call MVCC snapshot — the dominant
per-row cost in a full scan when misses are frequent.

### Query split (`benchmark/query_profile.dart`)

**Unindexed full scan, 1k rows** (total ≈ 20 ms): `backendRead` 13%,
`decode` 28%, `mapCopy` 6%, `predicate` 11%, `plan`/`indexLookup` 2% each,
`sort` 0 (unsorted), `model` 1.4%. Σ stages 64% of total.

**Unindexed full scan, 100k rows** (total ≈ 482 ms, ~4.8 µs/row — far below
the Phase 13 "110 µs/row" headline, which measured a heavier workload):
`backendRead` **70%** (336 ms — dominated by the single `scanAll` boundary
crossing that transfers all rows), `decode` **10%** (49 ms), `predicate` 1.5%,
`mapCopy` 0.8%, `sort`/`model` trivial.

**Indexed equality, 100k rows / 1000 matched** (total ≈ 38 ms):
`backendRead` **88%** (33.5 ms — 1000 per-id `snap.read` calls, each a
boundary crossing → the **N+1 problem**), `decode` 0.9%, everything else
trivial.

**Conclusion for Phase 2:** the cost is overwhelmingly in boundary crossings
(`backendRead`), not in Dart decode/predicate. Phase 2's "push the predicate
to Rust and traverse the durable `__gecko_index` in one FRB hop" attacks
both the full-scan `scanAll` transfer cost *and* the indexed N+1 reads.
Decode is the only Dart-side cost worth caring about, and only for full
scans; Phase 3's field-level decode will address it.

## Consequences

- The `slowQueryThresholdMicros` knob now carries a per-stage breakdown by
  default — no new opt-in beyond the existing Workstream-5 one. The
  disabled path is unchanged (zero overhead, confirmed by the existing
  "slow-query logging is off by default" test).
- `QueryStageTimings` is a new public type; the API snapshot and CHANGELOG
  record it. It is additive and does not alter any existing contract.
- Phase 2's targets (`indexed eq on 100k rows < 5 ms`, `full-scan per-row
  cost reduced ≥ 10×`) are now measurable directly against these numbers;
  the boundary benchmark and profiler are re-run before/after Phase 2.
- `benchmark/boundary.dart` and `benchmark/query_profile.dart` are advisory
  (not regression gates); `benchmark/baseline.json` + `tool/perf_gate.dart`
  remain the production regression gate. In-memory sub-µs workloads
  (`hotRead`, `coldRead`) are noisy on Windows — the strict gate is local,
  CI uses `--tolerance`.
