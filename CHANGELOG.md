# Changelog

All notable changes to gecko_db are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versioning follows
[docs/policies.md](docs/policies.md).

## [Unreleased]

### Added
- Workstream 4 — **Physical encryption and key management** (ADR-0009):
  - `EncryptingStorageBackend`: AES-256-GCM per physical page below redb
    (`[gen 1][ciphertext‖tag 4112][nonce 12]`), length-preserving and
    page-aligned; wrong key / corrupt page → typed errors before data.
  - `DatabaseConfig.physicalEncryptionKey` / `physicalKeyGeneration` /
    `keyProvider`; `KeyProvider` seam with `FixedKeyProvider`,
    `EnvironmentKeyProvider`, `FileKeyProvider`; fail-before-open key
    resolution (`keyUnavailable`).
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
- Phase 11: logical encryption (`EncryptedRawBackend`, `Aes256GcmCryptoBackend`).
- Phase 12: bulk writes, bounded cache, per-row diff watches, opt-in
  diagnostics.
- Phase 13: runnable quickstart/advanced examples and release-hardening docs.
