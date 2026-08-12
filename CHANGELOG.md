# Changelog

All notable changes to gecko_db are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning follows
[README.md](README.md).

## Unreleased

### Added

- **Composite durable indexes** (`collection(compositeIndexes: ...)`): declare
  multi-field indexes whose keys use the order-preserving prefix-then-values
  layout. Queries with an equality prefix plus an optional range/prefix on the
  trailing field are served as ONE ordered index scan instead of N
  single-field ranges plus Rust candidate intersection. Composite keys are
  maintained atomically with the rows and rebuilt by the one-time per-session
  repair.
- **Delta-only collection watch** (`collection.watchAllDeltas()`): a
  snapshot-less stream of `CollectionDelta<T>` (added/updated/removed only)
  for consumers with their own state store — no full collection snapshot is
  ever built. The existing `watchAllDiff` / `CollectionDiff.snapshot`
  behavior is unchanged.
- **Latest-state collection watch** (`collection.watchAllLatest()`): opt-in
  coalescing via `latestStateOnly` — a burst of full snapshots within one
  event-loop turn collapses to a single emission of the final state, so a
  slow listener never accumulates redundant snapshots. Default streams keep
  their current delivery semantics.
- **Native windowed live queries**: `Query.watch()` with `limit`/`offset`
  now runs through the worker's reactive registry (initial slice plus
  window-relative added/updated/removed deltas) instead of falling back to a
  full result set.
- **Missing-field index structure**: the durable index now records which
  primary rows lack an indexed field (`__gecko_index_missing`), so
  index-ordered fallback enumerates only genuinely missing rows instead of
  scanning the whole primary table; repair reconciles the structure.
- **One-pass relationship resolution**: child fetching and delete-resolution
  read each dependent row once (single foreign-key classification pass), and
  the native relationship scan groups candidates by FK in one fetch per row.
- **Native metadata query**: attachment/conflict listing runs a predicate
  scan + key-ordered result in Rust; orphaned-attachment detection caches
  parent-table existence and walks both parent fields in one pass.
- **Internal no-key clear/delete-range mode**: batches can request that Rust
  not collect every removed key (`RawBatchPlan.reportRemovedKeys`); a
  whole-table clear invalidates the application read cache as one table
  generation instead of enumerating keys. Existing per-key reporting is
  unchanged by default.
- **Worker queue-contention benchmark** (`benchmark/contention.dart`):
  measures latency-sensitive get/write latency (mean/p50/p95/p99/max),
  in-flight depth high-water, and write-gate contention under a concurrent
  background scan/repair/compaction, plus correctness under close.
- **Public web open via dedicated worker**: on the main thread (where OPFS
  sync access handles are unavailable), `Database.open` now provisions the
  in-package `web/gecko_db_worker.js` automatically and proxies every
  request over the transferable binary protocol; `nativeLibraryPath` on the
  web overrides the resolved worker URL.

### Changed

- **Diff-first watch delivery**: `watchAllDiff()` now computes its deltas from
  the committed post-batch values in the engine and emits an incremental
  `CollectionDiff` (added/updated/removed) without building a full-table
  snapshot per emission; the incremental `snapshot` is reconstructed on the
  Dart side in byte-key order.
- **Bounded negative read cache**: repeated reads of missing keys no longer
  cross the worker boundary, and writes invalidate only the keys they touch
  instead of clearing the whole read cache.
- **Per-subscriber watch backpressure**: a paused subscriber that falls too
  far behind drops its whole pending window and receives a single
  `ChangeBusOverflowError` carrying the event sequence, rather than silently
  dropping individual events.
- **Covered-filter skip**: when every predicate filter's field is in the
  durable index's declared fields, the exact eq/range/prefix bounds prove the
  whole predicate and Rust skips the per-row recheck (counted via
  `predicateEvaluations = 0`).
- **Index-ordered descending sorts**: DESC without an equality bound now
  streams the durable index in reverse (missing-field rows first) instead of
  running the full-scan top-K path; ties still break by ascending record key.
- **Native limit/offset pushdown**: single-range indexed queries route through
  the early-stopping index scan, so a small window visits only the rows it
  needs rather than materializing the whole candidate span.
- **Smaller-first streaming candidate intersection** with deterministic
  record-key output and a planner fallback to a full filtered scan when the
  index cannot narrow the candidate set.
- **Bounded open-snapshot cap**: the worker refuses to create more than 256
  concurrent read snapshots with an explicit typed error, so a leaked Dart
  snapshot can no longer pin MVCC versions and stall compaction silently.
- **Worker contention diagnostics**: `DiagnosticsSnapshot.workerContention`
  reports request count, queue-depth high-water mark, and average/max service
  time across the native worker boundary (zero allocation when unused).
- **Native sync/migration primitives**: state-transition filtering by
  collection/id set, a range-based `changesSince(lastSeq)`, orphaned
  attachment detection, and remote-deletion candidate selection now run in
  Rust; Dart only authors the matcher/ID sets and maps results.
- **Bounded, resumable record migrations**: large record rewrites now page
  BOTH the reads and the writes — durable progress is the last processed raw
  key, and each atomic chunk reads one bounded key-range page strictly after
  that key (never materializing the table), applies the upgrade transform,
  and records the new last key, so an interrupted migration resumes exactly
  where it left off. `RawSnapshot.scan` / `NativeRawSnapshot.scan` gained an
  optional `limit` argument, and the native range scan stops early at that
  limit, so callers can page a large table in O(page) memory.
- **Batched remote-change dedupe**: `applyRemoteTransactional` resolves
  duplicates with one batched snapshot read rather than one point read per
  record.
- **Zero-copy byte transport**: `Uint8List` values flow end-to-end through
  dispatch and the worker isolate without `List<int>.from` / `.toList()`
  copies; the web worker protocol gained a binary message path with a
  JSON/base64 fallback, and both client and worker build JS `Uint8Array`s
  with bulk `toJS` copies instead of per-byte loops.
- **Release profile**: the native crate now builds with `lto = true`,
  `codegen-units = 1`, and pinned `opt-level = 3` for cross-crate inlining on
  codec/predicate hot paths (`panic = "abort"` stays off because redb's
  `Drop`-based rollback needs unwinding).
- **Encrypted read path**: the physical-page read path fills the caller's
  page buffer directly and decrypts GCM in place into a reused plaintext
  scratch (one allocation per multi-page read instead of two per page), with
  page size, authentication, nonce, zero-page, and rotation semantics
  unchanged.
- **Exclusive native range bounds**: `RangeScan` / `SnapshotRangeScan` accept
  explicit inclusive flags so exclusive raw ranges never fall back to a full
  scan plus Dart-side filtering (exclusive bounds become inclusive redb
  ranges with an O(1) boundary-key skip).
- **Native scalar distinct dedup**: `queryFilteredDistinct` /
  `queryIndexedDistinct` deduplicate safe scalars in Rust before returning,
  so Dart receives one encoded value per distinct value.
