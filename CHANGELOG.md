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
