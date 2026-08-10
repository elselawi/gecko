# gecko_db policies

Release-facing policies for consumers and maintainers (Workstream 6). These
are the contract by which the package evolves without breaking the "install
and use, no monkey business" promise.

## Semantic-versioning policy

`gecko_db` follows [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** — breaking changes to the public API, the on-disk file format, the
  wire format, or the error taxonomy.
- **MINOR** — additive, backward-compatible features (new APIs, new
  collections/tables, new diagnostics counters) and deprecations.
- **PATCH** — bug fixes, performance improvements, and documentation that do
  not change behavior or signatures.

The version lives in `packages/gecko_db/pubspec.yaml`
(`geckoPackageVersion` in `lib/src/wire/compatibility.dart` mirrors it for the
Dart/native handshake).

## API deprecation policy

- A public API is never removed in a PATCH. It may be **deprecated** in a MINOR
  with a `@Deprecated('use X instead; removed in Y')` annotation and a
  migration note in `CHANGELOG.md`.
- Deprecated APIs are removed only in the next MAJOR, and only after having
  been deprecated for at least one MINOR release cycle.
- Public-API changes are ADR-gated: the CI contract gate
  (`tool/workstream0_contract_test.dart` + `tool/api_snapshot.txt`) fails when
  the public snapshot changes without an accompanying ADR or intentional
  version bump.

## Migration policy

- Schema/storage migrations are **additive by default**: new fields, new
  collections, and new reserved tables never require rewriting existing rows.
  Rows are interpreted lazily via Phase 3 missing/null/default semantics.
- Explicit version steps (`SchemaApi.stamp` / `migrateStep` / `MigrationPlan`)
  are transactional: each step commits atomically, and a failed step leaves the
  previous version intact.
- The open-time compatibility gate (`maxKnownSchemaVersion`) refuses to open a
  database stamped newer than this build understands with a typed
  `upgradeRequired` error, instead of silently misreading it.
- See [`docs/migration-from-hive.md`](migration-from-hive.md) for consumer
  migration guidance.

## Format-compatibility policy

- **On-disk file format**: redb 4.1.0 (currently `geckoFormatVersion = 1`).
  A database written by an older supported version opens cleanly; a database
  written by a *newer* incompatible version fails with a typed
  `upgradeRequired`/`checksumMismatch` error, never a silent misread.
- **Wire format**: `geckoWireVersion = 1` (`lib/src/wire/format_header.dart`),
  locked by the golden-bytes fixture (`tool/gen_golden_ops.dart`). Changing it
  requires an ADR and a version bump.
- **Native artifact**: the Rust worker reports a build id (`0.0.1+rust`) in the
  compatibility handshake; an artifact whose handshake does not match the
  package is rejected before use.
- **Encrypted databases**: the pre-release contract uses one optional raw
  32-byte key for native Rust AES-256-GCM physical encryption. Encryption is
  off by default; Web and in-memory encryption are unsupported. Reopening with
  the wrong key (or a corrupted page) fails authentication before any data is
  returned. Public key rotation remains atomic and crash-recoverable. Physical
  secure-deletion is **not** claimed. See ADR-0022.

## Security disclosure process

See [`SECURITY.md`](../SECURITY.md). In short: report suspected vulnerabilities
privately (do not open a public issue), maintainers respond within a
time-boxed window, fixes ship with an advisory in `CHANGELOG.md`, and
`gecko_db` makes **no** claim of physical secure deletion or protection against
a hostile OS with access to process memory.

## Changelog and releases

- Every release records user-visible changes in [`CHANGELOG.md`](../CHANGELOG.md):
  added / changed / deprecated / removed / fixed, with links to the relevant
  ADRs.
- Releases follow the dependency order in `plan.md` (the Production Completion
  Runbook); a release only ships when the CI gates (analysis, tests, coverage,
  Rust gates, bindings, doc examples, traceability) are green.
