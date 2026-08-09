# Architecture Decision Records

This directory is the locked history of every non-trivial architectural choice
in gecko_db, per Phase 0. Changes to the public API contract, error taxonomy,
wire format, or any decision flagged as ADR-gated in the plan **must** be
accompanied by a new ADR; a CI gate rejects changes that touch the locked
contract without one.

## Format

Each ADR is a numbered Markdown file with the following front-matter and
sections. Keep each record focused: one decision, one record.

```markdown
---
status: {accepted|superseded|deprecated|proposed}
date: YYYY-MM-DD
deciders: {who signed off}
---

# {NN} — {Short Title}

## Context
What problem, constraint, or goal motivates this decision.

## Decision
The choice made, precisely and narrowly.

## Consequences
What becomes easier, harder, or riskier because of this choice.

## Supersedes / Superseded by
(Optional) Links to the ADR(s) this one replaces, or that replaced it.
```

## Log

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-manual-mappers-over-codegen.md) | Manual mapper functions over codegen | accepted |
| [0002](0002-wire-format-v1.md) | Wire format & error taxonomy v1 snapshot | accepted |
| [0003](0003-worker-isolate.md) | Dedicated Dart worker isolate for the database client | accepted |
| [0004](0004-native-compatibility-and-error-envelope.md) | Native compatibility handshake and typed error envelope | accepted |
| [0005](0005-worker-isolate-client-and-finalizer-seam.md) | Worker-isolate native client and deterministic finalizer test seam | accepted |
| [0006](0006-native-mvcc-snapshots-and-dispose.md) | Native point-in-time MVCC snapshots and `RawSnapshot.dispose` | accepted |
| [0008](0008-durable-indexes-range-index-and-cursor.md) | Durable secondary indexes, range-index support, and the snapshot-bound cursor | accepted |
| [0009](0009-physical-encryption-and-key-management.md) | Physical page encryption and key management | accepted |
| [0010](0010-compaction-maintenance-and-diagnostics.md) | In-place compaction, maintenance state machine, and diagnostics | accepted |
| [0015](0015-phase1-query-instrumentation.md) | Per-stage query instrumentation (Phase 1 boundary + timing) | accepted |
| [0016](0016-phase2-native-query-fast-path.md) | Native query fast path over the durable index (Phase 2 step 1) | accepted |
| [0017](0017-phase2-predicate-push.md) | Native query fast path — predicate push (Phase 2 step 2) | accepted |
| [0011](0011-public-entry-and-release-contracts.md) | Public entry point and release contracts | accepted |
| [0012](0012-cross-platform-artifact-matrix.md) | Cross-platform artifact matrix and bundled distribution | accepted |
| [0013](0013-web-runtime-frb-glue-and-opfs.md) | Web runtime: FRB wasm glue and OPFS persistence | accepted |
| [0014](0014-in-package-web-worker-and-client.md) | In-package reusable web worker entry and `WebWorkerClient` | accepted |
