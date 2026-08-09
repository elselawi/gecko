---
status: accepted
date: 2026-08-07
deciders: gecko_db maintainers
---

# 0001 — Manual mapper functions over codegen

## Context

The plan (Design Principle 2) requires *no reflection-based or
annotation+codegen modeling*: models are plain Dart classes with a small,
hand-written mapping function pair (`toRow` / `fromRow`). This keeps consumers
free of `build_runner`, codegen steps, and annotation dependencies.

## Decision

The public `Collection<T>` contract accepts `toRow: Object? Function(T)` and
`fromRow: T Function(Object?)` as plain functions. `id` is an optional
`Object? Function(T)` extractor. There is no annotation processor, no
`build.yaml`, and no generated files. Schema validation happens at
collection-open time against the mapping functions, not via generated code.

## Consequences

- Positive: zero build step for consumers; ergonomic and debuggable plain Dart.
- Positive: the mapping pair can express arbitrary/composite transforms that a
  pure codegen approach would struggle with.
- Negative: consumers must hand-write the mapping pair (mitigated by Phase 3's
  standard (de)serialization helpers).
- Risk: mapping drift between `toRow`/`fromRow` — mitigated by Phase 3's
  round-trip `toRow`/`fromRow` tests and schema validation at open.

## Supersedes / Superseded by

None yet.
