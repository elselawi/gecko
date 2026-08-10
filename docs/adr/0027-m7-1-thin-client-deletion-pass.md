---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0027: M7.1 thin-client deletion pass

## Context

After M7.1 Slices 1–4, native execution and relationship retrieval are owned by
Rust, but Dart still contains public adapters, model mapping, migration
callbacks, relationship policy, reactivity, and the transitional in-memory
reference implementation. A broad deletion would cross the M7.5 product
boundary or alter public contracts.

## Decision

- Remove only the duplicate Dart predicate evaluation after the native
  `queryIndexedLimited` route. Rust already applies the complete predicate and
  performs early-window stopping for that route.
- Correct route and repair terminology so public diagnostics distinguish Dart
  reference-index candidate lookup from native durable-bound planning.
- Retain all public raw/snapshot adapters, tuple conversions, result decoding,
  cursor materialization, model mapping, migration callbacks, relationship
  policies/callbacks, reactive lifecycle, and in-memory index/storage paths.
- Record source-size measurements as a M7.5 baseline rather than treating all
  native-related Dart LOC as deletable.

## Consequences

- Windowed indexed native queries perform no redundant Dart predicate test.
- The implementation remains safe for the transitional in-memory backend and
  Web/shared-dispatch contracts.
- Larger deletions are deferred to M7.5, where removal of public in-memory mode
  and the Dart backend is explicitly planned and can be tested as a product
  migration.

## Validation

- Full Dart package tests: 530 passed.
- Dart analyze passed.
- Rust tests: 56 passed.
- Rust clippy with warnings denied passed.
- Offline lint and traceability passed.
- Security review passed with the repository's four existing advisory findings.
- Baseline: 12,743 non-generated Dart source LOC, 7,374 native/query/
  relationship/raw/database integration LOC, and 395 transitional in-memory/
  index reference LOC.
