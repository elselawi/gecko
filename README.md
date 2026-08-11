# gecko_db

A **local-first, reactive, embedded database** for Dart and Flutter. gecko_db
is a thin, platform-agnostic Dart client over a **Rust `redb` engine** that
runs in a worker isolate: storage, MVCC, indexing, query execution, reactive
change tracking, sync bookkeeping, compaction, and encryption all happen in
Rust. The Dart side authors queries, maps models, and coordinates policy —
it never executes database semantics.

```
┌──────────────────────────────────────────────────────────────┐
│  Your app (Dart / Flutter)                                    │
│  Database · Collection · Query · Transaction · watch()        │
├──────────────────────────────────────────────────────────────┤
│  gecko_db (pure Dart, thin client)                           │
│  query authoring · model mapping · policy · transport         │
├──────────────────────────────────────────────────────────────┤
│  Rust engine (redb) — worker isolate                          │
│  storage · MVCC · indexes · predicate/sort/aggregates ·       │
│  reactive registry · change log · sync aggregation ·          │
│  compaction · physical encryption                             │
└──────────────────────────────────────────────────────────────┘
```

- **Zero-setup**: prebuilt native artifacts are bundled with the package. No
  `cargo`, FFI, or build steps for consumers.
- **Reactive**: `watch()` / `watchAll()` streams are maintained by a Rust
  reactive registry that re-evaluates only the changed keys of each write.
- **File-backed everywhere**: native files on desktop/mobile, OPFS files in a
  Web Worker on the web.
- **Transactional**: every mutation is one atomic `redb` write transaction.

---

## Part 1 — For consumers: getting started

### Install

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  gecko_db:
    path: ../gecko
```

```sh
dart pub get
```

### Open a database

```dart
import 'package:gecko_db/gecko_db.dart';

final db = await Database.open('my.db');
```

### Define a collection

gecko_db uses plain Dart classes with a small hand-written mapping pair
(`toRow` / `fromRow`) — no code generation, no annotations.

```dart
class User {
  User(this.id, this.name, this.age);
  final String id;
  final String name;
  final int age;
}

final users = db.collection<User>(
  'users',
  toRow: (u) => {'id': u.id, 'name': u.name, 'age': u.age},
  fromRow: (row) => User(row['id'] as String, row['name'] as String, row['age'] as int),
  id: (u) => u.id,
  indexFields: const ['age'], // optional durable secondary index
);
```

### CRUD

```dart
await users.put(User('u1', 'Ada', 36));
final ada = await users.get('u1');
await users.delete('u1');

// Batches are atomic.
await db.bulkWrite([
  BulkMutation.put(table: 'users', key: 'u1', value: {'id': 'u1', 'name': 'Ada', 'age': 36}),
  BulkMutation.delete(table: 'users', key: 'u2'),
]);
```

### Query

```dart
final adults = await users
    .where((u) => u.age >= 18)
    .sortBy((u) => u.age, descending: true)
    .findAll();
```

Indexed equality, range, prefix, and multi-equality queries route through the
Rust durable index; filtering, sorting, and windowing always execute in Rust.

### Reactivity

```dart
final sub = users.watchAll().listen((rows) => print('users changed: ${rows.length}'));
// Or watch one record:
final sub2 = users.watch('u1').listen((user) => print(user));
```

Writes from any session are observed; the Rust registry diffs each committed
batch and Dart forwards the deltas to the `Stream`.

### Transactions, migrations, relationships, sync

- **Transactions**: `db.transaction(() async { ... })` with rollback support.
- **Migrations**: additive schema versions via `SchemaApi.stamp` /
  `migrateStep`; open-time compatibility gate refuses newer databases.
- **Relationships**: one-to-many / many-to-many helpers (`children`, `parent`,
  `loadAllChildren`, join tables) with delete behaviors.
- **Sync**: `pendingChanges` and the change log are aggregated in Rust.

### Supported platforms & artifacts

| Platform | Native artifact | Status |
|---|---|---|
| Windows x64 | `gecko_db_rust.dll` | ✅ built + bundled |
| Android (4 ABIs) | `gecko_db_rust.so` | ✅ built + bundled |
| Web (wasm32 + OPFS) | `gecko_db_rust_bg.wasm` | ✅ built + bundled |
| Linux / macOS | `.so` / `.dylib` | ⬜ release workflow (manual trigger) |
| iOS | FRB iOS plugin artifact | ⬜ pending FRB iOS plugin scaffold |

See [examples/README.md](examples/README.md) for runnable examples
(`quickstart.dart`, `advanced.dart`, and the consumer-surface-only
`consumer.dart`).

### Documentation for consumers

- [examples/README.md](examples/README.md) — runnable examples
- [CHANGELOG.md](CHANGELOG.md) — version history
- [SECURITY.md](SECURITY.md) — security policy & disclosure

---

## Part 2 — For developers

### Architecture

gecko_db is a **thin Dart client over a Rust engine**. The dividing line is a
hard rule: **anything that computes belongs in Rust; Dart authors, maps,
coordinates, and transports.**

| Rust owns (computation) | Dart owns (authoring/policy) |
|---|---|
| Storage, MVCC, file/OPFS I/O | Public API surface (`Database`, `Collection`, `Query`, ...) |
| Durable secondary indexes + repair | Query authoring DSL (`where`/`sortBy`/`filter`) |
| Predicate / sort / aggregate execution | `toRow`/`fromRow` model mapping |
| Reactive registry + per-batch diffs | Change-feed / reactive `Stream` lifecycle |
| Change-log pruning, sync-state aggregation | Delete behaviors, migration callbacks, conflict policies |
| Relationship candidate retrieval/classification | Transport (worker isolate client, dispatch) |
| Compaction, physical encryption | Typed errors, compatibility handshake |

The engine runs in a **worker isolate** (single writer, always batched); every
mutation crosses the boundary once as an encoded batch and applies in one
`redb` write transaction. On the web the same dispatch runs in the OPFS worker.

### Repository layout

```
packages/gecko_db/   the Dart package (lib/, test/)
rust/                the Rust engine crate (redb wrapper), src/, tests/
tool/                gates & tooling (coverage, traceability, contract,
                     artifact build, release checklist)
benchmark/           standalone benchmark package (native + comparative)
examples/            runnable, dependency-free examples
```

### Standards

- **No consumer-facing Rust/FFI/build steps.** All FRB codegen and native
  compilation happens once, producing prebuilt artifacts that ship inside the
  package. Consumers never run `cargo`.
- **No reflection or annotation+codegen modeling.** Models are plain Dart
  classes with `toRow`/`fromRow` — normal Dart code.
- **One writer, many readers, always batched.** Every Rust-side mutation goes
  through a single long-lived worker owning the `redb` handle, applied in one
  transaction.
- **Progressive disclosure.** Tier 1 (get/put/delete/watch) works with zero
  knowledge of indexes, queries, relationships, transactions, or sync.
- **Coverage gate.** The release checklist enforces ≥95% line / 100% branch
  coverage on the Dart package (measured from a **fresh** collection — stale
  lcov is never merged).
- **Contract gate.** The public API snapshot (`tool/api_snapshot.txt`) is
  regenerated and compared on every change; public-API changes must be
  intentional and ship with a version bump and release notes.
- **Thin-client rule.** Code that computes belongs in Rust; the acceptance
  test for any new feature is "does Dart only author, map, coordinate, and
  transport?"

### Building

```sh
# Dart deps
dart pub get

# Rust engine (debug for tests)
cd rust && cargo build

# Release native artifact (needed by benchmarks + release)
cd rust && cargo build --release
```

### Regenerating FRB bindings

After changing `rust/src/api.rs`:

```sh
flutter_rust_bridge_codegen generate --config-file frb.yaml
dart run tool/build_artifacts.dart build windows-x64 --out=build/native
dart run tool/build_artifacts.dart bundle --from=build/native
dart run tool/build_artifacts.dart check-bindings   # requires a clean tree
```

### Testing

```sh
# Full package suite
dart test packages/gecko_db/test

# Tool suites (enumerate explicitly — `dart test tool` alone does not work)
dart test tool/*_test.dart
```

The test suite covers the backend contract, differential parity, crash
recovery, indexes, relationships, transactions, sync, conflicts, attachments,
migrations, encryption, compaction, reactivity, and long-running
randomized/soak suites (heavy suites run with `GECKO_LONG_TEST=1`).

### Coverage

```sh
dart test packages/gecko_db/test --coverage=packages/gecko_db/coverage
dart run coverage:format_coverage --lcov --check-ignore \
  --in=packages/gecko_db/coverage -o packages/gecko_db/coverage/lcov.info \
  --report-on=packages/gecko_db/lib --ignore-files="**/native/generated/**"
dart run tool/coverage_gate.dart packages/gecko_db/coverage/lcov.info
```

`tool/coverage_gate.dart` measures existing lcov (it does **not** collect), so
always delete the coverage directory before measuring (the release checklist
does this for you).

### Performance

```sh
# Native workload benchmark + strict gate
dart run benchmark/bench.dart --native --json
dart run tool/perf_gate.dart

# Comparative benchmark: gecko_db vs Hive CE, Sembast, SQLite, Isar, Drift
cd benchmark && dart run comparative.dart            # all six backends
cd benchmark && dart run comparative.dart --json
```

The comparative benchmark is its **own package** (`benchmark/pubspec.yaml`):
SQLite/Drift resolve the native library via Dart native assets, and Isar uses
the maintained `isar_community` fork (which downloads its core binary on first
run). Run it from inside `benchmark/` — its native-assets build hooks must not
pollute the repo root's `dart run` stdout (the process tests rely on exact
output markers).

### Release

CI is **release-only**: `.github/workflows/release-matrix.yml` is triggered
manually and exists to build + verify + upload per-platform artifacts on
hardware the maintainer does not own (macOS runners). Quality gates are local:

```sh
# The one command that runs every gate:
dart run tool/release_checklist.dart            # all required gates
dart run tool/release_checklist.dart --long     # + heavy/soak suites
dart run tool/release_checklist.dart --perf     # + strict perf gate
dart run tool/release_checklist.dart --rust-coverage
```

Then trigger the release workflow (GitHub → Actions → release-matrix → Run
workflow), bundle the uploaded artifacts into `packages/gecko_db/lib/native/`,
and publish.

### Policies

- **API deprecation**: public API is never removed in a PATCH; deprecated in a
  MINOR with a `@Deprecated` note; removed only in the next MAJOR.
- **Migration**: schema/storage migrations are additive by default; rows are
  interpreted lazily with missing/null/default semantics.
- **Format compatibility**: on-disk format and wire format are versioned; a
  newer database fails with a typed `upgradeRequired` error, never a silent
  misread. The native artifact reports a build id in the compatibility
  handshake and is rejected on mismatch.
- **Encryption**: optional raw 32-byte key for native AES-256-GCM physical
  encryption; web/in-memory encryption unsupported; wrong keys fail
  authentication before any data is returned.

### Agent/automation instructions

Automated agents working in this repository should read
[AGENTS.md](AGENTS.md) (repository map + standards) and
[.github/copilot-instructions.md](.github/copilot-instructions.md)
(GitHub Copilot custom instructions).

---

## License & security

See [SECURITY.md](SECURITY.md) for the security policy and disclosure
process. See [CHANGELOG.md](CHANGELOG.md) for the full version history.
