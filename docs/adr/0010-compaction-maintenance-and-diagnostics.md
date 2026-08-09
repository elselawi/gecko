---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0010: In-Place Compaction, Maintenance State Machine, and Diagnostics

## Context

Workstream 5 requires controlling database growth without blocking readers
indefinitely and making engine behavior observable in production. The plan
mandates a maintenance state machine, an LSN/watermark compaction boundary, an
atomic compact-and-recover path that never swaps an open Windows file unsafely,
preservation of all metadata across compaction, logical/physical size
reporting, slow-query logging, and a battery of counters — all off by default
with near-zero overhead when disabled.

redb 4.1.0 offers two compaction strategies: in-place `Database::compact()`
(two-phase commits, iterative `compact_pages` + maximum shrink) and no public
sibling-image API. Building a sibling image ourselves would require pausing or
replaying concurrent writes to merge the post-snapshot LSN boundary — a large,
error-prone surface that redb's in-place path already handles safely.

## Decision

### 1. In-place compaction (redb's supported path)

Compaction uses `Database::compact()`, which:

- refuses to start while any read transaction is alive (typed
  `TransactionInProgress`), so snapshot-bound cursors/transactions block it;
- uses two-phase commits internally, so a crash at any point reopens a
  complete image (no sibling/swap, no unsafe Windows file replacement);
- iteratively relocates pages and shrinks the file via `set_len`.

The worker rejects compaction when open MVCC snapshots exist
(`RedbWorker::compact`), and the Dart maintenance layer additionally waits
(bounded, `compactionSnapshotDrainTimeout`) for in-flight readers to drain and
retries once if a reader starts in the dispatch window. Readers that start
while compaction is queued therefore finish normally on consistent old
snapshots, and writes after compaction continue at the next LSN (continuity,
never reuse). Compaction is refused on read-only and in-memory databases with
typed `invalidOperation` errors.

### 2. Maintenance state machine with a durable crash marker

A reserved `__gecko_maintenance` table stores a `state` marker
(`idle|compacting|committed|failed`), written directly at the raw backend (no
LSN bump, no change-feed event, no change-log entry). The Dart maintenance
layer drives the machine:

```text
idle ──compact()──> compacting ──success──> committed ──(next idle)──> idle
                       │
                       └── failure ──> failed ──recover()──> idle
```

Before compaction starts, the `compacting` marker is persisted; it is cleared
(committed/idle) or set to `failed` afterward. On open, a durable `compacting`
marker means a previous session crashed mid-compaction — redb's two-phase
recovery has already made the file consistent — and the machine surfaces
`recovering` until `recover()` clears the marker.

### 3. Size reporting and diagnostics

- **Size:** `storage_stats()` reports physical (file) bytes and logical
  (summed key+value payload) bytes plus table count, open snapshots, and commit
  sequence; the in-memory backend reports logical size (no disk).
- **Slow-query logging:** `DatabaseConfig.slowQueryThresholdMicros` (0 =
  disabled) arms a stopwatch on `Query.findAll`; queries over the threshold are
  recorded with their plan (indexed vs full-scan), table, filters, and sort,
  bounded to the most recent 32. Disabled ⇒ no stopwatch, near-zero overhead.
- **Counters:** `DiagnosticsSnapshot` gains slow-query count, lock-contention
  (write-gate waits), active change-feed subscribers (per-subscription counting
  on the change bus), compaction count/duration/reclaimed bytes, and the
  maintenance state. Diagnostics remain disabled by default.

## Consequences

- Growth is controllable on demand (`maintenance.compact()`), crash-safe at
  every point, and every table — user data, change log, sync metadata
  (watermark + LSN), indexes, attachments, schema stamp, and physical
  encryption pages — is preserved by redb's in-place compaction.
- Compaction requires quiescent MVCC snapshots; long-lived cursors block it
  until `compactionSnapshotDrainTimeout` elapses (typed timeout), an honest
  trade-off vs. a sibling-image design that would need write replay.
- redb's `compact()` is synchronous in the worker isolate, so a large
  compaction pauses other worker requests until it returns; readers that queue
  observe consistent post-compaction state. This is documented rather than
  hidden.
- The durable marker lets an interrupted compaction be diagnosed as
  `recovering` instead of silently retried; `recover()` is explicit.
- The maintenance API (`MaintenanceApi`, `MaintenanceState`, `StorageStats`,
  `SlowQueryRecord`), `Database.maintenance`, and the extended
  `DiagnosticsSnapshot`/`DatabaseConfig` are ADR-gated contract changes
  captured in `tool/api_snapshot.txt`.
- A pre-existing WS3 cursor leak (a created-but-unused cursor never released
  its snapshot on `dispose`) was found and fixed while writing the
  snapshot-drain guard.
