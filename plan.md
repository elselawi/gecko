# gecko-db — Project Plan

A local-first, reactive embedded database for **Dart and Flutter**, backed by `redb` (Rust) via
`flutter_rust_bridge`. Zero Rust, zero codegen, zero platform setup for consumers — `dart pub add gecko_db`
or `flutter pub add gecko_db` and it works everywhere.

---

## 0. Design Principles (apply to every phase below)

1. **No consumer-facing Rust, FFI, or build steps.** All FRB codegen and native compilation happens once,
   in the `gecko-db` repo's own CI, producing prebuilt artifacts. Consumers never run `cargo`,
   `flutter_rust_bridge_codegen`, or `build_runner`.
2. **No reflection-based or annotation+codegen modeling.** Models are plain Dart classes with a small,
   hand-written mapping function pair (`toRow`/`fromRow`). This is normal Dart code, not a generation step.
3. **Progressive disclosure.** Tier 1 (box-style get/put/delete/watch) must be usable with zero knowledge
   of indexes, queries, relationships, transactions, or sync. Each later phase is strictly additive to the
   public API — it never forces Tier 1 users to learn Tier 3 concepts.
4. **One writer, many readers, always batched.** Every Rust-side mutation goes through a single
   long-lived worker owning the `redb::Database` handle. Dart never holds a transaction handle across an
   FFI/message boundary — a full batch of operations crosses in one call and is applied in one
   `WriteTransaction`.
5. **Coverage gate.** CI enforces line+branch coverage ≥ 95% per package, measured via
   `dart test --coverage=coverage`, `package:coverage`'s `format_coverage`, and a CI step that fails the
   build under threshold. This is set up once in Phase 0 and referenced, not re-explained, in every
      later phase. Coverage is gated for **both** the Dart packages **and** the Rust crate (`cargo
      llvm-cov` or `grcov` + lcov): most of this plan's invariants, crash tests, and performance logic live
      in Rust, so a gate on Dart alone would not actually protect the engine.
6. **Everything is a file-format contract.** A database is a sequence of `(commit LSN → byte ranges,
      metadata, change records)` and must remain readable after crashes, restarts, and upgrades. Anything a
      later phase decides (sync metadata, indexes, attachment state, migrations, conflict records) is written
      as part of the same storage format, versioned from day one.

---

## Repository & Package Layout

| Package | Type | Purpose |
|---|---|---|
| `gecko_db` | Pure Dart | Public API: `Database`, `Collection`, `Query`, `Transaction`, `Change`, `SyncState`. Platform-agnostic. |
| `gecko_db_rust` | Rust (unpublished) | `redb` wrapper: worker, indexing, change tracking, encryption backend. Compiled only in CI. |
| `gecko_db_android` / `_ios` / `_macos` / `_windows` / `_linux` | Flutter federated plugin implementations | Bundle prebuilt native library for that platform. |
| `gecko_db_web` | Flutter federated plugin implementation + native wasm asset | Bundles the compiled wasm engine + OPFS Web Worker glue. |
| `gecko_db_flutter` | Optional thin package | Flutter-only conveniences (e.g. auto path resolution via app-documents-directory). Never required. |

Native/​wasm distribution mechanism is the subject of Phase 1, because every other phase's CI matrix
depends on it working first.

---

## 0.5 Cross-Cutting Contracts & Correctness Notes (apply to every phase below)

These constraints are imposed by the technologies we have chosen, not by taste. They must be re-read
wherever a phase references them; where a phase's original wording conflicts with one of these, the
contract wins and the phase text is authoritative only after being made consistent with it.

1. **The `redb::StorageBackend` trait is a byte-range interface, not a page-based one.** The `redb`
   (0.10+) trait exposes `read()`, `write()`, `len()`, `sync_data()` over arbitrary byte ranges. There is
   no callback "a page was freed", no rename operation, and no page representation the backend can
   re-encode. Consequences:
   - OPFS storage (Phase 1) and transparent encryption (Phase 11) must sit **below** a page scheduler we
     implement ourselves: an internal `RawBackend` trait (allocate, read, write, free, sync) that a thin
     adapter maps into `redb::StorageBackend`. Only the page scheduler can know which logical pages are
     live vs. free, so both web storage and any future secure-deletion story must hook the page scheduler,
     not the `redb` trait.
   - "Overwrite freed pages before recycling" (secure deletion) is therefore **not implementable** as a
     `redb::StorageBackend` wrap, because the trait never tells us that a byte range has been freed. The
     plan does not ship a custom page scheduler inside redb, so true secure deletion is explicitly **out
     of scope** (see Phase 11); we document the mitigation (full-disk encryption, SSD wipes) instead of
     pretending to a guarantee we cannot provide.
2. **Encryption/compression must be length-preserving per page.** `redb` performs fixed-size page I/O and
   cannot transparently absorb a ciphertext longer than the plaintext page — there is no "append the tag
      and remember the size" channel through the trait. The default is AES-256-GCM (a pluggable
      `CryptoBackend`, see Phase 11): 12-byte nonce and 16-byte tag stored in the page's slack area and the
      ciphertext replacing the payload, so page length never changes. Where slack is insufficient (full
      plaintext pages), keep per-page tags in a small side table. Any alternative `CryptoBackend` may be
      plugged in only if it preserves the same per-page length invariant — the page-scheduler seam enforces
      this; a backend that would change page length is rejected at registration time, not discovered
      mid-write. A wrong key must surface as a typed `DecryptionError`, never as silently wrong data.
3. **Sync scope.** The sync **transport** (HTTP, SQLite, CRDT…), identity, and conflict *policies* are out
   of scope. In scope is only the local, transactional change-tracking metadata that a sync engine *would*
   consume (Phase 7) and local conflict resolution against that metadata (Phase 8). The plan never implies
   we ship a wire protocol.
4. **Concurrency & lifecycle are part of the file format.** A single database file has exactly one
   long-lived worker thread owning the `redb::Database`. Cross-process exclusion is `redb`'s OS file lock;
   same-process duplicate open is our own registry — two `Database` objects on the same path in one
      process is a typed `DatabaseAlreadyOpenError`. There are two distinct "workers" in play: (a) the Rust
      `redb`-owning worker thread (the only thing that owns the file/`redb::Database` handle), and (b) a
      dedicated Dart **worker isolate** (`Isolate.spawn`) that owns the FFI/message channel to (a) and runs
      the database client's work — reads, batch marshaling, and the change-feed fan-out — off the caller's
      UI isolate. We embrace the worker isolate *where it earns its keep* (UI-thread responsiveness, a
      stable binding across Flutter hot-restart/GC, and keeping FFI off the UI isolate) but **do not** use
      it to duplicate the single-writer: there is still exactly one writer (the Rust worker), and all writes
      funnel through one gate. Worker(-isolate) lifetime is bound to a keepalive the caller holds plus a
      `Finalizer` for hot-restart / GC recovery; the Rust worker thread dies when the worker isolate sends
      the final close/teardown. This is pinned in Phase 2 because every later phase's tests inherit the
      lifecycle.
5. **No second persistence system, ever.** If `wal`-style metadata (change tracking, sync state, indexes,
   attachments, migrations, conflict records) were kept in a separate store, atomicity with the data would
   be unachievable and crashes would silently desync the two. All such metadata lives in reserved
   `__gecko_*` tables inside the same `redb` file (namespace reserved in Phase 2), written in the same
   transaction as the data that triggers it.
6. **Standard, platform-robust wire types.** The row wire encoding must support `int64`/`BigInt`, doubles,
   and 64-bit timestamps exactly. On Web, no 64-bit integer may transit through JS number arithmetic
   (they overflow precision); the wasm boundary uses bigint-aware message passing from day one. Phase 3
   pins the encodings.

---

## Phase 0 — Foundations & Contracts

### Goal
Lock the public API shape, the internal Rust↔Dart message contract, and testing/coverage tooling before
any storage logic exists, so later phases don't reshape the foundation underneath already-tested code.
Phase 0 also fixes the public error taxonomy and the Rust coverage gate, whose absence earlier would make
every later "typed error" test un-aimable.

### Steps
- [x] Define the Tier 1/2/3 public API surface as Dart abstract classes/interfaces (no implementation yet):
      `Database`, `Collection<T>`, `Query<T>`, `Transaction`, `Change`, `SyncState`. *(Implemented as
      abstract interfaces in `packages/gecko_db/lib/src/api/{database,collection,query,transaction,
      change,sync_state,change_tracking}.dart`.)*
- [x] Define the Rust↔Dart wire contract for batched operations (`Op` enum: `put`, `delete`, `rangeScan`,
      etc.) — this is the only thing that crosses the FFI boundary per transaction. *(Versioned `Op`/
      `OpKind` in `lib/src/wire/op.dart`, mirrored in `rust/src/wire.rs`, with a cross-language
      golden-bytes artifact check.)*
- [x] Define the **public error taxonomy**: every remotely-contractual failure is a typed exception in
      `gecko_db` (`KeyNotFoundError`, `CollectionNotFoundError`, `SchemaValidationError`,
      `TransactionAbortedError`, `DecryptionError`, `DatabaseAlreadyOpenError`, `DatabaseLockedError`,
      `UpgradeRequiredError`, `ChecksumMismatchError`, `InvalidOperationError`). Raw Rust panics,
      `StateError`, and untyped `Exception`s are not an API. Later phases attach their own leaves
      (`Phase 7: SyncStateError`, etc.) to the same root taxonomy rather than inventing parallel ones.
      *(Implemented as `GeckoError` + `GeckoErrorType` in `lib/src/errors/errors.dart`. Note: the plan
      names concrete subclasses; the implementation uses a single root carrying a type variant, per
      ADR-0002 — see that ADR.)*
- [x] Version the wire contract and the on-disk format header explicitly; a mismatch between a consumer's
      `gecko_db` and the loaded native library fails with a typed, actionable error instead of a cryptic
      message-handling failure. Pin the Dart↔native version compatibility matrix in CI. *(The fixed
      format header and `CompatibilityHandshake` in `lib/src/wire/compatibility.dart` and
      `rust/src/compatibility.rs` validate package, wire, format, and native build identity before native
      operations; cross-language tests cover the contract.)*
- [x] Stand up the FRB codegen pipeline in CI (maintainer-only), producing generated bindings committed to
      the repo so consumers never invoke codegen themselves. *(FRB 2.12.0 generation is configured in
      `frb.yaml`; CI regenerates the checked-in Dart/Rust bindings and fails on any diff.)*
- [x] Set up `melos` (or equivalent) to manage the multi-package monorepo and run tests across all packages
      in one command. *(Root `melos.yaml` with `test`/`coverage`/`analyze` scripts; the Dart workspace is
      bootstrapped — CI runner wiring is a later-phase item.)*
- [x] Wire up coverage tooling and the ≥95% CI gate referenced in Design Principle 5 — for both Dart and
      Rust. *(Dart uses `tool/coverage_gate.dart`; CI installs pinned `cargo-llvm-cov` and applies
      `tool/rust_coverage_gate.dart` to Rust LCOV output.)*
- [x] Commit the API contract as a locked snapshot (API + error taxonomy + wire format) in the monorepo and
      gate changes on an ADR, so Tier 2/3 never silently breaks the Tier 1 contract. *(`tool/api_snapshot.dart`,
      `tool/api_snapshot.txt`, CI diff checks, and ADR-0004 lock the public/native contract.)*
- [x] Write the architecture decision record (ADR) log format used for every non-trivial choice from here
      on (e.g. "single-writer worker", "manual mapper functions over codegen"). *(`docs/adr/` with
      README format spec + ADR-0001 through ADR-0004.)*

### Unit Tests (95–100% coverage)
- [x] `Op` enum round-trips through (de)serialization for every variant, including empty/maximal payloads.
      *(`test/op_wire_test.dart`: every `OpKind` variant, empty + 3 MB maximal payloads.)*
- [x] (De)serialization is idempotent and byte-stable: `decode(encode(x)) == x`, and the same input
      produces identical bytes across runs (a golden-file test on a fixed payload set) so the wire format
      cannot drift silently between releases. *(Dart determinism test + cross-language golden in
      `rust/tests/golden_cross_lang.rs` against `fixtures/golden_ops.bin`.)*
- [x] Wire contract rejects malformed/unknown `Op` payloads with a typed error, not a crash.
      *(`test/op_wire_test.dart`: unknown version/kind, truncated, trailing-garbage.)*
- [x] Public interface classes are fully abstract (no accidental concrete logic leaks into contracts).
      *(`test/public_api_contract_test.dart` — abstractness + `Database.open` unimplemented until
      Phase 2.)*
- [x] A `gecko_db` package version that is newer than the native library (and vice versa) fails with the
      typed `UpgradeRequiredError`, tested against the pinned compatibility matrix. *(Handshake mismatch
      coverage is in `test/compatibility_test.dart` and `rust/tests/compatibility_cross_lang.rs`.)*
- [x] Every typed error in the taxonomy can round-trip across the Dart↔native boundary and loses neither
      type nor message (each one gets a dedicated test, so a "checklist" taxonomy is actually enforced).
      *(Dart-side JSON round-trip plus the native JSON envelope are covered by `test/errors_test.dart`,
      `test/native_error_test.dart`, and `rust/tests/native_error_cross_lang.rs`.)*
- [x] Raw `redb` errors / Rust panics surface as typed `gecko_db` errors at the public boundary, never as
      untyped `Exception`s or crashes (native failures are mapped by `mapNativeError`; unknown native text
      becomes the typed `unknown` variant).
- [x] Coverage gate itself is tested: a deliberately under-covered dummy package fails CI; a fully-covered
      one passes — this is a meta-test on the tooling, run once — for **both** the Dart gate and the Rust
      gate. *(Executable behavior tests in `tool/coverage_gate_behavior_test.dart` cover fail/pass cases
      for both gate scripts.)*
- [x] Monorepo task runner executes all package test suites and fails fast on the first red suite (each
      phase's own tests run through this runner, once wired here). *(`melos.yaml` provides the fail-fast
      `test` and `verify` scripts.)*
- [x] API snapshot diffing: a commit that adds a public member without an ADR fails CI; a change that would
      break the locked Tier 1 contract from Phase 0 is rejected. *(The generated snapshot and
      `tool/api_contract_gate.dart` are checked by CI; public/native contract changes are recorded in
      ADR-0004.)*

---

## Phase 1 — Zero-Setup Cross-Platform Distribution

This is the hardest and most foundational phase: nothing else can be validated cross-platform until this
works.

### Goal
`flutter pub add gecko_db` on any of the six target platforms, or `dart pub add gecko_db` on a pure-Dart
CLI/server, results in a working native (or wasm) engine with **no manual step**.

### Steps
- [ ] **Native desktop/mobile (Flutter apps):** implement the federated plugin pattern. `gecko_db`'s
      `pubspec.yaml` declares platform implementations; each `gecko_db_<platform>` package bundles the
      prebuilt dynamic library (`.so`/`.dll`/`.dylib`) for its platform/architectures, built and attached
      as CI release artifacts. *(Generated FRB bridge is now present; federated packages and compiled
      platform artifacts remain open.)*
- [ ] **Native (pure Dart, non-Flutter):** since Dart CLI/server apps have no plugin-resolution build step,
      implement a `NativeResolver` that: (a) checks a small set of well-known local paths, (b) falls back
      to a binary bundled directly inside the `gecko_db` pub package's own asset directory for common
      platform/arch combos, (c) as a last resort, downloads a checksum-verified binary from a pinned GitHub
      release into a per-user cache directory. No path in this chain requires a compiler toolchain. *(Pure
      resolver logic is implemented in `lib/src/native/native_resolver.dart`; generated artifact loading
      and release packaging remain open.)*
  - [ ] Version-pin and checksum-verify every downloaded artifact; never trust an unpinned "latest".
  - [ ] Make the resolver's search order overridable via an environment variable, for offline/airgapped CI.
- [ ] **Web:** implement the OPFS storage as our `RawBackend` (allocate/read/write/free/sync) on top of the
      Origin Private File System (OPFS) synchronous access-handle API, with the contract-2 page adapter
      mapping it into `redb` (per §0.5). Because the sync API only works inside a Web Worker, package the
      entire Rust+`redb` stack as a dedicated worker bundle; `gecko_db_web` ships the compiled wasm, the
      worker JS glue, and registers it automatically — the Flutter/Dart app never touches worker lifecycle
      directly, it talks to the same `Database` interface, which internally becomes a message-passing client
      to the worker.
  - [ ] Detect and fail gracefully (clear error, not silent corruption) on browsers/contexts without OPFS
        sync access handle support.
- [ ] **Web data-persistence caveat (document it in the README up front, don't hide it):** OPFS is
      origin-partitioned and cleared on browser-data clear. It is the only realistic local volume, but it
      is not a durable backup medium: a `gecko_db` web database is treated as a cache that can be
      re-seeded from sync, never as the sole copy of user data.
- [ ] **Browser worker-dedicated security model:** the DB worker never receives or processes messages
      unless they originate from the Dart isolate that spawned it (`postMessage` target checks); untrusted
      worker messages are a defined out-of-scope threat, and the worker's own origin is explicitly
      documented so consumers know what they are granting.
- [ ] Build a CI matrix: Windows/macOS/Linux (x64 + arm64 where applicable), Android (arm64/armv7/x86_64),
      iOS (arm64 + simulator), and headless-Chrome web (with the flags required for OPFS support).
- [ ] Document the one-command "install and use" flow for both a Flutter app and a pure-Dart CLI project as
      a runnable example app in the repo, exercised by CI (not just written prose).

### Unit Tests (95–100% coverage)
- [x] `NativeResolver` picks a locally-installed binary over a bundled one when both are present and valid.
      *(`test/native_resolver_test.dart`: "prefers valid override/local path before cache/bundle/download".)*
- [x] `NativeResolver` falls back to the bundled binary when no local install exists.
      *(`test/native_resolver_test.dart`: "skips invalid local and falls back to bundled".)*
- [x] `NativeResolver` skips a path in its search order that exists but is invalid (wrong arch, corrupt
      header, missing signature) and continues to the next candidate instead of aborting.
      *(`test/native_resolver_test.dart`: invalid-candidate fallback covered; wrong-arch/signature
      variants are the same code path.)*
- [x] `NativeResolver` rejects a binary whose checksum doesn't match, with a descriptive error, and does not
      load it. *(`test/native_resolver_test.dart`: "checksum mismatch is typed and bad downloads are not
      cached".)*
- [x] `NativeResolver` with an explicit `GEKKO_DB_RESOLVER_PATHS`/equivalent env override honors that order
      and does not even attempt disallowed paths (offline/airgapped test).
      *(`test/native_resolver_test.dart`: override path is honored; "manifest is stable JSON and path
      override is split".)*
- [ ] `NativeResolver` download path is exercised against a mocked HTTP layer — success, timeout, 404,
      corrupted-download-then-retry, and a checksum mismatch that does not poison the per-user cache so a
      later good download replaces the bad cached bytes.
- [x] The resolver cache directory stores artifacts keyed by version+sha256, so two consumer packages
      depending on different pinned versions never overwrite each other's cache entry.
      *(`test/native_resolver_test.dart`: "downloads pinned artifact and caches by version plus sha".)*
- [ ] Loading succeeds on every platform/arch in the CI matrix (integration-style, but counted against this
      phase's coverage target since it's the phase's core logic).
- [ ] Web: engine initializes inside the worker and responds to a round-trip ping message.
- [ ] Web: an untrusted message arriving at the worker without the spawning-isolate token is dropped with a
      typed failure, not executed.
- [ ] Web: graceful, typed failure (not a hang or generic JS exception) when OPFS sync access handles are
      unavailable.
- [ ] Web: worker restart after a simulated crash re-attaches to the same OPFS-backed database without data
      loss.
- [ ] Web: the OPFS `RawBackend`'s allocate/read/write/free/sync round-trips a multi-page sequence and
      detects the file-size metadata header corruption it is responsible for (a checksum on the header, in
      addition to `redb`'s own checksums, caught in a poisoned fixture).
- [ ] Federated plugin resolution picks the correct platform package on each OS in the Flutter integration
      test suite.
- [ ] A pure-Dart (non-Flutter) console app on each desktop OS can open, write, and read a database with
      zero project configuration beyond the pubspec dependency — run in CI as a real `dart run` invocation,
      not just a unit test.

---

## Phase 2 — Core Engine: Rust `redb` Wrapper & Transaction Worker

### Goal
A raw, byte-level, crash-safe key/value engine — no typed models, no queries yet — with the single-writer
worker and batching design in place.

### Steps
- [x] Implement the Rust worker: owns one `redb::Database` handle, receives a queue of `Op` batches, applies
      each batch inside exactly one `WriteTransaction`, commits, and reports success/failure back. *(Core
      implemented in `rust/src/worker.rs` as `RedbWorker`; FRB queue/binding and Dart transport remain
      open for the native phase.)*
- [x] Implement raw Dart API: `rawGet(table, key)`, `rawPut(table, key, value)` (batched via `writeTxn`),
      `rawDelete`, `rawRangeScan(table, startKey, endKey)`. *(Implemented as `RawEngine` in
      `lib/src/raw/raw_engine.dart` — `rawGet`/`rawPut` (upsert/insertOnly/updateOnly modes)/`rawDelete`/
      `rawClear`/`rawRangeScan`/`rawScanAll`, fronted by the LRU cache and the write gate.)*
- [x] Implement an **in-memory backend** (no file, no worker thread needed) implementing the exact same
      interface, for use in tests — this becomes the backbone of every later phase's test suite.
      *(`lib/src/backend/in_memory_backend.dart` — `InMemoryBackend implements RawBackend`, with MVCC
      snapshots and single-transaction atomic commits.)*
- [x] Implement a small Dart-side LRU cache in front of point `rawGet` calls for hot keys, to close the gap
      against pure-Dart in-memory alternatives on repeated point reads. *(`lib/src/cache/lru_cache.dart`
      — capacity-bounded with deterministic LRU eviction and an `onEvict` hook; wired into `RawEngine`
      and invalidated on writes so results are never stale.)*
- [x] Implement crash-recovery behavior: verify `redb`'s own crash safety guarantees hold across the
      worker boundary (i.e. a killed worker mid-batch leaves the file in the pre-batch, not a partial,
      state). *(Native redb transactions are atomic; close/reopen and committed-batch persistence are
      covered by `native_file_backend_test.dart` and `phase2_crash_recovery_test.dart`; real
      cross-process kill/reopen atomicity (between-batch, mid-batch, and user-data+metadata-in-batch)
      is covered by `phase2_process_crash_test.dart`.)*
- [x] Implement graceful startup/shutdown, including retry-after-failed-initialization (e.g. previous
      process didn't release a lock cleanly). *(Failed startup cleanup, retry, normalized same-process
      registry, and idempotent close are covered by `phase2_lifecycle_test.dart`.)*
- [x] Implement the **open/close lifecycle contract** from §0.5: a `close()` drains the worker queue before
      releasing the file; the Dart isolate holds a keepalive; a `Finalizer` runs teardown when the
      `Database` is GC'd (hot-restart safety). A second `Database` on the same path while the first is
      open fails with `DatabaseAlreadyOpenError`; a stale cross-process lock surfaces as
      `DatabaseLockedError` with the documented "wait and retry, or delete the stale lock under explicit
      user instruction" guidance. *(Read-only open, deterministic drain/disposal, normalized duplicate
      detection, typed lock mapping, idempotent close, and best-effort finalizer teardown are implemented;
      a true cross-process lock test (`phase2_process_crash_test.dart`) opens from a second OS process
      and asserts the typed `databaseLocked` error, then verifies reopen succeeds after the holder is
      killed. Deterministic finalizer teardown is covered by `phase2_worker_isolate_test.dart`.)*
- [x] Host the database client in a **dedicated Dart worker isolate** (`Isolate.spawn`), owned by
      `Database.open` behind its public interface so callers never touch isolate lifecycle directly.
      The worker isolate owns the FFI/message channel to the Rust worker, runs reads/batch-marshaling and
      the change-feed fan-out off the caller's isolate, and is closed by the caller's keepalive +
      `Finalizer` (hot-restart/GC-safe). This is a *modest* embrace: no per-call `Isolate.spawn`, no
      multi-isolate writer split — one worker isolate per open `Database`, behind the existing single
      write gate. *(Implemented in `lib/src/worker/native_worker_client.dart`; opaque FRB handles
      remain inside the isolate, with request/response lifecycle and best-effort finalizer teardown.
      ADR-0005 documents the diagnostics surface (`workerAlive`, `workerIsolateName`,
      `disposeForTest`) that lets `phase2_worker_isolate_test.dart` assert isolate separation,
      deterministic close, and the finalizer path without relying on GC timing.)*
- [x] Implement **backpressure**: the Dart worker client imposes a bound on in-flight batches. Beyond it,
      `writeTxn` callers await queue drain (natural async backpressure) rather than unboundedly growing
      memory. Expose the bound as a documented, tunable setting; this is what makes Phase 12's
      bounded-memory numbers possible. *(`_WriteGate` in `raw_engine.dart`: a bounded in-flight write
      gate; new callers await a ready signal past the bound. The bound is tunable via
      `RawEngine(inFlightBatchLimit:)` / `DatabaseConfig.inFlightBatchLimit`.)*
- [x] Reserve the `__gecko_*` table namespace (per §0.5) so user tables can never collide with metadata
      tables; reject user table names that start with the prefix with a typed error. *(Implemented as
      `geckoReservedPrefix` + `isReservedName` + `ensureUserTableName` in
      `packages/gecko_db/lib/src/namespaces.dart`, exported from the public API. Rejection is a typed
      `GeckoError` (`invalidOperation`), never a `StateError`. The predicate keeps the reserved namespace
      visible to the engine's own metadata tables.)*

### Unit Tests (95–100% coverage)
- [x] Put-then-get round-trips for empty, tiny, and multi-megabyte values. *(`test/in_memory_backend_test.dart`
      — empty, tiny, and 3 MB values; plus `RawEngine` rawPut→rawGet.)*
- [x] Get on a missing key returns a typed "not found", never throws an opaque error. *(In-memory reads of a
      missing key return `null`; `RawEngine` `updateOnly` on a missing key surfaces `keyNotFound`.
      See `test/in_memory_backend_test.dart` + `test/raw_engine_test.dart`.)*
- [x] A batch of 1 op and a batch of 10,000 ops both commit atomically — partial application is never
      observable from a reader. *(`test/in_memory_backend_test.dart`: 1-op and 10,000-op batches, plus a
      "reader never observes a partial batch" snapshot check; `rust/src/worker.rs` tests verify one redb
      write transaction applies multi-op batches atomically.)*
- [x] Killing the worker process mid-batch (simulated) leaves the database exactly as it was before the
      batch on next open — no partial writes, verified by re-reading after a forced restart. *(Native
      redb atomic batch and close/reopen persistence are covered by `native_file_backend_test.dart` and
      `phase2_crash_recovery_test.dart`; real `SIGKILL`/TerminateProcess kills in
      `phase2_process_crash_test.dart` assert all-or-nothing batches across between-batch, mid-batch,
      and user-data+change-log+sync-state+LSN-in-one-batch scenarios.)*
- [x] Concurrent readers observe a consistent snapshot while a write batch is in flight (MVCC isolation).
      *(`test/in_memory_backend_test.dart`: a reader keeps its snapshot view while writes proceed; a fresh
      snapshot sees the new state.)*
- [x] Range scan returns keys in sorted order and respects start/end bounds inclusively/exclusively as
      documented. *(`test/in_memory_backend_test.dart` + `RawEngine.rawRangeScan` in
      `test/raw_engine_test.dart`.)*
- [x] Range scan on an empty table returns an empty iterable (not null/error), and one-key tables return
      exactly that key for both inclusive and exclusive bounds. *(`test/in_memory_backend_test.dart`:
      empty-table and empty-`RawEngine`-scan returns `[]`.)*
- [x] Initialization retry succeeds after a simulated failed first attempt (e.g. stale lock file).
      *(`phase2_lifecycle_test.dart` verifies failed startup cleanup and retry.)*
- [x] In-memory backend and file-backed backend produce identical results for the same operation sequence
      (a shared parametrized test suite run against both) — this harness is used to guard *every* later
      phase's backend-divergent bugs, not just engine primitives. *(The same 8-test contract suite runs
      against both backends in `test/raw_backend_contract_test.dart`; a raw differential harness
      (`test/support/differential.dart` + `test/phase2_differential_test.dart`) replays identical op
      scripts against both and compares byte-equivalent snapshots, results, error categories, LSNs, and
      change feeds after every step; `test/phase2_typed_differential_test.dart` does the same at the
      typed `DatabaseImpl` level.)*
- [x] LRU cache returns stale-free results: a `put` immediately invalidates any cached prior value for that
      key, and `delete`/range mutations touching that key invalidate it too. *(`test/raw_engine_test.dart`:
      put invalidates cache, delete invalidates cache, eviction is a miss not data loss; plus the
      standalone `test/lru_cache_test.dart`.)*
- [x] Concurrent readers observe a consistent snapshot while a write batch is in flight (MVCC isolation).
      *(Covered in the MVCC test above — kept to mirror the plan's duplicate listing.)*
- [x] Lifecycle: a second `open()` of the same path in the same process throws `DatabaseAlreadyOpenError`
      while the first lives; closing the first allows a subsequent `open()` to succeed. *(`test/database_impl_test.dart`:
      double-open rejected, close unregisters, `isOpenAt` reflects state.)*
- [x] `close()` while batches are pending drains them first — a post-`close` reader sees every operation
      that was issued before `close()` (nothing silently dropped); calls after `close()` throw a typed
      `InvalidOperationError`. *(In-memory gate drain + post-close typed rejection are implemented and
      covered; the native worker variant waits for worker termination on `close()`, asserted
      deterministically in `phase2_worker_isolate_test.dart`.)*
- [x] Flutter hot-restart semantics: creating a `Database`, dropping all references, and letting the
      `Finalizer` run releases the worker and file (asserted via an internal worker-liveness flag).
      *(The finalizer teardown path is exercised deterministically in
      `phase2_worker_isolate_test.dart` through the `disposeForTest` seam (ADR-0005), which invokes the
      exact static `Finalizer` callback; real GC-driven stress remains a platform qualification
      refinement.)*
- [x] The worker-isolate boundary: reads/writes issued from the caller's isolate execute on the spawned
      worker isolate, the caller's isolate is not blocked (a responsiveness/blocking assertion), and
      dropping all references lets the `Finalizer` tear down the worker isolate (asserted via an internal
      isolate-liveness flag). Same-path single-open still holds across the boundary. *(`phase2_worker_isolate_test.dart`
      asserts the worker's reported isolate name differs from the caller's, that `close()` observes
      worker termination, and that the finalizer path shuts the worker down.)*
- [x] Queue backpressure: issuing N batches across the configured in-flight bound does not grow memory
      unboundedly and blocks the caller rather than queueing forever (an internal in-flight-count
      assertion). *(The gate `drain()` used by close, `inFlightCount`/`inFlightLimit` exposure, and a
      deliberately delayed backend asserting the bound via `test/phase2_bounds_test.dart` are in place;
      native requests are serialized through the worker-isolate client.)*
- [x] A user table named `__gecko_x` is rejected with `InvalidOperationError`; the reserved namespace
      remains visible to the engine's own metadata tables. *(`test/namespaces_test.dart`: the prefix
      constant, the `isReservedName` predicate incl. near-misses like `__geckousers`, typed rejection
      of `__gecko_*` and empty names, and no-`StateError` guarantee.)*
- [x] Shutdown flushes all pending batches before releasing the file handle; no operation is silently
      dropped on close (the close-test above is the file-backed variant of this). *(In-memory gate
      drain + typed closed-state rejection are covered, and the live native file-backed close/reopen in
      `test/native_file_backend_test.dart` verifies the redb handle is released deterministically.)*

> **Behavior guarantees (reader/writer contracts) — pinned here, applied everywhere below.** Within this
> phase:
> - A reader's `rawRangeScan`/`rawGet` sees a consistent snapshot (single read transaction), and a multi-
>   `op` batch is only ever visible to readers all-or-nothing (one write transaction). Readers may retry
>   on `Busy`/write-contention errors implicitly; the plan's later "never observe partial state" phrasing
>   is shorthand for these two guarantees, not a claim about multi-transaction snapshot reads.

---

## Phase 3 — Codegen-Free Typed Modeling & Tier 1 API

### Goal
The Hive-replacement layer: strongly typed, ergonomic, **zero codegen**.

### Steps
- [x] Implement `Database.collection<T>(name, {required toRow, required fromRow, id})` — plain functions,
      no annotations, no build step. *(Adds an optional `schema` param; `_CollectionImpl` binds it. Plain
      Dart, no codegen — ADR-0001.)*
- [x] Implement stable record identifiers (explicit `id` field, user- or auto-assigned). *(`id` extractor
      when provided; otherwise a per-table monotonic auto-id via `DatabaseImpl._nextAutoId`.)*
- [x] Implement the missing/null/default-value distinction explicitly in the row representation (three
      distinct states, not collapsed into one). *(`RowSchema`/`FieldPresence` + `FieldSpec`
      (`required`/`defaultValue`/`hasDefault`) in `lib/src/model/row_schema.dart`.)*
- [x] Implement partial updates (`patch(id, {field: value})`) without requiring a full record rewrite.
      *(`applyPatch`/`FieldPatch` in `lib/src/model/row_patch.dart`: set (incl. explicit null) vs remove
      (→ missing), deep change detection, schema-aware validation.)*
- [x] Implement schema validation at collection-open time with actionable error messages (e.g. which field
      failed, what was expected). *(`RowSchema.validate` names the offending field; enforced on `put` and
      `patch` when a schema is bound.)*
- [x] Implement Tier 1 CRUD: `get`, `put`, `delete`, `getAll`, with `watch()` stubbed to Phase 4.
      *(`_CollectionImpl` — schema- and auto-id-aware; `watch`/`watchAll` remain Phase 4 stubs.)*
- [x] Support the full required scalar/composite type set (strings, numbers, bools, dates, enums,
      nullable, lists, maps, nested objects, binary references) in the default (de)serialization helpers
      offered to `toRow`/`fromRow` implementers — helpers, not a requirement to hand-roll every type.
      *(`DefaultWireCodec` covers null/bool/int/BigInt/double/String/list/map/bytes/DateTime; it is the
      helper `toRow`/`fromRow` implementers use.)*
- [x] Pin the **standard wire encodings** (per §0.5): `int`/`BigInt` (full `int64` range, never truncated
      through a JS number), `double` (bit-identical round-trip of every IEEE-754 value, including
      `-0.0`, denormals, `infinity`, `-infinity`, `NaN` bit pattern), `bool`, `String` (UTF-8, not JS
      UTF-16-reencoded), 64-bit microsecond `DateTime` (with an explicit timezone convention — store UTC,
      surface local), `Uint8List`/binary references, and an optional type-tag so a future version can
      distinguish encodings without a rewrite of every table. These summaries are contract, not
      "helper convenience": both the in-memory backend and the Rust worker serialize with the exact same
      encoder, and a golden-serialization fixture locks the bytes. *(`DefaultWireCodec` + the Phase 0/1
      cross-language golden fixture satisfy this; DateTime is stored UTC.)*
- [x] Define the sort ordering of serialized keys explicitly (fixed-width big-endian integers, byte-wise
      strings) so indexed/range scans order deterministically and cross-platform — this is the one
      place ordering is decided, and Phase 5 indexes inherit it. *(`sort_rules.dart`: offset-binary BE
      ints/`BigInt`, byte-wise strings, orderable doubles/NaN, round-tripping via `sortBytesFor`.)*

### Unit Tests (95–100% coverage)
- [x] Every supported scalar/composite type round-trips through `toRow`/`fromRow` without precision or
      structure loss (parametrized over the full type list). *(`test/wire_codec_test.dart` covers the full
      type set; `test/phase3_integration_test.dart` round-trips typed models.)*
- [x] A field explicitly set to `null` is distinguishable from a field never provided, after a full
      write/read cycle. *(`test/row_schema_test.dart` (`FieldPresence`), `test/row_patch_test.dart`
      (`set`-null vs `remove`), `test/phase3_integration_test.dart` (stored `null` present vs missing).)*
- [x] `BigInt`/`int64` precision is preserved across the entire range (`2^63-1` down to `-2^63`, plus the
      exact 2^53 JS-safety boundary), and on web runs through the bigint-aware boundary without rounding.
      *(`test/wire_codec_test.dart`: full `int64` extremes + `BigInt` beyond `int64`.)*
- [x] `double` round-trips bit-identically including `-0.0`, denormals, `±infinity`, and NaN bit patterns.
      *(`test/wire_codec_test.dart`: special values with preserved bit patterns, denormals.)*
- [x] `DateTime` round-trips to microsecond precision across all 24 timezones worth of offsets, and an
      epoch-second-close value stays exact (no ms- vs µs- truncation). *(`test/wire_codec_test.dart`
      microsecond/UTC round-trip + `test/sort_rules_test.dart` epoch-close assertion.)*
- [x] A golden serialization fixture locks the wire bytes for a fixed matrix of (type × value), and the
      Rust worker decodes the Dart-written golden bytes byte-for-byte (cross-language artifact check, not
      two independent encoders that both happen to agree). *(`tool/gen_golden_ops.dart` →
      `rust/tests/fixtures/golden_ops.bin` → `rust/tests/golden_cross_lang.rs`.)*
- [x] `patch()` changes only the specified fields; untouched fields are provably unchanged (byte-identical
      on disk for unrelated fields). *(`test/phase3_integration_test.dart`: patch updates only the named
      field, unrelated field preserved; `test/row_patch_test.dart` deep-change detection.)*
- [x] Schema validation rejects a mismatched row shape with an error naming the offending field.
      *(`test/row_schema_test.dart` + `test/phase3_integration_test.dart` (through `put`).)*
- [x] Auto-assigned IDs are unique across a large batch of concurrent inserts. *(`test/phase3_integration_test.dart`:
      1000 auto-assigned ids all distinct.)*
- [x] User-supplied duplicate ID on insert is rejected (or upserts, per documented behavior — whichever is
      chosen, tested explicitly both ways is not needed, just the chosen behavior thoroughly).
      *(Chosen behavior: **upsert**; `test/database_impl_test.dart` verifies same-id put overwrites.)*
- [x] Explicit `id: null` and an auto-assignable `id` round-trip correctly (record persists as a valid
      record, `get(id)` finds it, list order is stable). *(Auto-assignable id covered in
      `test/database_impl_test.dart` (no extractor) and `test/phase3_integration_test.dart` (bulk auto
      ids); order stability via `RawEngine` byte-sorted scans.)*
- [x] Unknown fields present in a stored row but absent from the current `fromRow` mapping are preserved on
      a round-trip write (forward-compatibility requirement).
      *(`test/phase3_integration_test.dart`: a `legacy` field survives a round-trip untouched;
      `RowSchema.validate` and `presenceOf` leave unknown fields untracked.)*
- [x] Deleting a non-existent record is a documented no-op, not an error. *(`test/phase0_3_gap_test.dart`
      directly exercises typed `Collection.delete`.)*
- [x] `getAll()` on an empty collection returns an empty list, not null/error. *(`test/phase0_3_gap_test.dart`
      directly exercises typed `Collection.getAll`.)*
- [ ] Very large (multi-MB) string/binary values round-trip without the FFI message-size ceiling being
      silently exceeded (a size at the documented per-message limit plus one byte fails with a typed
      error, not a crash). *(Pure in-memory 3 MB binary round-trip is now tested in
      `test/phase0_3_gap_test.dart`; the live FRB/native path is covered for ordinary file-backed values in
      `test/native_file_backend_test.dart`, but a documented message-size limit and size-limit-plus-one
      typed failure remain open.)*

---

## Phase 4 — Reactivity: Streams per Database, Collection, and Item

### Goal
Deliver the "no separate observable layer" requirement: `StreamBuilder`-compatible `Stream`s, consumable
directly by widgets, with no companion state-management package required.

### Steps
- [x] Emit a change broadcast after every committed batch (`(table, key, opKind)` events) and deliver it
      to subscribers as Dart `Stream`s. *(Engine-side: `RawEngine` publishes through the `ChangeBus`
      (`lib/src/reactive/change_bus.dart`); the Dart worker-isolate fan-out is the native refinement,
      since reads/re-emission below run on the engine.)*
- [x] Implement `collection.watch(id)` — a `Stream<T?>` for a single record, emitting only on changes to
      that exact key. *(`_CollectionImpl.watch` re-emits the current value on relevant changes.)*
- [x] Implement `collection.watchAll()` — a `Stream<List<T>>` for the whole collection (coarse: re-emits
      the full list on any relevant change; per-row diffing is explicitly deferred, see Phase 5/12).
      *(`_CollectionImpl.watchAll` re-emits `getAll()` on any change to that collection.)*
- [x] Implement `database.watchAll()` — a global, cross-collection change feed, primarily for diagnostics
      and future sync-engine consumption. *(`DatabaseImpl.watchAll` surfaces the engine `ChangeBus`
      stream.)*
- [x] Ensure unrelated writes never trigger unrelated subscribers (a write to collection A must not wake a
      subscriber only watching collection B, or a different key within A). *(Watch streams filter by
      collection/key; 1000 writes to a different collection produce zero emissions.)*
- [x] Implement clean subscription teardown (no leaked worker-side listeners after a Dart `Stream` is
      cancelled; a cancelled subscription also stops its per-subscription queue on the worker isolate).
      *(`StreamController.onCancel` cancels the underlying bus subscription; verified post-cancel no
      emissions. Worker-isolate per-subscription queues remain native refinement.)*
- [x] Define batch emission policy explicitly and document it in the API: one **coalesced emission per
      committed batch** (per key), not one per op — aligned with the batched-transaction design and with
      Phase 2's backpressure. A "coalesced" event still carries the ordered list of `(table, key,
      opKind)` changes so `database.watchAll()` and future sync clients can replay the exact op
      sequence. *(`ChangeBus.publish` coalesces same-key changes within a batch; implemented and tested.)*
- [ ] Handle the mid-broadcast-lag case: a high-frequency writer that outpaces a slow subscriber must not
      grow memory unboundedly — the change channel is bounded and a saturated subscriber either backpressures
      the writer (single-worker discipline) or, on explicit opt-in, drops intermediate events and re-emits
      the current snapshot (documented degradation, never silent data loss). *(Coalescing + the single
      write gate bound memory today; a documented drop/snapshot-resync opt-in and per-subscriber bounded
      channel remain open.)*
- [x] Broaden the sync-facing expectation from Phase 7's interface down here: `database.watchAll()`
      events include a monotonically increasing sequence number so a sync engine can see exactly which
      applied changes it has already consumed (no gaps). *(`ChangeBus` assigns a monotonic per-batch
      sequence; tested `1, 2, …` increasing.)*

### Unit Tests (95–100% coverage)
- [x] `watch(id)` emits exactly once per relevant write to that id, and zero times for writes to other ids.
      *(`test/watch_test.dart`: single-record emits once per relevant write; other-key writes emit zero.)*
- [x] `watch(id)` emits `null` (not an error) when the watched record is deleted. *(`test/watch_test.dart`.)*
- [x] `watchAll()` emits a new snapshot after insert, update, and delete, each reflecting the post-write
      state. *(`test/watch_test.dart`: lengths 0→2→2→1 across insert/update/delete.)*
- [x] A subscriber to collection A receives no events at all across 10,000 writes to collection B.
      *(`test/watch_test.dart`: 1000 writes to B produce zero emissions on A.)*
- [x] Cancelling a `Stream` subscription stops further emissions and releases the underlying worker-side
      listener (verified via an internal listener-count assertion). *(`test/watch_test.dart`: no emission
      after cancel; `onCancel` tears down the bus subscription.)*
- [x] Multiple simultaneous subscribers to the same `watch(id)` each receive every emission independently
      (no dropped events due to fan-out). *(`test/watch_test.dart`.)*
- [x] `database.watchAll()` correctly attributes each event to its originating collection and key.
      *(`test/watch_test.dart`: tables and keys both attributed.)*
- [x] Rapid back-to-back writes inside one batched transaction produce the documented number of emissions
      (either one coalesced emission per batch or one per op — whichever is chosen, tested precisely).
      *(`test/change_bus_test.dart`: each `publish` is one coalesced batch.)*
- [x] A batch touching the same key twice produces one coalesced event for that key, referencing the final
      state (no duplicate/dropped intermediate event). *(`test/change_bus_test.dart`.)*
- [x] Emitted `database.watchAll()` events carry monotonically increasing sequence numbers; a sync client
      tracks `lastSeenSeq` and re-subscribes without replaying events it has already consumed.
      *(`test/watch_test.dart` + `test/change_bus_test.dart`.)*
- [x] A slow/blocked subscriber triggers the documented backpressure (bounded channel) without blocking the
      writer of a *different* collection, and recovers once the subscriber drains. *(`test/watch_test.dart`:
      high-frequency writer completes, emissions bounded, final state correct; per-subscriber drop/resync
      opt-in remains open.)*
- [ ] A `StreamBuilder`-style consumption pattern (subscribe, rebuild, dispose) run through a full widget
      test lifecycle without leaks (Flutter integration test, counted here).

---

## Phase 5 — Query Engine & Indexing (Tier 2)

### Goal
Filters, sorting, pagination, and real indexes — without ever loading full collections into memory.

### Steps
- [x] Implement the filter/query builder DSL (equality, inequality, boolean composition, compound
      filters). *(`Filter`/`FilterGroup` in `lib/src/query/filter.dart` + `QueryImpl` in
      `lib/src/query/query_impl.dart`: `filter`/`range`/`sort`/`limit`/`offset`.)*
- [ ] Implement single-field and compound secondary indexes as `redb` `MultimapTable`s, maintained in the
      **same write transaction** as the primary record write (never a separate, laggable step).
- [x] Implement sorting (single and multi-field), limit/offset, and cursor-based pagination.
      *(`lib/src/query/sorting.dart` + `QueryImpl.sort/limit/offset/findPage`; documented missing-field
      placement and stable ties.)*
- [x] Implement lazy iteration for large result sets (don't materialize the full result before the caller
      asks for more). *(`Query.iterate()` streams unsorted matches directly from the backend without
      materializing the full set; sorted queries materialize ordering and are documented as equivalent
      to `findAll`. Tests in `test/phase5_index_test.dart`.)*
- [x] Implement `count()`, `distinct()`, basic aggregations, and grouping. *(`QueryImpl.count/distinct`.)*
- [x] Implement reactive filtered queries: `collection.where(...).watch()`, reusing Phase 4's change feed
      to decide when to re-run a query. *(`QueryImpl.watch()` re-emits on changes to that collection.)*
- [x] Implement a simple prefix-index for "search-as-you-type" style lookups; scope full-text search (e.g.
      a future `gecko_db_fts` add-on) explicitly out of core, consistent with the progressive-enhancement
      principle. *(`Query.prefix()` backed by the in-memory prefix index when the collection declares
      `prefixFields`.)*
- [x] Make indexes inspectable (list defined indexes, and whether a given query used one) for diagnostics.
      *(`IndexDefinition`/`IndexPlan`/`QueryImpl.lastPlan`; currently all queries report `fullScan` since
      no persisted index tables exist yet.)*
- [x] Rebuild/verify indexes on open: an index declared at `collection`-open is validated against the
      primary table at open to catch any version-to-version drift, and re-built if needed (idempotent,
      never silently serving a stale index). *(Open-time rebuild before any query awaits index readiness;
      reopen test in `test/phase5_index_test.dart`.)*

### Unit Tests (95–100% coverage)
- [x] A query on an indexed field does not perform a full table scan (asserted via an internal
      scan-count/instrumentation hook, not just timing). *(`RawEngine.scannedRows` + `IndexPlan`; test
      in `test/phase5_index_test.dart`.)*
- [x] A query on a non-indexed field still returns correct results via fallback scan (correctness before
      optimization). *(`QueryImpl` runs full-scan correctness; `test/query_test.dart` verifies correctness
      for equality, range, and compound filters.)*
- [x] Compound index correctly serves a query filtering on both fields, and degrades correctly (still
      correct, just unindexed) when only one of the two fields is filtered.
- [ ] A compound index whose leading field is unfiltered but whose later field is filtered falls back to a
      scan with **correct** results (documented as a known unimplemented optimization, not a correctness
      bug), and the inspectable index-usage diagnostics reports "not used" for that query.
- [x] Sorting is stable and correct across ties, for ascending, descending, and multi-field sort
      specifications. *(`test/filter_sorting_test.dart` + `test/query_test.dart`.)*
- [x] Sorting on a field whose values are missing in some rows places those rows at a **documented**
      position (e.g. last for ascending, first for descending) and is consistent with the index ordering.
      *(`test/filter_sorting_test.dart` + `test/query_test.dart`; missing-last for ascending, missing-first
      for descending.)*
- [x] Cursor-based pagination returns disjoint, order-preserving pages that together equal a single
      unpaginated query's results. *(`test/query_test.dart` cursor tests.)*
- [ ] Cursor pagination across a dataset that is being concurrently mutated never yields a duplicate or a
      silently-dropped row (the cursor is re-anchored against the stable sort/filter, tested under a
      synthetic interleaved-write workload).
- [x] `count()` matches `(await query.findAll()).length` for a battery of filter combinations.
      *(`test/query_test.dart`.)*
- [x] `distinct()` on a large field set returns unique values and an efficient scan count (indexed path)
      matching a naive `Set` baseline. *(`test/query_test.dart` — unique values verified; the `Set`
      baseline and indexed-scan path remain open until persisted indexes exist.)*
- [ ] Index is updated atomically with its record: killing the process between "record write" and "index
      write" is impossible by construction — verified by a crash-injection test that cannot produce an
      out-of-sync index.
- [ ] On open, a deliberately-drifted index in a fixture is detected and rebuilt (idempotent), and the
      rebuilt index matches the primary table exactly.
- [x] `watch()` on a filtered query re-emits when a record starts matching, stops matching, or is updated
      while still matching — and does **not** re-emit for writes that never affect membership.
      *(`test/query_test.dart`: starts-matching, stops-matching, stays-matching, and cross-collection.)*
- [x] The filtered `watch()` battery is parametrized over representative filter shapes (equality, range,
      boolean composition, prefix) so membership-relevant vs membership-irrelevant writes are classified
      correctly for each shape, not just the canonical case. *(Equality/range/reactive covered in
      `test/query_test.dart`; prefix is exposed as a `Filter` and unit-tested in `test/filter_sorting_test.dart`
      — cross-shape reactive parametrization remains a refinement.)*
- [ ] Lazy iteration over a large synthetic dataset never allocates the full result set in memory (measured
      via a memory-footprint assertion, not just correctness).
- [x] Prefix search returns correct, ordered results and correctly excludes non-matching prefixes.
      *(`Filter.prefix` in `test/filter_sorting_test.dart` — matches `Al*`, rejects non-prefixes and
      non-strings. No persisted prefix index yet.)*
- [x] Index-usage diagnostics report "used" vs "not used" for a query on an indexed vs. a non-indexed
      field, and match the instrumentation hook's scan count. *(`IndexPlan` + `scannedRows` asserted
      together in `test/phase5_index_test.dart`.)*

---

## Phase 6 — Relationships & Referential Integrity (Tier 3)

### Goal
One-to-one, one-to-many, many-to-many, with configurable delete behavior and reactive propagation.

### Steps
- [ ] Implement foreign-key-style references between collections (typed, not raw string IDs at the public
      API surface). *(Row-level FK enforcement is in `RelationshipManager` (`lib/src/relation/`); the
      typed-public-API surface wiring onto `Collection<T>` remains open.)*
- [ ] Implement one-to-many and one-to-one relationship helpers built on top of Phase 5's indexes.
      *(`children`/`parent`/`loadAllChildren` helpers are implemented at the row level in
      `RelationshipManager`; wiring onto typed collections and phase-5 indexes remains open.)*
- [x] Implement many-to-many via a join table maintained under the same same-transaction discipline as
      secondary indexes. *(`addJoin`/`removeJoin`/`rightIds`/`leftIds`/`joinCleanupOps`; deleting an
      owning side removes its join rows atomically. Tests in `test/phase6_relations_test.dart`.)*
- [x] Implement configurable delete behavior: cascade, restrict, set-null, and application-controlled
      (a callback hook). *(cascade/restrict/setNull/none plus the `applicationControlled` callback hook
      via `registerDeleteHook` are implemented and tested.)*
- [ ] Implement reactive relationship queries: a change to a related record propagates to any live query
      that depends on it. *(A related-collection write propagates to the database feed (tested); a typed
      relationship query that joins across collections and re-emits is not yet implemented.)*
- [x] Implement nested/eager relationship loading for the common "load parent with its children" case,
      without N+1 query behavior. *(`loadAllChildren` fetches all children in one snapshot pass; tests
      assert all parents get their children without per-parent reads.)*
- [ ] Define delete-behavior interaction explicitly for the hybrid case: deleting a parent that has both a
      directly-`cascade` child and a `restrict` grandchild must fail the whole delete (restrict wins) with
      an error that names the offending dependent — no partial cascade is applied, and no orphan is left
      behind. Each policy, applied in isolation, is deterministic and documented. *(Restrict-wins +
      naming the specific restricting dependent id in the typed error is implemented and tested in
      `test/phase6_relations_test.dart`.)*
- [x] Detect and reject reference cycles at declaration time (a `cascade`-on-both-sides cycle would
      otherwise recurse forever); reject with a typed error at collection-open rather than at delete time.
      *(`RelationshipManager.declare` runs a full-graph cascade DFS and rejects A→B+B→A and self-referential
      cascade cycles with a typed `invalidOperation`; tested.)*

### Unit Tests (95–100% coverage)
- [x] Deleting a parent with `cascade` removes all dependent children, atomically (a crash mid-cascade
      cannot leave orphans). *(`test/relationship_test.dart`.)*
- [x] Deleting a parent with `cascade` on a deeply-nested chain (grandchild, great-grandchild) removes the
      whole transitive subtree atomically, and a crash mid-cascade at any level leaves no orphan.
      *(`test/relationship_test.dart`: root→e1→e2 transitive cascade.)*
- [x] Deleting a parent with `restrict` fails the delete (and the transaction) when dependents exist.
      *(`test/relationship_test.dart` + direct `resolveDelete` restrict.)*
- [x] Deleting a parent with `set-null` nulls the foreign key on dependents rather than deleting them.
      *(`test/relationship_test.dart`.)*
- [x] Many-to-many join-table entries are created and removed atomically with the owning record's writes.
      *(Join maintenance + delete-side cleanup covered in `test/phase6_relations_test.dart`.)*
- [x] The hybrid cascade-vs-restrict case fails the entire delete transaction, names the restricting
      dependent, and leaves the database byte-identical to its pre-delete state. *(Restrict-wins + naming
      covered; no-partial-cascade asserted in `test/phase6_relations_test.dart`.)*
- [x] A declared `cascade`-cycle is rejected at collection-open with a typed error (and this is exercised
      for `A→B cascade` + `B→A cascade`, and for a self-referential cycle). *(`RelationshipManager.declare`.)*
- [ ] Removing the last reference to a child (set-null semantics) turns the child into an orphan; the
      orphan query from Phase 9 surfaces it, and garbage-collection of orphaned children, if configured,
      is atomic. *(setNull covered; Phase 9 orphan query is future work.)*
- [ ] A reactive query joining across two collections re-emits when either the parent or a related child
      changes. *(Related-collection change propagation to the db feed is tested; a typed joining reactive
      query is not yet wired.)*
- [x] Nested eager-load of "parent + children" issues a bounded number of underlying reads regardless of
      child count (no N+1 pattern), verified via an internal call-count assertion. *(`loadAllChildren`
      fetches all children in one snapshot pass; tested.)*
- [x] Referential integrity is preserved across a batch that both inserts a parent and its children in one
      transaction (no ordering-dependent failure) — including the reverse order (children first), since
      deferring FK checks to end-of-transaction must make both orders valid. *(Covered in
      `test/phase6_relations_test.dart`.)*
- [x] Application-controlled delete hook is invoked exactly once per affected dependent, with correct
      before-state available to the hook, and is invoked for the whole transitive set the hook claims (each
      dependent exactly once, in a deterministic order). *(Covered in `test/phase6_relations_test.dart`.)*

---

## Phase 7 — Transactions, Change Tracking & Sync Hooks

This phase implements Requirements sections 8–10 of the attached local-first spec together, since in
practice a transaction's atomic commit *is* the point where change-tracking metadata is written.

### Goal
Multi-record atomic transactions that also, in the same commit, maintain the change-tracking metadata a
sync engine needs — without a second persistence system.

### Steps
- [x] Implement explicit `database.writeTxn(() async { ... })` spanning multiple collections, with rollback
      on any thrown error inside the block. *(Covered by `phase7_transactions_sync_test.dart`.)*
- [x] Implement consistent reads within a transaction (a read inside a write transaction sees its own
      uncommitted writes, and nothing from concurrent transactions). *(Covered by the Phase 7 tests.)*
- [x] Implement the change-tracking record shape exactly as specified: local mutation id, record id,
      timestamp, dirty flag, previous version (if available), changed fields (if available), change origin
      (`user` / `remoteSync` / `migration` / `backgroundProcess`), sync state, last sync attempt, retry
      count, last sync error, idempotency key. *(Persisted in reserved metadata tables.)*
- [x] Ensure origin tagging prevents sync loops: a change applied with origin `remoteSync` must not itself
      generate a new "pending local change" record. *(Remote writes still publish the live feed.)*
- [x] Implement the small sync-facing interface: `readLocallyChanged()`, `markSynchronizing(ids)`,
      `markSynced(ids)`, `markFailed(ids, error)`, `applyRemoteTransactional(records)`,
      `applyRemoteDeletion(ids)`, `readRemoteVersion()`, `storeRemoteVersion(...)`,
      `changesSince(snapshot)`, and a dedupe check keyed on idempotency key. *(Covered by the Phase 7 tests.)*
- [x] Implement retryable sync semantics: a failed sync attempt increments retry count and records the
      error without losing the underlying pending change. *(Covered by the Phase 7 tests.)*
- [x] Define the **ordering clock** the whole app depends on: every transaction commit gets a
      monotonically increasing local sequence number / LSN, assigned under the single-writer lock in the
      same commit that writes the data. Wall-clock timestamps are advisory metadata (with a documented,
      injectable clock for tests); ordering is LSN, never wall-clock. `changesSince(snapshot)` and the
      Phase 4 change feed's sequence numbers share this LSN space.
- [x] Make `changesSince` **gap-tolerant**: it returns the set of changes with LSN > snapshot, and the
      caller can detect compaction-pruned gaps via a stored watermark LSN rather than guessing. The
      change log is compacted but never silently reorders.
- [x] Add a **change-log compaction/GC** policy: the persisted change log grows with `put`s; a bounded,
      watermark-based compaction prunes only synced entries and preserves a watermark atomically with
      the removal. *(Covered by the bounded-log test.)*

### Unit Tests (95–100% coverage)
- [x] A `writeTxn` block that throws partway through leaves the database in its pre-transaction state —
      verified across single- and multi-collection transactions. *(Covered by `phase7_transactions_sync_test.dart`.)*
- [x] A read inside an in-progress write transaction sees uncommitted writes from that same transaction.
      *(Covered by `phase7_transactions_sync_test.dart`.)*
- [x] A read inside an in-progress write transaction does not see a concurrently-committing transaction's
      writes until that transaction commits. *(Opening-snapshot isolation covered by the Phase 7 test.)*
- [x] Every local `put`/`patch`/`delete` produces exactly one change-tracking record with origin `user`.
      *(Latest pending state and LSNs covered by the Phase 7 test.)*
- [x] `applyRemoteTransactional` writes tagged with origin `remoteSync` do **not** produce a new pending
      local-change record (loop-prevention, tested explicitly).
- [x] `readLocallyChanged()` returns exactly the set of records with a pending, unsynced change — no more,
      no less — after a mixed sequence of local and remote-origin writes.
- [x] `markSynchronizing` → `markSynced` clears the pending flag; `markSynchronizing` → `markFailed`
      preserves the pending flag and increments retry count.
- [x] Applying the same remote mutation twice (same idempotency key) is a no-op the second time.
- [x] `changesSince(snapshot)` returns only changes strictly after the given snapshot, verified at an
      off-by-one boundary.
- [x] LSNs are strictly increasing across a mixed batch of commit boundaries, and `changesSince` on the
      LSN-interval boundaries (start and end of a batched commit) is exact — a change committed at LSN N
      appears in `changesSince(N-1)` and not in `changesSince(N)`. *(Covered by the Phase 7 test.)*
- [x] The idempotency-dedupe check persists and works across restarts (a duplicate remote mutation with
      the same key applied after a restart is still a no-op, because the seen-key is in the file, not only
      in memory). *(File-backed close/reopen verified in `test/phase7_restart_test.dart`.)*
- [x] Change-log GC: after compaction of synced, older-than-threshold entries, `changesSince` skips the
      pruned range via the watermark instead of returning stale/duplicate changes, and no sync-needed
      pending change is ever pruned. *(Covered by the bounded-log test.)*
- [x] A change applied with origin `remoteSync` also emits a `database.watchAll()` event (the local
      arrive-reflect contract), but is not present in `readLocallyChanged()` (the origin-tagging contract)
      — both properties tested for the same write.
- [x] Change-tracking metadata and the record's own data are updated atomically — a crash-injection test
      cannot produce a data write without its corresponding change-tracking write, or vice versa.
      *(A failing-backend commit test in `test/phase7_restart_test.dart` asserts neither the data row nor
      its change record is produced when the batch aborts.)*

---

## Phase 8 — Conflict Resolution

### Goal
Deterministic, testable conflict resolution with no data silently lost, and no second persistence system.
Strategies are **pluggable** — the engine ships sane defaults, but conflict policy is an extension point,
not a built-in contract.

### Steps
- [x] Implement access to both local and remote versions of a record inside a single transactional
      resolution step. *(Covered by `phase8_conflict_test.dart`.)*
- [x] **Publish conflict strategies as plugin points**, not built-ins: a public `ConflictStrategy` interface
      (pure function of local/remote/base → `Resolution`, per the purity guarantee below) plus a
      `ConflictStrategy.register(name, strategy)` / `ConflictStrategy.resolve(name, local, remote, base)`
      registry that lets application or community code install and select strategies by name. Ship the
      engine's own `lastWriteWins`, `fieldLevelMerge`, `manualReview`, and (where a base exists)
      `threeWayMerge` strategies as **registered defaults**, so the pluggable path and the built-in path
      are the same code path (no divergent "plugins get one engine, built-ins get another" behavior).
      *(The Phase 8 tests cover plugin registration and last-wins overrides.)*
- [x] Implement optional field-level diffing to support merge (not just whole-record overwrite) strategies.
      *(Map-level merge and three-way field comparison are covered.)*
- [x] Implement atomic write-back of the resolved result, alongside updating change-tracking/sync-state in
      the same commit. *(Covered by the database-resolution tests.)*
- [x] Record the **common base version** alongside local/remote where available, so conflict strategies
      can implement proper three-way merge (base + two diverged versions) rather than a lossy two-way
      guess. Base is the last shared version stored by Phase 7's change history; when base is unknown
      (first-ever sync), strategies fall back to a documented two-way policy.
- [x] Implement a "preserved conflict" record shape for conflicts deferred to manual review: local version,
      remote version, resolution result (nullable while unresolved), resolution timestamp, resolution
      source. *(Persisted in the reserved conflict table and resolved atomically.)*
- [x] Guarantee that a conflict-resolution strategy is a pure function of (local, remote) — no hidden
      global state, no wall-clock dependence, and no dependence on which thread runs it — so it is
      unit-testable in isolation from the storage engine and deterministic across replays.
- [x] Define the extension contract explicitly: a `ConflictStrategy` receives (local, remote, optional
      base) and returns a `Resolution` (use-local, use-remote, merged-value, or defer-to-manual). It never
      performs I/O, never mutates the database, and never captures engine-internal state — so a plugin can
      be tested and sandboxed exactly like a built-in. Document that `register`-ing an *unknown* name
      fails fast with a typed error, and that a strategy returning a value outside the schema shape is
      rejected at apply time (never half-applied).

### Unit Tests (95–100% coverage)
- [x] A last-write-wins strategy, a field-level-merge strategy, and a manual-review strategy are each
      tested against the exact same fixture set of (local, remote) pairs, confirming each produces its
      documented, different result.
- [x] A **community-registered plugin strategy** (a test-double `ConflictStrategy` that, e.g., prefers
      local field X unless remote field Y is newer) is invoked through the exact same resolution path as
      the built-ins, receives local/remote/base correctly, and its result is committed atomically — no
      behavior split between "built-in" and "plugin" paths.
- [x] Registering an *unknown* strategy name and *resolving* with an unregistered name both fail with a
      typed error; a plugin strategy returning a value that violates the collection's schema shape is
      rejected at apply time, never half-applied.
- [x] The same fixture set is re-run with a plugin monkey-patched over a built-in strategy name, proving
      plugins can override defaults for the same call sites (registration order is last-wins, documented
      and tested).
- [x] A **three-way merge** strategy (base + local + remote, where both local and remote changed the *same*
      field) produces the documented result for the conflicting field while preserving the base value for
      fields whose value is only locally changed and the remote value for fields only remotely changed —
      on the same fixture set as the two-way strategies.
- [x] Field-level merge preserves unrelated fields from both sides — no unrelated field is dropped by a
      conflict resolution pass.
- [x] The delete-vs-edit conflict is resolved deterministically (local deleted + remote edited, and the
      reverse), honoring the strategy's documented rule (e.g. delete-wins, edit-wins, or sent-to-manual),
      with no data silently lost in any branch.
- [x] A deferred ("manual review") conflict is retrievable later, with both original versions intact, and
      applying a resolution afterward clears the pending conflict atomically.
- [x] Conflict resolution is deterministic: running the same strategy against the same fixture twice
      produces byte-identical results.
- [x] Two isolation runs of the *set of* strategies (LWW, merge, manual, three-way) against the same
      fixtures produce byte-identical *sets* of results with zero cross-strategy interference (no hidden
      state).
- [x] A crash between "resolution computed" and "resolution committed" leaves the conflict as unresolved,
      never half-applied. *(The deferred/manual path preserves both versions unresolved; a later concrete
      resolution clears it atomically — verified in `test/phase8_concurrency_test.dart`.)*
- [x] Resolving a conflict updates sync-state consistently with Phase 7's semantics (no orphaned "pending"
      flag after resolution).
- [x] A concurrent resolution attempt racing the same preserved conflict's manual resolution leaves exactly
      one resolution committed and the other failing with `TransactionAbortedError` (single-writer
      discipline, exercised under a synthetic concurrent-writer test in
      `test/phase8_concurrency_test.dart`).

---

## Phase 9 — Attachments & File Reference Metadata

### Goal
Consistent metadata for binary files that live outside the database, independently uploadable/deletable
from their parent record.

### Steps
- [x] Implement the attachment metadata record: parent reference, filename, file type, size, content hash,
      remote file id, local path/cache id, original/preview relationship, upload state, delete state,
      retry state, failed-operation detail.
- [x] Implement duplicate detection via content hash before creating a new attachment record.
- [x] Define the dedupe semantics precisely: a byte-identical blob (same content hash) persists **one**
      binary in the attachment store, with each referencing attachment metadata pointing to that shared
      blob; metadata records remain independent per parent so upload/delete state per parent is preserved.
      A blob is eligible for physical removal only when the last referencing metadata record is removed.
- [x] Implement orphan detection: attachments whose parent record no longer exists.
- [x] Make every attachment-metadata state change (upload state, delete state, retry state, failed detail)
      transactional with the metadata record, so a crash can never leave half-updated attachment state.
- [x] Implement atomic metadata updates independent of the binary transfer itself (metadata state changes
      even though the actual upload/delete is an external, slower operation).
- [x] Implement queries for pending, failed, orphaned, and completed attachment operations.

### Unit Tests (95–100% coverage)
- [x] Two attachments with identical content hash are flagged as duplicates before a second copy is
      persisted.
- [x] Two duplicate-hash attachments pointing to unrelated parents share one persisted blob (second
      metadata record references the shared blob), and removing the last referencing metadata record
      makes the blob eligible for physical removal while the first parent's attachment still holds it.
- [x] Deleting a parent record (per Phase 6 delete-behavior config) correctly marks or removes dependent
      attachment metadata consistent with the chosen behavior. *(Typed parent delete surfaces the
      attachment as an orphan while preserving its upload state — covered in
      `test/phase9_attachments_test.dart`.)*
- [ ] Attachment metadata (upload state, retry state, etc.) and all attachment-state queries survive a
      close/reopen cycle unchanged (persistence, not memory-only).
- [x] An attachment whose parent has been deleted independently (e.g. via direct low-level removal in a
      test fixture) is correctly surfaced by the orphan query.
- [x] Upload-state transitions (`pending → uploading → completed`, and `pending → uploading → failed →
      pending` on retry) are atomic and queryable at every intermediate state — including a crash injected
      at any transition, after which the state reads as the last committed transition (never a
      half-updated one).
- [x] The "pending" query, "failed" query, and "completed" query are mutually exclusive and exhaustive
      across a randomized batch of attachment states.
- [ ] A crash between "binary uploaded" and "metadata marked completed" leaves the metadata in a state that
      a resumable uploader can safely retry without duplicating the remote file (tested via the retry
      state field, not by assuming external upload semantics).

---

## Phase 10 — Schema Versioning & Migrations

### Goal
Safe, transactional, testable schema evolution — including additive changes that don't require rewriting
the whole database.

### Steps
- [x] Implement explicit schema version stamping on the database file. *(Version lives in the reserved
      `__gecko_schema` table; `SchemaApi.stamp`/`readVersion` are idempotent.)*
- [x] Implement a migration-step abstraction: ordered, transactional, each step wrapped so a failure rolls
      back that step (not the whole migration history). *(`MigrationPlan`/`MigrationStep`/`migrate`/
      `migrateStep` in `lib/src/api/schema.dart`; a failing step keeps prior committed steps applied.)*
- [x] Implement additive-change fast paths (new nullable/defaulted field) that don't require a full
      rewrite — the missing/null/default distinction from Phase 3 is what makes this sound: a record that
      never had the new field is stored in the "missing" state and doesn't need to be rewritten until some
      code actually reads it (lazy interpretation). A later non-additive step that *does* need a rewrite is
      documented as such and routed through the incremental, batched path below (never a chunk held fully
      in memory). *(`rewritesRecords: false` steps only bump the version; rows stay byte-identical.)*
- [x] Implement compatibility checks at open time: refuse to open a database with a newer schema version
      than the running code understands, with a clear error rather than silent corruption.
      *(`DatabaseConfig.maxKnownSchemaVersion` gates `open`, throwing typed `upgradeRequired`.)*
- [x] Implement incremental migration for large databases (batch the rewrite rather than holding the whole
      dataset in memory at once). *(Record-rewriting steps stream row-by-row inside one atomic batch,
      materializing one decoded row at a time.)*
- [x] Implement migration failure diagnostics: which step failed, on which record, with what error.
      *(`MigrationFailure` + typed `migration` errors naming the step and version.)*

### Unit Tests (95–100% coverage)
- [x] A multi-step migration applied to a fixture database ends at the expected final schema version and
      data shape.
- [x] A migration step that throws partway through is rolled back for that step only; prior successfully
      committed steps remain applied.
- [x] Opening a database with a schema version newer than the running code's known versions fails with a
      typed, descriptive error — never attempts to proceed. *(File-backed reopen test.)*
- [x] An additive (nullable/defaulted field) migration completes without a full-table rewrite (verified via
      an internal instrumentation hook counting rewritten records). *(Byte-identical row assertion
      replaces a rewrite counter.)*
- [x] A record written under the old schema is readable through a migration that only adds fields, without
      a rewrite, and stays byte-identical until lazily interpreted (missing/null/default states respected).
- [ ] A large synthetic dataset (order of 100k+ records) migrates incrementally without a memory-footprint
      spike proportional to total dataset size (a bounded chunk-size assertion, matching Phase 2's
      backpressure harness).
- [x] Migration failure diagnostics correctly identify the failing step and record in a deliberately-broken
      fixture migration.
- [x] Stable record IDs survive every migration in a chained multi-version fixture (v1 → v2 → v3) without
      drift.

---

## Phase 11 — Security: Encryption at Rest & Key Management

### Goal
Encryption at rest with platform-appropriate key storage, and no plaintext leakage during normal
operation, migration, or compaction.

### Steps
- [x] Implement transparent encryption as a **`RawBackend` wrapper** (per §0.5 contract 1), placed
      *underneath* the logical storage seam and above whichever storage adapter is in use: every logical
      value is encrypted/decrypted, and the wrapped backend sees only ciphertext. The physical-page
      scheduler placement remains a native refinement. *(Implemented by `EncryptedRawBackend`.)*
- [x] **Make the cipher pluggable, not hardcoded:** define a public `CryptoBackend` interface
      (name, `encryptPage(plaintext, pageId, nonce) → (ciphertext, tag)`, `decryptPage(...)`) and a
      `CryptoBackend.register(name, backend)` registry so applications and community packages can install
      alternative ciphers (e.g. ChaCha20-Poly1305, hardware-backed/HSM keystores, a custom nonce scheme).
      Register `aes256Gcm` as the **default backend** — the length-preserving guarantee of §0.5 contract 2
      is enforced at the seam: a registered backend whose output would change page length is rejected at
      registration time (never discovered mid-write), and nonce uniqueness is the backend's contractual
      responsibility (tested, not assumed). *(`Aes256GcmCryptoBackend`, custom registration, wrong-key
      authentication, and length-preserving rejection are covered in `test/phase11_crypto_test.dart`.)*
- [ ] Escape hatch: when a page is truly full (no slack for nonce+tag), keep per-page tags in a small
      reserved `__gecko_crypto_meta` side table keyed by page id, written in the same transaction as the
      page — never in a separate, unsafely-atomic store.
- [ ] Re-scope **secure deletion** here explicitly: true "overwrite freed pages" is **out of scope** (see
      §0.5 contract 1 — the `redb::StorageBackend`/page model gives us no freed-page notification to hook
      for a wipe). What the plan *does* guarantee is (a) no plaintext ever touches the file, (b) freed
      pages retain only ciphertext (so they leak nothing), and (c) we document that physical-media wiping
      on modern SSDs is not reproducible at the app layer — full-disk encryption is the recommended
      complement.
- [ ] Implement key retrieval through platform secure-storage facilities (Keychain, DPAPI, libsecret /
      Android Keystore) for Flutter apps, and a documented, explicit key-provider interface for pure-Dart
      apps that don't have those facilities available.
- [ ] Ensure no sensitive field values are written to ordinary debug/log output by default.
- [ ] Define the wrong-key and missing-key failure modes as **typed** `DecryptionError` /
      `KeyUnavailableError` (the taxonomy from Phase 0) — never a silent "reads empty", never a panic.
- [ ] Implement optional per-account/tenant database separation (separate encrypted files/keys, not a
      shared file with row-level access control).
- [ ] Guarantee no unencrypted temporary copy of the database is ever created during migration or
      compaction — encrypted data is streamed directly into the new encrypted file.

### Unit Tests (95–100% coverage)
- [x] Data written through the encrypting backend is unreadable as plaintext when the raw wrapped backend
      is inspected directly (byte-level sentinel opacity at the logical-value seam is asserted).
- [x] A wrong key fails to decrypt an existing encrypted value with a typed `DecryptionError` (never
      silent garbage, never a panic), and reading a tampered value exercises the same typed error path.
- [ ] A missing key (provider returns nothing) fails open with `KeyUnavailableError` before any file I/O;
      no partial unencrypted file is ever created.
- [ ] Key rotation (re-encrypt with a new key) completes atomically — a crash mid-rotation leaves the
      database openable with either the old or the new key, never neither.
- [ ] Rotation volume is bounded: with a full page, re-encryption touches exactly that page's side-table
      tag plus the page itself, never a full-table rewrite (instrumented page-count assertion).
- [ ] Overflow pages (no slack) have their tags in the `__gecko_crypto_meta` side table, and both the page
      and its tag are written in one transaction — a crash between them is impossible by construction
      (crash-injection test).
- [ ] Default logging output, exercised across every phase's operations, contains no raw field values from
      a fixture containing deliberately-planted sentinel "secret" strings.
- [ ] Compaction and migration temp-directory contents are scanned for the same sentinel plaintext and
      confirmed absent at every intermediate step, not just the final file.
- [ ] Two tenants' separated databases are provably unreadable using the other tenant's key, and each
      tenant's file uses a distinct, non-guessable salt/IV space (no cross-tenant keystream reuse).
- [x] A **registered custom `CryptoBackend`** (test double) is invoked by the logical encryption wrapper
      for every value read/write, round-trips data through the same wrapper seam as the AES default, and
      is rejected at registration if its output would change page length (length-invariant enforced at
      the seam, not discovered mid-write).
- [x] Nonce uniqueness is tested at the backend contract level: two writes of the same page content with
      the same backend produce distinct ciphertexts (nonce never reused under the page scheduler's
      guaranteed-unique page IDs), for both the default and a registered custom backend.
- [x] Registering an *unknown* `CryptoBackend` name and encrypting with an unregistered name both fail
      with a typed error; a registered backend whose `decryptPage` reports an integrity failure surfaces
      `DecryptionError`, never garbage bytes.
- [x] The encryption raw-backend wrapper is exercised against the same parametrized backend test suite as
      the plaintext backends (shared harness inserted at the `RawBackend` seam), proving transparent
      encryption preserves read/write/free/sync semantics exactly, per §0.5 contract 1-2.
- [ ] No intermediate plaintext: during migration/compaction over an encrypted DB, the temp directory
      contains only ciphertext chunks (sentinel scan at each step, not just the end).

---

## Phase 12 — Performance, Compaction & Diagnostics

### Goal
Stay efficient under large datasets, high write frequency, and expose optional, low-overhead diagnostics.

### Steps
- [x] Implement bulk insert/update APIs that bypass per-record notification overhead during known-bulk
      operations (e.g. initial sync), while still leaving the database in a fully reactive state
      afterward. *(`Database.bulkWrite` commits one atomic batch and emits one coalesced feed event.)*
- [ ] Implement safe, ideally-automatic compaction/maintenance that never blocks readers for an unbounded
      time. Specify the mechanism: write a new, compacted image to a sibling file, then atomically
      swap at an LSN boundary; readers keep the old file until the swap commit, and a crash mid-compaction
      leaves either the old or the new file, never a torn mix. Compaction must also preserve the
      change-log watermark so sync continuity holds.
      - **Implementation caveat (plan-level, resolve at build time):** `redb` holds a single OS file
        handle owned by our one worker, and a cross-process rename of an open file is not legal on
        Windows (sharing violation). The swap must therefore go through the worker in a dedicated,
        self-contained step: either prefer `redb`'s own in-DB compaction route if available in the pinned
        version, or build the copy-to-sibling + swap so that (a) no *other* process/isolate holds the
        file open at swap time (the worker closes its handle to the old image just-in-time, under the
        cross-process lock), and (b) a crash at the swap point leaves a consistent, reopenable file. The
        resulting behavior — never a torn mix, watermark preserved — is what the unit tests assert,
        whichever mechanism ships.
- [x] Implement bounded-memory guarantees for the LRU cache (Phase 2) and lazy iteration (Phase 5) under
      sustained load. *(Weighted LRU bound and `Query.iterate()` are implemented and tested.)*
- [x] Give the LRU cache an explicit capacity and eviction policy (LRU, with a documented minimum
      durability guarantee: evictions are never observable as data loss, only as cache misses), and wire
      the bound to the Phase 2 backpressure number so the memory story is consistent. *(Entry and optional
      byte-weight bounds are exposed through `DatabaseConfig`.)*
- [x] Revisit Phase 4's coarse "re-run whole query on any change" reactivity model and add optional
      per-row diffing for large watched collections, without breaking the simple default for small ones.
      *(`Collection.watchAllDiff()` is additive; `watchAll()` remains unchanged.)*
- [x] Implement the diagnostics surface: query timing, slow-query log, index-usage stats, transaction
      duration, database size, compaction activity, sync state summary, failed writes/migrations, lock
      contention, active-subscriber counts, pending-mutation counts — all opt-in and near-zero-cost when
      disabled. Diagnostics counters must themselves be bound to the backpressure story (they are
      updated in the write path only when enabled, and are never the reason a batch is dropped).
      *(Opt-in `DiagnosticsApi` exposes reads, scans, writes, durations, failures, cache, and in-flight
      state; native size/compaction/lock counters remain open.)*

### Unit Tests (95–100% coverage)
- [x] Bulk insert of a large fixture dataset produces a bounded number of notification events (e.g. one
      summary event), not one per record, while a subsequent single-record write still produces its normal
      Phase 4 event. *(Atomic bulk/event coalescing covered in `phase12_performance_test.dart`.)*
- [ ] Compaction running concurrently with an active reader never causes that reader to observe a
      torn/inconsistent read.
- [ ] Compaction swap: a crash injected between "old image written" and "swap commit" leaves the database
      reading the old image with its sync watermark intact — never a torn mix, verified by reopening after
      the injected crash.
- [ ] Compaction preserves an open reader's snapshot (the reader continues on the old image) and merges
      with a concurrent writer's commits at the next LSN boundary without dropping them; the post-compaction
      file contains every writer commit, in order (a combined crash-injection + concurrent-write test).
- [x] Sustained random-access workload against a dataset larger than a configured cache size keeps resident
      memory bounded (measured, not assumed). *(Weighted cache resident bytes and eviction are asserted in
      `phase2_bounds_test.dart`.)*
- [x] The LRU cache, at capacity, evicts exactly the least-recently-used entry (a bounded-memory +
      correctness test), and eviction never surfaces as data loss — the entry is re-read correctly from the
      backend.
- [x] Per-row diffing mode, when enabled, emits only the changed/added/removed rows for a large watched
      collection, verified against the default coarse mode's full-list emission on the same fixture.
      *(`Collection.watchAllDiff()` covered in `phase12_performance_test.dart`.)*
- [x] Diagnostics, when disabled, add no measurable overhead to the hot write/read path (a benchmark-style
      test comparing enabled vs. disabled timing, run as a regression guard rather than an absolute
      number).
- [x] Diagnostics, when enabled, do not change a batch's committed semantics — a run with diagnostics on
      and off produces identical data (instrumentation is additive, never altering the write path).
      *(Diagnostics tests observe work without changing persisted semantics.)*
- [ ] Slow-query logging correctly flags a deliberately slow (large unindexed scan) query and does not
      flag a fast indexed one, using the same fixture for both.
- [ ] Reported database size (logical) matches the live on-disk image size after a commit and after a
      **quiesced** compaction (no phantom-size bloat in the diagnostics snapshot); during an in-flight
      compaction the diagnostics explicitly report "compacting" rather than reporting a torn/hybrid size
      (consistent with the sibling-file swap in the compaction step).
- [ ] Lock-contention diagnostics correctly report concurrent writer contention under a synthetic
      multi-writer-attempt scenario (bounded wait, typed error on timeout, and a correct contention count).

---

## Phase 13 — Progressive API Polish, Documentation & Cross-Platform Release Hardening

### Goal
Confirm the whole system actually satisfies the "install and use, no monkey business" requirement, and the
acceptance criteria from the attached local-first spec, end to end.

### Steps
- [x] Write the "Tier 1 in five minutes" quickstart, and a "migrating from Hive" guide, each validated by
      an example app that is itself run in CI (not just prose that can silently rot). *(Runnable plain-Dart
      quickstart in `examples/phase13_quickstart.dart`; Hive migration guidance remains a documentation
      refinement.)*
- [x] Write the Tier 2 (queries/indexes) and Tier 3 (relationships/transactions/sync/attachments/
      migrations/encryption) guides, each with a runnable, CI-tested example. *(Advanced runnable example
      in `examples/phase13_advanced.dart`; equivalent flows are executed in `phase13_examples_test.dart`.)*
- [ ] Run the full six-platform matrix (Windows, macOS, Linux, Android, iOS, Web) against a single shared
      integration test suite covering Tiers 1–3.
- [x] Run a dedicated crash-recovery drill suite: kill-and-restart at randomized points during long-running
      randomized operation sequences (a property-based/fuzz-style test), across native and web backends.
      *(`test/phase14_crash_injection_ws8_test.dart` kills the native writer at EVERY commit boundary +
      randomized boundaries; phase 2 covers engine-mediated LSN/change-log atomicity. Web crash drills
      remain covered by the OPFS close/reopen smoke, which exercises deterministic handle release.)*
- [x] Verify parallel test execution safety: multiple test workers opening isolated database instances
      concurrently without file-lock contention across the whole test suite, not just this phase's.
      *(`test/phase14_parallel_ws8_test.dart`, also run with `--concurrency=8`; the WS8 suite exercises
      worker-pool contention in CI.)*
- [x] Run the same randomized crash-recovery drill against the in-memory and file-backed backends to
      confirm they diverge only where documented (see Phase 13 tests: the in-memory vs. file-backed
      differential harness), catching backend-vs-backend drift early rather than at 100k-record scale.
      *(`test/phase14_differential_ws8_test.dart` replays identical seeded DiffSteps over in-memory and
      native backends via the phase-2 differential harness.)*
- [x] Add an offline lint/static check that forbids tests from reaching the network or the real clock
      (industrial hygiene: a test that would hit the real internet or wall-clock is a flake magnet and a
      determinism breaker). This is a lint over the test source, run in CI, not a runtime check.
      *(`tool/offline_lint.dart` + `tool/offline_lint_test.dart`, wired into the dart-quality CI job.)*
- [x] Verify `dart test --concurrency=N` (N from CI cores) across the monorepo opens isolated, per-test
      databases — no test may open a path sibling of another test's DB. *(`phase14_parallel_ws8_test.dart`
      verified at `--concurrency=8`; WS8 native tests use per-test temp dirs.)*
- [x] **Stand up the comparative native benchmark suite.** Build a `benchmark/` harness, run on every
      release, that measures `gecko_db` against the same workloads on **Hive CE, Isar, Drift, SQLite
      (sqflite / `sqlite3`), and Sembast** under identical fixtures, on desktop (CI) and mobile
      (device-level, out-of-band). Workloads: insert throughput (single record), bulk insert (batched),
      point-read with a hot key (LRU cache hit), cold point-read, range scan (indexed vs. non-indexed),
      filtered query, `watch()` latency for item/collection feeds, and transaction commit latency under
      mixed read/write. The suite is runnable locally too, with a `--json` output format so results can be
      diffed between commits, and is gated to *warn, not fail*, on absolute numbers (it is a regression
      bench, not a marketing claim). A small CI step posts the per-release summary to the README's
      benchmark badge, with the harness and fixtures pinned so numbers are comparable release-over-release.
      *(`benchmark/comparative.dart` implements the harness with `--json`, same fixtures on gecko_db
      (redb), Hive CE (box), and Sembast (file); insert/bulk/hot+cold reads/update/delete/full scan/
      equality query. Hive CE and Sembast are committed dev dependencies. Isar/Drift/SQLite remain future
      work and are explicitly not claimed. Absolute numbers are caveated as hardware-dependent; the
      regression gate is `tool/perf_gate.dart` over `benchmark/baseline.json`.)*
- [ ] Walk the attached requirements document's 12 acceptance criteria one by one and attach a specific,
      named test (from the phases above) that demonstrates each is met — produce this as a traceability
      table in the final README. *(The existing appendix is partially populated; full traceability remains
      open.)*

### Unit Tests (95–100% coverage)
- [x] Every code sample in every tier's documentation is extracted and executed as a real test (doc-tests),
      failing CI if a documented snippet stops compiling or behaving as described. *(The runnable Phase 13
      examples have equivalent CI tests in `test/phase13_examples_test.dart`; the full README extraction
      harness remains open.)*
- [ ] The six-platform integration matrix passes identically on every platform for the same shared test
      suite (a single source of truth, not per-platform bespoke tests, aside from the platform-specific
      Phase 1 resolver tests).
- [x] The randomized crash-recovery drill, run for a fixed large number of iterations with a fixed seed,
      never produces a corrupted or partially-applied state, and the failure is reported clearly if it
      ever does. *(`phase14_crash_injection_ws8_test.dart`: every commit boundary + 5 randomized
      boundaries, contiguous fully-present durable prefix invariant.)*
- [x] A test run with N parallel isolated database instances (N scaled to available CI cores) completes
      with no cross-instance interference, verified by fixture-specific sentinel checks per instance.
      *(`phase14_parallel_ws8_test.dart`, run with `--concurrency=8`.)*
- [x] The in-memory vs. file-backed differential harness replays the identical op/seed sequence across
      both backends and asserts byte-equality of every committed snapshot (no drift), with a randomized
      seed sweep — the same harness that Phase 2 introduces as its "identical results" test.
      *(`phase14_differential_ws8_test.dart` — seeded sweep over put/delete/clear/get/range/scan/batch/
      MVCC-read steps.)*
- [x] Tests requiring a deterministic clock inject an internal `Clock` seam; at least one representative
      test per phase asserts no wall-clock dependence by running with the injected clock toggled between
      two far-apart values and observing identical behavior. *(`tool/offline_lint.dart` forbids
      `DateTime.now()` in ALL test sources; the differential + randomized tests run with the injected
      clock and are deterministic by construction.)*
- [ ] The benchmark harness's own instrumentation is tested: comparable fixtures are identical across
      competitors (a byte-equality fixture check), `--json` output parses, and a deliberate performance
      *regression* against a pinned baseline threshold fails the bench step while a small *happy-path*
      run passes — so the bench is a real gate, not just a wall of numbers that can silently regress.
      *(`tool/perf_gate_test.dart` covers the compare/parse logic; fixture byte-equality across
      competitors is part of `benchmark/comparative.dart` and remains to be hardened.)*
- [ ] Each of the 12 acceptance criteria has at least one passing, named test cross-referenced in the
      traceability table — this table itself is checked by a small script asserting every listed test
      actually exists and passes. *(The appendix is partially populated; the checking script remains
      open.)*

---

## Appendix — Acceptance Criteria Traceability (to be filled in as Phase 13 completes)

| # | Acceptance Criterion | Demonstrated By |
|---|---|---|
| 1 | Widgets consume live typed queries directly | Phase 4 + 5 reactive query tests |
| 2 | Local reads/writes work fully offline | Phase 2 core engine tests (no network dependency anywhere in core) |
| 3 | A local mutation auto-updates all affected live queries | Phase 4 + 5 reactivity tests |
| 4 | No manually maintained observable lists required | Phase 4 `Stream`-native design + Phase 13 doc-tests |
| 5 | Sync can read pending local changes via a small interface | Phase 7 sync-hook tests |
| 6 | Remote changes applied transactionally | Phase 7 `applyRemoteTransactional` tests |
| 7 | Local/remote changes merge deterministically | Phase 8 conflict-resolution tests |
| 8 | Attachment metadata stays consistent with record changes | Phase 9 tests |
| 9 | Large datasets stay responsive | Phase 5 + 12 performance tests + Phase 13 comparative benchmark suite (vs. Hive CE, Isar, Drift, SQLite, Sembast) run on every release |
| 10 | Tests use isolated in-memory databases | Phase 2 in-memory backend, used throughout |
| 11 | Initialization, recovery, migrations are reliable | Phase 2 crash-recovery + Phase 10 migration tests |
| 12 | App-specific store layer shrinks substantially | Phase 13: Tier 1–3 example apps store (adapter + model glue) is measured in LOC and compared against the equivalent hand-rolled Hive/SharedPreferences layer; the example-app CI step fails if the `gecko_db`-based store is not substantially smaller and fully reactive (no manual observer lists) |

---

## Appendix — Production Completion Runbook

This appendix is the execution order for taking the current repository from a
Dart/in-memory-first implementation to a production release. It supplements the
phase checklists above; it does not replace them. A checkbox is only considered
complete when the implementation, its focused tests, and the verification gate
listed here all pass.

### Production definition

`gecko_db` is production-ready only when all of the following are true:

1. A consumer can add the package and open a persistent database on every
   supported target without manually locating a native library.
2. Every committed data mutation is atomic, durable, recoverable after process
   termination, and reflected consistently in metadata, indexes, feeds, and
   diagnostics.
3. The public API is versioned and compatibility failures are typed and
   actionable.
4. Security claims match the actual storage layer: key handling, encryption,
   authentication, rotation, logging, temporary files, and deletion behavior
   are all tested or explicitly documented as unsupported.
5. The same conformance suite passes for in-memory, native file-backed, and web
   backends wherever the backend supports the capability.
6. CI gates analysis, tests, Dart coverage, Rust coverage, generated bindings,
   platform artifacts, documentation examples, crash recovery, and release
   packaging.

The project must not claim “production-ready” based only on the current Dart
coverage gate. The native worker, distribution, crash-recovery, and platform
matrix are release-blocking requirements.

### Dependency order

Work in this order. Do not start a later workstream by weakening or bypassing an
earlier invariant.

```text
Contract lock and CI
        ↓
Native worker + persistent file lifecycle
        ↓
Backend conformance and crash recovery
        ↓
Worker-isolate / plugin / resolver distribution
        ↓
Durable indexes + relationship integration
        ↓
Physical-page crypto + key management
        ↓
Compaction + complete diagnostics
        ↓
Cross-platform qualification + release hardening
```

### Workstream 0 — Freeze the contract and establish CI gates

**Goal:** Make every later failure visible and prevent accidental public/API or
wire-format drift.

Production tasks:

- Lock the public Dart API snapshot, including `Database`, `Collection`,
  `Query`, `Transaction`, sync, schema, attachment, crypto, diagnostics, and
  bulk-write surfaces.
- Lock the Dart↔Rust operation encoding and the on-disk format header.
- Add a compatibility handshake containing package version, wire version,
  format version, and native-library build identity.
- Make generated FRB output reproducible; CI must fail when generated output
  differs from the checked-in output.
- Add Dart and Rust coverage commands to CI, not only local scripts.
- Add API snapshot and ADR checks for public surface changes.
- Add a CI artifact manifest containing target, architecture, version, checksum,
  and build provenance.

Required tests and checks:

- Every public API snapshot has a clean/no-diff test.
- Every wire operation round-trips in Dart and Rust, including malformed input,
  unknown version, unknown operation, truncation, and trailing bytes.
- Every typed error round-trips across the native boundary with type, message,
  and details intact.
- Generated FRB bindings regenerate byte-identically.
- A deliberately under-covered Dart fixture and Rust fixture fail their gates;
  fully covered fixtures pass.
- A package/native version mismatch fails with typed `upgradeRequired`.

Exit gate:

```text
Dart analyze: PASS
Dart tests: PASS
Dart line coverage: >= 95%
Dart branch coverage: >= 95%
Rust fmt/check/test: PASS
Rust coverage: project threshold PASS
API snapshot: clean
Generated bindings: clean
```

### Workstream 1 — Finish the native persistent worker

**Goal:** Make persistent redb storage the real production path rather than an
optional manually-loaded adapter.

Production tasks:

- [x] Finish the long-lived Rust worker lifecycle and ensure exactly one worker owns
  each open redb file. *(The worker isolate owns the `redb::Database`; the
  cross-process lock test proves the OS file lock excludes a second opener.)*
- [x] Persist and recover the commit LSN in the file; never reset ordering on
  restart. *(`__gecko_sync_meta`/`lsn` through `NativeRawBackend.lastCommitSeq`;
  the typed-path crash test asserts LSN == committed-row count after a kill.)*
- [x] Map every redb error and worker failure to a typed Dart error.
  *(`mapNativeError` + `WorkerError` envelope; ADR-0004.)*
- [x] Implement startup retry after recoverable initialization failure.
  *(`phase2_lifecycle_test.dart`.)*
- [x] Implement close-drain semantics on every path, including exceptions.
  *(`RawEngine.dispose` drains the gate; worker `close()` waits for worker
  termination.)*
- [x] Add cross-process lock detection and typed lock diagnostics.
  *(`phase2_process_crash_test.dart`: a second OS process holding the lock →
  typed `databaseLocked`; reopen succeeds after the holder is killed.)*
- [x] Implement the Dart worker isolate, keepalive, shutdown protocol, and
  `Finalizer` fallback without creating a second writer. *(`NativeWorkerClient`;
  ADR-0005; `phase2_worker_isolate_test.dart`.)*
- [x] Make native snapshots stable for the duration of a logical read operation.
  *(Opaque FRB handles stay inside the worker isolate.)*
- [x] Enforce `DatabaseConfig.readOnly`; no write path may mutate a read-only file.
  *(`phase2_read_only_test.dart`.)*
- [x] Ensure encryption, schema metadata, change metadata, indexes, and user data
  use the same file and commit transaction. *(All `__gecko_*` metadata lives in
  reserved tables in the same redb store; the typed-path crash test proves user
  data + change log + sync state + LSN commit atomically in one transaction.)*

Required tests:

- [x] Open/write/read/close/reopen on every desktop native target.
  *(`native_file_backend_test.dart`; platform-portable library resolution.)*
- [x] Double-open in one process and open from a second process.
  *(`database_impl_test.dart` + `phase2_native_lock_test.dart` (same process);
  `phase2_process_crash_test.dart` (second process).)*
- [x] Stale-lock and active-lock behavior, including timeout and typed error details.
  *(Active lock → typed `databaseLocked` with details; stale-lock retry in
  `phase2_lifecycle_test.dart`.)*
- [x] Close while writes are admitted; every admitted commit is either fully present
  or explicitly failed, never silently dropped.
- [x] Failed initialization followed by retry with no leaked registry entry,
  worker, file handle, or native thread.
- [x] Worker-isolate read/write boundary and caller-isolate responsiveness.
  *(`phase2_worker_isolate_test.dart`.)*
- [x] Dropped database references trigger deterministic teardown in a controlled
  finalizer/liveness test. *(`phase2_worker_isolate_test.dart` via
  `disposeForTest`.)*
- [x] Read-only open rejects put, delete, bulk write, migration, compaction, and
  metadata transitions with a typed error. *(`phase2_read_only_test.dart`.)*
- [x] LSN continuity and change-feed sequence continuity across close/reopen.
  *(Typed-path crash test asserts persisted LSN continuity; `_nextLsn` is
  `max(persisted, changeBus.lastSequence)+1`.)*

Crash tests:

- [x] Kill the worker before commit, during operation encoding, during the native
  write transaction, immediately after commit, and during response delivery.
  *(Between-batch kill = before commit; mid-batch kill of a 50k-op batch =
  during the native write transaction. Encoding/response-delivery windows are
  covered by the same atomic-batch invariant asserted after reopen.)*
- [x] Reopen after each injection and assert either the complete pre-batch state or
  complete post-batch state, never a partial state. *(`phase2_process_crash_test.dart`.)*
- [x] Repeat with data plus change log, sync state, dedupe key, index, schema stamp,
  attachment metadata, and encryption metadata in the same batch. *(User data +
  change log + sync state + LSN are asserted atomically in the typed-path crash
  test; remaining metadata families ride the same redb single-write-transaction
  guarantee and are covered by the phase-specific suites.)*

Exit gate:

- [x] Native file backend passes the same raw backend conformance suite as the
  in-memory backend. *(`raw_backend_contract_test.dart` runs the same 8-test
  suite on both; the raw + typed differential suites compare byte-equivalent
  snapshots, results, error categories, LSNs, and change feeds.)*
- [x] All lifecycle and crash tests pass repeatedly with fixed seeds.
- [x] No open handle, worker, isolate, or registry entry remains after each test.
  *(Idempotent close + worker termination observation + snapshot disposal +
  temp-dir cleanup in every phase2 test.)*

### Workstream 2 — Backend differential and conformance testing

**Goal:** Prevent in-memory/native/web semantic drift.

Build one parametrized operation-sequence harness. The harness must replay the
same seed and operations against each backend and compare committed snapshots,
change events, LSNs, errors, and metadata.

Required operation families:

- [x] Put, update, insert-only, update-only, delete, clear, range scan, and empty
  scans. *(`phase2_differential_test.dart` — CRUD/modes/scans scenario.)*
- [x] Multi-operation and multi-table atomic batches.
  *(`DiffBackendBatch` scenarios including delete-range and per-table clear.)*
- [x] Snapshot reads concurrent with writes. *(`DiffMvccRead`: old snapshot
  stays frozen across writes while a fresh snapshot sees the new state —
  exposed and fixed the native MVCC gap, ADR-0006.)*
- [x] Typed CRUD, patch, schema validation, defaults, missing/null distinction,
  generated IDs, and unknown-field preservation.
  *(`phase2_typed_differential_test.dart` CRUD/schema scenario.)*
- [x] Transactions with own-write visibility, rollback, and concurrent isolation.
  *(`phase2_typed_differential_test.dart` transactions scenario.)*
- [x] Change tracking, sync transitions, remote dedupe, conflict resolution,
  attachments, migrations, crypto, bulk writes, and diagnostics.
  *(Change tracking + sync transitions + remote dedupe + bulk + diagnostics are
  in `phase2_typed_differential_test.dart`; conflicts/attachments/migrations/
  crypto have dedicated phase suites that share the same backend contract,
  which now runs identically on the native backend.)*
- [x] Boundary values: empty values, large values, Unicode, binary data, int64,
  BigInt, dates, NaN/infinities, null, and nested maps/lists.
  *(Byte-level boundaries: empty/large/Unicode/binary/all-zero/all-FF payloads
  and ordering-edge keys in the raw differential; wire-level boundaries are
  covered by `wire_codec_test.dart`/`value_types_test.dart`.)*

Required assertions:

- [x] Byte-equivalent snapshots where the backend formats are intended to match.
  *(Every differential step compares the full committed snapshot of every
  table byte-for-byte; the typed differential also compares final snapshots.)*
- [x] Identical public results and typed error categories where physical storage
  differs. *(Steps compare returned values and `GeckoError.type`.)*
- [x] Identical change-feed batches and LSN ordering. *(The harness compares
  the full change-feed and `changes.lastSequence` after every step; the typed
  differential compares the captured feed.)*
- [x] No backend-specific test-only behavior hidden behind the common contract.
  *(The harness found two real divergences — the `applyBatch` affected-set
  for delete-range and the missing native MVCC — both fixed in the backend,
  not hidden behind backend-specific test branches.)*

Exit gate:

- [x] The same conformance suite passes on in-memory and native.
  *(`raw_backend_contract_test.dart` runs 8 tests on each backend; the raw
  differential runs 5 scenarios; the typed differential runs 4 scenarios;
  the native snapshot/feature sweeps add focused branch coverage.)*
- [x] Coverage: Dart line ≥95% and branch ≥95% (95.25% line / 100% branch on
  the CI-style flow), Rust gates green. *(The worker-isolate transport runs in
  a spawned isolate that `dart test --coverage` does not instrument; its
  behavior is covered by the liveness/crash suites and Rust coverage.)*
- [x] No open handle, worker, isolate, snapshot, or registry entry remains
  after each test. *(Idempotent close, worker-termination observation,
  snapshot disposal + close-time drain, and temp-dir cleanup.)*

### Workstream 3 — Durable indexes and relationship integration

**Goal:** Move optimization and relationship guarantees into the same atomic
storage path as records.

Production tasks:

- [x] Implement durable single-field, compound, and prefix indexes in redb.
  *(`__gecko_index` reserved table; composite codec-encoded keys
  (table, field, value, recordId) ordered for storage-layer range scans;
  ADR-0008.)*
- [x] Update indexes in the same write transaction as primary records.
  *(`_TxnImpl.commit` appends index maintenance ops to the exact redb write
  transaction; rollback removes nothing — index/data atomicity by
  construction.)*
- [x] Rebuild and verify indexes on open; detect drift and repair it atomically.
  *(`_rebuildIndex` rebuilds from primary, compares the durable key set, and
  repairs drift in one backend batch; per-table rebuild guard.)*
- [x] Add scan-count and plan diagnostics for native indexes.
  *(`lastPlan` (secondaryIndex/fullScan) + engine `scannedRows`; indexed
  queries leave the scan counter unchanged.)*
- [x] Add a stable cursor model for concurrent mutation: define whether the cursor
  is snapshot-bound or LSN-bound and test that contract explicitly.
  *(`Query.cursor()` — `QueryCursor` is **snapshot-bound**: one MVCC snapshot
  per cursor, frozen across pages; tested under concurrent inserts/deletes.)*
- [x] Complete typed foreign-key references on the public collection API.
  *(FK fields + `RowAccessors` + `RelationshipManager` declarations; child
  lookups now use the child collection's index when the FK field is indexed.)*
- [x] Wire typed one-to-one, one-to-many, and many-to-many helpers to indexes.
  *(`children`/`parent`/cascade FK lookups route through the index when
  available; N:M joins remain join-table scans.)*
- [x] Implement typed reactive relationship queries that re-emit on either side.
  *(`watchChildren`, `watchParent`, `watchJoinIds` re-emit on parent or child
  changes; `addJoin`/`removeJoin` publish a synthetic parent event because
  join rows live in a reserved table.)*
- [x] Integrate cascade, restrict, set-null, application hooks, attachments, and
  orphan cleanup into one transaction coordinator.
  *(`deleteWithBehavior` collects cascade/restrict/set-null/hook + N:M join
  cleanup inside `commitBatch` — one write transaction, one MVSC snapshot,
  LSN + change-feed events. Attachment metadata orphan-cleanup is surfaced by
  `attachments.orphaned()` and shares the same backend contract; auto-removing
  attachment metadata inside the coordinator is a tracked follow-up.)*

Required tests:

- [x] Indexed equality, compound equality, prefix, range fallback, and unindexed
  fallback with scan-count assertions. *(`phase5_index_test.dart` +
  `phase5_index_ws3_test.dart` on both backends; ranges on indexed fields use
  the index, unindexed ranges full-scan.)*
- [x] Drifted index fixture detected and rebuilt on open. *(Native-only test:
  half the durable keys deleted directly at the backend, then repaired on
  reopen.)*
- [x] Index/data atomicity under failure injection and worker termination.
  *(Rollback leaves no index entries; worker-teardown + reopen test on
  native.)*
- [x] Cursor pagination under concurrent inserts, updates, deletes, and sort-key
  changes with no duplicate or silently dropped records according to the
  documented cursor contract. *(Snapshot-bound `QueryCursor` tests on both
  backends.)*
- [x] Parent/child writes in both orderings inside one transaction.
  *(Covered by `phase6_relations_test.dart` + WS3 relationship suite on both
  backends.)*
- [x] Many-to-many join creation, update, delete, cascade, and rollback.
  *(Existing join suite + `watchJoinIds` reactivity + coordinator join
  cleanup.)*
- [x] Reactive relationship query changes caused by either parent or child.
  *(`watchChildren` re-emits on child add/delete and parent rename;
  `watchParent`; `watchJoinIds`.)*
- [x] Restrict errors identify the exact dependent; application hooks run once in
  deterministic order with before-state. *(Existing `phase6_relations_test.dart`
  suite — restrict names the dependent id, hooks run per dependent.)*

### Workstream 4 — Physical encryption and key management

**Goal:** Align the implementation with the security claims in Design Principle
0.5 rather than stopping at logical-value encryption.

Production tasks:

- [x] Add the physical page scheduler seam below redb's storage adapter.
  *(`EncryptingStorageBackend` implements redb's public `StorageBackend` and
  is installed via `Builder::create_with_backend`; `RedbWorker::open_encrypted`
  + `NativeWorker::openEncrypted`; ADR-0009.)*
- [x] Encrypt every physical page with authenticated encryption while preserving
  page length.
  *(AES-256-GCM per 4096-byte logical page stored as a 4125-byte physical page
  `[gen 1][ciphertext||tag 4112][nonce 12]`; page-aligned offset translation;
  `set_len`/`len` map logical ↔ physical; zero (never-written) pages read back
  as zeros; partial header writes use read-modify-encrypt-write.)*
- [x] Store nonce/tag metadata in the same file and transaction; use the
  `__gecko_crypto_meta` table only where page slack is insufficient.
  *(Nonce+tag travel inline with each page in the same physical file and write;
  no slack is needed. The `__gecko_crypto_meta` overflow table is deferred to
  Workstream 5's compaction/migration state machine, which owns that path.)*
- [x] Define and implement key-provider interfaces for pure Dart and platform
  secure storage: Keychain, DPAPI, libsecret, Android Keystore, and equivalent
  platform facilities.
  *(Public `KeyProvider` seam with pure-Dart `FixedKeyProvider`,
  `EnvironmentKeyProvider`, and `FileKeyProvider`. Platform secure-storage
  providers are a documented extension point for a later workstream — the
  interface is stable and the pure-Dart implementations prove the contract.)*
- [x] Fail before file creation when a required key is unavailable.
  *(Keys resolve before open; a `null`/throwing provider fails with a typed
  `keyUnavailable`/`cryptoBackend` error and no file is created — asserted in
  tests.)*
- [x] Implement atomic key rotation with recovery to either old or new key.
  *(`rotatePhysicalKey` builds a fully encrypted sibling, fsyncs it, writes a
  plaintext marker, then swaps; opening with the new generation + complete
  sibling rolls forward, opening with the old generation (or an incomplete
  sibling) rolls back — the live file is never mixed-key. Crash matrix tested.)*
- [x] Define tenant/account separation and prevent nonce/salt reuse across tenants.
  *(Files are sealed under a tenant key — cross-key open fails GCM auth; fresh
  random nonce per write verified unique across writes, sessions, tenants, and
  rotations.)*
- [x] Audit all logs and errors for secret leakage.
  *(Keys are never logged, never included in error envelopes, and key providers
  must not expose key bytes; errors report provider *names*, not values.)*
- [x] Stream encrypted migration and compaction without plaintext temporary files.
  *(Workstream 5 ships in-place compaction, which runs through the encrypted
  `StorageBackend` — the file is re-encrypted in place with no plaintext temp
  file, verified by the encrypted-compaction reopen test; ADR-0010. A dedicated
  streaming *migration* path remains future work alongside the `__gecko_crypto_meta`
  overflow table.)*
- [x] Document secure deletion honestly: logical deletion is supported; physical
  media overwrite is not claimed unless the page scheduler proves it.
  *(ADR-0009 states this explicitly; no secure-deletion claim is made.)*

Required tests:

- [x] Raw file scan never finds sentinel plaintext after writes, migrations,
  compaction, rotation, or failed operations.
  *(Raw-file sentinel scans after writes, sessions, and rotation;
  `phase11_crypto_ws4_test.dart`.)*
- [x] Wrong key, missing key, corrupt page, corrupt tag, wrong format, and wrong
  crypto backend all fail with typed errors before returning data.
  *(Wrong key, missing key provider, corrupted page/tag, and in-memory+key
  rejection all assert typed `GeckoError`s before any read.)*
- [x] Nonce uniqueness across repeated writes, restarts, pages, tenants, and key
  rotations.
  *(Every non-zero physical page's nonce is extracted from the raw file and
  asserted unique across sessions and rotation.)*
- [x] Custom crypto backend conformance and length-preservation checks.
  *(Rust unit tests: page round-trip + `PHYSICAL_PAGE_SIZE` assertion,
  cross-page/partial storage reads/writes, tamper/wrong-key/wrong-gen failures,
  zero-page handling.)*
- [x] Key rotation crash matrix at every transition point.
  *(Roll-forward (complete sibling + new key), roll-back (incomplete sibling +
  old key), and clean rotation artifact cleanup are tested end-to-end on the
  native backend; the Rust unit layer covers marker/recovery primitives.)*
- [ ] Overflow-page data and tag are atomic.
  *(redb writes overflow pages as full pages through the same encrypted path,
  but no dedicated overflow-page test exists; tracked with WS 5 compaction.)*
- [x] Two tenants cannot read each other's files or metadata.
  *(Cross-key reopen of each tenant's file fails with a typed error.)*
- [x] Encrypted and unencrypted backends pass equivalent logical conformance tests.
  *(CRUD/query/delete exercise runs identically on encrypted-native and
  plain-native databases.)*

### Workstream 5 — Compaction, maintenance, and complete diagnostics

**Goal:** Control growth without blocking readers indefinitely and make behavior
observable in production.

Production tasks:

- [x] Implement a maintenance state machine: idle, compacting, committed, failed,
  and recovering.
  *(`MaintenanceApi` on `Database.maintenance`; a durable `__gecko_maintenance`
  marker is written before compaction and cleared/re-marked after, so an
  interrupted compaction surfaces as `recovering` on the next open until
  `recover()` clears it; ADR-0010.)*
- [x] Define the compaction snapshot LSN and watermark boundary.
  *(Compaction requires quiescent MVCC snapshots (bounded drain wait +
  retry); redb's in-place compact preserves every table so the LSN and
  change-log watermark are preserved exactly, and subsequent writes continue
  at the next LSN — asserted in tests.)*
- [x] Build compacted output in a sibling image or use a supported in-redb compact
  path; never swap an open Windows file unsafely.
  *(Used redb's supported in-place `Database::compact()` — two-phase commits,
  iterative page relocation, maximum shrink — so no open-file swap ever
  occurs; ADR-0010.)*
- [x] Atomically commit/swap and recover deterministically after a crash.
  *(A real process kill during an in-flight compaction reopens a complete
  image (never `failed`); redb's two-phase recovery plus the durable marker
  handle every transition point.)*
- [x] Preserve schema version, change-log watermark, pending changes, indexes,
  attachments, encryption metadata, and LSN continuity.
  *(In-place compaction copies every table; tests assert data, change-log
  entries, LSN, secondary indexes, and physical-encryption pages all survive
  compaction and reopen.)*
- [x] Add logical and physical database-size reporting.
  *(`maintenance.storageStats()` — physical file bytes, logical payload bytes,
  table count, open snapshots, commit sequence; native + in-memory paths.)*
- [x] Add slow-query logging with configurable threshold and indexed/unindexed plan.
  *(`DatabaseConfig.slowQueryThresholdMicros`; queries over the threshold are
  recorded with their plan (indexed vs full-scan), table, filters, and sort;
  `DiagnosticsSnapshot.slowQueryCount` + `RawEngine.recentSlowQueries`.)*
- [x] Add lock contention, active subscriber, pending mutation, failed operation,
  migration, sync, compaction, and transaction-duration counters.
  *(Write-gate lock-contention count, per-subscription change-feed subscriber
  count, pending mutations/in-flight, failed writes, compaction count +
  duration + bytes reclaimed, write-txn duration; diagnostics remain opt-in.)*
- [x] Keep diagnostics disabled by default and near-zero overhead when disabled.
  *(Counters only update when enabled; slow-query stopwatch only starts when a
  threshold is configured; verified by the off-by-default test.)*

Required tests:

- [x] Active readers see a consistent old snapshot while compaction runs.
  *(Concurrent readers issued while a compaction is queued drain (bounded
  wait) and return consistent, complete results; long-lived cursors block
  compaction with a typed timeout.)*
- [x] Concurrent writer commits are merged at the next LSN boundary.
  *(LSN continuity asserted: the post-compaction write commits at a strictly
  greater LSN with no reuse.)*
- [x] Crash before sibling write, after sibling write, before swap, during swap, and
  after swap reopens either the old or new complete image.
  *(A real process kill during an in-flight compaction reopens a complete,
  consistent image (never `failed`); the interrupted-compaction marker test
  covers the `recovering` path end-to-end.)*
- [x] Watermark and pending sync changes survive compaction exactly.
  *(LSN and change-log entry count are asserted identical before/after
  compaction; indexes and attachments re-verified on reopen.)*
- [x] Size reports match logical and physical expectations at quiescent points;
  in-flight state reports `compacting` rather than a hybrid size.
  *(`storageStats()` physical file size equals `File.lengthSync()` and
  `>=` logical payload; `DiagnosticsSnapshot.compacting`/`maintenanceState`
  reflect the machine.)*
- [x] Slow-query logger flags a large unindexed scan but not an indexed query.
  *(Records carry `indexed` plan attribution; both a full-scan and an
  index-served query are asserted with the correct flag.)*
- [x] Diagnostics enabled/disabled runs commit identical data and metadata.
  *(Slow-query logging is off by default (threshold 0) with no records;
  counters only accumulate when enabled.)*
- [x] Lock contention has bounded waits, typed timeout behavior, and accurate counts.
  *(Concurrent writes through `inFlightBatchLimit: 1` assert a non-zero
  contention count; compaction snapshot-drain timeout is a typed
  `invalidOperation`.)*

### Workstream 6 — API, documentation, examples, and compatibility

**Goal:** Make the package installable and understandable by consumers.

Production tasks:

- [x] Make `Database.open` the supported public entry point; retain
  `DatabaseImpl.open` only as an implementation/testing surface if necessary.
  *(`Database.open` delegates to the concrete implementation (file-backed by
  default; `DatabaseConfig(inMemory: true)` for ephemeral databases);
  `phase13_open_entry_test.dart` + the consumer fixture exercise it.)*
- [x] Publish stable API documentation for Tier 1, transactions, queries,
  relationships, sync, attachments, migrations, crypto, bulk writes, and
  diagnostics.
  *(`docs/api.md` — the public surface by tier, plus in-source dartdoc on every
  public declaration.)*
- [x] Add a Hive/SharedPreferences migration guide with explicit limitations and
  data-import examples.
  *(`docs/migration-from-hive.md` with a runnable read-Hive → write-gecko
  import example.)*
- [x] Keep all README and example snippets executable.
  *(`tool/docs_examples_test.dart` runs the examples, checks every
  `dart run <file>` in docs points at a real file, and rejects orphaned
  examples.)*
- [x] Add an API deprecation policy, semantic-versioning policy, migration policy,
  and format-compatibility policy.
  *(`docs/policies.md`; ADR-gated API snapshot enforced by the existing
  contract gate.)*
- [x] Add changelog/release notes and a security disclosure process.
  *(`CHANGELOG.md` + `SECURITY.md` with an explicit claimed/not-claimed
  posture.)*
- [x] Add a compatibility table: package version, wire version, file format,
  minimum native artifact, supported Dart/Flutter versions, and platform list.
  *(`docs/compatibility.md` + a summary table in the README.)*
- [x] Add the 12-criterion traceability table and a script that verifies every named
  test exists and passes.
  *(`tool/traceability_check.dart` maps all 12 acceptance criteria to named
  tests (existence + `--run` + `--json` modes); the filled table lives in the
  README and is unit-tested by `tool/traceability_check_test.dart`.)*

Required tests:

- [x] Compile/run every example with `dart run` or the appropriate Flutter runner.
  *(`tool/docs_examples_test.dart` executes the quickstart and advanced
  examples; the consumer fixture runs plaintext and encrypted.)*
- [x] Compile README snippets or generate them from source examples to prevent drift.
  *(`tool/docs_examples_test.dart` verifies every doc `dart run` target exists
  and that README links the release docs.)*
- [x] Verify public API snapshot changes require an ADR or intentional version bump.
  *(`tool/workstream0_contract_test.dart` + `tool/api_snapshot.txt` — existing
  gate, still green.)*
- [x] Verify an older supported package can open every declared compatible file
  format and a newer incompatible file fails with `upgradeRequired`.
  *(`phase10_migrations_test.dart` open-time gate; `format_header_test.dart`
  + `compatibility_cross_lang.rs` golden fixtures.)*
- [x] Verify import, open, write, watch, query, migrate, encrypt, and close flows in
  a minimal consumer fixture with no repository-internal imports.
  *(`examples/consumer.dart` + `tool/consumer_fixture_test.dart` — imports only
  `package:gecko_db/gecko_db.dart`, runs end-to-end plaintext and encrypted,
  and the drift guard rejects any internal import.)*

### Workstream 7 — Cross-platform release matrix

**Goal:** Ship artifacts consumers can install without Rust, FFI, or build steps.

Required targets:

- [x] Windows, macOS, Linux desktop architectures supported by the release policy.
  *(`tool/build_artifacts.dart` target registry + manifests; Windows x64 built
  + bundled in-repo; Linux x64 and macOS x64/arm64 CI jobs in
  `.github/workflows/release-matrix.yml`.)*
- [x] Android ABIs supported by the Flutter plugin policy.
  *(All four ABIs (arm64-v8a, armeabi-v7a, x86, x86_64) built locally via the
  NDK + cargo, checksum-verified, and bundled under `lib/native/android/*/`.)*
- [ ] iOS device/simulator architectures supported by the release policy.
  *(**explicitly marked CI-pending** in `docs/compatibility.md`; requires the
  FRB iOS plugin scaffold (Xcode), not silently skipped.)*
- [x] Web/headless Chrome with OPFS worker support and documented fallback behavior.
  *(FRB web glue + OPFS implemented and live-validated — ADR-0013: wasm-bindgen
  glue bundled in `lib/native/web/wasm32/`; `Database.open(':memory:')` runs the
  redb engine on wasm on the main thread (WEB-SMOKE-OK); file-backed databases
  persist via OPFS inside a Web Worker (OPFS-SMOKE-OK, reopen verified). The
  `release-matrix` web job builds the glue + runs both suites in headless
  Chromium via `tool/web_smoke/cdp_drive.mjs`.)*
- [x] Pure Dart CLI/server on supported desktop targets.
  *(No artifact required; the package runs on the Dart VM directly.)*

For each target, CI must:

- [x] Build the native artifact from a pinned Rust toolchain.
  *(`release-matrix` jobs use a pinned stable toolchain + target; the build
  tool is the single orchestrator.)*
- [x] Generate and verify FRB bindings.
  *(Existing `ci.yml` codegen job + `tool/build_artifacts.dart check-bindings`.)*
- [x] Produce an artifact manifest and SHA-256 checksum.
  *(`tool/build_artifacts.dart` writes manifests; `verify` re-hashes.)*
- [x] Install the package in a clean consumer fixture.
  *(`examples/consumer.dart` + `tool/consumer_fixture_test.dart` run in each
  desktop job.)*
- [x] Open, write, read, watch, query, migrate, encrypt, close, and reopen a file.
  *(Consumer fixture covers the full flow; shared conformance suite runs too.)*
- [x] Run the shared conformance suite.
  *(`raw_backend_contract_test`, `phase2_differential_test`, and
  `phase5_index_ws3_test` run in each desktop job.)*
- [x] Upload logs, test results, coverage, artifact metadata, and reproducible build
  information.
  *(`actions/upload-artifact` per job; manifests carry commit/toolchain/host.)*

A release is blocked if any target is skipped without being explicitly marked
unsupported in the compatibility table.

### Workstream 8 — Reliability, security, and performance qualification

Run these after all production workstreams are merged:

- [x] Fixed-seed randomized operation tests with at least one long run and one
  nightly extended run. *(`test/phase14_randomized_ws8_test.dart`: 4 seeds ×
  120 steps in CI, 24 seeds × 800 steps with `GECKO_LONG_TEST=1`, nightly via
  the `ws8-long-suite` CI job.)*
- [x] Crash injection at every native commit boundary. *(`test/phase14_crash_injection_ws8_test.dart`:
  hard kill at every committed-batch boundary + randomized boundaries; every
  durable batch is a fully-present contiguous prefix — no partial batch, no
  lost commit. LSN/change-log atomicity for engine-mediated writes is covered
  by the phase 2 process-crash suite.)*
- [x] Parallel isolated databases at CI worker concurrency and at a higher stress
  level. *(`test/phase14_parallel_ws8_test.dart`: N in-memory + N native on
  distinct files + mixed, all with per-instance sentinel checks; verified under
  `dart test --concurrency=8`.)*
- [x] Native/in-memory differential replay with randomized seeds. *(`test/phase14_differential_ws8_test.dart`:
  seeded DiffSteps over every write mode/read via the phase-2 differential
  harness; 12 seeds × 400 steps with `GECKO_LONG_TEST=1`.)*
- [x] Large data tests: 100k+ records, large values, many indexes, many pending
  sync changes, many attachments, and long migration chains. *(`test/phase14_large_data_ws8_test.dart`:
  100k rows + secondary index (200k in long mode), 100KB+ values bit-exact,
  4 simultaneous indexes, 10k pending-sync log surviving reopen, 300 attachment
  records with blob de-dup, and a 13-step migration chain over 10k rows.)*
- [x] Soak tests for sustained writes, watches, queries, migrations, encryption,
  compaction, and reopen cycles. *(`test/phase14_soak_ws8_test.dart`: 6 cycles
  (24 in long mode) of mixed put/patch/delete + indexed queries + watch feed +
  pending sync + additive migrations + compaction + reopen, all under physical
  AES-256-GCM encryption, with a raw-file plaintext-leak scan and wrong-key
  typed failure.)*
- [x] Performance baselines for point reads, cold reads, writes, bulk writes, range
  scans, indexed/unindexed queries, watches, transactions, migrations, and
  compaction. *(`benchmark/bench.dart` covers reads/writes/bulk/scans/queries/
  watches/transactions with `--json` output; `tool/perf_gate.dart` compares
  every workload against `benchmark/baseline.json` and fails on regression.
  The comparative Phase 13 suite adds Hive CE + Sembast. Migration/compaction
  perf are asserted functionally by the soak test's compaction cycles.)*
- [x] Security review of key handling, logs, temporary files, error messages,
  dependency licenses, and release artifacts. *(`tool/security_review.dart`
  scans Dart + Rust sources for secret literals, key logging, raw values in
  errors, and base64 credential blobs; hard rules fail CI. The soak test proves
  encrypted files leak no plaintext and wrong keys fail typed.)*
- [x] Dependency audit, Rust audit, static analysis, secret scan, and license scan.
  *(`dart pub outdated` / `cargo audit` are run manually pre-release and
  recorded with the release; `dart analyze`, `cargo clippy`, and the security
  review gate run on every push. Dev-dependency licenses (Hive CE: Apache-2.0;
  Sembast: BSD-3-Clause) are documented.)*

Define and pin release thresholds before evaluating results. A benchmark must
fail on regression against a documented baseline, but must not claim a universal
absolute performance number without recording hardware, OS, compiler, runtime,
and dataset details. *(`tool/perf_gate.dart` + `benchmark/baseline.json` pin
thresholds; the harness records platform/OS/dart in both table and JSON output.
CI runs the gate with a deliberately generous tolerance because runner hardware
differs from the dev machine that pins the baseline — the strict gate is a
local, same-machine check.)*

### Required verification commands

The exact CI commands may be wrapped by Melos, but the release pipeline must
execute equivalent steps:

```text
# Repository bootstrap
dart pub get

# Dart quality
dart analyze
dart test packages/gecko_db/test --reporter=compact
dart test packages/gecko_db/test --coverage=packages/gecko_db/coverage

dart run coverage:format_coverage \
  --lcov --check-ignore \
  --in=packages/gecko_db/coverage \
  -o packages/gecko_db/coverage/lcov.info \
  --report-on=packages/gecko_db/lib \
  --ignore-files="**/native/generated/**"
dart run tool/coverage_gate.dart packages/gecko_db/coverage/lcov.info

# Rust quality and tests
cd rust
cargo fmt --check
cargo check --all-targets
cargo test
cargo clippy --all-targets --all-features -- -D warnings
# Rust coverage command must be pinned and wired in CI, for example:
# cargo llvm-cov --all-features --workspace --lcov --output-path coverage.lcov

# Generated native bridge verification
# Run the pinned flutter_rust_bridge generator and fail if git diff is non-empty.

# Consumer/example verification
cd ..
dart run examples/phase13_quickstart.dart
dart run examples/phase13_advanced.dart
```

Platform CI must additionally build the native artifact, install it into a
clean consumer fixture, and run the shared integration suite. Crash, compaction,
crypto-rotation, and platform tests must run in separate jobs when they require
process control, filesystem permissions, device hardware, or a browser worker.

### Final release checklist

Before publishing a production release, require all answers below to be “yes”:

- [ ] Public API snapshot reviewed; all changes have ADR/release-note coverage.
- [ ] File format, wire protocol, native artifact, and package compatibility
      matrix is current.
- [ ] Generated bindings are reproducible and committed/packaged correctly.
- [ ] Every supported platform has a checksum-verified artifact and clean
      consumer fixture.
- [ ] Dart and Rust analyzers, tests, coverage, and lint gates pass.
- [ ] Shared backend differential suite passes.
- [ ] Crash-recovery and reopen drills pass at fixed seeds.
- [ ] Transaction, index, sync, attachment, migration, crypto, and compaction
      atomicity tests pass.
- [ ] No sensitive plaintext appears in database files, temporary directories,
      logs, diagnostics, crash reports, or release artifacts.
- [ ] Read-only, lock, upgrade, corruption, wrong-key, missing-key, and typed
      error paths are verified.
- [ ] Performance results meet the pinned workload thresholds and are recorded
      with environment metadata.
- [ ] Documentation examples run from a clean checkout/consumer fixture.
- [ ] Security, dependency, license, and artifact audits pass.
- [ ] Changelog, migration notes, rollback plan, support policy, and disclosure
      contact are published.

The release owner must attach the CI run URLs, artifact manifest, coverage
reports, benchmark report, crash-drill seed/results, compatibility matrix, and
traceability report to the release. If a checklist item is intentionally not
supported, the release must label it as unsupported rather than silently
shipping a partial guarantee.

---

## Appendix — Remaining Work & Next Steps

This appendix is the working plan for what is still open, in the order it
should be done. It states facts, then gives each step with a concrete action
and a "done when" check. Measurement comes before optimization: Phase 1 must
complete before Phases 2–6 start; Phase 7 can run in parallel with Phases 3–6.

### 1. Current facts (starting point)

- The full six-platform integration matrix does not run end to end: Windows
  and Android build/validate; Linux/macOS CI jobs exist; the web engine runs
  via the wasm/OPFS browser smoke; **iOS is CI-pending**.
- The Phase 13 comparative benchmark covers Hive CE and Sembast; **Isar,
  Drift, and SQLite (sqflite / sqlite3) are not yet included**.
- Documented code samples are covered by runnable examples and equivalent
  tests, but there is **no harness that extracts and executes every documented
  snippet**.
- The 12-criterion acceptance traceability table is **partially populated**;
  no script asserts every listed test exists and passes.
- Dependency, Rust, and license audits are **manual at release time**, not
  automated in CI.
- Measured baseline on the reference machine (native file backend,
  `benchmark/baseline.json`): single insert ≈ 1.6 ms/op, bulk insert
  ≈ 100 µs/row, hot point read ≈ 2–4 µs, cold read ≈ 130 µs, unindexed
  full-scan query ≈ 110 ms per 1,000 rows, indexed equality query ≈ 1 ms,
  transaction commit ≈ 1.2 ms.
- Live queries evaluate in Dart: every scanned row is decoded into a Dart map,
  copied again, and predicated in Dart. The durable index table is currently
  only used to rebuild/validate the in-memory Dart index at open, not to serve
  live queries.

### 2. Phase 1 — Instrument the read/query path  ✅ DONE (ADR-0015)

**Goal:** know where time goes before changing anything.

1. Build a boundary micro-benchmark (`benchmark/boundary.dart`) measuring, in
   order: a plain Dart call, an isolate round trip, an FRB call, a Rust
   no-op, a `redb` point get, and the complete `rawGet`. Record each latency.
2. Add per-stage timers to the query path: planner → index lookup → backend
   read → row decode → map copy → predicate → model conversion → sort; expose
   them through the existing opt-in diagnostics surface.
3. Profile a full unindexed scan and an indexed equality query at 1k and 100k
   rows.
4. Re-run `benchmark/bench.dart` and the comparative suite; record the split.

**Done when:** a written breakdown shows where the ≈110 µs/row full-scan cost
and the per-query cost come from, and the boundary costs are quantified. ✅
(Findings recorded in ADR-0015: cost is overwhelmingly in boundary crossings —
`backendRead` is 70% of a 100k-row full scan and 88% of an indexed eq query —
not Dart decode/predicate. Phase 2 attacks both.)

### 3. Phase 2 — Native query fast path

**Goal:** stop decoding rows that cannot match; make indexed queries traverse
the durable index instead of a Dart copy.

1. ✅ Add a Rust-side query operation: for equality filters on an indexed
   field, traverse the durable `__gecko_index` table and return only matching
   `(id → encoded row)` pairs in one FRB hop (`RedbWorker.query_indexed` /
   `snapshot_query_indexed`; `NativeWorker.queryIndexed`; Dart dispatch +
   `NativeRawBackend.queryIndexed` / `NativeRawSnapshot.queryIndexed`). Range
   and prefix variants are follow-on (see step 5).
2. ✅ For filters with no usable index, push the predicate to Rust and return
   only matching rows (no Dart decode of non-matches). A Rust port of the
   `DefaultWireCodec` value codec (`rust/src/value_codec.rs`) + a predicate
   wire format + evaluator (`rust/src/predicate.rs`) let `RedbWorker::
   query_filtered` / `snapshot_query_filtered` scan every row, evaluate the
   AND-composed predicate against each row's bytes IN RUST (decoding only the
   referenced fields via `find_field`), and return only matches in one FRB
   hop. Dart serializes the `FilterGroup` via `encodePredicate`
   (`predicate_codec.dart`); `QueryImpl._scanWith` routes any unindexed query
   on a `NativeRawSnapshot` through the native path
   (`IndexPlan.nativeFilteredScan`).
3. ✅ The in-memory Dart index is still rebuilt/validated at open; the Rust
   traversal is the default for index-served equality queries on the native
   backend (the in-memory backend keeps the Dart per-id path). Multi-eq,
   range, and prefix filters fall back to the Dart per-id path until their
   bound helpers land — results agree across both paths.
4. Targets: indexed query on 1,000 rows < 1 ms; highly selective indexed
   query on 100k rows < 5 ms; full-scan per-row cost reduced ≥ 10×.
   **Status (Windows dev machine, ADR-0016 + ADR-0017):**
   - Indexed eq on 100k rows: **38 ms → 12 ms (3.2×)** (step 1).
   - **Full scan 100k rows: 482 ms → 39 ms (12.4×) ✅** — the `≥ 10×`
     per-row target is MET (step 2). `backendRead` dropped 336 ms → 38 ms.
   - Full scan 1k rows: 20 ms → 7.8 ms (2.6×).
   - Indexed eq on 1k rows ~1.7 ms (close to the 1 ms target; floor is the
     FRB boundary crossing).
   - Highly-selective indexed eq on 100k rows: met for ~1 match; ~12 ms at
     1% selectivity (1000 matched).

**Done when:** targets are met on the reference machine, indexed and full-scan
plans still agree on all query tests, and the regression gate is green.
*Step 1 (indexed eq fast path, ADR-0016) and step 2 (predicate push, ADR-0017)
are DONE and verified: parity tests pass across native + in-memory backends,
full-scan per-row cost reduced 12.4×, coverage 95% line / 100% branch. The
`≥ 10×` full-scan target is MET. Steps 5–6 (range/prefix/multi-eq indexed
fast path) remain as a smaller optimization on top of the already-pushed
predicate (range/prefix already go through `query_filtered`; the indexed
traversal would skip the full scan for covered range/prefix filters).*

### 3.1 Phase 2 follow-ons (after step 1)

5. Extend the Rust fast path to range and prefix filters on indexed fields
   (port the `eqBounds` helper to `rangeBounds`/`prefixBounds`; the codec key
   layout makes these contiguous byte ranges too).
6. Multi-eq intersection in Rust (intersect several index range scans in one
   hop) instead of falling back to the Dart per-id path.

### 4. Phase 3 — Projection and batch reads

**Goal:** decode only the fields a predicate needs; collapse many small
boundary crossings into one.

1. Implement field-level decode and use it for predicate evaluation before
   materializing the full row.
2. Add `getMany(keys)` (one call, packed result) and a batched
   `iterateBatch()` on the query path; both public and tested.
3. Route relationship eager-loading through `getMany` to eliminate N+1 reads
   everywhere.

**Done when:** `getMany` is public and tested, relationship loads use it, and
predicate evaluation avoids full-row decode.

### 5. Phase 4 — Indexed sorting and early limit

**Goal:** answer ordered, limited queries without materializing and sorting the
whole result set.

1. When sort fields are covered by an index, stream keys from the index in
   order and stop at the limit (the composite keys are already byte-ordered
   for this).
2. Apply `limit`/`offset` during the scan, not after collecting everything.
3. Target: `WHERE … ORDER BY indexedField LIMIT 20` on 100k rows < 5 ms.

**Done when:** ordered limited queries no longer materialize the full candidate
set, and results match the current plans exactly.

### 6. Phase 5 — Incremental reactivity

**Goal:** a write updates only the live result sets it can affect.

1. On each change batch, compute which indexes/queries are affected and update
   only those result sets (start in Dart; re-evaluate Rust routing later).
2. Preserve the coalesced single-event-per-batch behavior; only the per-query
   work changes.

**Done when:** with N live filtered queries and a single-row write, the update
cost does not grow with the size of the watched collections.

### 7. Phase 6 — Architecture decisions, measured

**Goal:** settle the two open architecture questions with data.

1. Worker-isolate cost: use the Phase-1 boundary numbers to decide whether the
   VM worker isolate earns its marshalling cost. Any removal must be opt-in,
   preserve the single-writer rule, and pass the crash/reopen and hot-restart
   suites.
2. Encryption layering: confirm from the Phase-1 profile whether the Dart
   logical-encryption layer appears in any hot path; if not, keep it (it is
   the only encryption surface for in-memory databases).

**Done when:** both decisions are recorded in an ADR with measured
justification.

### 8. Phase 7 — Mechanical completion (can run in parallel with Phases 3–6)

1. Stand up the full six-platform matrix against the single shared integration
   suite; bring iOS CI up.
2. Extend the comparative benchmark with Isar, Drift, and SQLite (sqflite /
   sqlite3) under identical fixtures.
3. Build a doc-test harness that extracts every documented snippet and runs it
   in CI.
4. Complete the 12-criteria traceability table and add a script asserting
   every listed test exists and passes.
5. Automate dependency, Rust, and license audits in CI.

### 9. Phase 8 — Release hygiene

1. Lock the native-artifact distribution: remove the runtime network-download
   fallback for release builds (air-gapped environments, macOS Gatekeeper),
   keeping static bundling and explicit local paths.
2. Plan a wire-format v2 for byte-orderable (little-endian, offset-binary)
   encodings behind the existing format-version gate, with a migration path;
   do not change v1 in place.

**Done when:** release artifacts contain no runtime download path, and the
format versioning/migration plan is documented.

### 10. Ground rules

- Benchmark before and after every phase with the pinned baseline
  (`tool/perf_gate.dart`) and record the numbers.
- The Phase 0 design principles (single writer, always batched, coverage gate,
  file-format contract) apply unchanged.
- Phase 1 gates Phases 2–6. Phase 7 can start immediately in parallel.
