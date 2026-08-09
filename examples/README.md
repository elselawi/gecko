# gecko_db runnable examples

These examples are intentionally plain Dart and use the in-memory backend so
that they remain runnable without Flutter, platform plugins, or a native
artifact.

## Tier 1 / Tier 2 quickstart

From the repository root:

```text
dart run examples/phase13_quickstart.dart
```

It opens a database, declares a typed collection, performs CRUD/patch, and
runs an indexed range query.

## Transactions, bulk writes, diagnostics, migrations

```text
dart run examples/phase13_advanced.dart
```

It demonstrates one atomic bulk write, opt-in diagnostics, and an additive
schema migration.

## Consumer fixture (public-surface only)

```text
dart run examples/consumer.dart <dbPath> <nativeLibPath> [hexEncryptionKey]
```

`consumer.dart` is exactly what an external consumer would write: it imports
only `package:gecko_db/gecko_db.dart` (no repository-internal imports) and
exercises import → open → write → watch → query → migrate → encrypt → maintain
→ close, printing `CONSUMER-OK` on success. `tool/consumer_fixture_test.dart`
runs it in CI and rejects any internal import that creeps in.

The examples are documentation fixtures; `packages/gecko_db/test/phase13_examples_test.dart`
executes equivalent flows in the package test suite.
