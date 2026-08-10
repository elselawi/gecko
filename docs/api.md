# gecko_db API reference

The stable public surface lives behind the single barrel
`package:gecko_db/gecko_db.dart`. The API snapshot (`tool/api_snapshot.txt`)
is the locked contract; any change is ADR-gated (see `docs/policies.md`).

Every surface is documented in-source with dartdoc comments; this page is the
maintainer/consumer orientation guide.

## Entry point

- **`Database.open(path, {DatabaseConfig config})`** — the supported public
  entry point. File-backed by default; `DatabaseConfig(inMemory: true)` for
  ephemeral databases (tests/examples).
- **Web.** The native redb engine runs on wasm: `Database.open(':memory:')`
  works on the main thread, and file-backed paths persist through OPFS inside
  a Web Worker (see [ADR-0013](adr/0013-web-runtime-frb-glue-and-opfs.md) and
  `tool/web_smoke/` for the worker bootstrap pattern). On the web
  `DatabaseConfig.nativeLibraryPath` is interpreted as the glue URL prefix.
- **`DatabaseConfig`** — read-only, in-memory, optional native physical
  encryption key, native library path, LRU bounds, backpressure, change-log
  retention, schema gate, slow-query threshold, compaction snapshot-drain
  timeout. M6.5 simplifies encryption to one optional raw 32-byte key; the
  target contract has no logical encryption, custom crypto, or key providers.

## Tier 1 — collections (boxes)

`Database.collection<T>(name, toRow:, fromRow:, id:, schema:, indexFields:,
prefixFields:)` returns a `Collection<T>`:

- `get(id)` / `getMany(ids)` (batched point-read — rows in input order,
  absent ids skipped; one native hop) / `put(model)` / `delete(id)` /
  `patch(id, fields)` / `getAll()`
- `watch(id)` → `Stream<T?>`, `watchAll()` → `Stream<List<T>>`,
  `watchAllDiff()` → `Stream<CollectionDiff<T>>`
- `where([predicates])` → `Query<T>`

## Tier 2 — queries and indexes

- `Query<T>`: `filter` / `range` / `prefix` / `sort` / `limit` / `offset` /
  `findAll` / `iterate` (lazy) / `count` / `distinct` / `watch` /
  `cursor({pageSize})` (snapshot-bound `QueryCursor<T>`).
- `IndexPlan` (secondaryIndex / fullScan / nativeFilteredScan) via
  `Query.lastPlan`.
- Durable secondary + range indexes (`__gecko_index`, ADR-0008).

## Tier 3 — relationships, transactions, sync

- **Relationships**: `Database.relationships` (`RelationshipManager`) —
  `children`/`parent`/`loadAllChildren`, delete behaviors (cascade, restrict,
  set-null, application hook), many-to-many joins, reactive
  `watchChildren`/`watchParent`/`watchJoinIds`.
- **Transactions**: `Database.writeTxn((txn) async {...})` — one atomic
  write transaction spanning collections; `txn.put/get/delete/scanAll`.
- **Sync**: `Database.sync` (`SyncHookApi`) — durable change tracking,
  pending changes, `applyRemoteTransactional`, idempotency, LSN ordering,
  GC watermark.
- **Conflicts**: `Database.conflicts` (`ConflictApi`) — strategies
  (last-write-wins, field-level merge, manual review, three-way), preserved
  manual conflicts, atomic resolution.
- **Attachments**: `Database.attachments` (`AttachmentApi`) — metadata,
  content-hash dedupe, upload/delete state machines, orphan detection.
- **Migrations**: `Database.schema` (`SchemaApi`) — `stamp`, `migrateStep`,
  `migrate(MigrationPlan)`, version reads, open-time `upgradeRequired` gate.

## Encryption

M6.5 target contract (ADR-0022):

- Encryption is **off by default** when no key is supplied.
- Native file encryption uses one fixed Rust AES-256-GCM physical page layer.
- The application supplies one raw 32-byte `encryptionKey`; key storage remains
  the application's responsibility.
- There is no logical value-encryption wrapper, custom crypto registry,
  provider abstraction, text key encoding, or user-supplied encryption method.
- Encryption is native-only; Web and in-memory encryption are rejected.
- Public `rotatePhysicalKey(oldKey, newKey)` remains atomic and crash-recoverable.

The existing physical format and rotation implementation are documented in
[ADR-0009](adr/0009-physical-encryption-and-key-management.md).

## Bulk writes and diagnostics

- **Bulk**: `Database.bulkWrite(List<BulkMutation>)` — one atomic commit, one
  coalesced change event.
- **Diagnostics**: `Database.diagnostics` (`DiagnosticsApi`) — opt-in counters
  (reads, writes, scans, failed writes, slow queries, lock contention,
  subscribers, compaction stats, maintenance state).
- **Maintenance** (ADR-0010): `Database.maintenance` (`MaintenanceApi`) —
  `compact()`, `recover()`, `storageStats()`; `MaintenanceState`,
  `StorageStats`, `SlowQueryRecord`.

## Errors

- `GeckoError` with `GeckoErrorType` taxonomy (unknown, keyNotFound,
  collectionNotFound, schemaValidation, transactionAborted, decryption,
  databaseAlreadyOpen, databaseLocked, upgradeRequired, checksumMismatch,
  invalidOperation, syncState, conflict, attachment, migration,
  migration). M6.5 removes the obsolete key-provider and custom-crypto error
  categories from the target public surface.
- `mapNativeError` converts native worker failures to typed `GeckoError`s.

## Guarantees (summary)

- Every committed mutation is atomic, durable, recoverable after process
  termination, and consistent across metadata, indexes, feeds, and
  diagnostics.
- Reads use MVCC snapshots; snapshot-bound cursors never duplicate/drop rows
  under concurrent writes.
- The same conformance suite runs on in-memory and native backends.

See `examples/` for runnable code and `docs/migration-from-hive.md` for
migration guidance.
