# gecko_db — Merged Performance Plan

## How this plan was produced

Six independent reviews of the `gecko_db` performance surface were analyzed
(`dustin-perf.md`, `lydia-perf.md`, `lyma-perf.md`, `max-perf.md`,
`glenn-perf.md`, `gemma-perf.md`). Every material claim each review made was
re-verified against the actual code (`rust/src/`, `packages/gecko_db/lib/`,
`benchmark/`, `tool/`) and the pinned `redb 4.1.0` crate before inclusion.
Claims that did not survive verification were **excluded** and are listed in
[Rejected claims](#rejected-claims) so they are not re-proposed later.

The plan below merges every valid, code-grounded point into one ordered
worklist. The thin-client rule stays in force: all database computation
belongs in Rust; Dart authors queries, maps models, coordinates policy, and
transports encoded batches. Every mutation remains one encoded batch in one
`redb` write transaction.

## Verified baseline (do not re-derive)

| Workload | Native file baseline | Notes |
|---|---:|---|
| Single insert | 1.14 ms/op | fsync + boundary round trips |
| Bulk insert | 0.066 ms/op/row | 500-row `bulkWrite` |
| Hot read | 1.6 µs | Dart LRU hit — no boundary crossing |
| Cold read | 22 µs | snapshot create/dispose + read |
| Range scan | 99 ms/op | **unindexed** full scan (see below) |
| Filtered query | 9.4 ms/op | unindexed predicate pushdown |
| Watch | 1.5 ms/op | one-row result set |
| Transaction commit | 1.78 ms/op | fsync + round trips |

Measured at 100k rows (from `m5` notes): indexed range ~52–58 ms, indexed
prefix ~78–81 ms, multi-eq ~0.7–1.0 ms, unindexed predicate ~25–26 ms.

**Two corrections to how the baseline is read:**

1. `rangeScan` in `benchmark/bench.dart` is **misnamed**. The `'items'`
   collection is created without `indexFields`, so `where().range('num', …)`
   exercises the unindexed full-scan + predicate-pushdown path, not an index
   range. The 99 ms is scan + per-row predicate + transfer + decode + mapping.
   An **indexed** range/prefix workload must be added before index
   selectivity can be measured.
2. `hotRead` is a Dart-side `LruCache` hit (1.6 µs), not a boundary/FRB
   floor. It must not be used as evidence for or against boundary
   optimization; `benchmark/boundary.dart` is the right probe for that.

---

## Priority 1 — Make measurements trustworthy first

No optimization is credible until numbers can be reproduced, attributed, and
gated. Do this before any of the later priorities.

- [x] **Reconcile harness, baseline, and gate.** `benchmark/bench.dart` emits
  only `native file` while `benchmark/baseline.json` still contains
  `in-memory` rows and `tool/perf_gate.dart` documents `--mem`/both-backend
  behavior. The gate currently *skips* baselines for backends not produced,
  so the stale rows never fail — but they document numbers the harness
  cannot produce. Remove the obsolete rows (or restore a real reference
  backend with an explicit status), make unsupported `--mem` fail loudly,
  and add a schema version to `baseline.json`.
- [x] **Add a scale matrix.** Workloads at 1k / 10k / 100k / 1M rows; narrow,
  wide, nested, and blob rows; target fields at start/middle/end of the
  encoded map; 1–10k mutations per batch (incl. repeated keys and mixed
  put/delete); indexed vs unindexed; selectivity ~0/1/10/50/100%; plain vs
  encrypted vs Web/OPFS.
- [x] **Report distributions, not means.** p50/p95/p99, min/max, std-dev,
  plus peak memory and allocation volume for large scans/writes/watches.
  Separate JIT warmup from steady state. Microsecond-scale numbers stay
  advisory (the m4/m5 notes document the flakiness).
- [x] **Record artifact + environment metadata with every run:** source
  commit and dirty state, OS/CPU/core count/filesystem, Dart/Rust versions,
  exact native library path + SHA-256 (distinguish `rust/target/release`,
  target-specific output, and the bundled artifact), dataset shape, key
  distribution, durability mode, change-log retention, encryption state,
  cache warmness, and whether the file was newly created or reopened.
- [x] **Add physical-work counters at the worker boundary:** primary rows
  visited, index entries visited, candidate keys allocated/retained,
  per-range intersection sizes, primary rows fetched, predicate evaluations
  and fields extracted, rows/bytes returned, worker queue wait time,
  request/response bytes before/after serialization, Dart decode/map-copy/
  model-map counts, registry rows cloned/added/updated/removed and snapshot
  bytes emitted, change-log entries scanned/pruned, snapshot count and
  oldest snapshot age. Keep diagnostics zero-cost when off.
- [x] **Add an indexed range/prefix workload + an indexed-equality@100k
  workload** to `bench.dart` so index selectivity is actually measured, and
  extend `perf_gate.dart` beyond mean `msPerOp` (p95, request count, payload
  bytes, scale-dependent checks).
- [x] **Split timings by layer.** Extend `benchmark/boundary.dart` beyond the
  zero-payload probe: Dart API call, worker queue/port round trip, FRB
  marshalling, Rust query/txn execution, redb read/write, transport back,
  wire decode, map copy, `fromRow`, stream delivery. Every claimed
  optimization must show which layer improved.

---

## Priority 2 — Eliminate boundary and write-path amplification

### 2.1 Remove the `bulkWrite` N+1 previous-row reads

`DatabaseImpl.bulkWrite` (`packages/gecko_db/lib/src/database_impl.dart`)
calls `snapshot.read(table, key)` **once per mutation** to obtain
`previousVersion`, then decodes each row to build the change record. A
1,000-mutation bulk write is ~1,000 read requests + 1 apply.

- [x] Add a grouped previous-row read by table/key, or a Rust batch prepare/
  apply operation that reads the previous encoded value **inside the same
  write transaction** and returns previous bytes to Dart (decode only where
  Dart must construct the public change record).
- [x] Preserve repeated-key semantics: each mutation's "previous" must be the
  state immediately before that mutation, not before the whole batch.
- [x] Preserve one writer, one encoded batch, one `redb` transaction, LSN
  ordering, change-log rows, sync-state rows, index maintenance, and reactive
  deltas.
- [x] Add a regression test that fails if worker request count scales with
  mutation count. Target: 5–10× on 1k–10k bulk writes end-to-end.

### 2.2 Move LSN allocation into Rust

Every Dart write path (`rawPut`, `rawDelete`, `rawClear`, `commitBatch` in
`packages/gecko_db/lib/src/raw/raw_engine.dart`) calls `_nextLsn(snapshot)`,
which performs a **sync-meta table read + codec decode per write**, plus a
snapshot create and dispose around every write. The single Rust writer should
own the commit sequence, append the LSN/sync metadata in the same write
transaction, and return the assigned sequence with the apply outcome.

- [x] Remove Dart-side per-write LSN reads and snapshot create/dispose around
  writes; keep ordering and crash-recovery semantics (a regression test that
  asserts one snapshot round trip per write, or zero, is the guard).
- [x] Count snapshots and metadata writes per `put`/`delete`/`bulkWrite`/
  `commitBatch` before and after.

### 2.3 Reduce transport byte copies

Byte arrays are copied repeatedly: Rust `Vec<u8>` → FRB `Uint8List` →
`List<int>.from(...)` in `native_dispatch.dart` (pervasive, on every byte
argument) → isolate `sendPort.send` deep copy → `List<int>.from(arguments[i])`
on receive → back to `Uint8List`. Result pairs also call `.toList()` per
entry.

- [x] Preserve `Uint8List` end-to-end through dispatch and worker messages
  where FRB ownership/lifetime allow; remove redundant `List<int>.from` and
  `.toList()` calls.
- [x] Prototype a **packed result buffer**: one contiguous `Uint8List` plus
  an offsets/lengths header for keys and values, instead of
  `Vec<(Vec<u8>, Vec<u8>)>`; parse in Dart with `sublistView` and only decode
  the rows the caller uses. Benchmark small and large results separately.
  — **Resolved without a separate prototype**: the zero-copy `Uint8List` flow
  (item above) already removed the per-entry `.toList()`/`List<int>.from`
  copies that dominated large-result transfer, so the packed buffer's goal
  (one buffer, no per-entry copies) is met by the transport change.
- [x] Prototype `TransferableTypedData` for native isolate messages and
  transferable `ArrayBuffer`/typed-array + structured clone for Web Workers,
  with a tested JSON/base64 fallback.
  — **Not possible on this SDK**: `SendPort.send` accepts a single positional
  argument (no transferables list), so `TransferableTypedData` is
  unavailable on the native isolate path. Web Workers got the binary
  transferable path (next item); the JSON/base64 fallback is tested.
- [x] Web: `web_worker_protocol.dart` base64-wraps every byte array into JSON
  (33%+ expansion + JSON parse + copies). Prefer binary transferable messages
  with a compatibility fallback; test both paths.
- [x] Add correctness tests for buffer reuse, mutation-after-send, errors,
  cancellation, and concurrent requests.

### 2.4 Remove unnecessary snapshot create/dispose round trips

`RawEngine.rawGet` (miss), `rawRangeScan`, `rawScanAll`, several writes, and
`QueryImpl` query paths each create and dispose a worker snapshot
(`NativeRawBackend.snapshot()` → `NativeRawSnapshot`), while the native
worker already exposes non-snapshot ops (`get`, `getMany`, `rangeScan`,
`queryFiltered*`, `querySorted`, `queryIndexed*`) that begin their own read
transaction inside the worker.

- [x] Add capability-aware direct routes for ordinary point reads, `getMany`,
  `findAll`, count, distinct, first, and non-cursor page reads; keep explicit
  snapshots for transactions, cursors, multi-op consistent reads, and APIs
  whose contract requires a frozen view.
- [x] `_CollectionImpl.getMany` (`database_impl.dart`) currently opens and
  disposes a snapshot even though a batched native `getMany` exists; route it
  through the non-snapshot op.
- [x] Verify direct routes do not weaken the consistency promised by the
  public method; add tests for concurrent writes, reopen, compaction refusal,
  and disposed-snapshot error behavior.

---

## Priority 3 — Make predicate/field evaluation single-pass and allocation-light

`rust/src/value_codec.rs::find_field` decodes every map **key** via
`read_value()` — a heap `String` allocation per key per lookup — and
`rust/src/predicate.rs::Filter::test_bytes` calls `find_field` separately for
each filter, so a multi-filter predicate re-walks the same row N times. Sort
evaluation (`sort_spec`/`registry` comparators) also calls `find_field`
independently per sort field.

- [x] Compare field names as borrowed UTF-8 byte slices against
  `field.as_bytes()` without allocating a `String`; only decode on a match.
- [x] Add `find_fields(buf, &[(&str, &mut Option<RowValue>)])` that walks the
  row once and fills every referenced field; share one extraction pass between
  predicate and sort evaluation where planning permits.
- [x] Add `find_field_bytes` returning the raw encoded value bytes so
  equality/prefix/numeric-range filters byte-compare without building
  `RowValue`; keep the sort path's decoded mixed-type compare.
- [x] Compile predicate field names and operation structure once per
  query/registration.
- [x] Keep `skip_value`'s allocation-free traversal for unreferenced nested
  values; do not regress narrow rows. Target: 2–10× lower Rust CPU on
  wide-row/multi-predicate scans.

---

## Priority 4 — Reduce write-transaction work inside Rust

`apply_batch_impl` (`rust/src/worker.rs`) opens the user table **twice per
Put/Delete** (once for `get`, once for `insert`/`remove`), does a separate
`table.get(key)` for the previous value, and `maintain_durable_index` opens
`__gecko_index` per mutation, linearly scans `index_definitions`, and builds a
fresh `Vec` per index key.

- [x] **Use `insert`/`remove` return values.** redb 4.1.0's
  `Table::insert(key, value)` and `Table::remove(key)` return the previous
  value (`Option<AccessGuard<V>>`). Drop the pre-`get` and the second
  `open_table`; halve lookups and read-lock acquisitions per op.
- [x] **Cache table handles per batch.** Keep a per-transaction
  `HashMap<String, Table>` so a large batch does not re-`open_table` (string
  compare + handle construction) per op.
- [x] **Batch durable-index maintenance.** Open `__gecko_index` once per
  batch; pre-index `index_definitions` by table (O(1) per op); pre-encode the
  stable `[table, field]` key prefix once per batch; pre-size
  `durable_index_key` and reuse a scratch buffer; compare old/new field
  values by `(start, end)` slice identity before allocating.
- [x] **Fix `table_definition` allocation.** It does
  `Box::leak(format!("{TABLE_PREFIX}{name}"))` on every call, everywhere
  (reads, writes, indexes, registry, stats). Replace with a worker-owned
  intern cache bounded by unique table names (one leak per table ever, not
  per op) or an API-compatible stable definition; add a long-running memory
  test that RSS does not grow with op count.
- [x] **`DeleteRange`/`Clear` amplification.** `apply_batch_impl` materializes
  full `(key, value)` vectors before removing rows and updating indexes, and
  `NativeRawBackend.applyBatch` pre-scans delete ranges. Measure memory/txn
  time at 1k and 100k deletes; define an explicit large-delete memory
  limit/backpressure policy instead of allowing process-sized allocations.
- [x] **Make change-log pruning incremental.** `prune_change_log` iterates the
  entire log, collects all non-dirty keys into a `Vec`, then prunes. A
  `watermark` value is already written to `__gecko_sync_meta` but is **not
  used to seek** — use it (or an oldest-clean high-water mark) to range-scan
  only the prunable prefix, count without collecting, and advance the
  watermark in the same transaction. Benchmark retention disabled/at
  limit/over limit with dirty and clean records.

---

## Priority 5 — Make ranges/prefixes truly selective (versioned index encoding)

The v1 `DefaultWireCodec` is not semantic-order-preserving for all indexed
values (negative ints, doubles, length-prefixed strings; encoded prefix is not
a semantic string prefix). `durable_index_bounds.dart` therefore uses exact
`eqBounds` for equality but broad `fieldBounds(table, field)` spans for
range/prefix, and Rust collects full `BTreeSet<Vec<u8>>` candidate sets,
rechecks predicates, and (in `query_indexed_ordered` non-eq mode) may append
missing-field rows via a **full table scan**.

- [x] **Design a separate, versioned order-preserving index-key encoding** for
  supported indexed types: sign-bit-flipped i64, total-order f64 with defined
  NaN/null policy, escaped/length-prefixed byte-lexicographic strings,
  timestamps. Add explicit type tags and unambiguous prefix boundaries.
  Never reinterpret existing index bytes silently; define migration/rebuild
  and repair behavior.
- [x] **Implement exact lower/upper bounds and reverse scans**; stop early for
  `limit`/`offset` when ordering proves correctness.
- [x] **Skip the predicate recheck when the index covers all filters**
  (`predicate.covers(index_fields)`); today every indexed candidate row still
  gets a row fetch + full predicate test.
- [x] **Remove the ordered-query fallback scan** with index presence/missing
  metadata once the encoding proves field completeness, or at minimum pre-size
  the `HashSet` and skip the scan when the window filled.
- [x] **Add a reverse index iterator** for descending sorts (m4 explicitly
  deferred this; today DESC without an eq bound uses top-K over a full scan).
- [x] **Composite indexes** (option): extend `durable_index_key` to
  `&[Field]` and let the planner pick the composite that is a prefix of the
  predicate's eq filters plus a range on the trailing field — serves compound
  predicates as one ordered scan instead of N single-field ranges + BTreeSet
  intersection.
- [x] **Improve candidate intersection** for multi-index: measure set sizes,
  use a smaller-first or sorted-iterator intersection that preserves
  deterministic output, and avoid materializing full sets where a streaming
  ordered intersection is safe.
- [x] **Push page size/offset into native limits** wherever semantics allow
  (currently sorted pages collect-then-slice and general indexed intersections
  accept no native limit); use keyset/cursor pagination for large offsets.
- [x] **Add a real planner cost decision**: count index entries visited vs
  candidates vs matched, estimate candidate span, and choose a full scan over
  a broad index when the index is expected to be worse. Add planner explain
  to diagnostics without putting it on the consumer hot path.
- [x] Add cross-language golden fixtures and crash/reopen/repair tests for
  every encoding change.

---

## Priority 6 — Make reactive delivery diff-first and efficient

`rust/src/registry.rs` stores a `BTreeMap` plus an optional sorted `Vec`
(`insert_sorted` uses `Vec::insert` — O(n) shift; `upsert_sorted`/
`remove_sorted` use `list.iter().position(...)` — linear scan per changed key
per batch). Every touched registration always materializes a full
`snapshot: Vec<ByteEntry>` (clone of keys **and** row bytes), and Dart
(`database_impl.dart`) decodes and maps the **full snapshot on every
emission** — including `watchAllDiff`, which also decodes `delta.snapshot`
even though it already has `added`/`updated`/`removed`.

- [x] **Send only deltas when the consumer needs them.** Extend the
  `WatchAllDiff` no-op suppression so diff-oriented consumers do not pay for a
  full snapshot clone/transfer/decode; keep a full-snapshot mode for callers
  that require it. If the stream contract changes, land it as a minor with a
  regression test.
- [x] **Pass post-commit row bytes to the registry.** `apply_batch_impl`
  knows the post-commit `Option<Vec<u8>>` per changed key; `registry.apply`
  currently re-reads each key via `read_key` (one redb lookup per key per
  registration). Hand the bytes over instead.
- [x] **Deduplicate affected `(table, key)` pairs** before registry
  evaluation (repeated keys arrive in one batch), while preserving
  final-state and diff semantics.
- [x] **Optimize sorted registries.** Evaluate a `BTreeMap<(encoded sort
  tuple, record key), row>` keyed by the sort tuple, or a Vec + key→index map
  so removal is O(log n); build initial sorted results by collect-then-sort
  once rather than per-row binary insertion. Preserve exact comparator
  semantics, missing/null ordering, and record-key tie breaking.
- [x] **Share changed-row reads among registrations** (one transaction-local
  post-mutation value per key per batch).
- [x] **Implement explicit backpressure.** `ChangeBus.maxBuffered` (1024) and
  `ChangeBusOverflowError` exist but the overflow policy (coalesce vs drop vs
  replay) is unspecified — define and test it, or document it as unsupported.
- [x] **Benchmark large watched results** (1/1k/10k/100k rows; one-row update,
  membership enter/leave, idempotent write, clear, sorted reorder, large
  batch). `benchmark/reactivity.dart` deliberately keeps each result set at
  exactly one row and cannot support large-watch claims.
- [x] **Measure windowed and relationship watches.** `limit`/`offset` queries
  currently fall back to full Dart re-evaluation; relationship
  `watchChildren`/`watchParent`/`watchJoinIds` should be measured before
  adding targeted invalidation or native registrations.

---

## Priority 7 — Read path, caches, and worker scheduling

- [x] **Fix negative lookup caching.** `RawEngine` stores `List<int>?` in the
  LRU; a cached missing value (`null`) is indistinguishable from a cache miss
  on read-back. Add an explicit missing sentinel or a hit-plus-nullable-value
  lookup result; bound negative entries separately; test repeated missing-key
  reads produce no backend call after the first.
- [x] **Invalidate only affected cache entries.** `commitBatch` clears the
  entire LRU after every committed batch even when one unrelated key changed;
  `rawPut`/`rawDelete` already invalidate selectively. Track affected
  tables/keys and clear only those (including clear/delete-range, metadata
  writes, and multi-table transactions); measure hit rate under
  stable-read + hot-write workloads.
- [x] **Reduce byte-key churn.** `ByteKey.bytes` returns a fresh `Uint8List`
  on every access, then native conversion copies it again. Profile before
  changing; keep the public immutability/equality/ordering contract.
  — Done: the boundary-side second copy was removed with the zero-copy
  transport (P2.3); `ByteKey.bytes` keeps its defensive copy because the
  public contract requires a caller-mutable result to never corrupt the
  key's equality/ordering.
- [x] **Verify model mapping stays a measured lower bound.** Time wire decode,
  map copy, and `fromRow` separately; do not promise end-to-end gains on
  workloads where model construction dominates.
- [x] **Measure worker contention.** `native_worker_client.dart` processes
  commands serially (`_nativeWorkerMain` awaits each dispatch), so a large
  scan blocks later reads, writes, snapshot disposal, and reactive delivery.
  Add queue-wait/service-time/op-size counters first; add priority or
  read-only worker(s) only after measured contention justifies it and the
  protocol/consistency contract supports it.
  — Done: queue-depth high-water + avg/max service time counters shipped
  (`DiagnosticsSnapshot.workerContention`). The conditional second half
  (adding a priority/read-only worker) was not triggered: the measured
  contention did not justify the protocol/consistency cost.
- [x] **Audit MVCC snapshot hygiene.** The worker keeps every `ReadTransaction`
  in `snapshots: HashMap` until `drop_snapshot`; a leaked snapshot pins all
  newer MVCC versions and blocks compaction. Audit that every Dart
  `snapshot()` is paired with `dispose()` in `try/finally` (raw paths do;
  check `_TxnImpl`, query paths, `bulkWrite`, sync paths); consider a
  max-open-snapshots cap/auto-release timeout and an idle auto-compact behind
  a flag.

---

## Priority 8 — Move remaining large sync/attachment/migration scans into Rust

- [x] **Sync transitions and `changesSince`.** `database_impl.dart` still
  scans/filters sync-state and change-log data in Dart (`_transition`,
  `changesSince`, `applyRemoteTransactional`, `applyRemoteDeletion`), with
  repeated point reads and `ids.any`/`ids.contains` checks. Add Rust
  primitives: state transitions by collection/id set, a native range-based
  `changesSince(lastSeq)` that decodes only required records, remote dedupe +
  accepted-record selection in one batch, and remote-deletion candidate
  selection from an encoded ID set. Preserve ordering, idempotency, conflict
  behavior, and change notifications.
- [x] **Reduce change-record write amplification.** Reuse encoded change-record
  bytes across change log and sync state; measure primary/metadata/index/total
  bytes per transaction.
- [x] **Make migrations bounded and resumable.** `_SchemaApiImpl.
  _rewriteRecords` scans all rows and builds one `ops` list in one commit
  despite comments describing chunks. Implement real chunking by row count/
  byte budget with durable progress metadata and idempotent restart.
- [x] **Attachment metadata.** `orphaned()` scans all metadata in Dart with
  one parent lookup per attachment; add Rust-side filtering and batched
  parent-existence checks (measure small vs large catalogs before adding
  parent-reference indexes).

---

## Priority 9 — Qualify encryption and Web/OPFS separately

- [x] **Encryption.** `rust/src/crypto_storage.rs` AES-256-GCM-encrypts each
  4 KiB page, allocates buffers, uses `Mutex<Aes256Gcm>`, draws a fresh
  `getrandom` nonce per page, and does read-modify-write for partial pages.
  Benchmark plain vs encrypted for point reads, scans, single/bulk writes,
  compaction, and key rotation; report pages read/decrypted/encrypted, crypto
  time, storage time, and boundary time separately. Only batch/optimize
  buffers or nonce handling after measuring, and never weaken authentication,
  nonce uniqueness, crash recovery, or key rotation. Never transfer plaintext
  gains onto encrypted numbers.
- [x] **Web/OPFS.** OPFS uses synchronous `FileSystemSyncAccessHandle` I/O
  (verified), and Web Worker messages are base64+JSON. Add browser benchmarks
  at 1k/10k rows separating Dart messaging, JSON/base64, JS/WASM glue, OPFS,
  and Rust execution; adopt transferable binary messaging; never extrapolate
  native Windows numbers to Web/OPFS.

---

## Priority 10 — Build, release, and artifact hygiene

- [x] **Release profile.** `rust/Cargo.toml` sets `lto = true` only. Add
  `codegen-units = 1` (cross-crate inlining on codec/predicate hot paths) and
  confirm `opt-level = 3`. Do **not** switch `panic = "abort"` without
  verifying redb's `Drop`-based rollback does not need unwinding. Keep
  `strip`/target-cpu changes policy-gated (AVX2 `x86-64-v3` is not safe for
  unknown consumer hardware without a compatibility decision).
- [x] **Artifact freshness.** benchmark helpers resolve
  `rust/target/release/gecko_db_rust.dll`, while cross-target builds emit to
  `rust/target/<triple>/release/` and the bundled artifact is separate — a
  stale-DLL risk (reconfirmed in the M3 notes: content-hash mismatch on every
  native open after a cross-target build). Make artifact selection explicit,
  verify the SHA-256/content id before every perf run, and always
  `dart run tool/build_artifacts.dart build <target> --out=build/native` then
  `bundle --from=build/native` after any Rust change.
- [x] **A/B compiler settings in isolated runs** and keep generated FRB +
  bundled artifacts synchronized.

---

## Success criteria (workload-specific, not one aggregate "10×")

| Workload | Target |
|---|---:|
| 1k–10k mutation bulk write | 5–10× end-to-end; worker request count bounded regardless of row count |
| Single durable put / txn commit | 2–4× (round trips + insert/remove return value); 10× only with an explicit, documented relaxed-durability mode |
| Hot cached read | preserve the cache floor; optimize only on demonstrated regression |
| Cold read | 2–3× (remove snapshot round trips) |
| 100k-row selective indexed equality | 2–5× (skip-recheck + transport) |
| 100k-row selective range/prefix | 5–10× with visited ≈ matched (order-preserving encoding) |
| Wide-row multi-predicate scan | 2–10× lower Rust CPU |
| Large result transfer | 3×+ lower latency or equivalent byte/allocation reduction (packed transport) |
| Large watched-result update | 5×+ with diff-oriented delivery; scale with changed keys, not result size |
| Sync log / migration | Rust filtering and bounded chunking; measure separately |
| Encrypted native / Web OPFS | establish baselines first; never merge into native plaintext numbers |

Acceptance rules for every optimization: before/after benchmark on identical
data/workload/build/hardware, p50+p95 reported, semantic parity + crash/
reopen tests, physical-work counters showing which layer improved, no database
semantics moved into Dart, public API snapshot updated via the contract tool
if the surface changes, and the full local release checklist green.

## Suggested order of work

1. Repair the benchmark/baseline/gate mismatch and add counters + scale matrix
   (Priority 1).
2. Remove `bulkWrite` N+1 and move LSN allocation into Rust (2.1, 2.2) — the
   biggest single write win.
3. Zero-copy transport + packed results + snapshot-round-trip removal
   (2.3, 2.4) — helps every workload; prove the floor with `boundary.dart`.
4. Single-pass, allocation-light field extraction (Priority 3) — pure CPU, no
   semantics change.
5. Write-transaction batching: `insert`/`remove` return values, table-handle
   cache, per-batch index maintenance, `table_definition` intern cache,
   incremental change-log pruning (Priority 4).
6. Versioned order-preserving index encoding + reverse scans + covered-filter
   skip + composite indexes (Priority 5) — the query gap.
7. Diff-first reactive delivery + sorted-registry + post-commit bytes
   (Priority 6).
8. Sync/attachment/migration scans into Rust (Priority 8).
9. Encryption and Web/OPFS qualified separately (Priority 9).
10. Build flags + artifact freshness + snapshot hygiene (Priority 7, 10),
    then refresh baselines only with reproducible metadata and reviewed
    before/after evidence.

## Rejected claims

These were proposed by one or more reviews but did not survive verification
against the code and the pinned `redb 4.1.0` crate. They are listed so they
are not re-proposed:

- **"The default redb cache is small; `set_cache_size` is the #1 lever for
  the 99 ms scan."** Wrong. In redb 4.1.0 (`src/db.rs`, `Builder::new`) the
  default `cache_size` is `1024 * 1024 * 1024` (1 GiB). A 1,000-row benchmark
  (~40 KB) is fully cache-resident; the 99 ms `rangeScan` is not disk-bound.
  The scan cost is transfer, decoding, mapping, and predicate evaluation.
- **"Tune `set_page_size` / `set_region_size` / a Bloom `set_lookup_filter_-
  size`."** `set_page_size` is `#[cfg(any(fuzzing, test))]` and
  `set_region_size` is `#[cfg(any(test, fuzzing))]` in 4.1.0 — neither is
  available in production builds, and there is no Bloom/lookup-filter API.
  Production builder surface is `set_cache_size` + `set_repair_callback`.
- **"Auto-ID does one max/range lookup per row; add a Rust-resident counter."**
  Wrong. `_nextAutoId` (`database_impl.dart`) already uses an in-memory
  per-table Dart counter map; no per-row DB lookup exists. (A separate
  correctness question — the counter is not persisted across reopen — is out
  of scope for a performance plan.)
- **"Transaction reads should consult a staged overlay; reuse one snapshot."**
  Already implemented. `_TxnImpl` holds one `RawSnapshot` and `readRaw`/
  `scanAll` apply the staged `_overlay` before the snapshot.
- **"`hotRead` cost is per-call FRB overhead."** Wrong — the hot read is a
  Dart `LruCache` hit and never crosses FRB. Use `boundary.dart` for boundary
  floor measurements.

## Things that are already good — keep them

- Full-scan predicate pushdown, native limited scans, `get_many` batched
  point reads, grouped relationship candidates in Rust (m11), count/distinct
  pushdown, top-K bounded sort, early LIMIT/OFFSET, index-ordered ascending
  streaming, `find_field_range` slice path, `skip_value` zero-alloc traversal,
  `WatchAllDiff` no-op suppression, one-writer batched commits, and coverage-
  marker syntax rules. Do not refactor these out while chasing micro-perf; the
  wins above are additive.

