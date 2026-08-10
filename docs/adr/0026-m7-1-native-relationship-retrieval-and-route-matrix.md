---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0026: M7.1 native relationship retrieval and route matrix

## Context

M7 moved indexed and unindexed child filtering to Rust, but `parent()`,
`loadAllChildren()`, and many-to-many ID reads still performed Dart-side point
reads or full scans. M7.1 also requires an explicit native/Web/in-memory route
matrix before the thin-client deletion pass.

## Decision

- Native relationship reads use worker-owned snapshot primitives:
  - parent reads extract the child FK from encoded bytes in Rust and perform the
    parent point read in the same snapshot;
  - eager child reads use the union of durable FK index ranges when indexed, or
    Rust-side FK matching over the child table when unindexed;
  - many-to-many ID reads scan and filter encoded join rows in Rust.
- Dart retains relationship declarations, accessors, model mapping, delete
  policies, application-controlled callbacks, change-feed events, and reactive
  stream lifecycle.
- In-memory relationship reads retain the existing Dart reference routes.
- The route matrix records snapshot boundary, backend hops, transferred rows,
  diagnostics, typed-error behavior, and only the changed-row/indexed-field/
  batch metadata intended for M8. No Rust query registry or persistent reactive
  query state is introduced.

## Consequences

- Native parent and eager-child reads avoid repeated Dart backend hops and
  avoid full Dart child-table materialization where Rust primitives apply.
- Relationship reads are snapshot-consistent on native and preserve the existing
  missing-row and missing-parent contracts.
- Many-to-many join policy and synthetic change-feed behavior remain Dart-owned.
- The reusable Web worker uses the shared dispatch path; the documented route
  matrix distinguishes it from the temporary in-memory reference backend.

## Validation

- Focused relationship suites: 33 passed.
- Rust tests: 56 passed, including snapshot-bound relationship primitives.
- Dart analyze passed.
- Rust clippy with warnings denied passed.
