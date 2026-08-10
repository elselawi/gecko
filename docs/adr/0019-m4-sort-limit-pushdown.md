---
status: accepted
date: 2026-08-09
deciders: maintainer
---

# ADR-0019: M4 indexed sorting and early LIMIT pushdown

**Builds on:** ADR-0016 (Phase 2 step 1 indexed fast path), ADR-0017 (Phase 2
step 2 predicate push), ADR-0018 (M3 read-path completion)

## Context

Before M4, sorted queries ran entirely in Dart: `_collectOrdered` materialized
the full candidate set (streamed from Rust for filtered/indexed queries),
sliced it, and then Dart called `compareRows` + `decoded.sort`. `ORDER BY`
always paid a full materialization + transfer of every matching row, and
`LIMIT 20` was applied *after* the sort — the "no materialization, no sort"
goal of the milestone was unmet. The durable index's composite keys
(`[table, field, value, recordId]`) are already byte-ordered by value, so an
index-covered sort can be streamed in order with no sort work at all. This ADR
records the sort/limit pushdown to Rust, the top-K heap for non-indexed sorts,
and the tie-break contract that keeps every path deterministic.

## Decision

### 1. Four new windowed Rust operations

The M2/M3 ops (`query_filtered`, `query_indexed`, …) gained windowed
counterparts that take `limit: Option<u64>` and `offset: u64` and **stop early**
instead of materializing the full result:

- `query_filtered_limited` / `snapshot_query_filtered_limited` — scan +
  predicate test, collect rows in `[offset, offset+limit)`, early-stop.
- `query_indexed_limited` / `snapshot_query_indexed_limited` — stream the
  durable index within an `eqBounds` window, join to rows, predicate-test,
  early-stop.
- `query_sorted` / `snapshot_query_sorted` — full scan but **top-K heap**:
  `TopK<SortCandidate>` bounded to `offset + limit`. For each row only the
  sort fields are extracted (via `value_codec::find_field` — no full decode),
  compared with `sort_compare` (a port of Dart's `compareFieldValues`:
  numerics compare numerically regardless of type, then string/bool/DateTime
  natural order, then the null/`toString` fallback), and the heap keeps the
  K smallest/largest.
- `query_indexed_ordered` / `snapshot_query_indexed_ordered` — for an
  **index-covered sort with an equality filter on the sort field**, stream the
  `eqBounds` window in index order (all rows already tie on the sort value, so
  both ascending and descending are index-ordered). For a plain ascending
  index-covered sort it streams the whole `fieldBounds` window; if the window
  is not exhausted but rows that **lack** the sort field must appear last (or
  first when descending), a follow-up table scan appends the missing-field
  rows. If the index table is missing entirely, it falls back to
  `query_sorted`.

All windowed ops return `Vec::new()` for `limit == Some(0)`.

### 2. Sort-spec wire format

New module `rust/src/sort_spec.rs` with `SORT_SPEC_WIRE_VERSION = 1`:

```
version:u8(=1) | count:uvarint | per spec: field:string(uvarint len + utf8), descending:u8(0/1)
```

`encode_sort_specs` (Dart `sort_spec_codec.dart`) and `decode_sort_specs`
(Rust) are exact mirrors; the Rust side is also used by the worker fallback
and unit tests.

### 3. Routing rules in `QueryImpl`

`_collectOrdered` first tries `_nativeOrderedCollect` (native only): it opens a
snapshot, encodes predicate + sort specs, and routes via `_indexCoveredSortRoute`:

- exactly **one** sort spec **and** the sort field is indexed → `query_indexed_ordered`:
  - equality filter on the sort field → `eqBounds`, `eqBounded = true` (both
    directions index-ordered because all values are equal);
  - else **ascending only** → `fieldBounds`, `eqBounded = false` (descending
    without an eq filter would need to walk the index backwards — not done in
    M4; it falls through to top-K);
- otherwise → `query_sorted` (top-K).

When the native ordered collect returns, Dart does **no** sort and **no**
slicing. In-memory keeps the existing materialize-then-slice path (parity).

### 4. Deterministic tie-break: recordId

Probing showed Dart's `List.sort` (dual-pivot quicksort) is **not stable**:
rows with equal sort keys came back in arbitrary order (`r30,r20,r10,r0`),
while the durable index yields `(value, recordId)` order (`r0,r10,r20,r30`).
To make every path agree — native index-ordered, Rust top-K, and in-memory
Dart sort — ties are broken by the raw record key bytes:

- Rust top-K: `compare_rows_from_keys(...).then_with(|| a.key.cmp(&b.key))`;
- Dart: `_compareDecoded = compareRows(a,b) → tiebreak a.key.compareTo(b.key)`,
  used at every `decoded.sort` call site.

This makes all three paths produce byte-identical row order for equal sort
keys, so parity tests can assert exact sequences.

## Consequences

- **M4 done-when met.** On a 100k-row native store: indexed `ORDER BY nick
  LIMIT 20` measured **110–209 µs** (target < 5 ms), early `LIMIT 20` **129–191
  µs**, and non-indexed top-K `ORDER BY age LIMIT 20` ~28 ms (full scan is
  required, but Dart never materializes more than the heap's `offset+limit`).
- **No full materialization on native.** Sorted/limited queries transfer only
  the requested window (plus the top-K heap in Rust for non-indexed sorts).
  The `_collectOrdered` materialize-then-slice path remains for in-memory
  parity only.
- **Deterministic ordering is now a contract.** Record-key tie-break means a
  query's row order for equal sort keys is stable across backends and runs;
  this is stricter than before (arbitrary quicksort order) and is asserted by
  the M4 parity tests. No existing test relied on the old arbitrary order
  (existing suites use distinct sort values or insertion order, and
  `compareRows` semantics are unchanged).
- **Descending index-covered sort without an eq filter is not optimized in
  M4** — it uses top-K. Reverse-walking the durable index is a possible M5/M6
  follow-up if a profile shows it hot.
- **In-memory last-plan for sort-only indexed queries is `fullScan`.** The
  in-memory index serves filters, not sorts; `_nativeOrderedCollect` is the
  only sort-aware path. Tests assert plans per backend.
- **New internal surface only.** `encodeSortSpecs`/`fieldBounds` and the Rust
  ops are internal; the public API is unchanged. No `api_snapshot.txt` change.
