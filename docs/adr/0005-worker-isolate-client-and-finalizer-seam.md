---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0005: Worker-Isolate Native Client and Deterministic Finalizer Test Seam

## Context

ADR-0003 placed the FRB `NativeWorker` behind a dedicated Dart worker isolate.
Workstream 1 hardening added two qualification requirements that were not yet
verifiable in-process:

1. Prove that reads and writes actually execute on the spawned isolate (never
   the caller's), and that `close()` tears the worker down deterministically.
2. Prove the `Finalizer` teardown path actually shuts the worker down, without
   depending on real garbage collection (which is inherently
   non-deterministic and cannot be asserted in a unit test).

## Decision

A dedicated `NativeWorkerClient` (in
`lib/src/worker/native_worker_client.dart`) owns the isolate, its receive
ports, the request/response protocol, and the `Finalizer` token. It exposes a
small, documented **diagnostics surface**:

- `isWorkerAlive` — true after the startup handshake, false once the worker
  has reported termination.
- `workerIsolateName` — the isolate's own `debugName`, proving operations run
  off the caller's isolate.
- `debugFinalize()` — a deterministic test seam that invokes the **exact
  static `Finalizer` callback** (sends `finalize` to the worker) and awaits
  the worker's `workerExit` acknowledgement.

`NativeRawBackend` re-exposes this surface as `workerAlive`,
`workerIsolateName`, and `disposeForTest()` so qualification tests can reach
it through the public `engine.backend` accessor. The worker isolate always
emits a final `workerExit` message (including on startup errors) so the client
can observe termination deterministically. `close()` waits briefly for that
acknowledgement before reporting the worker as dead.

## Consequences

- Qualification tests can prove isolate separation, deterministic close, and
  finalizer teardown without relying on GC timing.
- The diagnostics members are part of the public API snapshot and therefore
  ADR-gated like any contract change; they are documentation-marked as
  test/qualification surface and are not a data-path API.
- `close()` may take up to ~5s longer in the pathological case where the
  worker cannot respond (it waits for `workerExit` with a timeout).
- A real GC-driven finalize still sends the same message; the seam and the
  production path share one callback, so the seam cannot drift from reality.
