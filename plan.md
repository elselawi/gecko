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
a client for the read/query path on the native backend; the in-memory backend retains the Dart path
(it has no Rust).

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
   wrong data. Web and in-memory encryption are unsupported.
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
| 2 | Core engine: Rust `redb` worker, single-writer, MVCC, in-memory backend, crash recovery | ADR-0003 worker isolate, ADR-0005 client+finalizer, ADR-0006 MVCC snapshots; `phase2_*` tests |
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

- **WS0–2** ✅ Contract lock, native worker lifecycle, backend differential/conformance (in-memory ↔
  native parity via `raw_backend_contract_test.dart` + `phase2_differential_test.dart`).
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
| **M3** Read-path completion + `getMany` | (a) route `iterate()` through `_scanWith` (deleted the `_streamUnsorted` per-id loop); (b) aggregate pushdown `query_filtered_count` / `query_filtered_distinct` (+ `value_codec::find_field_range`); (c) public `Collection.getMany(ids)` = `RedbWorker::get_many` (one read txn, N keys); (d) relationship `children` batches through `snap.getMany` | ADR-0018 | `count()`/`distinct()` on native transfer zero rows (count) / one field-slice per row (distinct); `getMany` kills the relationship N+1; all read paths now use the native fast path || **M4–M6.5** Query optimization + architecture | Indexed sort/limit, indexed filter intersection, worker/encryption architecture decisions, pre-release encryption simplification | ADR-0019–0022 | M4 indexed sort+limit 154µs median on 100k; M5 multi-eq ~1.0ms but broad range/prefix bounds remain slower than full scan; M6 isolate 57.3µs vs direct FRB 25.1µs and logical encryption 121.6ms vs plain 4.4ms, motivating M6.5 removal |
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
> already-done Phases 1–13 in §1. They are now **Milestones** (M1–M6 done; M6.5 next; M7–M10 open).
> Each milestone has a goal, concrete steps, a "done when" check, and — where it moves Dart→Rust — an
> ROI note and the Rust tests + Dart deletions it requires.
>
> **Ordering.** M3 gates M4–M7 (read-path completion must finish before sort/limit/migration cleanup
> build on it). **M9 can start immediately in parallel** with anything.

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

### M7 — Dart→Rust migration cleanup (the "Dart as thin client" pass)  ☐ next

**Goal:** now that the read/query path moved to Rust (M2–M5), audit and delete Dart code that is
genuinely redundant on the native backend, and strengthen Rust unit tests to cover what the deleted Dart
tests covered.

This is NOT "move everything to Rust" — only high-ROI moves. The in-memory backend keeps its Dart path
(no Rust). For each candidate below, the rule is: **move to Rust only if (a) it's on the native hot path
AND (b) the Rust port has stronger test coverage than the Dart it replaces.**

**Candidates (in ROI order):**

| Move | Why | Dart deleted | Rust tests added |
|---|---|---|---|
| **Sort + limit/offset** (✅ done in M4/ADR-0019) | Hot path (`ORDER BY … LIMIT`) | Dart `compareRows`/`decoded.sort` on native (index-covered) — native routes through `_nativeOrderedCollect`; Dart sort retained for in-memory parity only | top-K heap + indexed-order streaming (`query_sorted` + `query_indexed_ordered`) |
| **`SecondaryIndex` rebuild-at-open → lazy/optional** | On native open, Dart reads the *whole* `__gecko_index` table to rebuild the in-memory index (a full-table scan). If Rust serves all index lookups via the durable table (M3+M5 done), the in-memory index becomes a pure cache; rebuild can be lazy/optional. | `_indexCandidates` + `SecondaryIndex.lookup*` on native (keep for in-memory) | durable-index scan + intersection in Rust |
| **Change-feed affected-query computation** (ties to M8) | A write currently broadcasts to *all* live queries, each re-evaluating in Dart. Rust could compute which queries a batch affects (via the durable index) and emit only affected-query signals. | Dart per-query re-eval fan-out | affected-query set computation in Rust |
| **`count`/`distinct` aggregates** (part of M3) | Materialize-then-count in Dart → count-only in Rust | Dart `count()`/`distinct()` scan loops on native | aggregate pushdown tests |
| **`getMany`** (part of M3) | Per-id reads → one batched read | Dart per-id `snap.read` loops in relationships + `_streamUnsorted` | `get_many` Rust tests |

**What stays in Dart (do NOT move):**
- `Filter` / `FilterGroup` / `Filter.eq/between/prefix` — the **public authoring API**
  (`col.where({'x':1}).range(...)`). `encodePredicate` reads them.
- The in-memory backend's entire query path (`InMemoryBackend` has no Rust).
- `toRow`/`fromRow` model mapping (codegen-free design principle).
- The worker-isolate transport itself (M6 decides its fate).

**Done when:** each moved subsystem has Rust unit tests covering the cases the deleted Dart tests
covered; the deleted Dart tests are removed (or converted to thin parity tests calling the Rust path);
coverage gate stays ≥95% line / 100% branch; parity tests confirm identical results across native +
in-memory.

### M8 — Incremental reactivity  ☐

**Goal:** a write updates only the live result sets it can affect (not a full re-evaluation).

**Steps:**
1. On each change batch, compute which indexes/queries are affected and update only those result sets
   (start in Dart; if M7's affected-query computation moved to Rust, wire it).
2. Preserve the coalesced single-event-per-batch behavior; only the per-query work changes.

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
| 10 | Tests use isolated in-memory databases | Phase 2 in-memory backend, used throughout |
| 11 | Initialization, recovery, migrations are reliable | Phase 2 crash-recovery + Phase 10 migrations |
| 12 | App-specific store layer shrinks substantially | Phase 13 examples; consumer fixture LOC vs hand-rolled Hive layer |

## Appendix B — Final release checklist

Before publishing a production release, require all answers below to be "yes":

- [ ] Public API snapshot reviewed; all changes have ADR/release-note coverage.
- [ ] File format, wire protocol, native artifact, and package compatibility matrix is current.
- [ ] Generated bindings are reproducible and committed/packaged correctly.
- [ ] Every supported platform has a checksum-verified artifact + clean consumer fixture (iOS = M9).
- [ ] Dart and Rust analyzers, tests, coverage, and lint gates pass.
- [ ] Shared backend differential suite passes (in-memory ↔ native ↔ web).
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
