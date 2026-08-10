# gecko-db — Project Plan

A local-first, reactive embedded database for **Dart and Flutter**, backed by `redb` (Rust) via
`flutter_rust_bridge`. Zero Rust, zero codegen, zero platform setup for consumers — `dart pub add gecko_db`
or `flutter pub add gecko_db` and it works everywhere.

> **How to read this document.** It has four parts:
> 1. **Design Principles & Contracts** (§0, §0.5) — permanent invariants, never change per-feature.
> 2. **What's Done** (§1) — a condensed history of Phases 0–13 + Workstreams 0–8 + Milestones 1–2,
>    each annotated ✅ with the ADR/test that proves it. A new dev reads this to learn the current
>    architecture without spelunking commits.
> 3. **What's Open** (§2) — the **Milestones** roadmap (this is the active TODO list; "Milestone"
>    replaces the old confusing "Phase" word, which is already used by Phases 0–13 above).
> 4. **Appendices** — traceability table, release checklist, ground rules, commands, file map.
>
> **Status legend:** ✅ done · ⏳ in progress · ☐ not started.

---

## 0. Design Principles (apply to everything below)

1. **No consumer-facing Rust, FFI, or build steps.** All FRB codegen and native compilation happens once,
   in the `gecko-db` repo's own CI, producing prebuilt artifacts. Consumers never run `cargo`,
   `flutter_rust_bridge_codegen`, or `build_runner`.
2. **No reflection-based or annotation+codegen modeling.** Models are plain Dart classes with a small,
   hand-written mapping function pair (`toRow`/`fromRow`). Normal Dart code, not a generation step.
3. **Progressive disclosure.** Tier 1 (box-style get/put/delete/watch) must be usable with zero knowledge
   of indexes, queries, relationships, transactions, or sync. Each later feature is strictly additive to
   the public API.
4. **One writer, many readers, always batched.** Every Rust-side mutation goes through a single
   long-lived worker owning the `redb::Database` handle. Dart never holds a transaction handle across an
   FFI/message boundary — a full batch of operations crosses in one call and is applied in one
   `WriteTransaction`.
5. **Coverage gate.** CI enforces line+branch coverage ≥ 95% for the Dart package (`dart test --coverage`,
   `format_coverage`, `tool/coverage_gate.dart`) and a Rust gate (`cargo llvm-cov`/`grcov`). Most
   invariants, crash tests, and performance logic live in Rust, so a Dart-only gate would not protect
   the engine.
6. **Everything is a file-format contract.** A database is a sequence of `(commit LSN → byte ranges,
   metadata, change records)` and must remain readable after crashes, restarts, and upgrades. All
   metadata (sync, indexes, attachments, migrations, conflict records) lives in reserved `__gecko_*`
   tables in the **same** redb file, written in the **same** transaction as the data that triggers it.

### Architecture (one-paragraph orientation)

There are two execution paths. **Native (VM):** caller isolate → `Isolate.spawn` worker isolate
(`packages/gecko_db/lib/src/worker/native_worker_client.dart`) → FRB → Rust `RedbWorker` (owns
`redb::Database`). **Web:** Dart `WebWorkerClient` → Dedicated Worker
(`packages/gecko_db/web/gecko_db_worker.dart`) → JSON protocol
(`lib/src/worker/web_worker_protocol.dart`) → FRB → wasm. Queries historically ran in **Dart**
(`lib/src/query/query_impl.dart`): every row decoded into a Dart map, copied, predicated in Dart.
**Milestones 1–2 (done)** moved the hot query path into Rust: indexed equality traverses the durable
`__gecko_index` table in one FRB hop (`RedbWorker::query_indexed`), and unindexed scans push the
predicate to Rust (`RedbWorker::query_filtered` + `value_codec.rs` + `predicate.rs`). Dart now acts as
a client for the read/query path on the native backend. The Dart in-memory backend is retained only as
a transitional reference implementation until M7.5; the final supported paths are Rust-owned native
files and Rust/Wasm OPFS files.

---

## 0.5 Cross-Cutting Contracts & Correctness Notes

These constraints are imposed by the technologies we chose, not by taste. Re-read wherever a milestone
references them; where older text conflicts, the contract wins.

1. **`redb::StorageBackend` is a byte-range interface, not page-based.** No "page was freed" callback,
   no rename. OPFS storage and transparent encryption sit **below** a page scheduler; secure deletion
   is explicitly **out of scope** (no callback to know a byte range was freed) — mitigated by
   full-disk encryption / SSD wipes, documented honestly.
2. **Encryption/compression must be length-preserving per page.** The sole pre-release encryption
   mechanism is optional native Rust AES-256-GCM: 12-byte nonce + 16-byte tag in page slack,
   ciphertext replaces payload. A wrong key surfaces as a typed `DecryptionError`, never silently
   wrong data. Native-file encryption is supported; Web OPFS remains file-backed but unencrypted;
   there is no in-memory database mode.
3. **Sync scope.** Only the local transactional change-tracking metadata + local conflict resolution are
   in scope. The transport (HTTP, SQLite, CRDT…), identity, and conflict *policies* are out of scope.
4. **Concurrency & lifecycle.** One worker per file; cross-process exclusion is redb's OS lock;
   same-process duplicate open is a typed `DatabaseAlreadyOpenError`. Worker-isolate lifetime is a
   keepalive + `Finalizer`; the Rust worker dies when the isolate sends close/teardown.
5. **No second persistence system, ever.** All metadata lives in reserved `__gecko_*` tables in the same
   redb file, in the same transaction as the data.
6. **Standard, platform-robust wire types.** `int64`/`BigInt`, doubles, 64-bit timestamps exactly. On
   Web, no 64-bit integer transits through JS number arithmetic — the wasm boundary is bigint-aware.

---

## Repository & Package Layout

| Package | Type | Purpose |
|---|---|---|
| `gecko_db` | Pure Dart | Public API: `Database`, `Collection`, `Query`, `Transaction`, `Change`, `SyncState`. Platform-agnostic. |
| `gecko_db_rust` (rust/) | Rust (unpublished) | `redb` wrapper: worker, indexing, change tracking, encryption, query fast path. Compiled only in CI. |
| `gecko_db_android` / `_ios` / `_macos` / `_windows` / `_linux` | Flutter federated plugins | Bundle prebuilt native library (artifact matrix in `tool/build_artifacts.dart`). |
| `gecko_db_web` | Federated plugin + wasm asset | Bundles the compiled wasm engine + OPFS Web Worker glue. |

Bundled artifacts live under `packages/gecko_db/lib/native/{windows,android,web}/…`. The Windows x64 DLL
is built + bundled in-repo; other platforms are built in CI (`.github/workflows/release-matrix.yml`).

---

## 1. What's Done (history — read this to understand the current architecture)

The project was built in three waves. Each item is ✅ and names the ADR/test that proves it; the
**active TODO list is §2 (Milestones)**, not this section.

### Wave A — Phases 0–13 (the original plan; core engine through polish)

All ✅. The table names the subsystem + key proof; consult the named ADR/test files for detail.

| Phase | What | Key ADRs / proof |
|---|---|---|
| 0 | Foundations: public API shape, `Op` wire format, error taxonomy, coverage gate, traceability | ADR-0001 manual mappers; ADR-0002 wire v1; ADR-0004 error envelope; `tool/api_snapshot.dart`, `tool/coverage_gate.dart` |
| 1 | Zero-setup cross-platform distribution: federated plugins, native resolver, OPFS web worker | ADR-0012 artifact matrix, ADR-0013 web glue; iOS explicitly CI-pending (see M9) |
| 2 | Core engine: Rust `redb` worker, single-writer, MVCC, historical in-memory backend, crash recovery | ADR-0003 worker isolate, ADR-0005 client+finalizer, ADR-0006 MVCC snapshots; `phase2_*` tests; M7.5 removes the Dart backend before release |
| 3 | Codegen-free typed modeling: `RowSchema`, `toRow`/`fromRow`, patch, auto-ids, Tier 1 API | `phase3_integration_test.dart`, `row_schema_test.dart` |
| 4 | Reactivity: `watch(id)` / `watchAll()` / `database.watchAll()` streams | `watch_test.dart` |
| 5 | Query engine + indexing (Tier 2): filters, sort, pagination, count/distinct, durable indexes | ADR-0008 durable indexes; `query_test.dart`, `phase5_index_ws3_test.dart` |
| 6 | Relationships (Tier 3): FK helpers, delete behaviors, eager load, cycle detection, reactive relations | `phase6_relations_ws3_test.dart` |
| 7 | Transactions, change tracking, sync hooks | `phase7_transactions_sync_test.dart` |
| 8 | Conflict resolution against sync metadata | `phase8_conflict_test.dart` |
| 9 | Attachments & file-reference metadata (blob de-dup) | `phase9_attachments_test.dart` |
| 10 | Schema versioning & migrations (additive + breaking, open-time gate) | `phase10_migrations_test.dart` |
| 11 | Encryption at rest: physical AES-256-GCM (Rust) + raw-key rotation; historical logical layer removed by M6.5 | ADR-0009, ADR-0022; `phase11_crypto_ws4_test.dart` |
| 12 | Performance, compaction, diagnostics: `bulkWrite`, LRU, slow-query logging, maintenance machine | ADR-0010; `phase12_*` tests |
| 13 | API polish, docs, examples, compatibility matrix, consumer fixture | ADR-0011; `examples/`, `tool/docs_examples_test.dart`, `tool/consumer_fixture_test.dart` |

### Wave B — Workstreams 0–8 (production qualification)

All ✅ except two explicitly-deferred items (noted ☐).

- **WS0–2** ✅ Contract lock, native worker lifecycle, and historical backend differential/conformance
  (in-memory ↔ native parity via `raw_backend_contract_test.dart` + `phase2_differential_test.dart`).
  M7.5 replaces this transitional Dart-memory comparison with native-file and Web/OPFS contract tests.
- **WS3** ✅ Durable indexes + relationships (`__gecko_index`, drift repair, reactive relations).
- **WS4** ✅ Physical encryption (AES-256-GCM per page, raw-key contract, rotation crash matrix).
  M6.5 removes the historical key-provider and logical-encryption layers before release.
  ☐ Overflow-page data/tag atomicity — tracked, no dedicated test (redb writes overflow through the same
  encrypted path).
- **WS5** ✅ Compaction (in-place `Database::compact`, 5-state machine), diagnostics (slow-query,
  counters, `QueryStageTimings`).
- **WS6** ✅ API/docs/examples/compat (`docs/api.md`, `migration-from-hive.md`, `policies.md`,
  `compatibility.md`, traceability checker).
- **WS7** Cross-platform matrix: Windows x64 + 4 Android ABIs + web ✅ built/bundled; Linux/macOS CI
  jobs ✅; **iOS ☐ CI-pending** (needs FRB iOS plugin scaffold — carried into M9).
- **WS8** ✅ Reliability/security/perf qualification: randomized (4 seeds × 120 steps; long 24×800),
  crash-injection, parallel, differential, large-data (100k+), soak, perf baselines, security review.
  494+ package + 32 tool tests; 95% line / 100% branch coverage gate.

### Wave C — Milestones 1–2 (the query-path instrumentation + native fast path) ✅

These replaced the original "Appendix — Remaining Work" (which confusingly used "Phase 1/2/3" alongside
the already-done Phases 1–3 of Wave A). **All done.**

| Milestone | What | ADR | Measured result |
|---|---|---|---|
| **M1** Instrument the read/query path | `benchmark/boundary.dart` (per-layer latency), `QueryStageTimings` (8 query-path stages on `SlowQueryRecord.timings`), `benchmark/query_profile.dart` (1k/100k split) | ADR-0015 | FRB floor ~18–19µs dwarfs redb's get; full-scan 100k `backendRead` 70%, indexed eq `backendRead` 88% (N+1) |
| **M2 Native query fast path** | (a) `RedbWorker::query_indexed` — durable-index traversal in one hop (kills N+1); (b) `RedbWorker::query_filtered` + `value_codec.rs` (Rust port of `DefaultWireCodec`) + `predicate.rs` (predicate evaluator) — push predicate to Rust | ADR-0016 (indexed), ADR-0017 (predicate push) | Indexed eq 100k: 38ms→12ms (3.2×); full-scan 100k: 482ms→39ms (**12.4×**, meets ≥10× target) |
| **M3** Read-path completion + `getMany` | (a) route `iterate()` through `_scanWith` (deleted the `_streamUnsorted` per-id loop); (b) aggregate pushdown `query_filtered_count` / `query_filtered_distinct` (+ `value_codec::find_field_range`); (c) public `Collection.getMany(ids)` = `RedbWorker::get_many` (one read txn, N keys); (d) relationship `children` batches through `snap.getMany` | ADR-0018 | `count()`/`distinct()` on native transfer zero rows (count) / one field-slice per row (distinct); `getMany` kills the relationship N+1; all read paths now use the native fast path || **M4–M7** Query optimization + architecture | Indexed sort/limit, indexed filter intersection, worker/encryption architecture decisions, pre-release encryption simplification, native execution ownership | ADR-0019–0023 | M4 indexed sort+limit 154µs median on 100k; M5 multi-eq ~1.0ms but broad range/prefix bounds remain slower than full scan; M6 isolate 57.3µs vs direct FRB 25.1µs and logical encryption 121.6ms vs plain 4.4ms; M7 Rust index repair + native FK lookup/predicate push |
**Known gaps after M2 — closed by M3 (ADR-0018):**
- `iterate()` / `count()` / `distinct()` / `first()` / `findPage()` on native now **use the native
  fast path** (`iterate` via `_scanWith`; `count`/`distinct` via aggregate pushdown; `first`/`findPage`
  were already routed via `_scanWith`).
- The 1k `< 1ms` indexed target is ~1.7ms (FRB boundary floor; deferred to the M6 arch decision).

### Current test / ADR inventory

- **68 Dart test files** in `packages/gecko_db/test/` (phase0–14, query, relationship, backend,
  predicate_codec, durable_index_bounds, m3_read_path, etc.).
- **22 ADRs** in `docs/adr/` (0001–0022).
- **Rust unit tests** in `rust/src/{worker,value_codec,predicate,wire,format_header,compatibility,
  crypto_storage}.rs` + integration tests in `rust/tests/`.
- Gates (all green on `origin/main` before M6.5 implementation): `dart analyze`,
  `dart test packages/gecko_db/test` (539 tests), `dart test tool` (32),
  coverage 95% line / 100% branch, `tool/coverage_gate`, `tool/offline_lint`,
  `tool/security_review`, `tool/traceability_check`, `tool/api_snapshot`, `tool/build_artifacts
  check-bindings`, `cargo check`/`test`/`clippy -- -D warnings`/`fmt --check`.

---

## 2. What's Open — the Milestones roadmap

> **Naming note.** Earlier versions called these "Phase 1–8" in an appendix, which collided with the
> already-done Phases 1–13 in §1. They are now **Milestones** (M1–M6.5 done; M7 core done; M7.1 next;
> M7.5 follows; M8–M10 open). Each milestone has a goal, concrete steps, a "done when" check, and —
> where it moves Dart→Rust — an ROI note and the Rust tests + Dart deletions it requires.
>
> **Ordering.** M3 gates M4–M7 (read-path completion must finish before sort/limit/migration cleanup
> build on it). M7 must establish the native execution boundary before M8 changes reactivity semantics.
> **M9 can start immediately in parallel** with anything.

### M3 — Read-path completion + `getMany` (projection & batch reads)  ✅ done (ADR-0018)

**Goal:** finish what M2 started — make every read path go through Rust on native, and collapse the
remaining N+1 reads (relationships) into batched calls.

**Status:** All done-when items landed (508 tests green, both backends): `iterate` routes through
`_scanWith` (the `_streamUnsorted` per-id loop is deleted); `count`/`distinct` push the aggregate to
Rust on native (`query_filtered_count` / `query_filtered_distinct`); `getMany` is public + tested
(one `get_many` Rust call per batch); relationship `children` batches through `snap.getMany`.

**Steps:**
1. ✅ **Route `iterate()` / `count()` / `distinct()` / `first()` / `findPage()` through the native fast
   path.** (`findPage` + `first` already delegate to `_collect`; `count`/`distinct`/`iterate` now use
   the Rust path — see step 3.)
2. ✅ **Add `getMany(keys)`** — a public batched point-read: one Rust call fetches N keys in one read
   transaction, returning `(key → row)` pairs. Kills the relationship N+1 that `RelationshipManager`
   paid via per-id `lookupEq` + `snap.read`.
3. ✅ **Aggregate pushdown:** `count()` returns just a count (no row transfer); `distinct(field)` returns
   just the distinct value-set. `query_filtered_count` / `query_filtered_distinct` stream-scan and emit
   only the aggregate.
4. ☐ **Projection (field-selective decode) — DEFERRED to M4.** Not in M3's done-when; it needs a public
   `select(fields)` surface on `Query` whose output is a projected row (not `T`) — a public-API design
   decision. The Rust primitive (`find_field_range`, added for distinct) already supports slicing a
   single field's bytes; a projection-spec is an FRB argument, not a wire-format change. Tracked in
   ADR-0018 Consequences.
5. ✅ **Route relationship eager-loading through `getMany`** — the per-child `snap.read` in
   `RelationshipManager._childRowsFrom` is now one `snap.getMany` batch.

**Dart deletions enabled:** the per-id `snap.read` loop in `_streamUnsorted` (the `iterate()` path) is
**deleted**; the Dart predicate eval (`FilterGroup.test`) stays for the **in-memory backend only** (it
has no Rust). Do NOT delete `Filter`/`FilterGroup` — they're the public authoring API that
`encodePredicate` reads.

**Rust tests required:** `get_many` (N keys, missing keys, empty, missing table); `query_filtered_count`
/ `_distinct` against known datasets — all landed in `rust/src/{worker,value_codec}.rs`.

**Done when (met):** `getMany` is public + tested; `iterate`/`count`/`distinct`/`first`/`findPage` on
native use the Rust path (asserted via `IndexPlan.nativeFilteredScan` + parity tests); relationship
loads use `getMany` (no per-id reads in a profiler); parity tests pass
(`packages/gecko_db/test/m3_read_path_test.dart`).

### M4 — Indexed sorting and early LIMIT  ✅ done (ADR-0019)

**Goal:** `WHERE … ORDER BY indexedField LIMIT 20` on 100k rows < 5 ms — no materialization, no sort.

**Steps:**
1. ✅ **Sort push to Rust:** when sort fields are covered by an index, stream keys from the durable index
   in order (the composite keys are already byte-ordered). Rust's `query_indexed_ordered` streams the
   index window in order and stops early; for non-indexed sorts, `query_sorted` runs a Rust-side
   `sort_compare` (port of Dart `compareFieldValues`) + a bounded top-K heap (`offset + limit`).
2. ✅ **`limit`/`offset` during scan** — `query_filtered_limited`/`query_indexed_limited`/`query_sorted`/
   `query_indexed_ordered` accept `limit`/`offset`; Rust stops scanning at the limit, never materializes
   the full set.
3. ✅ **Dart sort elimination on native:** when the sort is index-covered, Dart receives pre-sorted +
   limited results from `_nativeOrderedCollect` — `compareRows` / `decoded.sort` are bypassed on native
   (kept for in-memory parity). All Dart `decoded.sort` call sites now use a record-key tie-break so
   native index order, Rust top-K, and in-memory sort agree exactly.

**Dart deletions enabled:** `compareRows` / `decoded.sort` in the index-covered-sort path (native only);
the `_collectOrdered` materialize-then-slice is replaced with the native streaming limit on native.

**Rust tests required:** ✅ `sort_spec` wire round-trip + `compare_rows`; indexed-ordered asc/desc
early-stop + missing-field append; top-K vs a Dart full-sort oracle; limit/offset edge cases (0,
negative, > result count).

**Done when:** ✅ `ORDER BY indexedField LIMIT 20` on 100k = **110–209 µs** (< 5ms); ordered/limited
queries no longer materialize the full candidate set; results match the current Dart plans exactly
(parity test vs in-memory full-sort — 14 new tests in `m4_sort_limit_test.dart`).

### M5 — Range/prefix/multi-eq indexed fast path  ✅ done (ADR-0020)

**Goal:** extend the M2 indexed-eq fast path to the remaining index-usable filters, so they skip the
full scan instead of going through `query_filtered`.

**Steps:**
1. ✅ **Durable candidate bounds:** exact equality filters use `eqBounds`; range and prefix filters use
   broad `fieldBounds(table, field)` spans. `DefaultWireCodec` v1 is not semantic-order-preserving
   for every supported value, so M5 intentionally does not invent unsafe `rangeBounds`/`prefixBounds`.
2. ✅ **Multi-index intersection in Rust:** `query_indexed_multi` scans all covered durable-index ranges,
   intersects row-key sets in one MVCC read transaction, joins rows, and rechecks the complete predicate
   in Rust. This covers multi-eq and mixed equality + range + prefix filters.
3. ✅ **Aggregates:** covered range/prefix/multi-eq `count()` and `distinct()` retain the indexed route;
   uncovered filters continue through native predicate push.

**ROI note:** Range/prefix already worked correctly through Rust predicate push; M5 now avoids the
full primary-table scan and Dart per-id loop for covered candidates while keeping exact parity through
Rust predicate re-evaluation.

**Done when:** ✅ covered range/prefix/multi-eq use `IndexPlan.secondaryIndex` and the durable candidate
route; native/in-memory parity tests pass; Rust intersection and predicate-recheck tests pass; full
package suite remains green.

### M6 — Architecture decisions, measured  ✅ done (ADR-0021; encryption retention superseded by ADR-0022)

**Goal:** settle two open architecture questions with data (M1 boundary numbers are the input).

1. **Worker-isolate cost:** fresh boundary measurement shows `isolateRoundTrip` **57.3µs** vs
   direct FRB **25.1µs** (+32.3µs marshalling).
   Decide whether the worker isolate earns its keep (UI-thread offload, hot-restart/GC stability, FFI
   off the UI isolate) vs an opt-in direct-FFI mode. Any removal must be opt-in, preserve the
   single-writer rule, and pass crash/reopen + hot-restart suites. **Also decides the 1k `< 1ms`
   indexed target** (the FRB floor is the blocker).
   **Decision:** retain the worker isolate as the default; do not add a direct-FFI mode in M6. The
   ~32µs premium is below the 1k-row query budget and buys UI-thread offload, single-writer ownership,
   deterministic teardown, and crash/reopen qualification. An opt-in direct mode remains deferred
   until a measured workload shows the boundary is the bottleneck.
2. **Encryption layering:** M6 measured the Dart logical-encryption layer at plain native median
   **4.4ms** versus logical-encrypted median **121.6ms** (~27.5×). M6.5 now supersedes the initial
   retention decision: because the product has no released consumers, remove logical encryption and
   custom/provider surfaces before release rather than preserve the expensive second layer. Physical
   Rust encryption remains the sole supported encryption mechanism.

**Done when:** ✅ both decisions are recorded in ADR-0021 with measured justification.

### M6.5 — Rust-only encryption simplification  ⏳ next (ADR-0022)

**Goal:** simplify the pre-release encryption contract from two encryption layers and extensible
providers into one optional native Rust physical-encryption mechanism. Encryption is off by default,
enabled only by a raw 32-byte key, and unavailable on Web/in-memory backends. Public raw-key rotation
remains. No released-consumer migration is required.

**Target contract:**

- no key → native file uses ordinary plaintext redb pages;
- raw 32-byte `encryptionKey` → native file uses Rust AES-256-GCM physical page encryption;
- no logical per-value encryption, custom crypto algorithms, crypto registry, key-provider abstraction,
  text key encodings, or user-supplied encryption method;
- `rotatePhysicalKey(oldKey, newKey)` remains public and crash-recoverable;
- encryption requested for Web or in-memory is rejected explicitly with a typed error;
- query execution is identical for encrypted and unencrypted native files because encryption is below
  Rust/redb, not an encrypted Dart `RawBackend` wrapper.

**Steps:**
1. ✅ **Lock the API and format policy.** Adopted the single raw-key contract, native-only behavior,
   default-off policy, retained public rotation, and no logical-encryption compatibility migration.
2. ✅ **Delete logical encryption.** Removed `EncryptedRawBackend`, logical envelopes, `CryptoBackend`,
   `CryptoPage`, `Aes256GcmCryptoBackend`, registry methods, and wrapper-specific error branches.
3. ✅ **Simplify `DatabaseConfig`.** Removed `cryptoBackendName`, logical/physical layering,
   `KeyProvider`, `KeyEncoding`, provider resolution, and the old `physicalEncryptionKey` naming;
   retained one optional raw `encryptionKey` plus the generation value needed for rotation recovery.
4. ✅ **Simplify native open.** Validates exactly 32 raw bytes before file access, passes them directly to
   Rust physical storage, rejects keys on Web/in-memory, and preserves typed wrong/corrupt-key and
   read-only behavior.
5. ✅ **Preserve public key rotation.** Kept raw old/new key validation, closed-file requirements,
   generation handling, atomic sibling swap, interruption recovery, and no key persistence/logging.
6. ✅ **Remove obsolete public exports and tests.** Updated `gecko_db.dart`, API snapshot, physical
   encryption tests, dependent tests, examples, and error expectations; removed logical-encryption tests.
7. ☐ **Qualify security and storage behavior.** Cover encryption-off plaintext, encryption-on secrecy,
   wrong keys, tampering, reopen, compaction, snapshots, indexes, query pushdown, rotation, interrupted
   rotation, and explicit unsupported Web/in-memory behavior.
8. ☐ **Measure performance.** Replace the logical-wrapper benchmark with plaintext versus Rust physical
   encryption measurements for writes, indexed reads, scans, compaction, and rotation. Confirm M4/M5
   query routes remain available when physical encryption is enabled.
9. ☐ **Update all documentation.** Rewrite ADR-0009 historical scope, ADR-0021's superseded decision,
   `README.md`, `CHANGELOG.md`, `docs/api.md`, `docs/policies.md`, `SECURITY.md`, `improvements.md`,
   examples, and compatibility/release notes.
10. ☐ **Run release gates.** Run API snapshot/contract, traceability, full Dart/Rust tests, coverage,
    security review, offline lint, artifact/binding checks, crash/reopen tests, and the native/Web/
    in-memory matrix.

**Dart deletions expected:** approximately 300–450 production lines and 250–400 encryption-specific
 test lines, plus obsolete exports/documentation. The exact count is recorded after implementation.

**Rust changes expected:** primarily API/configuration integration and test updates; approximately
50–150 lines changed or added. No second logical encryption implementation is planned.

**Why this simplification is justified:** M6 measured logical encryption at 121.6 ms median versus
4.4 ms plain native for a 10k-row indexed equality workload (~27.5× overhead). There are no released
consumers, so removing the unfinished logical/custom-provider surface avoids migration burden while
making every native query use the same Rust path.

**Done when:** the single raw-key/native-only contract is implemented and documented; public rotation
and physical-format compatibility remain; logical/custom/provider surfaces are gone; encrypted native
queries retain M4/M5 routes; all security, parity, API, coverage, and release gates pass.

### M7 — Native execution ownership and Dart cleanup  ✅ core slice done (ADR-0023); remaining work moved to M7.1

**Goal:** make Rust the authoritative execution engine for native databases while keeping Dart as the
public API, model-mapping, reactive, migration-callback, and transitional in-memory reference layer.
M7.5 then removes that reference backend from the product; M7 must not make final architecture decisions
that depend on `InMemoryBackend` surviving release. Remove only
Dart execution logic that duplicates a proven Rust native path; do not move code merely to reduce the
Dart line count.

This is **not** "move everything to Rust." During M7, the in-memory backend may remain as a temporary
semantic differential oracle; M7.5 removes it after native execution ownership is proven. Web uses the
Rust/Wasm path through its existing OPFS worker. Every move
must satisfy all four gates: (a) it is on a native hot path, (b) the Rust path has equal or stronger
coverage, (c) snapshot/error/diagnostic semantics are preserved, and (d) native/in-memory parity passes.

**Required native route matrix:** before deleting any Dart path, document and test every read operation
as native Rust, in-memory Dart reference, or Web Rust/Wasm. Each route records its `lastPlan`, snapshot
boundary, backend hop count, rows transferred, and typed-error behavior. This matrix is part of M7's
completion evidence.

**Candidates and required decisions (in ROI order):**

| Candidate | Why | M7 action | Rust/native proof |
|---|---|---|---|
| **Secondary-index rebuild at open** | Native currently rebuilds a complete Dart `SecondaryIndex` from `__gecko_index`, duplicating durable state and adding an open-time full scan. | Remove the native Dart rebuild/readiness dependency during M7; retain it only as a temporary reference until M7.5 removes the Dart backend. Decide and implement one authoritative native repair/verification path. | 100k+ open-latency benchmark; stale/missing/extra index repair; put/update/delete/bulk-write atomicity; concurrent reopen/crash tests. |
| **Durable-index maintenance ownership** | Removing the Dart index cache is safe only if durable index writes and repair remain authoritative and atomic. | Audit `_durableIndexOps`, bulk writes, deletes, updates, prefix entries, drift repair, and transactions. Prefer moving maintenance/repair into Rust if that is required to eliminate split authority; otherwise document the temporary boundary explicitly. | Rust tests for index/data atomicity, replacement, deletion, bulk batches, missing tables, stale repair, and rollback. |
| **Native aggregate paths** | M3 already added Rust count/distinct, but Dart fallback branches can silently reintroduce materialization. | Audit `count()`/`distinct()` for unindexed, exact-eq, M5 multi-index, sorted/limited, and snapshot-bound queries. Delete redundant native Dart loops; retain only temporary reference coverage until M7.5. | Result/order parity, plan attribution, zero/full row-transfer assertions, snapshot consistency. |
| **Native relationship reads** | `children()` still combines Dart index metadata with `getMany`; `parent()` decodes in Dart; `loadAllChildren()` scans and filters in Dart. | Move candidate retrieval and batched child/parent reads to Rust where a stable snapshot-bound operation is beneficial. Keep relationship declarations, delete behaviors, and public policy in Dart. Prioritize `loadAllChildren()` full-scan avoidance. | Native/Web parity, missing/stale FK behavior, snapshot consistency, N+1/backend-hop benchmark, delete-policy regression tests. |
| **Native raw-backend adapters** | `NativeRawBackend`/`NativeRawSnapshot` contain repeated Dart tuple conversion and native-path branching accumulated across M2–M6. | Audit direct worker calls, snapshot lifecycle, non-snapshot helpers, error mapping, diagnostics, and duplicated conversion/filter logic. Remove only redundant native execution code. | Raw-backend contract, finalizer, close, read-only, MVCC snapshot, typed-error, and Web protocol tests. |
| **M3/M4 completed paths** | Sort/top-K/indexed ordering, `getMany`, and basic aggregate pushdown are already implemented. | Treat these as audits/regression guards, not new migrations. Remove stale comments or dead fallback branches only after route-matrix proof. | Existing M3/M4 Rust tests plus parity and plan assertions. |
| **M8 handoff primitives** | Change-feed invalidation currently broadcasts batches and queries re-evaluate in Dart. A Rust query registry would change lifecycle and reactive semantics. | Do not build a persistent Rust query registry in M7. Expose only measured primitives needed by M8: changed row keys, changed indexed fields, and batch metadata. | Coalescing, ordering, cancellation, close, backpressure, and replay contract remains unchanged. |

**What stays in Dart (do not move in M7):**

- `Filter` / `FilterGroup` / `Filter.eq/between/prefix` — the public query-authoring API; `encodePredicate`
  serializes them for Rust.
- `toRow`/`fromRow` model mapping and typed collection APIs.
- Migration callbacks (`MigrationStep.upgrade` and `RecordRewriter`); Rust may own bounded streaming,
  snapshots, and atomic batches, but cannot execute arbitrary user Dart callbacks.
- Reactive stream objects, subscriber lifecycle, cancellation, backpressure, and public change models.
- Relationship declarations and delete-policy decisions; Rust may own candidate retrieval/traversal.
- The in-memory backend's full Dart query path and the worker-isolate transport.

**M7 implementation sequence:**

1. ✅ Inventory the native/in-memory/Web route matrix and capture before metrics.
2. ✅ Remove native `SecondaryIndex` rebuild dependency and define durable-index repair ownership.
3. ✅ Move durable-index verification/repair to Rust via `repair_index`; prove atomicity with drift tests.
4. ✅ Audit native aggregates and raw adapters; existing M3/M4 Rust routes remain authoritative.
5. ✅ Add native relationship child primitives: durable indexed FK lookup and Rust predicate push fallback.
6. ☐ Add only the M8 handoff primitives; leave query registration and invalidation policy to M8.
7. ✅ Convert the completed native ownership changes into thin contract/parity tests; retain the
   temporary in-memory reference tests only until M7.5 removes the backend.
8. ✅ Run regression, coverage, Rust, security, traceability, artifact, and performance gates for the
   completed core slice.

**Core slice done when:** ✅ native has Rust-owned index repair and query execution; no native Dart index
rebuild remains; native indexed relationship children use Rust durable lookup/predicate push; M3/M4
behavior is unchanged; route, snapshot, error, diagnostics, parity, coverage, FRB, Rust, security,
traceability, and performance gates pass. M7.5 remains the final removal of the temporary Dart
reference backend; remaining M7 work is the route-matrix completion and M8 handoff, not a new query
registry.

### M7.1 — Remaining Dart→Rust migration slices  ☐ after M7 core

**Goal:** complete the Dart-thinning work that M7 core intentionally left behind. These slices are
ordered so every removal has a Rust replacement, native snapshot/error/diagnostic parity, and a focused
before/after benchmark. M7.1 must finish before M7.5 removes the transitional Dart reference backend.

**Slice 1 — Durable index maintenance ownership ✅**

Moved `_durableIndexOps` and its mutation/bulk/transaction integration from Dart-generated `RawOp`s into
Rust's atomic write path. Rust receives native index declarations, derives old/new indexed field values
from encoded primary rows, and applies index deletes/inserts in the same redb write transaction. The
existing wire/file format is unchanged; equality and prefix declarations retain their full-value durable
entries and query-bound semantics. Dart keeps declarations/metadata and the temporary in-memory
reference index, but no longer constructs durable index mutations for native writes.

**Proof:** Rust tests cover put/update/delete, missing fields, repeated-key bulk sequencing, rollback on
batch validation failure, stale repair, and index/data atomicity; focused native index/reopen/drift tests
and the full 528-test package suite pass. Crash/reopen coverage remains in the existing native batch
and worker qualification tests; explicit index-enabled crash injection remains follow-up coverage.

**Slice 2 — Native aggregate and raw-adapter cleanup ✅**

Native `count()` and `distinct()` now use snapshot-bound Rust durable-index candidate aggregates for
indexed equality/range/prefix/multi-equality routes, while unindexed routes retain Rust predicate
pushdown. Matching primary rows are no longer transferred to Dart merely to count or extract distinct
values. Native routing no longer performs the transitional Dart candidate lookup; in-memory routing is
unchanged. Delete-range pre-scans and `lastCommitSeq()` now dispose their native snapshots reliably.

**Proof:** focused M3 aggregate, native snapshot, durable-index, and raw-backend suites pass (73 tests);
full package and Rust validation passes; `lastPlan`, stage timings, snapshot cleanup, typed errors, and
Web/shared-dispatch behavior remain covered.

**Slice 3 — Native relationship retrieval ✅**

Moved the remaining expensive relationship reads to snapshot-bound Rust primitives:

- `parent()` → Rust child FK extraction plus parent point read;
- `loadAllChildren()` → one Rust operation using the union of indexed FK ranges or Rust-side FK matching;
- many-to-many `rightIds()`/`leftIds()` → Rust snapshot join scan/filter.

Dart retains relationship declarations, delete behaviors, policy decisions, model mapping, and reactive
stream lifecycle. Rust executes no arbitrary Dart relationship callbacks.

**Proof:** native/in-memory relationship suites pass, including indexed and unindexed child retrieval,
parent updates and missing rows, many-to-many IDs, reactive watches, snapshot consistency, and delete
policy behavior. Rust relationship primitive coverage passes.

**Slice 4 — Native route matrix and M8 handoff ✅**

Documented the native file/Web-Wasm/in-memory route matrix in `docs/native-route-matrix.md`, including
plan, snapshot boundary, backend hops, transferred rows, typed errors, diagnostics, and the limited M8
handoff metadata. No Rust query registry or reactive query registration was added.

**Proof:** shared native dispatch is used by native and Web-Wasm paths; generated FRB bindings and
relationship/aggregate route tests pass. Change-feed/LSN ordering, migration callbacks, model mapping,
relationship policies, and reactive lifecycle remain Dart-owned.

**Slice 5 — Thin-client deletion pass ☐**

After Slices 1–4 are proven, delete obsolete native Dart execution branches and comments, retain only the
Dart public API/model mapping/migration callback/reactive layers, convert deleted tests into native/Web
contract tests, and measure Dart LOC, native open latency, backend hops, rows transferred, memory, and
query latency before/after.

**M7.1 done when:** all five slices have Rust tests and native/Web contract coverage; native durable index
writes and repair have one Rust authority; no native Dart materialization remains for aggregates or the
selected relationship operations; migration callbacks and public/reactive semantics remain Dart-owned;
the route matrix and M8 handoff are documented; coverage, parity, security, FRB, Rust, and release gates
pass. M7.5 then removes the Dart `InMemoryBackend` and public in-memory mode.

### M7.5 — File-backed Rust engine consolidation  ☐ after M7.1

**Goal:** remove the Dart `InMemoryBackend` and the public in-memory database mode while preserving Web
support through the Rust/Wasm + OPFS file-backed path. After M7.5, every supported database is backed
by Rust/redb and a file-like persistent store; Dart no longer contains a second storage/query/index
engine.

**Product contract after M7.5:**

- Native desktop/mobile: Dart API → worker isolate → Rust/redb → native database file.
- Web: Dart `WebWorkerClient` → Dedicated Worker → Rust/Wasm/redb → OPFS database file.
- No `DatabaseConfig.inMemory`, `useInMemory`, `mem://` path, or `Database.open(':memory:')`.
- No Dart `InMemoryBackend`, Dart-only query execution, or Dart-only secondary-index authority.
- Native physical encryption remains optional and Rust-owned; Web OPFS remains file-backed but
  unencrypted under the M6.5 native-only encryption policy.
- Temporary directories/files are used for tests; they are not a separate database implementation.

**Steps:**
1. ☐ **Lock the product decision.** Add an ADR defining native-file/OPFS-file support, removal of
   in-memory APIs, the Web persistence contract, encryption behavior, and the replacement test strategy.
2. ☐ **Remove the public in-memory surface.** Remove `DatabaseConfig.inMemory`, `useInMemory`, `mem://`,
   `:memory:`, and related public documentation, examples, error branches, and API snapshot entries.
3. ☐ **Delete the Dart backend.** Remove `InMemoryBackend`, Dart-only storage snapshots, Dart-only query
   and index execution, and backend-specific branches that exist only for in-memory behavior.
4. ☐ **Add/finish Rust ephemeral-file support only if needed.** Do not recreate a second engine. If tests
   need disposable stores, use temporary native files; if Web needs ephemeral behavior, use a temporary
   OPFS file and close/delete it. Do not reintroduce `:memory:` as a product mode.
5. ☐ **Retain and qualify Web OPFS.** Keep `WebWorkerClient`, OPFS registration, Wasm artifacts, browser
   smoke tests, persistence/reopen behavior, and explicit Web encryption rejection. Update terminology from
   "in-memory Web" to "temporary or persistent OPFS file".
6. ☐ **Replace differential testing.** Convert in-memory-vs-native tests into native temporary-file tests,
   Rust unit/contract tests, and native-vs-Web/OPFS tests where practical. Preserve semantic coverage for
   filters, sorting, indexes, snapshots, transactions, migrations, relationships, and errors.
7. ☐ **Rework fixtures and benchmarks.** Replace `mem://` fixtures with isolated temporary native files;
   ensure cleanup after crashes/failures; update comparative/performance harnesses and open-latency metrics.
8. ☐ **Audit lifecycle and concurrency.** Verify file locks, close/reopen, temporary-file cleanup, OPFS
   access-handle release, worker finalization, snapshots, and same-path duplicate-open behavior.
9. ☐ **Recalculate coverage and artifacts.** Remove obsolete Dart-backend tests, add Rust/OPFS contract
   coverage, regenerate the API snapshot and FRB artifacts if needed, and preserve the ≥95%/100% gates.
10. ☐ **Run release gates.** Run full native tests, Rust tests, Web smoke, API/traceability, security,
    offline lint, coverage, artifact/binding, crash/reopen, transaction, migration, relationship,
    encryption, and cleanup checks.

**What remains in Dart:** public API, query authoring, model mapping, migration callbacks, reactive
stream lifecycle, relationship declarations/policies, typed errors, and Web Worker/client integration.
Dart no longer executes database storage, index, predicate, sort, aggregate, or snapshot semantics.

**Dart deletions expected:** the complete `InMemoryBackend` and its storage/query/index branches, the
in-memory configuration and path surface, differential fixture helpers, and obsolete documentation/tests.
The exact count is recorded after implementation.

**Done when:** every supported database path is Rust-owned and file-backed (native file or OPFS file);
no public in-memory mode or Dart storage engine remains; Web OPFS persistence and smoke tests pass; all
native/Web parity, lifecycle, file-cleanup, encryption, API, coverage, FRB, Rust, and release gates pass.

### M8 — Incremental reactivity  ☐

**Goal:** a write updates only the live result sets it can affect (not a full re-evaluation).

**Steps:**
1. Consume M7's documented change metadata handoff (changed row keys, indexed fields, and batch
   metadata); do not assume a Rust query registry exists.
2. Define query registration, identity, lifecycle, cancellation, backpressure, replay, and snapshot
   semantics before moving invalidation computation.
3. Compute which indexes/queries are affected and update only those result sets (start in Dart; move
   pure candidate computation to Rust only after the lifecycle contract is locked).
4. Preserve the coalesced single-event-per-batch behavior; only the per-query work changes.

**Done when:** with N live filtered queries and a single-row write, the update cost does not grow with
the size of the watched collections.

### M9 — Mechanical completion (can run in parallel with M3–M8)  ☐

1. Stand up the full six-platform matrix against the single shared integration suite; **bring iOS CI up**
   (the one ☐ from WS7).
2. Extend the comparative benchmark (`benchmark/comparative.dart`) with Isar, Drift, and SQLite
   (sqflite / sqlite3) under identical fixtures (currently Hive CE + Sembast).
3. Build a doc-test harness that extracts every documented snippet and runs it in CI.
4. Complete the 12-criteria traceability table + a script asserting every listed test exists/passes.
5. Automate dependency, Rust, and license audits in CI.

### M10 — Release hygiene  ☐

1. Lock native-artifact distribution: remove the runtime network-download fallback for release builds
   (air-gapped environments, macOS Gatekeeper), keeping static bundling + explicit local paths.
2. Plan a wire-format v2 for byte-orderable (little-endian, offset-binary) encodings behind the existing
   format-version gate, with a migration path; do not change v1 in place.

**Done when:** release artifacts contain no runtime download path; the format v2/migration plan is
documented.

---

## 3. Ground rules

- **Benchmark before and after every milestone** with `tool/perf_gate.dart` + `benchmark/baseline.json`;
  record the numbers.
- The §0 design principles (single writer, always batched, coverage gate, file-format contract) apply
  unchanged.
- **M3 gates M4–M7** (read-path completion must finish before sort/limit/migration cleanup build on it).
  **M7 gates the M8 invalidation handoff**; M8 owns query registration and reactive lifecycle semantics.
  **M9 can start immediately in parallel.**
- Every Dart→Rust move (M7) lands with Rust unit tests first; Dart code is deleted only after the Rust
  path is green and parity tests pass.
- FRB codegen: after changing `rust/src/api.rs`, run
  `flutter_rust_bridge_codegen generate --config-file frb.yaml`, then
  `dart run tool/build_artifacts.dart build windows-x64 --out=build/native` + `bundle --from=build/native`
  (the bundled DLL must match the regenerated bindings or `backend_edge_test` fails with a content-hash
  mismatch).

---

## Appendix A — Acceptance Criteria Traceability

| # | Acceptance Criterion | Demonstrated By |
|---|---|---|
| 1 | Widgets consume live typed queries directly | Phase 4 + 5 reactive query tests |
| 2 | Local reads/writes work fully offline | Phase 2 core engine tests (no network dependency) |
| 3 | A local mutation auto-updates all affected live queries | Phase 4 + 5 reactivity tests (M8 deepens this) |
| 4 | No manually maintained observable lists required | Phase 4 `Stream`-native design + Phase 13 doc-tests |
| 5 | Sync can read pending local changes via a small interface | Phase 7 sync-hook tests |
| 6 | Remote changes applied transactionally | Phase 7 `applyRemoteTransactional` tests |
| 7 | Local/remote changes merge deterministically | Phase 8 conflict-resolution tests |
| 8 | Attachment metadata stays consistent with record changes | Phase 9 tests |
| 9 | Large datasets stay responsive | Phase 5 + 12 perf tests + `benchmark/baseline.json` gate (M1–M4 deepen this) |
| 10 | Tests use isolated file-backed databases | M7.5 temporary native files + Web OPFS isolation; no Dart in-memory backend |
| 11 | Initialization, recovery, migrations are reliable | Phase 2 crash-recovery + Phase 10 migrations |
| 12 | App-specific store layer shrinks substantially | Phase 13 examples; consumer fixture LOC vs hand-rolled Hive layer |

## Appendix B — Final release checklist

Before publishing a production release, require all answers below to be "yes":

- [ ] Public API snapshot reviewed; all changes have ADR/release-note coverage.
- [ ] File format, wire protocol, native artifact, and package compatibility matrix is current.
- [ ] Generated bindings are reproducible and committed/packaged correctly.
- [ ] Every supported platform has a checksum-verified artifact + clean consumer fixture (iOS = M9).
- [ ] Dart and Rust analyzers, tests, coverage, and lint gates pass.
- [ ] Shared file-backed contract suite passes (native files ↔ Web/OPFS); no Dart in-memory backend remains.
- [ ] Crash-recovery and reopen drills pass at fixed seeds.
- [ ] Transaction, index, sync, attachment, migration, crypto, and compaction atomicity tests pass.
- [ ] No sensitive plaintext in database files, temp dirs, logs, diagnostics, crash reports, or artifacts.
- [ ] Read-only, lock, upgrade, corruption, wrong-key, missing-key, and typed error paths verified.
- [ ] Performance results meet the pinned workload thresholds + are recorded with environment metadata.
- [ ] Documentation examples run from a clean checkout/consumer fixture.
- [ ] Security, dependency, license, and artifact audits pass.
- [ ] Changelog, migration notes, rollback plan, support policy, and disclosure contact are published.

The release owner attaches CI run URLs, artifact manifest, coverage reports, benchmark report,
crash-drill seeds/results, compatibility matrix, and traceability report. If an item is intentionally
not supported, label it unsupported rather than silently shipping a partial guarantee.

## Appendix C — Commands cheat-sheet

```text
# Bootstrap
dart pub get

# Dart quality (must be clean before + after every change)
dart analyze
dart test packages/gecko_db/test --reporter=compact            # ~35-50s, full suite
dart test packages/gecko_db/test --concurrency=8                # concurrency check
dart test packages/gecko_db/test --coverage=packages/gecko_db/coverage
dart run coverage:format_coverage --lcov --check-ignore \
  --in=packages/gecko_db/coverage -o packages/gecko_db/coverage/lcov.info \
  --report-on=packages/gecko_db/lib --ignore-files="**/native/generated/**"
dart run tool/coverage_gate.dart packages/gecko_db/coverage/lcov.info

# Rust quality
cd rust && cargo fmt --check && cargo check --all-targets && cargo test && \
  cargo clippy --all-targets --all-features -- -D warnings

# Generated bindings (run after changing rust/src/api.rs)
flutter_rust_bridge_codegen generate --config-file frb.yaml
dart run tool/build_artifacts.dart build windows-x64 --out=build/native
dart run tool/build_artifacts.dart bundle --from=build/native
dart run tool/build_artifacts.dart check-bindings    # clean-tree only

# Other gates
dart test tool
dart run tool/offline_lint.dart
dart run tool/security_review.dart
dart run tool/traceability_check.dart
dart run tool/api_snapshot.dart tool/api_snapshot.txt   # commit if public API changes
dart run tool/perf_gate.dart            # strict local; CI uses --tolerance (mem is noisy on Windows)

# Benchmarks (advisory breakdown harnesses; not perf_gate inputs)
dart run benchmark/bench.dart [--native|--mem|--json]
dart run benchmark/boundary.dart [--json]          # M1 layer breakdown
dart run benchmark/query_profile.dart              # M1/M2 per-stage split
dart run benchmark/comparative.dart [--json]       # Hive CE + Sembast

# Long/scale modes (nightly CI job ws8-long-suite)
GECKO_LONG_TEST=1 dart test packages/gecko_db/test/phase14_*_ws8_test.dart
# phase14_crash_injection spawns OS processes — don't run parallel with heavy tests
```

## Appendix D — Key file map

| Concern | Path |
|---|---|
| Public API | `packages/gecko_db/lib/gecko_db.dart` (barrel + `show:` exports) |
| Query engine (Dart) | `packages/gecko_db/lib/src/query/query_impl.dart` |
| Predicate wire codec (Dart→Rust) | `packages/gecko_db/lib/src/query/predicate_codec.dart` |
| Durable-index eq bounds | `packages/gecko_db/lib/src/query/durable_index_bounds.dart` |
| Native backend | `packages/gecko_db/lib/src/backend/native_raw_backend.dart` |
| Worker isolate client | `packages/gecko_db/lib/src/worker/native_worker_client.dart` |
| Rust worker (redb + query ops) | `rust/src/worker.rs` |
| Rust value codec (port of DefaultWireCodec) | `rust/src/value_codec.rs` |
| Rust predicate evaluator | `rust/src/predicate.rs` |
| Rust FRB API surface | `rust/src/api.rs` |
| Wire format (Dart↔Rust Op batch) | `packages/gecko_db/lib/src/wire/op.dart` ↔ `rust/src/wire.rs` |
| ADRs | `docs/adr/` (0001–0017) |
| Gates | `tool/{coverage_gate,offline_lint,security_review,traceability_check,api_snapshot,perf_gate,build_artifacts}.dart` |
