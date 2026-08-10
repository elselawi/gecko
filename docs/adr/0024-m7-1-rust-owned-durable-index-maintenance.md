---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0024: M7.1 Rust-owned durable index maintenance

## Context

M7 moved native durable-index verification and repair into Rust, but normal
native writes still expanded typed mutations into Dart-generated `RawOp`s for
`__gecko_index`. That left multiple mutation paths vulnerable to drift and
made Rust's primary-row authority incomplete. The existing durable key format
is `encode([table, field, value, recordId]) -> encode(recordId)` and is already
used by native query bounds and repair.

## Decision

- Native collection declarations are registered with the native backend and
  sent as metadata alongside the existing versioned operation batch. The
  operation wire/file format is unchanged.
- Rust derives old and new indexed field payloads directly from encoded primary
  row bytes using the existing value codec.
- Rust removes old entries and inserts new entries in the same redb write
  transaction as each primary put, delete, delete-range, or clear. The write
  transaction's current state is used, so repeated keys in one batch are
  sequentially correct.
- Missing fields produce no new entry; a present encoded `null` remains an
  indexed value. Equality and prefix declarations use the existing full-value
  durable entries and unchanged query-bound/predicate-recheck behavior.
- Native Dart keeps index declarations and the temporary in-memory
  `SecondaryIndex`, but does not construct durable index mutation `RawOp`s or
  apply native reference-index mutations. In-memory behavior remains the
  reference path until M7.5.
- Open-time `repair_index` remains the recovery authority for pre-existing
  drift and continues to use the unchanged durable layout.

## Consequences

- All native primary/index mutations handled by the batch path have one Rust
  authority and one atomic commit boundary.
- Bulk writes, transactions, relationship-generated batches, sync writes, and
  migration rewrites receive the same index maintenance behavior when their
  declarations are registered.
- Direct writes made before declaration registration, or writes that bypass
  the normal native collection declaration lifecycle, still require repair on
  open; the raw backend does not infer user index schemas.
- Crash/reopen atomicity is inherited from the single redb transaction. An
  explicit index-enabled crash-injection qualification remains follow-up work.
- No persistent Rust query registry or arbitrary Dart callback execution is
  introduced.

## Validation

- Rust unit tests: 55 passed, including native put/update/missing/delete,
  repeated-key bulk sequencing, rollback-on-invalid-batch, and existing repair.
- Focused native index/reopen/drift tests: 2 passed.
- Full Dart package tests: 528 passed.
- Dart analyze and Rust clippy with warnings denied passed.
- Offline lint, security review, traceability, API contract, and release build
  checks were run; the security review reported only its existing advisory
  findings. The repository's current pre-existing Rust formatter changes in
  `worker.rs`/`api.rs` still need normalization before the final commit.
