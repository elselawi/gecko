---
status: accepted
date: 2026-08-07
deciders: gecko_db maintainers
---

# 0003 — Dedicated Dart worker isolate for the database client

## Context

The single-writer design pins a long-lived Rust worker thread owning the
`redb::Database` handle. The open question is where the *Dart-side client work*
runs: reads, batch marshaling, change-feed fan-out, and FFI channel ownership.
If it all runs on the caller's (UI) isolate, then FFI round-trips, re-emission
of watched lists, and marshaling can contend with the caller's frame timing and
make hot-restart cleanup fragile.

## Decision

`Database.open` transparently spawns **one dedicated Dart worker isolate** per
open database, which owns the FFI/message channel to the Rust worker and runs
the client work (reads, batch marshaling, change-feed fan-out). Callers never
touch isolate lifecycle — they get the same `Database` interface; the agent
isolate is a private implementation detail bound to a keepalive the caller
holds and a `Finalizer` for hot-restart/GC recovery.

This is a *modest* embrace, explicitly bounded:

- One worker isolate per open `Database` — no per-call `Isolate.spawn`.
- The worker isolate is a **client**, never a second writer: there is still
  exactly one writer (the Rust worker) and one write gate. The isolate host
  does not split or multiply the single-writer discipline.
- No multi-isolate consistency model is introduced: ordering, atomicity, and
  MVCC remain exactly as §0.5 contract 4 defines, regardless of which isolate
  issues reads.

## Consequences

- Positive: UI-thread responsiveness (reads/re-emission/FFI off the caller
  isolate); a stable binding point across Flutter hot-restart (the spawned
  isolate + `Finalizer` can tear down cleanly when the caller's isolate dies).
- Positive: matches the plan's existing phrasing ("worker lifetime is bound to
  a keepalive the isolate holds") by making that isolate concrete.
- Negative: one extra message boundary (agent isolate ↔ caller) on top of FFI.
- Risk: on Web there is no Dart isolate host — the Web Worker already plays the
  "away from the caller" role (Phase 1), so the isolate host is a native/Dart
  concern only; the web path is intentionally out of this ADR's scope.

## Supersedes / Superseded by

None yet. Refines §0.5 contract 4 and the Phase 2 lifecycle step.
