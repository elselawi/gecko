# audited-test-gaps.md — verified missing-test list for `gecko_db`

This file is an **audited consolidation** of `DS-tests.md` and `lydia-tests.md`.
Every item below was checked against the actual repository (source + existing
tests) on 2026-08-11. Items are marked:

- **[confirmed]** — verified absent from the current suite (searched source and
  tests; no test covers it).
- **[partial]** — some coverage exists; the specific edge listed is not tested.
- **[DS]** / **[L]** — originated in DS-tests.md / lydia-tests.md.
- **[new]** — added by this audit; not present in either student list.

Everything else in the two student documents was **checked and found already
covered** (see Part 1) — do not re-add those.

---

# Part 1 — Corrections: claims that are already covered (do not re-add)

These areas are substantially covered today. The student lists overstate the
gaps here; specific already-existing tests are cited.

## 1.1 Wrong / stale claims (flat corrections)

| Claim | Reality |
|---|---|
| [DS §2.6] `worker.rs` has "28 inline tests" | **31** inline tests (lines 2592–4700). Stale count. |
| [DS §2.5] `registry.rs` is the "biggest gap", implying nothing tests it | `worker.rs` has 7 `live_registry_*` tests covering register / apply / unregister / whole-table clear / idempotent-write / batch coalescing / sorted-insert. Only **inline** `registry.rs` tests are absent (see 3.1). |
| [L §1.11] conflict edges mostly untested | `conflict_test.dart` + `concurrency_test.dart` already cover the strategy registry, all `ResolutionKind`s, `ConflictVersion` deleted/sequences/DateTime, lastWriteWins matrix, field merge, three-way delete corners, manualReview, preserved-conflict resolve, concurrent resolve winner, and crash-between-compute-and-commit. Only a handful of edges remain (2.12). |
| [L §1.18] relationship edges mostly untested | `relationship_test.dart` + `relations_test.dart` + `relation_query_test.dart` already cover declarations, malformed FK, cascade chains/cycles, restrict/set-null/none, app hooks, many-to-many, `loadAllChildren`, reactive watches, and snapshot parity. Area is effectively complete. |
| [L §1.4] wire codec "missing" broad matrix | `wire_codec_test.dart` already covers int64/BigInt bounds, NaN/-0.0/±inf bit patterns, denormals, DateTime, bytes, list/map, byte-stability, and the malformed-decode group. Remaining gaps are narrow (2.4). |
| [L §1.20] cross-layer property suite missing | The differential work already exists: `differential_test.dart`, `typed_differential_test.dart`, `randomized_test.dart`, `differential_long_test.dart`. The real gap is web-vs-native and encrypted-vs-plaintext parity (2.21). |
| [L §1.17] web smoke "untested" | Browser smoke lives under `tool/web_smoke/` (`web_worker_smoke.dart`, `opfs_worker.dart`, `cdp_drive.mjs`), not in `packages/gecko_db/test/`. Protocol-level malformed-input edges remain untested (2.17). |

## 1.2 Sub-claims already covered (spot list of the biggest)

- Concurrent same-path opens, path-lock, second `close()` harmless, concurrent
  `close()`, stale-handle-after-close, worker-startup retry — `lifecycle_test.dart`,
  `coverage_gap_test.dart`, `native_lock_test.dart`, `process_crash_test.dart`.
- Reserved-name rejection everywhere, absent-table reads, unknown-field
  preservation, auto-ID uniqueness, `getMany` input order — `namespaces_test.dart`,
  `database_impl_test.dart`, `read_path_test.dart`, `integration_test.dart`.
- Failed `insertOnly`/`updateOnly` typed errors, mid-batch rollback, write-gate
  bound, cache invalidation, cache isolation by table, LRU eviction order,
  `ByteKey` edges, range-scan bounds — `raw_engine_test.dart`, `restart_test.dart`,
  `bounds_test.dart`, `lru_cache_test.dart`, `byte_key_test.dart`.
- Mixed-type comparison, NaN/-0.0 sort ordering, `BigInt` sort consistency —
  `filter_sorting_test.dart`, `sort_rules_test.dart`.
- `limit(0)`, offset-beyond-end, `first()` on empty, findPage disjoint/exhaustive
  + strict-after resume, frozen cursor across writes, disposed-cursor rejection,
  `lastPlan` on the main routes — `sort_limit_test.dart`, `query_test.dart`,
  `index_query_test.dart`.
- Compound + prefix index, rollback-leaves-no-index-entries, drift repair on
  open — `index_test.dart`, `index_query_test.dart`.
- Watch initial emission, multiple subscribers, monotonic burst ordering,
  idempotent-write suppression, coalesced per-batch events, `watchAllDiff`
  added/updated/removed — `watch_test.dart`, `reactivity_test.dart`.
- Read-your-writes + snapshot isolation in transactions, rethrow of throwing
  body — `transactions_sync_test.dart`, `backend_edge_test.dart`.
- Bulk atomicity + one-feed-event, bulk index maintenance — `performance_test.dart`.
- Sync: mark transitions, dedupe across calls/reopen, `changesSince` strictly-after,
  watermark GC, remote-version persistence — `transactions_sync_test.dart`,
  `restart_test.dart`.
- Attachments: dedupe/refcount, upload transitions, orphan, exhaustive queries,
  parent-delete atomicity, last-reference frees blob — `attachments_test.dart`.
- Migrations: stamp, requiresUpgrade boundary, non-consecutive steps, failing-step
  rollback with prior steps committed, stable IDs across rewrite — `migrations_test.dart`.
- Maintenance: lifecycle transitions, drain timeout with `{openSnapshots}`,
  recover in failed/read-only states, marker → `recovering` on reopen, stats,
  diagnostics counters, slow-query ring — `maintenance_test.dart`,
  `maintenance_coverage_test.dart`.
- Encryption: full lifecycle, wrong key, tenant separation, rotation both
  directions, interrupted rotation, tampering, nonce uniqueness, encryption +
  compaction — `crypto_test.dart`, `maintenance_test.dart`.
- Resolver precedence, corrupt-candidate skipping, checksum mismatch, bad-download
  not cached — `native_resolver_test.dart`, `defensive_coverage_test.dart`.
- Concurrent conflict resolve (one winner), preserved-conflict double-resolve
  rejection — `concurrency_test.dart`, `native_features_test.dart`.

---

# Part 2 — Confirmed missing: Dart tests

Place under `packages/gecko_db/test/`. Each bullet is one (or a small family of)
tests; the target file is the natural home.

## 2.1 Lifecycle / open / config — `lifecycle_test.dart`, `read_only_test.dart`, `open_entry_test.dart` additions

- **[confirmed][DS][L]** Read-only `open` of a **new / nonexistent** path — today
  `read_only_test.dart` only opens an existing store. Assert the documented
  typed error.
- **[confirmed][new]** A true **"close blocks until in-flight writes land"**
  assertion on the public API — only the engine-level `drain()` seam is tested
  (`defensive_coverage_test.dart`).
- **[confirmed][DS][L]** Concurrent `open()` for the same path where the **first
  throws** — the second must not be permanently stuck with `databaseAlreadyOpen`.
  Only the "second loses" case is tested.
- **[confirmed][DS][L]** Windows path normalization: `C:\x\db` vs `c:\x\db`,
  relative vs absolute vs normalized-dot — lock the exact normalization policy.
- **[confirmed][DS][L]** Invalid path kinds: a **directory**, an **unreadable**
  file, a **path whose parent does not exist** — typed error, registry cleaned.
- **[confirmed][DS][L]** Config knob edge values (each: rejected / clamped /
  pass-through, locked): `inFlightBatchLimit` 0/negative/huge, `lruCapacity`
  0/1/negative/huge, `lruMaxWeight` 0/negative/smaller-than-one-value/huge,
  `changeLogMaxEntries` 0/1/exact/negative/huge, negative/huge
  `maxKnownSchemaVersion`, `slowQueryThresholdMicros` 0/negative/huge,
  `compactionSnapshotDrainTimeout` 0/negative/tiny/huge.

## 2.2 Mapping / collections — `namespaces_test.dart`, `database_impl_test.dart`, `integration_test.dart` additions

- **[confirmed][DS][L]** `toRow` **throws** (sync and async) → no mutation, no
  metadata event, no index change, no LSN bump.
- **[confirmed][DS][L]** `fromRow` **throws** across `get`/`getMany`/`getAll`/
  queries/watches/relationship loads → typed error, no cache poisoning.
- **[confirmed][DS]** `toRow` returns a **non-Map** → locked behavior with and
  without a schema (replace vs reject).
- **[confirmed][DS]** `put` **shallow-merge vs replace** of known fields (update
  ≠ replace) — only unknown-field preservation is currently asserted.
- **[confirmed][L]** Two handles for the same table with **conflicting**
  mapper/schema/index declarations → first-wins/merge/rejection, locked.
- **[confirmed][DS][L]** **Declaration-list defensive copies**: mutating the
  caller's schema/index/prefix list after construction must not change the
  collection.
- **[confirmed][DS]** `getMany` with **duplicate input ids** (one row per
  occurrence vs dedupe — lock).
- **[confirmed][DS][L]** Auto-ID **monotonicity** and **no reuse of deleted ids**
  (uniqueness is covered; monotonicity/reuse is not).

## 2.3 Raw engine / cache / write gate — `raw_engine_test.dart`, `lru_cache_test.dart`, `change_bus_test.dart` additions

- **[confirmed][DS][L]** Empty `commitBatch` returns `lsn - 1`, writes no LSN
  record, publishes no feed event.
- **[confirmed][DS]** Failed `insertOnly`/`updateOnly` do **not** bump LSN,
  invalidate cache, or emit changes (typed error alone is tested today).
- **[confirmed][L]** Cache value **defensive copies / missing-value sentinel**
  isolation — mutating a returned list must not affect cache/engine.
- **[confirmed][DS]** Reserved-table feed filtering: a batch touching only
  `__gecko_*` emits zero public changes; mixed batches emit only user-table
  changes.
- **[confirmed][DS]** LRU: a single value with `weight >= maxWeight` is
  **immediately evicted, never cached**; `onEvict` does **not** fire on explicit
  `remove`/`invalidate`/`clear` or on put-replace; negative `weightOf` (no
  validation — pin).
- **[confirmed][DS]** `publishAt` with a stale sequence → bumped to
  `_nextSeq+1`, never regresses; two publishes with the same sequence coalesce.

## 2.4 Wire codec & op codec — `wire_codec_test.dart`, `op_wire_test.dart` additions

- **[confirmed][DS][L]** **Recursion depth / cycle guard**: deeply nested
  lists/maps (≈10k) and self-referential values — today there is no depth guard.
  Pin current behavior; ideally add a guard and test it.
- **[confirmed][DS]** `List<int>` encodes as tag `0x06`, `Uint8List` as `0x08` —
  assert exact tags; empty `Uint8List`.
- **[confirmed][DS]** Bool leniency: payload `0x02..=0xFF` decodes as `true`.
- **[confirmed][DS]** `DateTime` **pre-epoch** values (epoch/UTC are covered).
- **[confirmed][DS]** `BigInt` is **always exactly 16 bytes**; decode of 15/17-byte
  payloads → error.
- **[confirmed][DS][L]** **Non-string map keys** (null/bool/int/BigInt/double/
  bytes/date/list/map); duplicate-key policy after decode; byte-stability of map
  iteration order.
- **[confirmed][DS]** **Invalid UTF-8** decode → typed error (no raw exception).
- **[confirmed][DS]** Op codec: invalid-UTF-8 **table name** currently throws a
  raw `FormatException` (not `OpDecodeException`) — pin; non-canonical presence
  byte (`0x02` = present) tolerated; `put` with null value round-trips.

## 2.5 Sort rules — `sort_rules_test.dart` additions

- **[confirmed][DS]** `compareFieldValues` int-vs-double **numeric** comparison
  (`3 > 2.5`, `5 == 5.0`); num-vs-String and bool-vs-int fallback — never tested.
- **[confirmed][DS]** **UTF-16 code-unit** ordering for astral-plane characters
  (current test is ASCII-only); document the wire-UTF-8 vs sortable-UTF-16
  difference.
- **[confirmed][DS]** `compareRows`: null vs **missing** is distinct (null is
  present); both-missing on a spec → next spec; one-missing placement in both
  directions.

## 2.6 Query / cursors / plans — `query_test.dart`, `read_path_test.dart`, `sort_limit_test.dart` additions

- **[confirmed][DS][L]** **Builder immutability**: every `filter`/`sort`/`limit`/
  `offset`/`where` returns an independent query; no parent/sibling mutation;
  append-vs-replace semantics for repeated calls locked.
- **[confirmed][DS]** **Type-strict equality**: `5` ≠ `5.0` ≠ `BigInt(5)`;
  `true` ≠ `1` — no test anywhere.
- **[confirmed][DS]** `distinct` with **missing-field rows** (skip vs include —
  lock) and explicit-null handling.
- **[confirmed][DS]** `findPage`/`cursor`: `afterKey` that is **not a
  `List<int>`** currently throws a raw `TypeError` (`query_impl.dart:677` — pin);
  `pageSize: 0` and negative; repeated `next()` after exhaustion → `([], null)`;
  cursor created-but-never-iterated then disposed → snapshot released (no
  compaction block).
- **[confirmed][DS]** `iterate()` **cancellation** and **close-during-iterate**
  (laziness is covered in `index_test.dart`).
- **[confirmed][DS]** `lastPlan` after `first()`, `findPage`, a **failed** query,
  and repeat execution.
- **[confirmed][DS]** Slow-query exact-threshold boundary (`duration ==
  threshold` recorded or not — lock `>=`); `timings.total` ≤ `durationMicros`.

## 2.7 Durable indexes — `index_test.dart`, `index_query_test.dart` additions

- **[confirmed][DS]** Index on **null values** (equality on null finds them;
  null→value and value→null maintenance).
- **[confirmed][DS]** Index on **List/Map-valued fields** (broad bounds + Rust
  predicate recheck).
- **[confirmed][DS]** **Two separate indexes on one table** (today only a
  compound index is tested).
- **[confirmed][DS][L]** Index maintenance across **`clear`** and across
  **cascade delete** (children's entries removed).
- **[confirmed][DS]** `repairIndex` **idempotence**: consistent → no-op (no write
  txn, no sequence bump); repair-twice.
- **[confirmed][DS]** Index on an encrypted DB, write, close/reopen, query by
  index (cross-feature gap).

## 2.8 Reactivity / change bus — `change_bus_test.dart`, `watch_test.dart`, `reactivity_test.dart` additions

- **[confirmed][DS]** `ChangeBusOverflowError` / `maxBuffered` are **declared but
  never enforced** — pin the doc-vs-code mismatch (a slow subscriber today
  receives all events, no overflow).
- **[confirmed][DS]** Coalescing when `Change.key` is a raw `List`/`Uint8List`
  (identity `==`) — byte-equal keys from separate batches may not coalesce — pin.
- **[confirmed][DS]** **Throwing subscriber** during sync-broadcast `publishAt` —
  does the publisher survive? Pin.
- **[confirmed][DS][L]** **Windowed** (limit/offset) query watch: full
  re-evaluation; a row added that pushes another out of the window; unrelated
  tables don't trigger.
- **[confirmed][DS][L]** **DB close with active subscriptions** → stream
  close/error, registry cleanup, subscriber counters → 0.
- **[confirmed][DS][L]** **Removed diffs carry the previous row** (today only
  removed ids are asserted).
- **[confirmed][L]** Registration race (subscribe concurrently with writes
  landing — no committed change lost/duplicated); backend failure during refresh
  → error delivery + subscription cleanup.

## 2.9 Transactions — `transactions_sync_test.dart`, `backend_edge_test.dart` additions

- **[confirmed][DS][L]** **Empty transaction** on a normal DB (no ops): commit
  finishes, no LSN, no feed event.
- **[confirmed][DS][L]** **Nested `writeTxn`** → rejection or serialization
  without deadlock (lock).
- **[confirmed][L]** **Operations after finish** (commit/rollback) → typed
  `invalidOperation`; throw-after-`commit()` → committed data preserved, error
  rethrown.
- **[confirmed][DS]** **Large txn** (thousands of staged ops) mid-body failure →
  complete rollback (table empty, no change-log entries, LSN unchanged).
- **[confirmed][L]** Concurrent txns writing the **same key**; **close/compact
  while a txn is active**; cascade fully inside one txn (all-or-nothing).

## 2.10 Bulk writes — `performance_test.dart`, `typed_differential_test.dart` additions

- **[confirmed][DS][L]** Empty bulk on a normal DB → `BulkWriteResult(0, 0)`, no
  LSN, no events.
- **[confirmed][DS][L]** **Repeated mutations to one `(table, key)`** in one
  batch (put-then-delete, delete-then-put, multiple clears) → final state +
  coalesced events.
- **[confirmed][DS][L]** **Invalid op before/after valid ops** → complete
  rollback of the whole batch.
- **[confirmed][L]** Bulk atomicity with **sync metadata, attachment refcounts,
  relationship side effects, retention pruning**.

## 2.11 Sync / change log — `transactions_sync_test.dart`, `restart_test.dart` additions

- **[confirmed][DS]** `markSynchronizing` twice → idempotent; `markFailed` after
  `markSynced` → transitions back (lock the phase machine); `markSynced` with
  non-pending ids → no-op.
- **[confirmed][DS]** `markSynced` **rewrites change-log entries** — after it,
  log records are clean and `changesSince` no longer returns them.
- **[confirmed][DS]** `applyRemoteTransactional` with a record lacking
  `collection` throws a raw `ArgumentError` (`database_impl.dart:1468`) — pin the
  untyped leak.
- **[confirmed][DS][L]** Idempotency dedupe **within one batch** (two records,
  same key → first only) and across reopen (across-call dedupe is covered).
- **[confirmed][L]** **Malformed remote records** (null collection, unknown
  kind/origin, missing value, invalid id/version, malformed metadata) → typed
  errors + rollback.
- **[confirmed][DS]** `SyncState`/`ChangeRecord.copyWith` cannot null out
  `syncState`/`lastSyncAttempt`/`lastSyncError` (`??` semantics) — pin.
- **[confirmed][DS]** `_recordFromMap` with corrupt `timestamp`/`localMutationId`
  currently throws a raw `TypeError` (`as` casts) — pin.
- **[confirmed][L]** `RecordRef` **cross-collection** matching (equal ids in
  different collections must not collide).

## 2.12 Conflicts — `conflict_test.dart` additions (rest is covered)

- **[confirmed][DS]** Registered handler **throws** → propagates (lock); handler
  returning a `mergedValue` that is a `Function` → typed error.
- **[confirmed][DS]** `_deepEqual`: NaN ≠ NaN; `0` vs `0.0` equal.
- **[confirmed][DS]** `resolvePreserved` with a `manualReview` decision → typed
  error ("must be concrete").

## 2.13 Attachments — `attachments_test.dart` additions

- **[confirmed][DS]** `AttachmentMetadata.copyWith` always overwrites
  `failedOperationDetail` (cannot clear to null) — pin.
- **[confirmed][L]** **Failed/completed upload state matrix** (only `pending` is
  asserted today) and `setDeleteState` failure-detail handling.
- **[confirmed][L]** Corrupt attachment/blob metadata → typed `attachment` error,
  not a raw cast exception.
- **[confirmed][DS]** Deleting a parent via `deleteWithBehavior` — exact
  attachment-orphan behavior locked (state-only today).

## 2.14 Migrations — `migrations_test.dart` additions

- **[confirmed][DS]** `_rewriteRecords` defaults `step.collection` to `'items'`
  when `rewritesRecords: true` and no collection is set (`database_impl.dart:2396`)
  — pin the surprising default.
- **[confirmed][DS]** `migrateStep` on the **same step twice** → typed error;
  user-supplied **`upgrade` callback** hooks (throw / return null / return
  non-Map) — only step objects are tested today.
- **[confirmed][DS][L]** **Migration × index** (no stale entries after rewrite)
  and **migration × encryption**.
- **[confirmed][DS][L]** **Large-rewrite boundedness** — the implementation
  processes the whole table in one atomic batch despite a "bounded chunks /
  resumable" comment (`database_impl.dart:2390`) — pin the actual single-batch
  behavior and guard memory.

## 2.15 Maintenance / diagnostics — `maintenance_test.dart` additions

- **[confirmed][DS][L]** `compact()` on an **empty DB** and a **metadata-only DB**
  (success vs no-op return; state transitions).
- **[confirmed][DS]** **Two concurrent compactions** → one runs, the other gets a
  typed error; in-flight race while the first drains.
- **[confirmed][DS]** `totalQueryDurationMicros` is **hardcoded `0`** in
  `_DiagnosticsApiImpl.snapshot()` (`database_impl.dart:2464`) — pin so the fix
  flips the test green deliberately.

## 2.16 Encryption (Dart side) — `crypto_test.dart` additions

- **[confirmed][DS][L]** **Read-only + encryption** → typed error (Rust has no RO
  encrypted mode).
- **[confirmed][DS]** **Generation 0** open behavior (Rust only `debug_assert`s
  `key_gen >= 1`).
- **[confirmed][DS]** `rotatePhysicalKey` on a **live/open DB** → typed error
  (requires closed); on an **unencrypted file**; `validateEncryptionKey` length
  matrix (31/33/0; `List<int>` vs `Uint8List`; mutable key list mutated after
  open).

## 2.17 Web worker / OPFS / protocol — `web_worker_protocol_test.dart`, `platform_seam_test.dart` additions

- **[confirmed][DS][L]** Malformed protocol messages: bad JSON, unknown/missing
  operation, unknown/missing request id, **duplicate response id dropped**,
  invalid response, wrong-shape response (raw `TypeError` today — pin).
- **[confirmed][DS]** **No per-request timeout** on isolate or web-worker paths
  (only open/close/finalize time out) — pin; `close()` mid-request → pending fail
  with typed message; `debugFinalize()` vs `disposeForTest` behavior.
- **[confirmed][DS]** Web worker client surfaces errors as **`StateError`**
  (losing the `GeckoError` taxonomy) and `close()` **leaves pending completers
  dangling** (diverges from native) — pin both.
- **[confirmed][DS]** `encodeValue`/`decodeValue`: `List<int>` round-trips as
  `Uint8List` (type identity lost); map keys coerced via `toString()` (lossy);
  `{'b64': non-string}` falls through to generic map; malformed `storageStats` →
  `FormatException`.
- **[confirmed][DS]** OPFS `registerOpfsHandle` **error-string contract** — each
  distinct message (no navigator / no secure context / `getDirectory()` null /
  `getFileHandle` null / `createSyncAccessHandle` null / missing wasm glue /
  generic exception) locked exactly; VM `opfs_io` fixed message.
- **[confirmed][L]** JS-safe/unsafe integer boundaries across the protocol;
  large values across `postMessage`; multiple OPFS files and same-path
  exclusivity.

## 2.18 Native resolver / bridge / platform seam — `native_resolver_test.dart`, `native_bridge_contract_test.dart`, `platform_seam_test.dart` additions

- **[confirmed][DS]** Download **transport error** (socket/non-200): non-200 is
  typed; transport exceptions propagate raw (untyped) — pin; partial download →
  not cached.
- **[confirmed][DS]** `GECKO_DB_RESOLVER_PATHS` separators (`;` on Windows / `:`
  elsewhere), empty segments, multiple paths in order.
- **[confirmed][DS]** `bundledArtifactPath` per OS/arch; `hostArchitecture`
  `ia32` quirk (identical ternary returns `'x86'` in both arms) — pin.
- **[confirmed][new]** `native_bridge_contract_test.dart` is only **15 lines**
  (two superficial assertions) — a real dispatch-contract test (every operation
  maps to the intended generated method; BigInt/string conversion; defensive
  byte copies; omitted optional arguments) is effectively absent.
- **[confirmed][new]** `platform_seam_test.dart` is **44 lines** — per-OS
  artifact names and the web-glue URL override path are untested.

## 2.19 Consumer surface — `examples_test.dart` additions

- **[confirmed][new]** `examples/consumer.dart` is **not executed** by
  `examples_test.dart` (only quickstart and advanced are run) — add it.
- **[confirmed][DS][L]** Malformed encryption keys (short/long/non-hex), wrong-key
  open → clean failure/cleanup and reopenability, consumer callback throws →
  process cleanup + reopen.

## 2.20 Cross-feature combinations — new `cross_feature_test.dart`

- **[confirmed][DS][L]** Encryption × indexes / relationships / migrations /
  sync / read-only; relationships × transactions (cascade inside one txn) and ×
  sync (cascade then remote-apply of the deleted child); attachments × conflict
  (parent resolved away); compaction × relationships and × sync; one bulk across
  two indexed tables (one atomic batch, one event per key, indexes + change-log +
  sync-state correct); watch × compaction (no spurious emissions).

## 2.21 Heavy / long-running extensions (run with `GECKO_LONG_TEST=1`)

- **[confirmed][L]** `randomized_test.dart`: add schema'd collections with
  defaults, transactions, and relationship cascades to the model check.
- **[confirmed][new]** **Encrypted-vs-plaintext differential**: identical script
  → identical logical results (both directions).
- **[confirmed][DS][L]** `soak_test.dart`: hold a snapshot cursor open across
  several compact/rewrite cycles.
- **[confirmed][DS]** `crash_injection_test.dart`: boundaries around index
  maintenance and compaction-marker writes (kill between marker write and
  compact start → `recovering`).

---

# Part 3 — Confirmed missing: Rust tests

Inline `#[cfg(test)]` modules in `rust/src/`; integration in `rust/tests/`.

## 3.1 `registry.rs` — no inline tests at all (worker-level behavior IS covered)

Add a `#[cfg(test)]` module (mirrors the 7 `live_registry_*` worker tests but at
unit level):

- **[confirmed][DS]** `register`: sequential ids from 0; missing table → empty;
  non-matching rows excluded; `LiveQueryKind::from_u8` 0/1/2 valid, 3/255 → None;
  malformed predicate/sort bytes → `Wire` error.
- **[confirmed][DS]** `apply_one` clear / key-join / same-value re-put (no delta,
  `unchanged=true`) / match-status flips (matching→non-matching → `removed`;
  non-matching→matching → `added`) / duplicate affected keys (last state wins).
- **[confirmed][DS]** Sorted registration: insert at comparator position,
  update re-positions, ties break by key bytes; `unregister` idempotent + stops
  deltas; non-durability across "restart".

## 3.2 `api.rs` — no inline tests at all

- **[confirmed][DS]** `encode_worker_error` mapping table: `InvalidOperation`/
  `Wire` → `InvalidOperation`; `DatabaseLocked` → `DatabaseLocked` +
  `{reason, retryable: true}`; `Storage` → `Unknown`; **`Decryption` is declared
  but never produced** — pin.
- **[confirmed][DS]** `rekey_encrypted_file` key-length pre-check → envelope
  error before FS work; all-zero 32-byte key accepted (length-only);
  `apply_batch` with undecodable bytes → `InvalidOperation`; `register_live_query`
  invalid kind → `InvalidOperation`; `NATIVE_BUILD_ID` format.

## 3.3 `opfs.rs` — wasm32-only, no tests

- **[confirmed][DS][L]** `#[cfg(all(test, target_arch = "wasm32"))]` module or a
  VM harness abstracting the JS FFI: register/take/unregister, `len`/read at
  offset, short read → `UnexpectedEof`, short write → `WriteZero`, `set_len` via
  truncate, `sync_data` via flush, `close` swallows errors, `js_err` mapping.

## 3.4 `value_codec.rs` (5 tests today)

- **[confirmed][DS]** Unknown-tag sweep (`0x0A..=0xFF`) → `DecodeError`;
  **truncation sweep at every byte offset** (no panic, no infinite loop).
- **[confirmed][DS]** **Count-overflow memory-exhaustion vector**: `read_value`
  does `Vec::with_capacity(count)` from an untrusted u32 **before** bounds checks
  fail (`value_codec.rs:345,353`) — pin with a huge-count test and drive a fix
  capping capacity by remaining bytes.
- **[confirmed][DS]** `find_field` duplicate-name **first-wins**; `skip_value`
  direct tests (bool skips exactly 1 byte); `finish` rejects trailing bytes.
- **[confirmed][DS]** Cross-type `compare` (Int64 always < F64 — **type-rank**,
  NOT numeric, differing from `sort_compare`); `equals`/`deep_equals`
  (`Int64(5)` ≠ `F64(5.0)` ≠ `BigInt(5)`; maps equal regardless of key order).

## 3.5 `wire.rs` (6 tests today)

- **[confirmed][DS]** Varint boundaries (0/127/128/16383/16384/`u64::MAX`,
  shift-overflow); **invalid UTF-8** → `WireError`; presence-byte leniency (any
  nonzero = present); **count over-claim** → truncation error; **empty batch**;
  large (≈8 MB) payload round-trip; semantically-invalid-but-decodable ops decode
  fine (validation is the worker's job — lock).

## 3.6 `predicate.rs` (5 tests today)

- **[confirmed][DS]** Type-mismatch equals (`Int64(5)` vs stored `F64(5.0)`/
  `BigInt(5)`); equals on **List/Map** values (structural); range **`min > max`**
  → always false; **cross-type range** ordering (type-rank); **malformed decode**
  (bad version, count over-claim, truncation, trailing garbage, invalid UTF-8);
  non-canonical `has_min`/`has_max` (any nonzero = true).

## 3.7 `sort_spec.rs` (3 tests today)

- **[confirmed][DS]** Malformed decode: truncated field, count over-claim,
  invalid UTF-8; **descending leniency** (any nonzero); `compare_rows`:
  **both-missing** → next spec, **null vs missing distinct**, empty specs →
  Equal for everything.

## 3.8 `worker.rs` (31 tests today) — uncovered behaviors

- **[confirmed][DS]** `TopK` unit tests: `cap == 0` (push no-op), `cap+1` keeps
  the smallest cap, **ties keep the incumbent** (only strictly-`Less` replaces —
  `worker.rs:161-162`), duplicate keys, unsorted → ascending.
- **[confirmed][DS]** `slice_offset_limit`: offset == len, offset > len,
  saturating offset+limit.
- **[confirmed][DS]** `open`: `DatabaseAlreadyOpen` → `DatabaseLocked`; invalid
  path → `Storage`; reopen-after-close restores state; **`open_encrypted`**:
  wrong-length key, wrong-key reopen — **no test at all today**.
- **[confirmed][DS]** `apply_batch` validation matrix: `Get`/`RangeScan` inside a
  write batch → `InvalidOperation`; `DeleteRange` without bounds; read-only worker
  rejects all writes (only put-without-value is covered).
- **[confirmed][DS]** `get_many` **duplicate keys**; `range_scan` **inverted
  bounds** → empty; `repair_index` **already-consistent no-op** (no write, no
  sequence bump) / missing primary table / read-only rejection.
- **[confirmed][DS]** `query_indexed`: **orphaned index entries silently
  skipped**; **drifted entries** (index value ≠ primary) → predicate recheck
  wins. `query_indexed_multi`: empty ranges, disjoint ranges (early exit).
- **[confirmed][DS]** `query_sorted` with **empty specs → empty result (NOT all
  rows)** — behavior at `worker.rs:2042`, untested.
- **[confirmed][DS]** `query_indexed_ordered`: missing-index-table fallback
  (eq-bounded → empty; non-eq → `query_sorted`); descending without an eq bound.
- **[confirmed][DS]** `tables()` strips the `__gecko_user_` prefix — no test;
  compaction rejects a **write in progress** (`TransactionInProgress`);
  `prune_change_log` retention-0 / watermark-max / lsn-less records;
  `pending_changes` missing-`dirty` defaults.
- **[confirmed][L]** `open_encrypted` wrong-length/wrong-key reopen; `range_scan`
  exclusive-bound snapshot variants (native snapshot exclusivity is covered in
  Dart).

## 3.9 `crypto_storage.rs` (10 tests today)

- **[confirmed][DS]** **Key-gen wrap**: `rekey_file` with `old_gen = 255` →
  `new_gen = 0` (`wrapping_add` at `crypto_storage.rs:390`, collides with the
  all-zero-page sentinel — latent bug) — pin and drive a fix.
- **[confirmed][DS]** `len` **floors** non-multiple physical lengths
  (`crypto_storage.rs:177`); `read_physical_page` **past EOF → zeros**
  (no Windows zero-length-read loop); `set_len` → `ceil(len/4096)*4125`;
  **marker corruption** (wrong prefix, truncated payload, tampered key-gen byte);
  **reverse rotation** (new→old key → readable with the original key).

## 3.10 Cross-language fixtures — `rust/tests/`

Today: `golden_cross_lang.rs` covers **only op kinds + table names** (7 ops;
string/int values only); `native_error_cross_lang.rs` covers **only
`DatabaseLocked`**; `format_header_cross_lang.rs` has a byte golden;
`compatibility_cross_lang.rs` is field-level.

- **[confirmed][DS][L]** Extend the golden fixture to **BigInt, DateTime, Bytes,
  bool, null, nested list/map** (regenerate via `tool/gen_golden_ops.dart` — note
  it currently generates op-wire only and needs a companion generator for the
  other goldens).
- **[confirmed][DS][L]** **Predicate golden** (Dart-encoded predicate bytes
  decode identically in Rust, match the same rows); **sort-spec golden** +
  `compare_rows` parity fixture; **error-envelope matrix for all 11 types**;
  **crypto layout golden** (key-gen byte + tag length + nonce placement);
  **malformed-fixture rejection** in both languages.
- **[confirmed][DS]** Property tests: `decode(encode(x)) == x` for generated
  `RowValue`s; `compare` antisymmetric/transitive; `sort_compare` total order;
  `TopK` property (cap-smallest with the documented tie rule); seeded
  malformed-input sweep over `decode_value` / `decode_predicate` /
  `decode_sort_specs` / `Op::decode_batch` / `FormatHeader::decode` — no panics,
  only typed errors.

---

# Part 4 — Confirmed missing: release-tool tests (`tool/`)

None of the proposed `*_edge_test.dart` files exist. The existing equivalents are
thin (e.g. `api_contract_gate_test.dart` has one test and never runs the gate).
Each is a small family of edge tests for the existing tool:

- **[confirmed][DS][L]** `api_snapshot_edge_test.dart` — symbol removal/addition
  without the version/release-note policy, deprecation preservation/removal,
  generic/param/export/return-type changes, generated-code exclusion, stable
  ordering, line-ending normalization, duplicate symbols.
- **[confirmed][L]** `artifact_manifest_edge_test.dart` — missing/invalid
  checksum, duplicate/unsupported targets, missing artifacts, content mismatch,
  path traversal, Windows paths, all release targets, incomplete web-glue pairs.
- **[confirmed][L]** `build_artifacts_edge_test.dart` — unknown/host-incompatible
  target, build failure, bundle collision, stale cleanup, checksum regeneration,
  clean-tree enforcement, generated-binding mismatch.
- **[confirmed][L]** `coverage_gate_edge_test.dart` — empty/malformed LCOV,
  missing paths, duplicate records, no-branch records, zero-line files, threshold
  rounding, 0/100 thresholds, invalid numeric fields, ignored-file syntax,
  fresh-collection behavior.
- **[confirmed][L]** `release_checklist_edge_test.dart` — step ordering, every
  optional-flag combination, missing working dir, env propagation, coverage
  cleanup, first-failure behavior, output-tail, nested-directory execution.
- **[confirmed][L]** `docs_examples_edge_test.dart` — broken links, stale release
  instructions, internal imports, nonpublic consumer imports, platform-specific
  commands.
- **[confirmed][L]** `security_review_edge_test.dart` — key literals, key
  logging, network access, unsafe temp files, sentinel leakage, incorrect
  coverage exclusions, dylib policy.
- **[confirmed][L]** `offline_lint_edge_test.dart` — HTTP/socket imports,
  real-clock use, process/network APIs, hidden network access, generated-file
  exclusions, comment/doc false positives.

---

# Part 5 — New findings from this audit (not in either student list)

1. **[new]** `examples/consumer.dart` is never executed by `examples_test.dart`
   (only `quickstart.dart` and `advanced.dart` run) — the consumer fixture is the
   best end-to-end surface check and is currently skipped.
2. **[new]** `native_bridge_contract_test.dart` is 15 lines / two superficial
   assertions and `platform_seam_test.dart` is 44 lines — the FRB dispatch
   contract and per-OS/platform seam are effectively untested despite the files
   existing (see 2.18).
3. **[new]** `tool/gen_golden_ops.dart` generates **op-wire goldens only** —
   there is no generator for value/predicate/sort-spec/error/crypto fixtures, so
   the cross-language matrix (3.10) needs a companion generator, not just more
   fixtures.
4. **[new]** `worker.rs` actually has **31** inline tests, not the 28 reported in
   DS-tests.md (count drift — harmless, but the new tests should be numbered
   against the real inventory).
5. **[new]** `read_only_test.dart` requires an existing store before every test —
   the "read-only open of a brand-new file" behavior is not just untested but
   structurally unexercised (2.1).
6. **[new]** No test asserts `lastPlan` after a **failed** query or that
   diagnostics counters stay untouched when diagnostics are disabled mid-write.
7. **[new]** No test covers `publishAt` after `close()` (currently returns
   current seq, no throw) — an easy lifecycle pin (2.3).
8. **[new]** Web-worker vs native **parity** (same script, both transports) does
   not exist as a single property test anywhere (2.21).

---

# Part 6 — Suggested priority order

1. **Rust correctness pins** (highest value, cheapest): 3.8 (TopK ties,
   `open_encrypted`, empty-specs `query_sorted`, `tables()`, `apply_batch`
   validation matrix), 3.4 (count-overflow exhaustion vector), 3.9 (key-gen
   255→0 wrap), 3.6/3.7 (predicate/sort malformed decode).
2. **Dart atomicity pins**: 2.2 (throwing mappers), 2.3 (empty commit, failed
   insertOnly LSN), 2.10 (bulk rollback), 2.11 (malformed remote records).
3. **Transaction/query edges**: 2.6 (builder immutability, type-strict equality,
   afterKey TypeError), 2.9 (nested/empty txn).
4. **Reactivity**: 2.8 (change-bus overflow pin, windowed watch, close-with-subs,
   removed-diff payload).
5. **Cross-feature matrix**: 2.20, then 2.7 (index × encryption/clear/cascade).
6. **Wire/web/protocol**: 2.4 (recursion guard), 2.17 (protocol malformed matrix),
   2.18 (dispatch contract).
7. **Tool gates**: Part 4 (eight small files).
8. **Heavy/property**: 2.21 and 3.10 (fixtures + property tests), gated by
   `GECKO_LONG_TEST=1`.

Every behavior change above ships with a failing-before test; run
`dart run tool/release_checklist.dart` plus `cargo test` before pushing. Keep
titles conventional and specific; no planning/milestone terminology.
