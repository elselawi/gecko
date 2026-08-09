# gecko_db

A local-first, reactive embedded database for **Dart and Flutter**, built for the
"install and use, no monkey business" experience. It aims to be the Hive /
SharedPreferences replacement you never have to hand-roll an observable layer for:
widgets consume live, typed queries directly — no separate state-management
package required.

> **Status: in active development (Phases 0 and 2–13 implemented).** See
> [`plan.md`](plan.md) for the full roadmap and the per-phase progress checkboxes.

---

## What it is

- **Local-first** — everything reads/writes fully offline in a single database
  file (native) or OPFS (web), with a sync *story* (change tracking, conflict
  resolution) that ships later.
- **Reactive** — `Stream`s per database, collection, and item, consumable
  directly by `StreamBuilder`. No manual observer lists to maintain.
- **Codegen-free** — models are plain Dart classes plus a small hand-written
  `toRow`/`fromRow` mapping pair. No annotations, no `build_runner`, no codegen
  step for consumers.
- **Progressive disclosure** — Tier 1 (box-style `get`/`put`/`delete`/`watch`)
  needs zero knowledge of indexes, queries, relationships, transactions, or sync.
- **Cross-platform** — Windows, macOS, Linux, Android, iOS, and Web, backed by
  `redb` (Rust) via `flutter_rust_bridge`, with zero Rust/FFI/build steps for
  consumers.

---

## Current status

| Phase | What | State |
|-------|------|-------|
| 0 | Foundations & contracts (API, error taxonomy, wire format, ADRs, coverage gate) | ✅ |
| 1 | Zero-setup cross-platform distribution (federated plugins, native resolver, OPFS web worker) | ⬜ pending |
| 2 | Core engine: byte-level backend, raw API, LRU cache, backpressure, lifecycle | ⚠️ in-memory half done |
| 3 | Codegen-free typed modeling & Tier 1 API (schema, patch, auto-ids) | ✅ |
| 4 | Reactivity: watch(id)/watchAll()/database.watchAll() streams | ✅ |
| 5 | Query engine & indexing (Tier 2): filters, sort, pagination, count/distinct, reactive queries | ✅ core + in-memory secondary/prefix index, lazy iterate, scan diagnostics |
| 6 | Relationships & referential integrity (Tier 3): FK helpers, delete behaviors, eager load, cycle detection | ✅ many-to-many joins, delete hooks, restrict-naming; typed-collection wiring open |
| 7 | Transactions, durable change tracking, sync hooks, LSN ordering, origin tagging, idempotency, and GC watermark | ✅ |
| 8 | Pluggable conflict resolution, three-way merge, preserved manual conflicts, and atomic resolution | ✅ |
| 9 | Attachment metadata, content-hash dedupe, shared blobs, orphan detection, and state queries | ✅ |
| 10 | Schema versioning & migrations: version stamping, ordered transactional steps, additive fast paths, open-time compatibility gate | ✅ |
| 11 | Logical-value encryption, pluggable authenticated crypto, opaque backend storage, and typed decryption failures | ✅ logical + physical AES-256-GCM page encryption, key providers, atomic key rotation (ADR-0009) |
| 12 | Bulk writes, bounded cache/lazy iteration, per-row diff watches, and opt-in diagnostics | ✅ + in-place compaction, maintenance state machine, size reporting, slow-query logging, counters (ADR-0010) |
| 13 | Runnable quickstart/advanced examples and release-hardening documentation | ✅ examples/tests, consumer fixture, policies/compatibility/migration docs, traceability checker; platform matrix and benchmark open |

### Coverage

The Dart package is held to a **≥95% line + branch** gate and currently sits at
**95% line / 100% branch** (excluding generated FRB glue — native-only
adapter/resolver edge branches remain). The Rust crate is gated separately as CI wiring
lands (Phase 0/1 item).

```text
Dart unit tests: 442 passing (package) + 19 (tool)
Coverage gate:   95% line / 100% branch  → PASS
```

---

## Tier 1 quickstart (the five-minute path)

```dart
import 'package:gecko_db/gecko_db.dart';

class User {
  User(this.id, this.name);
  final String id;
  final String name;
}

// Hand-written mapping pair — plain Dart, no codegen.
Object? userToRow(User u) => {'name': u.name};
User userFromRow(Object? row) => User('', (row as Map)['name'] as String);
Object? userId(User u) => u.id;

Future<void> example(Database db) async {
  final users = db.collection<User>('users',
      toRow: userToRow, fromRow: userFromRow, id: userId);

  await users.put(User('u1', 'Alice'));
  final alice = await users.get('u1');          // User
  await users.patch('u1', {'name': 'Alicia'});  // partial update
  await users.delete('u1');
  final all = await users.getAll();             // List<User>
}
```

### Reactivity (no observable layer to maintain)

```dart
// Watch a single record — a `Stream<User?>` that emits on changes to that id.
users.watch('u1').listen((user) => setState(() => this.user = user));

// Watch a whole collection — coarse `Stream<List<User>>`, re-emitted on any change.
users.watchAll().listen((list) => setState(() => this.users = list));

// Global cross-collection feed, with monotonic per-batch sequence numbers
// (what a future sync engine consumes).
db.watchAll().listen((ChangeSet set) => print('${set.sequence}: $set'));
```

## Tier 2 — queries, sorting, pagination

```dart
// Equality + range filters, composed with chained `.filter()`/`.range()`.
final adults = await users
  .where()
  .range('age', min: 18)
  .filter('active', true)
  .findAll();

// Sort, limit, offset.
final top5 = await users
  .where()
  .sort([const SortSpec('age')])
  .limit(5)
  .findAll();

// count / distinct / first
final n = await users.where({'age': 30}).count();
final ages = await users.where().distinct('age');

// Cursor pagination (opaque key bytes as the cursor).
var cursor;
do {
  final (page, next) = await users.where().sort([const SortSpec('age')])
    .findPage(afterKey: cursor, pageSize: 20);
  // render page...
  cursor = next;
} while (cursor != null);

// Reactive filtered query: re-emits when membership changes.
users.where().range('age', min: 18).watch().listen((list) => setState(() {}));
```

## Tier 3 — relationships & referential integrity

Declare relationships between collections and control delete behavior:

```dart
final r = db.relationships;
r.registerAccessors('posts', RowAccessors(
    childIdOf: (row) => row['id'],
    parentIdOf: (row) => row['authorId']));

r.declare(Relationship(
  name: 'author_posts',
  parentCollection: 'authors',
  childCollection: 'posts',
  foreignKeyField: 'authorId',
  deleteBehavior: DeleteBehavior.cascade, // cascade | restrict | setNull | none
));

final children = await r.children(authorPostsRel, 'a1');   // 1-many
final parent   = await r.parent(authorPostsRel, 'p1');     // reverse lookup
final grouped  = await r.loadAllChildren(authorPostsRel, ['a1','a2']); // no N+1

await r.deleteWithBehavior(authorPostsRel, 'a1'); // enforces delete behavior atomically
```

Cascade cycles (`A→B cascade` + `B→A cascade`, or self-referential) are rejected
at declaration time with a typed `GeckoError`.

### Opening a database

```dart
// In-memory (tests / ephemeral):
final db = await DatabaseImpl.open('mem://demo', useInMemory: true);

// File-backed arrives with the native distribution phase (Phase 1/2).
await db.close();
```

> **Reserved namespace:** table names starting with `__gecko_` are reserved for
> engine-internal metadata and are rejected with a typed `GeckoError`
> (`invalidOperation`). Deleting a missing record is a no-op, and `getAll()` on
> an empty collection returns an empty list.

---

## Tier 3 sample — schema + missing/null/default

`patch` and schema validation preserve the three distinct field states
(**missing** / **null** / **value**):

```dart
final schema = RowSchema.of({
  'name':   const FieldSpec(name: 'name', required: true),
  'status': const FieldSpec(name: 'status',
      defaultValue: 'active', hasDefault: true),
});

final users = db.collection<User>('users',
    toRow: userToRow, fromRow: userFromRow, id: userId, schema: schema);

// Schema-validated put; defaults filled for missing fields.
await users.put(User('u1', 'Alice'));

// Partial update: only 'name' changes; 'status' falls back to 'active'.
await users.patch('u1', {'name': 'Alicia'});
```

---

## Architecture

The design is documented in [`plan.md`](plan.md) and in the
[architecture decision records](docs/adr/). Key points:

- **Single writer, many readers, always batched.** Every mutation funnels through
  one write gate into an atomic batch; a reader never observes a partial batch
  (MVCC snapshots). `RawEngine` in `lib/src/raw/raw_engine.dart` provides
  `rawGet` / `rawPut` / `rawDelete` / `rawRangeScan` with a bounded in-flight
  buffer (backpressure) and an LRU cache for hot point reads.
- **Two "workers", one writer.** A Rust `redb`-owning worker thread owns the file.
  A dedicated Dart **worker isolate** hosts the database client's work (reads,
  batch marshaling, change-feed fan-out) off the caller's UI isolate — embraced
  *modestly* (one isolate per open database, never a second writer). See
  [ADR-0003](docs/adr/0003-worker-isolate.md).
- **Everything is a file-format contract.** All state — including change
  tracking, sync, indexes, attachments, migrations, encryption metadata — lives
  in reserved `__gecko_*` tables in the same store, transactionally with the data.
  Phase 7 adds staged multi-collection `writeTxn` blocks, durable LSN-ordered
  change records, origin-tagged sync hooks, idempotency dedupe, and watermark-
  based change-log compaction.
- **Performance and diagnostics.** Phase 12 adds atomic `bulkWrite`, weighted
  LRU bounds, lazy `Query.iterate`, optional `watchAllDiff` row deltas, and
  opt-in diagnostics counters.
- **Runnable examples.** Phase 13 keeps plain-Dart quickstart and advanced
  examples under `examples/`, with equivalent package tests in
  `test/phase13_examples_test.dart`.
- **Attachment metadata.** Phase 9 tracks binaries that live outside the
  database: parent references, content-hash dedupe with shared blobs, and
  transactionally-advanced upload/delete/retry states with pending/failed/
  completed/orphan queries.
- **Encryption seam.** Phase 11 provides `EncryptedRawBackend`, a pluggable
  authenticated `CryptoBackend` registry, AES-256-GCM, ciphertext opacity, and
  typed wrong-key/tamper failures. Workstream 4 adds **physical** AES-256-GCM
  page encryption below redb (`EncryptingStorageBackend`), key providers
  (`FixedKeyProvider`, `EnvironmentKeyProvider`, `FileKeyProvider`),
  fail-before-open key resolution, and atomic key rotation with crash recovery
  to either the old or the new key
  (see [ADR-0009](docs/adr/0009-physical-encryption-and-key-management.md)).
- **Compaction & maintenance.** Workstream 5 adds in-place compaction via
  `Database.maintenance` (`compact()`/`recover()`/`storageStats()`) with a
  five-state machine (idle/compacting/committed/failed/recovering), a durable
  interrupted-compaction marker, crash-safe two-phase compaction that works
  under physical encryption, logical + physical size reporting, slow-query
  logging with indexed/full-scan attribution, and diagnostics counters
  (lock contention, active subscribers, compaction stats) — all off by
  default (see [ADR-0010](docs/adr/0010-compaction-maintenance-and-diagnostics.md)).
- **Pluggable conflict resolution.** Phase 8 exposes pure, registry-backed
  strategies for last-write-wins, field-level merge, manual review, and
  three-way merge. Deferred conflicts are preserved in `__gecko_conflicts` and
  concrete resolutions write data and sync metadata atomically.
- **Codegen-free modeling.** Manual `toRow`/`fromRow` pairs, schema validation,
  and partial `patch` (see [ADR-0001](docs/adr/0001-manual-mappers-over-codegen.md)).

### Repository layout

```
packages/gecko_db/        Public API + in-memory engine (pure Dart)
rust/gecko_db_rust/       Rust engine crate (redb wrapper)       [in progress]
docs/adr/                 Architecture decision records
tool/                     Coverage gate, golden-fixture generator
plan.md                   The full, versioned roadmap
```

---

## Documentation

- **[API reference](docs/api.md)** — the public surface by tier
  (collections, queries, relationships, transactions, sync, conflicts,
  attachments, migrations, encryption, bulk writes, diagnostics, maintenance).
- **[Migration guide](docs/migration-from-hive.md)** — moving from Hive /
  SharedPreferences, with explicit limitations and a data-import example.
- **[Policies](docs/policies.md)** — semantic versioning, deprecation,
  migration, and format-compatibility policies.
- **[Compatibility matrix](docs/compatibility.md)** — package/wire/format
  versions, native artifact, Dart/Flutter, and platform support.
- **[Security](SECURITY.md)** — disclosure process and explicit security
  posture (what is and is not claimed).
- **[Changelog](CHANGELOG.md)** — release notes.
- **[Architecture decision records](docs/adr/)** — the locked history of
  non-trivial choices.

## Compatibility (summary)

| Component | Version |
|---|---|
| Package / wire / file format | `0.0.1` / `1` / `1` (redb 4.1.0) |
| Native build id | `0.0.1+rust` |
| Dart SDK | `^3.10.8` |
| Platforms | Windows ✅ · macOS/Linux/Android/iOS/Web ⬜ matrix pending |

See [docs/compatibility.md](docs/compatibility.md) for the full table and
rules. Forward reads are supported; a newer incompatible file fails with a
typed `upgradeRequired` error, never a silent misread.

## Acceptance-criteria traceability

The local-first acceptance criteria are each demonstrated by named tests,
verified by `dart run tool/traceability_check.dart`:

| # | Criterion | Demonstrated by |
|---|---|---|
| 1 | Widgets consume live typed queries directly | `query_test.dart` reactive filtered watch; `phase5_index_ws3_test.dart` |
| 2 | Local reads/writes work fully offline | `phase2_differential_test.dart`; `in_memory_backend_test.dart` |
| 3 | A local mutation auto-updates all affected live queries | `query_test.dart` starts/stops-matching; `watch_test.dart` |
| 4 | No manually maintained observable lists required | `watch_test.dart`; `phase13_examples_test.dart` |
| 5 | Sync can read pending local changes via a small interface | `phase7_transactions_sync_test.dart` pending-record test |
| 6 | Remote changes applied transactionally | `phase7_transactions_sync_test.dart` rollback/own-write tests |
| 7 | Local/remote changes merge deterministically | `phase8_conflict_test.dart` strategy + manual-conflict tests |
| 8 | Attachment metadata stays consistent with record changes | `phase9_attachments_test.dart` dedupe/free tests |
| 9 | Large datasets stay responsive | `phase12_performance_test.dart`; `phase5_index_ws3_test.dart` |
| 10 | Tests use isolated in-memory databases | `in_memory_backend_test.dart`; `phase2_differential_test.dart` |
| 11 | Initialization, recovery, migrations are reliable | `phase2_process_crash_test.dart`; `phase10_migrations_test.dart` |
| 12 | App-specific store layer shrinks substantially | `phase13_examples_test.dart`; `tool/consumer_fixture_test.dart` |

---

## Development

```bash
# Bootstrap (Dart workspace)
dart pub get

# Analyze the whole workspace
dart analyze

# Run all Dart tests
cd packages/gecko_db && dart test

# Coverage gate (from repo root, after generating an lcov.info)
dart run tool/coverage_gate.dart packages/gecko_db/coverage/lcov.info

# Rust tests (cross-language golden fixture included)
cd rust && cargo test

# Regenerate the cross-language Op golden fixture (only with an ADR)
dart run tool/gen_golden_ops.dart
```

The coverage gate enforces **≥95% line + branch** on the Dart package and
accepts both `*.lcov` and the standard `lcov.info` output from
`package:coverage`. CI wiring (also covering the Rust gate with
`cargo llvm-cov`/`grcov`) is still a Phase 0/1 item because the Rust coverage
binary and native artifact matrix are not yet present.

---

## Roadmap

See [`plan.md`](plan.md) for the full 13-phase plan. Soonest next steps:
**Phase 2 completion** (native file-backed worker, crash recovery, full lifecycle),
then **Phase 1** (cross-platform distribution — the hardest and most foundational
phase), then **Phase 4** (reactivity: `watch` streams).
The pure-Dart portions of the remaining Phase 0–3 gaps are covered by format-header,
lifecycle, raw-backend contract, cache-isolation, schema-open, unknown-field, resolver,
and large-value tests. The Rust `redb` worker core, generated FRB bridge, and live Windows file-backed
Dart-to-Rust integration test are also implemented and tested. OPFS, federated
platform packaging, cross-process lock diagnostics, crash-kill stress, platform
CI, and Rust coverage tooling remain deferred until their required artifacts exist.
