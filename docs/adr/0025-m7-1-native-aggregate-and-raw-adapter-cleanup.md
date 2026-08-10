---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0025: M7.1 native aggregate and raw-adapter cleanup

## Context

M3 already pushed unindexed native `count()` and `distinct()` into Rust, but
indexed aggregate queries still routed through row-returning indexed queries.
That caused Dart to receive and decode every matching primary row solely to
count it or extract one distinct field. Native query planning also consulted
the transitional Dart secondary index even though Rust durable indexes were the
native authority after M7.

## Decision

- Add snapshot-bound Rust indexed aggregate operations that intersect durable
  index candidate ranges and recheck the complete predicate in Rust.
- `count()` returns only a scalar count for indexed native routes.
- `distinct(field)` returns only encoded field-value slices; Dart retains the
  final decode and insertion-order dedup contract.
- Native query routing skips Dart candidate-id lookup while preserving the
  existing `IndexPlan.secondaryIndex` and timing semantics.
- The in-memory backend continues to use the Dart reference index and materialized
  aggregate behavior until M7.5.
- Native delete-range pre-scans and `lastCommitSeq()` must dispose temporary
  snapshots in `finally` blocks.
- Existing inclusive/exclusive raw scan behavior and tuple conversion at the
  Dart raw-backend boundary are retained because they preserve current public
  contracts and protocol boundaries.

## Consequences

- Indexed native aggregates no longer transfer matching primary rows to Dart.
- M5 multi-range intersection and predicate semantics remain Rust-owned and
  snapshot-consistent.
- Distinct decoding/dedup remains Dart-owned because it preserves the current
  public insertion-order result behavior.
- No persistent Rust query registry or public API change was introduced.
- The separate reusable Web worker client remains a limited protocol client;
  normal `DatabaseImpl` Web/Wasm routing uses the shared native dispatch path.

## Validation

- Focused M3 aggregate, native snapshot, durable-index, and raw-backend tests:
  73 passed.
- Full Dart package suite was run during implementation after rebuilding the
  native artifact; one diagnostic timing assertion required preserving the
  existing index-lookup timer placement.
- Dart analyze passed.
- Rust tests: 55 passed.
- Rust clippy with warnings denied passed.
