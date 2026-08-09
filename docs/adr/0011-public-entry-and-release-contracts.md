---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0011: Public Entry Point and Release Contracts (Workstream 6)

## Context

Workstream 6 requires making the package "installable and understandable":
`Database.open` must be the supported public entry point, the public API must
be documented and versioned, consumers must be able to migrate from
Hive/SharedPreferences, and every release must be auditable (compatibility
table, policies, changelog, security process, and a 12-criterion acceptance
traceability table verified by a script).

Before this ADR, `Database.open` on the abstract contract class threw
`UnimplementedError` ("Phase 2 provides the implementation"), so the only way
to open a database was the implementation surface `DatabaseImpl.open` — the
wrong public story for consumers.

## Decision

1. **`Database.open` is the supported public entry point.** The abstract
   `Database` contract delegates to the concrete `DatabaseImpl.open` via a
   circular import (legal in Dart; the public barrel already pulls the
   implementation's `dart:io` dependencies, and web compilation will be handled
   by conditional imports when the Phase 1 web backend lands). An earlier
   registration-seam approach was rejected because Dart initializes top-level
   variables lazily — load-time side effects do not run on import, so the
   opener was never registered before first use.
2. **`DatabaseConfig.inMemory`** selects the ephemeral in-memory backend
   through the public entry point (tests/examples/dev); the default remains the
   native file backend. `DatabaseImpl.open(useInMemory:)` stays as the
   implementation/testing surface.
3. **Consumer fixture.** `examples/consumer.dart` uses only the public barrel
   and exercises import → open → write → read → watch → query → migrate →
   encrypt → maintain → close; `tool/consumer_fixture_test.dart` runs it in a
   subprocess and rejects any `package:gecko_db/src/` import (drift guard).
4. **Release contracts are documentation + tooling:**
   - `docs/api.md` — the public surface by tier.
   - `docs/migration-from-hive.md` — Hive/SharedPreferences migration guide
     with limitations and a runnable import example.
   - `docs/policies.md` — semver, deprecation, migration, format-compatibility.
   - `docs/compatibility.md` + a README summary — version matrix (package, wire,
     file format, native build id, Dart/Flutter, platforms).
   - `CHANGELOG.md` + `SECURITY.md` — release notes and a disclosure process
     with an explicit claimed/not-claimed posture.
   - `tool/traceability_check.dart` — maps the 12 local-first acceptance
     criteria to named tests (existence, `--run`, `--json`); the filled table
     lives in the README.
   - `tool/docs_examples_test.dart` — runs the examples, checks every
     `dart run <file>` in docs, and prevents orphaned examples.

## Consequences

- Consumers open databases with `Database.open` (file-backed by default) and
  never need `DatabaseImpl`.
- The public API snapshot and the compatibility matrix are the locked contract;
  changes require an ADR or intentional version bump (enforced by the existing
  contract gate).
- Example/documentation drift is caught in CI rather than on release day.
- While auditing the consumer flow, ten pre-existing MVCC snapshot leaks were
  found and fixed (sync transitions, remote apply, conflict resolution,
  attachments, schema stamp/migrate): every operation now disposes its
  snapshot, so long-running consumer sessions no longer accumulate open redb
  read transactions (which also blocked compaction).
- `Database.open`'s delegation is a contract change (previously a throwing
  stub), gated by this ADR and captured in `tool/api_snapshot.txt`.
