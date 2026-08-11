# gecko_db runnable examples

These examples are intentionally plain Dart and use a temporary native
file-backed database so they remain runnable without Flutter or platform
plugins (the bundled native artifact is resolved automatically).

## Tier 1 / Tier 2 quickstart

From the repository root:

```text
dart run examples/quickstart.dart
```

It opens a database, declares a typed collection, performs CRUD/patch, and
runs an indexed range query.

## Transactions, bulk writes, diagnostics, migrations

```text
dart run examples/advanced.dart
```

It demonstrates one atomic bulk write, opt-in diagnostics, and an additive
schema migration.

## Consumer fixture (public-surface only)

```text
dart run examples/consumer.dart <dbPath> <nativeLibPath> [hexEncryptionKey]
```

`consumer.dart` is exactly what an external consumer would write: it imports
only `package:gecko_db/gecko_db.dart` (no repository-internal imports) and
exercises import → open → write → watch → query → migrate → optional native
physical encryption → maintain → close, printing `CONSUMER-OK` on success.
uses one raw 32-byte key and does not expose custom crypto or key-provider
methods. `tool/consumer_fixture_test.dart` runs it as part of the release
checklist and rejects any internal import that creeps in.

The examples are documentation fixtures; `packages/gecko_db/test/examples_test.dart`
executes equivalent flows in the package test suite.
