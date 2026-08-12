# Changelog

All notable changes to gecko_db are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning follows
[README.md](README.md).

## Unreleased

### Added

- **Composite durable indexes** (`collection(compositeIndexes: ...)`): declare
  multi-field indexes whose keys use the order-preserving prefix-then-values
  layout. Queries with an equality prefix plus an optional range/prefix on the
  trailing field are served as ONE ordered index scan instead of N
  single-field ranges plus Rust candidate intersection. Composite keys are
  maintained atomically with the rows and rebuilt by the one-time per-session
  repair.

### Changed

- **Diff-first watch delivery**: `watchAllDiff()` now computes its deltas from
  the committed post-batch values in the engine and emits an incremental
  `CollectionDiff` (added/updated/removed) without building a full-table
  snapshot per emission; the incremental `snapshot` is reconstructed on the
  Dart side in byte-key order.
- **Bounded negative read cache**: repeated reads of missing keys no longer
  cross the worker boundary, and writes invalidate only the keys they touch
  instead of clearing the whole read cache.
- **Per-subscriber watch backpressure**: a paused subscriber that falls too
  far behind drops its whole pending window and receives a single
  `ChangeBusOverflowError` carrying the event sequence, rather than silently
  dropping individual events.
- **Covered-filter skip**: when every predicate filter's field is in the
  durable index's declared fields, the exact eq/range/prefix bounds prove the
  whole predicate and Rust skips the per-row recheck (counted via
  `predicateEvaluations = 0`).
- **Index-ordered descending sorts**: DESC without an equality bound now
  streams the durable index in reverse (missing-field rows first) instead of
  running the full-scan top-K path; ties still break by ascending record key.
- **Native limit/offset pushdown**: single-range indexed queries route through
  the early-stopping index scan, so a small window visits only the rows it
  needs rather than materializing the whole candidate span.
- **Smaller-first streaming candidate intersection** with deterministic
  record-key output and a planner fallback to a full filtered scan when the
  index cannot narrow the candidate set.
