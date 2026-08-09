---
status: accepted
date: 2026-08-07
deciders: gecko_db maintainers
---

# 0002 — Wire format & error taxonomy v1 snapshot

## Context

Phase 0 locks the Rust↔Dart wire contract and the public error taxonomy before
any storage logic exists, so later phases don't reshape the foundation
underneath already-tested code. Versioning the wire contract and on-disk format
header explicitly means a mismatch between a consumer's `gecko_db` and the
loaded native library fails with a typed, actionable error instead of a cryptic
message-handling failure.

## Decision

- The `Op` batch wire format carries a version byte (`Op.wireVersion == 1`); an
  unknown version is rejected with a typed `OpDecodeException` (never a crash).
- The public error taxonomy is a single root `GeckoError` carrying a
  `GeckoErrorType` variant. Raw Rust panics, `StateError`, and untyped
  `Exception`s are not an API.
- Every typed error round-trips across the Dart↔native boundary via
  `GeckoError.toJson()` / `GeckoError.fromJson()` without losing type or
  message (enforced by dedicated Phase 0 tests).
- Both the API contract and this wire format are ADR-gated: a change to the
  locked Tier 1 contract from Phase 0, or to the error taxonomy, requires a new
  ADR.

## Consequences

- Positive: stable foundation; cross-language artifact checks can be golden.
- Positive: consumers get typed, actionable errors rather than opaque messages.
- Negative: adding a wire variant or error leaf requires a deliberate, versioned
  change rather than an ad-hoc edit.
