# ADR-0004: Native Compatibility Handshake and Typed Error Envelope

- **Status:** Accepted
- **Date:** 2026-08-09
- **Decision:** Add a versioned Dart/native compatibility handshake and a JSON
  error envelope at the FRB boundary.

## Context

The package and loaded native artifact must fail deterministically when their
wire or file-format contracts do not match. Native failures also need to retain
a machine-readable error kind and actionable details instead of becoming an
untyped Dart exception.

## Decision

`CompatibilityHandshake` carries the handshake version, package version, wire
version, format version, and native build identity. The Dart adapter validates
it before accepting native operations. Rust emits the same fields and the CI
matrix pins the package, wire, format, and generator versions.

Native operation failures use a JSON envelope with `type`, `message`, and
optional `details`. Dart maps that envelope to `GeckoError`; unrecognized native
text becomes the typed `unknown` variant rather than escaping as an untyped
exception.

## Consequences

- Version mismatches fail as `upgradeRequired` before normal native work.
- Native errors can be tested cross-language and retain their type/message.
- The build identity is diagnostic metadata; compatibility is decided by the
  versioned package/wire/format matrix.
- Adding or changing this contract requires updating the API/wire snapshots,
  focused cross-language tests, and this ADR log.
