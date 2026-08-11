# AGENTS.md

This file is the primary orientation document for **automated coding agents**
(and humans) working in this repository. It is intentionally short and
pointing: every section links to the authoritative source.

> Agents using **GitHub Copilot** should also read
> [`.github/copilot-instructions.md`](.github/copilot-instructions.md) — it
> carries the same conventions in a form Copilot loads automatically.

## What this repository is

`gecko_db` — a local-first, reactive, embedded database for Dart/Flutter.

A **thin pure-Dart client** (`packages/gecko_db`) sits over a **Rust `redb`
engine** (`rust/`) running in a worker isolate. All database semantics are
computed in Rust; Dart only authors queries, maps models, coordinates policy,
and transports encoded batches.

## Repository map

| Path | What lives here |
|---|---|
| `packages/gecko_db/` | The Dart package. `lib/` public API, `test/` suite (483 tests) |
| `rust/` | The Rust engine crate. `src/api.rs` (FRB surface), `src/worker.rs`, `src/`, `tests/` |
| `tool/` | Gates & tooling — see [Tooling](#tooling) |
| `benchmark/` | **Standalone** benchmark package (own `pubspec.yaml`), native + comparative |
| `examples/` | Runnable, dependency-free examples (`quickstart.dart`, `advanced.dart`, `consumer.dart`) |
| `.github/workflows/` | `release-matrix.yml` — the **only** workflow; manual, release-only |

## Non-negotiables (agents must respect these)

1. **Thin-client rule.** Anything that computes belongs in Rust. Dart code
   must only author, map, coordinate, and transport. A new feature is
   "done" only when no database logic leaked into Dart.
2. **Never require consumers to build.** No consumer-facing `cargo`, FFI, or
   codegen. FRB bindings + native artifacts are built once here and bundled.
3. **No annotation/codegen modeling.** Models are plain Dart classes with
   `toRow`/`fromRow`. Do not introduce mirrors or build_runner modeling.
4. **One writer, always batched.** Mutations cross to Rust as one encoded
   batch and apply in a single `redb` transaction. Never add Dart-side direct
   write paths.
5. **Coverage markers.** Use `coverage:ignore-line` (trailing comment) or
   `coverage:ignore-start` / `coverage:ignore-end` (block). After the marker
   only letters, digits, and whitespace may follow — no `:`, `-`, or `;` —
   or `format_coverage --check-ignore` fails. The gate is ≥95% line /
   100% branch on a fresh collection.
6. **Contract gate.** `tool/api_snapshot.txt` must match the public API.
   After changing the public surface, regenerate with
   `dart run tool/api_contract_gate.dart --update` and review the diff.
7. **Don't reformat for no reason.** Do not run `dart format` or `cargo fmt`
   on unrelated lines; FRB codegen reformats hand-written files — revert
   that noise with `git checkout HEAD -- <file>`.
8. **Tool tests are enumerated.** `dart test tool` alone fails; use
   `dart test tool/*_test.dart`.

## Tooling

Run from the repository root unless noted.

| Tool | Purpose |
|---|---|
| `dart run tool/release_checklist.dart` | The **single** command for every local release gate (16 steps). Flags: `--long`, `--perf`, `--rust-coverage`, `--no-coverage` |
| `dart run tool/coverage_gate.dart <lcov>` | Checks coverage from existing lcov (never collects). Always delete the coverage dir first (checklist does) |
| `dart run tool/traceability_check.dart` | Verifies every user-facing feature has a test + doc reference |
| `dart run tool/contract_gate_test.dart` | Backend contract between Dart and Rust |
| `dart run tool/api_contract_gate.dart` | Public API snapshot compare / `--update` |
| `dart run tool/api_contract_gate_test.dart` | Snapshot gate test |
| `dart run tool/build_artifacts.dart` | Build / bundle / verify native artifacts (`build`, `bundle`, `check-bindings`) |
| `dart run tool/perf_gate.dart` | Strict native perf thresholds (used with `--perf`) |
| `dart run tool/artifact_manifest_test.dart`, `coverage_gate_test.dart`, `perf_gate_test.dart`, `security_review_test.dart`, `offline_lint_test.dart`, `docs_examples_test.dart`, `release_checklist_test.dart`, `consumer_fixture_test.dart` | The individual gate tests |

## Building

```sh
dart pub get
cd rust && cargo build            # engine (debug, for tests)
cd rust && cargo build --release  # native artifact (benchmarks, release)
```

### Regenerating FRB bindings

After editing `rust/src/api.rs`:

```sh
flutter_rust_bridge_codegen generate --config-file frb.yaml
dart run tool/build_artifacts.dart build windows-x64 --out=build/native
dart run tool/build_artifacts.dart bundle --from=build/native
dart run tool/build_artifacts.dart check-bindings   # requires clean tree
```

## Testing

```sh
# Dart package suite (483 tests)
dart test packages/gecko_db/test

# Tool suites — always enumerate
dart test tool/*_test.dart

# Rust engine
cd rust && cargo test

# Heavy suites
dart test packages/gecko_db/test --run-skipped  # or set GECKO_LONG_TEST=1
```

## Coverage

```sh
dart test packages/gecko_db/test --coverage=packages/gecko_db/coverage
dart run coverage:format_coverage --lcov --check-ignore \
  --in=packages/gecko_db/coverage -o packages/gecko_db/coverage/lcov.info \
  --report-on=packages/gecko_db/lib --ignore-files="**/native/generated/**"
dart run tool/coverage_gate.dart packages/gecko_db/coverage/lcov.info
```

## Performance

```sh
# Native workload + strict gate
dart run benchmark/bench.dart --native --json
dart run tool/perf_gate.dart

# Comparative (gecko_db vs Hive CE, Sembast, SQLite, Isar, Drift)
cd benchmark && dart run comparative.dart
cd benchmark && dart run comparative.dart --json
```

`benchmark/` is a **standalone package**. Always `cd benchmark` first — its
Dart native-assets build hooks pollute `dart run` stdout at the repo root and
break the process tests that match exact output markers. Codegen (Isar) uses
`dart run build_runner build --force-jit`.

## Contributing

- **Small, reviewable commits.** One concern per commit; no mega-diffs.
- **Tests first or alongside.** Every behavior change ships with a test that
  fails before the change.
- **Run the gates before pushing.** At minimum
  `dart run tool/release_checklist.dart` plus `cargo test`.
- **Respect the API contract.** Snapshot changes are intentional and noted in
  the changelog.
- **Documentation drift guards.** Any doc that references `dart run <file>`
  must point at a real file; every example must be referenced by docs or tests
  (`tool/docs_examples_test.dart` enforces both).
