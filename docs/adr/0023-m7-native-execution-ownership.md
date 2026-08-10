---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0023: M7 native execution ownership

## Context

M2–M6 moved query operations into Rust, but native collection open still
rebuilt a duplicate Dart `SecondaryIndex` from every primary row. That rebuild
also verified and repaired the durable `__gecko_index` table, so simply
skipping it would have removed a correctness guarantee.

M7 requires Rust to be the authoritative native execution layer without
removing the transitional Dart reference backend before M7.5.

## Decision

- Native collection index preparation calls Rust `repair_index(table, fields)`.
- Rust derives expected durable index entries from primary row bytes, compares
  them with entries for the table, and repairs differences atomically in one
  write transaction.
- Native Dart code no longer decodes every primary row to rebuild a secondary
  index or owns native index repair.
- The Dart `SecondaryIndex` rebuild remains only for the transitional in-memory
  reference backend until M7.5 removes that backend.
- Native relationship child reads use durable Rust index lookup when the FK is
  indexed, and Rust predicate push for unindexed FKs; Dart retains relationship
  declarations, policy, and model mapping.
- Native query readiness still awaits asynchronous Rust repair, preserving the
  no-read-before-repair contract.
- M8 query registration and reactive invalidation policy remain deferred; M7
  adds no persistent Rust query registry.

## Consequences

- Native open avoids Dart row materialization for index rebuild and repair.
- Durable index repair has one native authority and remains atomic with respect
  to the repaired index table.
- The transitional Dart backend still provides semantic reference coverage;
  it is not a second native source of truth and is removed in M7.5.
- Native relationship reads avoid Dart index metadata dependence and full Dart
  child scans where Rust primitives are available.
- The Rust repair operation adds one native operation and must remain covered by
  stale/missing/extra index, rollback, and reopen tests.

## Validation

- Native index/relationship suites pass, including drift repair.
- Rust repair unit coverage passes with 53 Rust unit tests plus integration
  tests.
- Full package tests: 528 pass; tool tests: 32 pass.
- Coverage: 95% line / 100% branch.
- Rust fmt/clippy and API/binding gates pass; performance baseline refreshed
  after unrelated micro-benchmark noise.
