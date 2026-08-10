# Changelog

All notable changes to gecko_db are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning follows
[docs/policies.md](docs/policies.md).

## [Unreleased]

### Added
- **M8 — Incremental reactivity** (ADR-0029): `watchAll()`, `watchAllDiff()`,
  and `query.where(...).watch()` materialize their result sets once and then
  update them incrementally per coalesced batch — each changed key is
  point-read once under a single Rust read transaction (new one-hop
  `RawBackend.getMany`) and re-tested, instead of re-running a full
  collection scan per write. `scannedRows` stays flat under watch-only writes;
  ordering parity with `getAll()`/`findAll()` (byte-key) and comparator order
  for sorted queries is preserved; whole-table clears reset the caches;
  unchanged-value diffs emit nothing; windowed (limit/offset) queries keep
  documented full re-evaluation. New `MaterializedRows` cache helper and
  `packages/gecko_db/test/m8_reactivity_test.dart` (8 tests); the done-when is
  measured by `benchmark/m8_reactivity.dart` (update latency flat across a 5x
  collection size with live filtered queries, `scannedRows == 0`).
- **M7.5 — File-backed Rust engine consolidation complete**: the Dart
  `InMemoryBackend` and `SecondaryIndex` are deleted, and every supported store
  is Rust/redb (native file or OPFS file). `DatabaseConfig.inMemory`, the
  `useInMemory` opener path, `mem://`, `Database.open(':memory:')`, the wasm
  `:memory:` worker branch, and the main-thread `:memory:` web smoke are
  removed. All fixtures, benchmarks, examples, tools, docs, and Web smokes are
  file-backed. The query engine, collection reads, and relationship manager
  contain no Dart-only execution branches (snapshots are typed
  `NativeRawSnapshot`); Rust is the sole durable-index authority with
  repair-on-open wired into collection creation. Reactive streams serialize
  async re-reads so emissions stay in change-feed order on the native worker.
- **M7.5 kickoff** (ADR-0028): locked the file-backed Rust/redb product
  contract and migration plan. The public `DatabaseConfig.inMemory` option,
  `useInMemory` opener path, and `InMemoryBackend` export are removed; temporary
  native-file fixture conversion and the remaining Dart backend deletion are
  staged next.
- **M7.1 Slice 5 — Thin-client deletion pass**: removed the redundant Dart
  predicate recheck after Rust's windowed indexed query route and corrected
  native/in-memory route and repair terminology. Public/raw/snapshot contracts,
  model mapping, migrations, relationship policies, reactive lifecycle, and the
  transitional in-memory reference engine remain intentionally retained until
  M7.5. Recorded the baseline Dart LOC measurements in `plan.md`.
- **M7.1 Slices 3–4 — Native relationships and route matrix**: `parent()`,
  `loadAllChildren()`, and many-to-many ID retrieval now use snapshot-bound Rust
  primitives on native/Web-Wasm, with Dart retaining relationship policy,
  callbacks, mapping, and reactive lifecycle. Added the native/in-memory/Web
  route matrix and M8 handoff documentation without adding a Rust query registry.
- **M7.1 Slice 2 — Native aggregate/raw cleanup**: indexed native `count()` and
  `distinct()` now use snapshot-bound Rust durable-index candidate aggregates,
  avoiding primary-row transfer for aggregate-only queries. Unindexed predicate
  pushdown remains unchanged; native Dart candidate lookup is skipped, and native
  delete-range/LSN snapshot lifetimes are now closed deterministically.
- **M7.1 Slice 1 — Rust-owned durable index maintenance**: native batch writes now
  pass declared indexed fields to Rust, which derives old/new values from encoded
  primary rows and updates `__gecko_index` atomically with puts, deletes, ranges,
  clears, and repeated-key bulk operations. Native Dart no longer emits durable
  index `RawOp`s; the in-memory reference index remains until M7.5. Existing
  index format and prefix query semantics are unchanged.
- **M7 — Native execution ownership core** (ADR-0023): native collection index
  preparation now verifies and atomically repairs durable `__gecko_index`
  entries in Rust without rebuilding a duplicate Dart index. Indexed native
  relationship child reads use durable Rust index lookup, while unindexed FK
  reads use Rust predicate pushdown. The Dart index rebuild remains only for
  the transitional in-memory reference backend until M7.5.
- **M6 — Measured architecture decisions** (ADR-0021):
  - Retains the worker-isolate native client as the default. The measured
    isolate round trip is 57.3µs versus 25.1µs for direct FRB, but the isolate
    preserves UI-thread offload, single-writer ownership, deterministic
    teardown, and crash/reopen qualification.
  - The logical-encryption measurement (121.6ms median versus 4.4ms plain
    native) became the justification for M6.5's pre-release removal decision;
    it is not retained as a product feature.
  - Added `benchmark/m6_architecture.dart` for repeatable measurements.
- **M6.5 — Rust-only physical encryption simplification** (ADR-0022):
  - Planned pre-release contract: encryption off by default; one raw 32-byte
    `encryptionKey` enables fixed Rust AES-256-GCM physical encryption on
    native file databases.
  - Logical value encryption, custom crypto registries, key providers, text
    encodings, and user-supplied encryption methods are removed from the target
    API. Public raw-key rotation remains.
  - Web and in-memory encryption are explicitly unsupported; no released
    consumer migration is required.
- **M5 — Indexed range, prefix, and multi-equality intersection** (ADR-0020):
  covered native filters now narrow candidates through the durable index in one
  MVCC read operation and recheck the complete predicate in Rust.
  - Exact equality filters use `eqBounds`; range and prefix filters use broad
    `fieldBounds(table, field)` spans because `DefaultWireCodec` v1 is not
    semantic-order-preserving for every supported numeric/string value.
  - `query_indexed_multi` intersects durable row-key candidate sets for
    multi-eq and mixed equality + range + prefix filters, then applies the
    complete Rust predicate for correctness.
  - Covered `count()` and `distinct()` retain `IndexPlan.secondaryIndex`;
    uncovered filters continue through native predicate push.
  - 10 new parity/bounds/index-hop tests; benchmark profile:
    `benchmark/m5_indexed_filters.dart`.
- **M4 — Indexed sorting and early LIMIT** (ADR-0019): sorted/limited queries
  push sort + window to Rust on native — no materialization, no Dart sort.
  - `query_indexed_ordered` streams index-covered sorts directly from the
    durable index in byte order (ascending, or both directions when the sort
    field is equality-filtered) and stops early at the limit; rows missing the
    sort field are appended last (first when descending). If the index table
    is absent it falls back to `query_sorted`.
  - `query_sorted` does a full scan but keeps only a bounded **top-K heap**
    (`offset + limit`) using the new `sort_spec::sort_compare` port of Dart's
    `compareFieldValues`; only sort fields are extracted per row (via
    `value_codec::find_field`), never a full decode.
  - `query_filtered_limited` / `query_indexed_limited` add `limit`/`offset`
    early-stop to the existing M2/M3 scans.
  - New `sort_spec` wire format (`SORT_SPEC_WIRE_VERSION = 1`), mirrored by
    `encodeSortSpecs` (Dart) and `decode_sort_specs` (Rust).
  - `_nativeOrderedCollect` in `query_impl.dart` routes native sorted queries
    to the Rust ops, bypassing `compareRows`/`decoded.sort` entirely.
  - **Deterministic tie-break:** all paths (native index order, Rust top-K,
    in-memory Dart sort) now break equal sort keys by raw record-key bytes,
    since Dart's `List.sort` is not stable.
  - 14 new parity tests in `packages/gecko_db/test/m4_sort_limit_test.dart`;
    perf probe shows indexed `ORDER BY … LIMIT 20` on 100k rows at
    **110–209 µs** (target < 5 ms).
- **M3 — Read-path completion + `getMany`** (ADR-0018): every native read path
  now uses the Rust fast path, and reads aggregate / batch instead of moving
  whole rows to Dart.
  - `iterate()` now routes through `_scanWith` (indexed-eq → `query_indexed`,
    unindexed → `query_filtered` on native); the old `_streamUnsorted` per-id
    `snap.read` loop is deleted.
  - `count()` / `distinct()` push the aggregate to Rust on native:
    `RedbWorker::query_filtered_count` (returns only a `u64` count — no row
    transfer) and `query_filtered_distinct` (emits only the encoded bytes of
    the requested field per matching row via the new
    `value_codec::find_field_range`; Dart decodes + dedups, and rows missing
    the field are omitted, matching Dart `distinct()`).
  - **`Collection.getMany(ids)`** — a public batched point-read: one
    `RedbWorker::get_many` Rust call fetches N keys in one read transaction,
    returning rows in input order and skipping absent ids. Inside a
    transaction it observes the staged overlay.
  - `RelationshipManager._childRowsFrom` batches indexed FK lookups through
    `snap.getMany` (one boundary crossing instead of one per child id).
  - `RawSnapshot.getMany` (per-key default; native override does the single
    hop) added to the raw contract.
  - 14 new parity tests in `packages/gecko_db/test/m3_read_path_test.dart`
    (in-memory + native) + Rust unit tests for `get_many`,
    `query_filtered_count`, `query_filtered_distinct`, `find_field_range`.
- **Phase 2 step 2 — Native predicate push for unindexed full scans**
  (ADR-0017): unindexed queries on the native backend now push the predicate
  to Rust, evaluating it against each row's bytes IN Rust (decoding only the
  referenced fields) and returning only matches in one FRB hop. Non-matching
  rows are never decoded in Dart. Full scan 100k rows dropped 482 ms → 39 ms
  (**12.4×**, meeting the `≥ 10×` target); `backendRead` dropped 336 ms →
  38 ms.
  - Rust: `value_codec.rs` (a byte-for-byte port of `DefaultWireCodec`:
    `RowValue` enum + `decode_value` + `find_field` field-skip + `compare`);
    `predicate.rs` (wire format + `Predicate` evaluator over `RowValue`);
    `RedbWorker::query_filtered` / `snapshot_query_filtered`.
  - Dart: `encodePredicate` (`predicate_codec.dart`) serializes a `FilterGroup`;
    `NativeRawBackend.queryFiltered` / `NativeRawSnapshot.queryFiltered`;
    `QueryImpl._scanWith` routes any unindexed query on a `NativeRawSnapshot`
    through the native path.
  - `IndexPlan.nativeFilteredScan` attributes the new plan (distinct from
    `fullScan` / `secondaryIndex`).
  - 4 new parity/perf tests in `phase5_index_ws3_test.dart` + 7 unit tests for
    `encodePredicate` / `value_codec` / `predicate` (lexicographic inclusion,
    range bounds, prefix, AND composition, multi-byte varint, find_field skip).
- **Phase 2 step 1 — Native query fast path over the durable index**
  (ADR-0016): indexed equality queries on the native backend now traverse the
  durable `__gecko_index` table and join back to the rows in ONE FRB hop,
  eliminating the Dart-side N+1 point reads (88% of indexed eq per the Phase 1
  profile). Indexed eq on 100k rows dropped from 38 ms → 12 ms (3.2×);
  `backendRead` dropped 33.5 ms → 4.6 ms (7.4×).
  - Rust: `RedbWorker::query_indexed` / `snapshot_query_indexed` + FRB
    `NativeWorker.queryIndexed` / `snapshotQueryIndexed`.
  - Dart: `NativeRawBackend.queryIndexed` / `NativeRawSnapshot.queryIndexed`
    (non-snapshot + snapshot-bound); `QueryImpl._scanWith` routes single
    covered equality filters through the native path when the snapshot is a
    `NativeRawSnapshot`. Multi-eq / range / prefix fall back to the Dart
    per-id path (results agree).
  - `eqBounds(table, field, value)` helper (`durable_index_bounds.dart`)
    computes the lexicographic `[start, end]` byte bounds for an eq prefix
    scan over the 4-element composite durable-index key.
  - `NativeRawSnapshot` (was `_NativeSnapshot`) is now public so the query
    engine can detect the native-snapshot capability.
  - 5 new parity/perf regression tests in `phase5_index_ws3_test.dart` + 4
    unit tests for `eqBounds` (lexicographic inclusion/exclusion + 0xFF carry).
- **Phase 1 — Read/query path instrumentation** (ADR-0015):
  - `benchmark/boundary.dart`: per-layer latency micro-benchmark
    (dartCall → isolateRoundTrip → frbCall → rustNoop → redbGet →
    rawGet cold/hot) on the native backend; advisory, not a regression gate.
  - `benchmark/query_profile.dart`: per-stage split for a full scan and an
    indexed equality query at 1k and 100k rows.
  - `QueryStageTimings` (public, on `SlowQueryRecord.timings`): per-stage µs
    for the 8 query-path stages (plan → indexLookup → backendRead → decode →
    mapCopy → predicate → model → sort) + `rowsScanned`/`rowsMatched`;
    populated only when `slowQueryThresholdMicros > 0` (zero overhead when
    disabled).
  - `NativeRawBackend.commitSequenceProbe()`: perf instrumentation accessor
    that runs a worker-isolate round trip with trivial Rust work, isolating
    the isolate/port + FRB marshalling cost.
  - Finding: the cost is overwhelmingly in boundary crossings
    (`backendRead` is 70% of a 100k-row full scan and 88% of an indexed eq
    query), not Dart decode/predicate — directly motivates Phase 2.
- Workstream 4 — **Physical encryption and key management** (ADR-0009,
  historical pre-M6.5 surface):
  - `EncryptingStorageBackend`: AES-256-GCM per physical page below redb
    (`[gen 1][ciphertext‖tag 4112][nonce 12]`), length-preserving and
    page-aligned; wrong key / corrupt page → typed errors before data.
  - The pre-M6.5 implementation exposed separate physical-key and provider
    configuration; ADR-0022 replaces that unfinished public surface with one
    raw `encryptionKey` while preserving the Rust physical format and rotation
    behavior.
  - `rotatePhysicalKey`: atomic key rotation with crash recovery to either the
    old or the new key.
- Workstream 5 — **Compaction, maintenance, and diagnostics** (ADR-0010):
  - `Database.maintenance`: in-place compaction (redb two-phase), a
    five-state maintenance machine (`idle/compacting/committed/failed/
    recovering`) with a durable interrupted-compaction marker,
    `storageStats()` (logical + physical size), snapshot-drain wait + retry.
  - Slow-query logging (`DatabaseConfig.slowQueryThresholdMicros`) with
    indexed/full-scan attribution; `DiagnosticsSnapshot` counters
    (slow queries, lock contention, active subscribers, compaction stats,
    maintenance state); per-subscription change-feed subscriber counting.
- Workstream 6 — **API, docs, examples, compatibility**:
  - `Database.open` is the supported public entry point
    (`DatabaseConfig.inMemory` for ephemeral databases).
  - Consumer fixture (`examples/consumer.dart`) exercising import → open →
    write → watch → query → migrate → encrypt → maintain → close with no
    repository-internal imports, run in CI.
  - Policies (`docs/policies.md`), compatibility matrix
    (`docs/compatibility.md`), Hive/SharedPreferences migration guide
    (`docs/migration-from-hive.md`), API reference (`docs/api.md`),
    `CHANGELOG.md`, `SECURITY.md`, and the 12-criterion traceability checker
    (`tool/traceability_check.dart`).

### Fixed
- MVCC snapshot leaks in `_SchemaApiImpl.stamp`/`migrateStep`, sync
  `_transition`/`applyRemoteTransactional`, conflict `resolve`/
  `resolvePreserved`, and several attachment operations — each now disposes
  its snapshot (surfaced by the consumer fixture and the compaction
  snapshot-drain guard).
- `QueryCursor.dispose` released a created-but-unused cursor's snapshot (WS3
  leak).
- **`bulkWrite` did not maintain secondary indexes** (WS8 large-data suite):
  indexed queries returned wrong results after bulk inserts/updates/deletes.
  `bulkWrite` now maintains the durable `__gecko_index` table in the same
  atomic batch and applies the in-memory index after the durable commit, with
  a regression test (`phase12_performance_test.dart`).
- **`bulkWrite` did not write change-tracking records**: bulk-written changes
  never appeared in the sync pending set or `changesSince`. `bulkWrite` now
  writes change-log + sync-state records atomically with the data, so a sync
  engine sees bulk writes like any other local mutation.
- **`markSynced`/`_rewriteLogRecord` were O(ids × change-log)**: a 10k-record
  `markSynced` took many minutes. `_transition` now indexes the change log in
  one pass (O(log + ids)), cutting the large-data sync test from >10 min to
  ~seconds.

### Added (this workstream)
- **Reusable in-package web worker + `WebWorkerClient`** (ADR-0014):
  `packages/gecko_db/web/gecko_db_worker.dart` is a ready-made OPFS
  DedicatedWorker entry; `WebWorkerClient.open(...)` mirrors the VM
  `NativeWorkerClient` with a documented JSON wire protocol
  (`web_worker_protocol.dart`) and deterministic boot/close. Live-validated by
  the CDP browser harness (`GECKO-WORKER-OK`).
- **Workstream 8 reliability/security/performance qualification**:
  `phase14_*_ws8_test.dart` — fixed-seed randomized ops, backend differential
  replay, crash injection at every native commit boundary, parallel isolated
  databases, 100k+ large-data, and a sustained soak under physical encryption.
- **Performance regression gate**: `benchmark/bench.dart --json` +
  `tool/perf_gate.dart` against pinned `benchmark/baseline.json`.
- **Phase 13 comparative benchmark**: `benchmark/comparative.dart` vs Hive CE
  and Sembast (dev-only deps) with `--json`.
- **Offline determinism lint** (`tool/offline_lint.dart`) and **security
  review** (`tool/security_review.dart`), both wired into CI.

## [0.0.1] — initial development

- Phase 0: public contracts, error taxonomy, wire format v1, ADRs, coverage
  gate (≥95% line + branch).
- Phase 2: byte-level backend, raw API, LRU cache, backpressure, worker
  isolate, process-crash recovery, native MVCC snapshots.
- Phase 3: codegen-free typed modeling, schema, patch, auto-ids.
- Phase 4: reactivity (`watch`/`watchAll`/`database.watchAll`).
- Phase 5: query engine, sorting, pagination, count/distinct, durable
  secondary + range indexes (ADR-0008), snapshot-bound cursors.
- Phase 6: relationships, delete behaviors, N:M joins, reactive relationship
  queries.
- Phase 7: transactions, durable change tracking, sync hooks, LSN ordering,
  origin tagging, idempotency, GC watermark.
- Phase 8: pluggable conflict resolution, three-way merge, preserved manual
  conflicts.
- Phase 9: attachment metadata, content-hash dedupe, orphan detection.
- Phase 10: schema versioning and transactional migrations.
- Phase 11: historical logical encryption (`EncryptedRawBackend`,
  `Aes256GcmCryptoBackend`), scheduled for removal before first release by
  M6.5/ADR-0022.
- Phase 12: bulk writes, bounded cache, per-row diff watches, opt-in
  diagnostics.
- Phase 13: runnable quickstart/advanced examples and release-hardening docs.
