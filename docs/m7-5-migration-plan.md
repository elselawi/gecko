# M7.5 migration plan

M7.5 removes the pre-release public in-memory mode and the duplicate Dart
storage engine. The product remains local-first and offline, but every supported
store is backed by Rust/redb: a native file on desktop/mobile or an OPFS file on
Web. See ADR-0028 for the locked decision.

## Dependency inventory

| Area | Current dependency | M7.5 replacement | Status |
|---|---|---|---|
| Public API | `DatabaseConfig.inMemory`, `Database.open` forwarding `useInMemory` | File/OPFS path only | ✅ Done |
| Concrete opener | `DatabaseImpl.open(..., useInMemory)` | NativeRawBackend for all supported paths | ✅ Done |
| Public export | `InMemoryBackend` from `gecko_db.dart` | Remove export | ✅ Done |
| Storage engine | `in_memory_backend.dart`, `_State`, `_Table`, `_MemSnapshot` | Rust/redb and NativeRawSnapshot | ✅ Done (deleted) |
| Query engine | `SecondaryIndex`, Dart candidate execution, Dart full scans | Rust durable bounds/predicate/sort/aggregate routes | ✅ Done (deleted) |
| Tests | `mem://`, `useInMemory: true`, direct `InMemoryBackend` | Temporary native files and Web/OPFS contract tests | ✅ Done |
| Differential tests | in-memory versus native | native temporary-file contract plus Rust/Web parity | ✅ Done |
| Benchmarks/examples | memory fixtures and paths | temporary native files or explicit OPFS fixtures | ✅ Done |
| Documentation | in-memory/API and `:memory:` examples | file-backed native/temporary OPFS terminology | ✅ Done |
| Web | `:memory:` main-thread smoke and OPFS Worker | temporary/persistent OPFS file smoke | ✅ Done (OPFS worker + WebWorkerClient smokes) |

## Sequencing rules

- Do not remove the public API until replacement temporary-file fixtures pass.
- Do not remove `InMemoryBackend` until raw, typed, query, relationship,
  transaction, migration, sync, attachment, error, and lifecycle coverage has a
  native temporary-file equivalent.
- Keep one migration slice small enough that a failed file cleanup or worker
  lock is attributable to one change.
- Preserve public query authoring and `fromRow`/`toRow` mapping in Dart.
- Preserve migration callbacks, relationship policies/callbacks, reactive
  streams, typed errors, and Web Worker/client integration.

## Replacement fixture helpers

Create shared test support for:

- `withNativeDatabase(name, callback)`: unique temporary directory, native
  release artifact path, deterministic close/cleanup in `finally`;
- `withNativeEngine(name, callback)`: native temporary-file `RawEngine`;
- `withWebOpfsDatabase(name, callback)`: browser smoke/Worker fixture with
  explicit OPFS handle release and reopen verification;
- crash fixture cleanup that tolerates a killed worker/process and removes the
  temporary directory after reopen verification.

Fixtures must never reuse paths between tests and must not hide cleanup failures.

## Test conversion groups

1. raw backend and raw engine contracts;
2. database lifecycle, read-only, locks, snapshots, and crash recovery;
3. typed CRUD, schema, patch, transactions, sync, conflict, attachments,
   migrations, and relationships;
4. filters, indexes, sorting, limits, aggregates, cursors, watches, and
   diagnostics;
5. randomized/differential/large-data/soak tests;
6. Web Worker and OPFS browser smoke tests.

The old in-memory suite can remain temporarily as a comparison oracle during the
conversion, but it must not remain a product path after the public API removal.

## Measurement baseline

Before deletion, record:

- Dart source LOC, split by public/model/reactive versus storage/query/index;
- native open latency and temporary-file cleanup latency;
- backend hops per representative read/write/relationship operation;
- rows and field bytes transferred across the Dart/native boundary;
- peak memory for 1k/100k-row query workloads;
- query latency for indexed, unindexed, aggregate, sorted, and relationship
  routes.

After each removal, rerun the same workloads. Do not weaken performance or
coverage thresholds to accommodate fixture conversion.

## Completion gates

M7.5 is complete only when:

- the public in-memory API and paths are absent;
- no Dart storage engine or Dart-only secondary-index authority remains;
- native temporary-file and Web/OPFS contract suites pass;
- close/reopen, locks, snapshots, crash recovery, cleanup, encryption, and Web
  smoke behavior pass;
- API snapshot, FRB/artifact checks, coverage, offline lint, security review,
  traceability, Rust, and release gates pass;
- README, API docs, compatibility notes, migration docs, examples, and
  benchmarks describe only file-backed product paths.
