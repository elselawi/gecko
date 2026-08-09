---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0006: Native Point-in-Time MVCC Snapshots and `RawSnapshot.dispose`

## Context

Workstream 2's backend differential harness replays identical operation
scripts against the in-memory and native file backends and compares committed
snapshots, results, error categories, LSNs, and change feeds after every step.
The harness immediately exposed a contract violation: the native
`_NativeSnapshot` proxied reads to the live worker, so a snapshot captured
before a write observed the *post*-write state — unlike the in-memory
backend's immutable point-in-time snapshots. The shared `RawSnapshot` contract
("Readers capture a snapshot (MVCC), observe a single consistent view") was
not honored by the native backend.

## Decision

Native snapshots are now backed by a held redb `ReadTransaction`:

- `RedbWorker` keeps a `HashMap<u64, ReadTransaction>` of open snapshots and
  exposes `create_snapshot`, `snapshot_get`, `snapshot_range_scan`, and
  `drop_snapshot`. The FRB `NativeWorker` and the Dart `NativeWorkerClient`
  expose the same four operations.
- `NativeRawBackend.snapshot()` creates a worker snapshot id and returns a
  `_NativeSnapshot` that reads exclusively through the held read transaction,
  so it observes exactly the committed state at creation time.
- `RawSnapshot` gains a `dispose()` (default no-op; `_EncryptedSnapshot`
  forwards; `_MemSnapshot` is a no-op) so native snapshots are released
  deterministically. The engine disposes every snapshot it creates, and
  `DatabaseImpl.writeTxn` disposes the transaction snapshot when the
  transaction finishes. `NativeRawBackend` tracks open ids and drops them all
  on `close()`; a `Finalizer` on `_NativeSnapshot` releases any snapshot the
  caller drops without disposing.

## Consequences

- The native backend now satisfies the same MVCC contract as the in-memory
  backend; the differential harness and the shared conformance suite pass
  identically on both.
- `RawSnapshot.dispose()` is a new (additive) member on an exported interface;
  it is safe to call multiple times and is a no-op on backends without held
  resources.
- Native reads now take three worker round-trips (create → read → drop)
  instead of one live read. Correctness and the shared contract are the
  priority here; hot-path round-trip reduction is deferred to the performance
  workstreams.
- An undisposed native snapshot is reclaimed by the `Finalizer` and, in the
  worst case, when the backend closes — no read transaction is leaked.
