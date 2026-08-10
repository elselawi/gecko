---
status: accepted
date: 2026-08-10
deciders: maintainer
---

# ADR-0020: M5 indexed range, prefix, and multi-equality intersection

**Builds on:** ADR-0016 (native indexed equality fast path), ADR-0017 (native
predicate push), ADR-0019 (indexed sorting and early LIMIT)

## Context

The in-memory secondary index already supported range, prefix, and compound
equality filters, but native queries for those filters still used a full-table
Rust predicate scan. M5 requires the durable index to narrow those queries and
preserve the existing Dart semantics.

The v1 `DefaultWireCodec` is a storage-stable value codec, not a semantic
order-preserving key codec for every supported value: signed integers,
doubles, and length-prefixed strings do not all sort lexicographically in
Dart's comparison order. Prefix bytes are also not necessarily a byte prefix
of the encoded full string. Consequently, naive `rangeBounds` or
`prefixBounds` based on encoded minimum/maximum values would create false
negatives.

## Decision

### 1. Use broad field bounds as candidate generators

For each covered filter, Dart constructs one durable-index range:

- equality: exact `eqBounds(table, field, value)`;
- range: broad `fieldBounds(table, field)`;
- prefix: broad `fieldBounds(table, field)`.

`fieldBounds` covers every durable index entry for one `(table, field)` pair,
while excluding other tables and fields. It is deliberately not presented as
a semantic value-order range.

### 2. Intersect candidates in Rust

The new snapshot-bound FRB operation
`query_indexed_multi(table, indexTable, ranges, predicateBytes)`:

1. decodes the predicate once;
2. scans every requested durable-index range;
3. collects row keys into deterministic ordered sets;
4. intersects all candidate sets;
5. joins candidates to user rows in the same read transaction; and
6. re-evaluates the complete predicate in Rust before returning a row.

The predicate recheck is mandatory. It handles broad range/prefix bounds,
additional unindexed filters, stale index entries, missing fields, and all
Dart comparison semantics. The result is ordered by encoded record key for
determinism. Empty intersections return immediately; a missing index table is
an empty result.

### 3. Query routing

`QueryImpl._nativeIndexedRanges` selects the multi-index route when at least
one filter is covered by the collection's secondary index metadata. Native
single equality retains the existing exact `queryIndexed` fast path. Native
range, prefix, multi-equality, and mixed covered filters use
`queryIndexedMulti` and retain `IndexPlan.secondaryIndex`, even though Rust
performs the final predicate decision. Uncovered filters continue to use
`nativeFilteredScan` on native or `fullScan` in memory.

`count()` and `distinct()` use the indexed row route when covered candidates
exist, preserving M5 plan observability and avoiding a native full-table
aggregate scan. M4 sorted/limited routing remains separate: sort ordering is
still handled by the M4 index-ordered/top-K operations.

## Consequences

- Covered native range, prefix, multi-equality, and mixed filters avoid a
  full-table scan and a Dart per-id/N+1 loop.
- Candidate scans may read more index entries than the semantic result because
  range and prefix bounds are broad; Rust predicate evaluation guarantees
  correctness.
- The v1 storage format remains unchanged. A future order-preserving index-key
  format could narrow range/prefix candidate bounds, but would require a
  separate wire-format decision.
- Complex value equality remains subject to the existing byte-stable durable
  index encoding contract; Rust predicate rechecking prevents false positives,
  while the exact equality bound can still be conservative for alternate
  encodings. No new public API is introduced.
- M5 does not add early termination for general multi-index intersections:
  candidate sets must be complete before intersection. M4's ordered/limited
  routes remain the only safe early-stop paths.

## Validation

- Native/in-memory parity tests cover inclusive and open ranges, prefix
  matching, multi-equality, range + prefix + equality intersection, aggregates,
  and backend plan selection.
- Rust unit coverage includes deterministic multi-range intersection and full
  predicate rechecking.
- Full package tests, tool gates, Rust tests/clippy/fmt, traceability,
  security review, offline lint, and 95% line / 100% branch coverage pass.
