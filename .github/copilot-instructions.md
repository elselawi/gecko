# GitHub Copilot instructions for the gecko repository

These instructions are loaded automatically by GitHub Copilot when editing
code in this repository. Read [AGENTS.md](../AGENTS.md) for the full
repository map; this file is the compact, enforceable subset.

## Project shape

`gecko_db` is a **thin pure-Dart client** (`packages/gecko_db`) over a
**Rust `redb` engine** (`rust/`) in a worker isolate. Rust computes; Dart
authors, maps, coordinates, and transports.

## Hard rules

1. **Thin-client rule.** All database semantics (storage, indexes, query
   execution, reactivity, sync aggregation, compaction, encryption) belong in
   Rust. Never move computation into Dart.
2. **No consumer-facing native build.** Consumers never run `cargo`, FFI, or
   codegen. Native artifacts are prebuilt and bundled.
3. **No codegen modeling.** Models are plain Dart classes with `toRow` /
   `fromRow`. Do not add mirrors, annotations, or build_runner modeling.
4. **One writer, always batched.** Mutations cross the worker boundary once
   as an encoded batch and apply in a single `redb` write transaction.
5. **Progressive disclosure.** The public API is tiered: Tier 1
   (get/put/delete/watch) must not require knowledge of queries, indexes,
   relationships, transactions, or sync.

## Testing discipline

- Put Dart tests under `packages/gecko_db/test/`; Rust tests under
  `rust/tests/` (and `#[cfg(test)]` modules).
- Every behavior change ships with a failing-before test.
- Tool tests are enumerated explicitly: `dart test tool/*_test.dart`
  (`dart test tool` alone does not work).
- Heavy suites (`randomized`, `soak`, `differential_long`, `crash_*`,
  `large_data`, `parallel`) run with `GECKO_LONG_TEST=1`.

## Coverage markers

Use `coverage:ignore-line` (trailing) or `coverage:ignore-start` /
`coverage:ignore-end` (block) to exclude code from the gate. **Syntax rule:**
after the marker, only letters, digits, and whitespace may follow — no `:`,
`-`, or `;` — or `format_coverage --check-ignore` throws. Example:

```dart
// coverage:ignore-line
// coverage:ignore-start
// coverage:ignore-end
```

The release gate requires ≥95% line / 100% branch on a **fresh** collection.

## What to avoid

- Do **not** run `dart format` or `cargo fmt` on unrelated lines. Keep diffs
  focused. FRB codegen reformats hand-written files — revert that noise with
  `git checkout HEAD -- <file>`.
- Do **not** add planning/milestone terminology (e.g. "phase", "milestone",
  "workstream", "wave", or shorthands like `P2`, `WS4`, `M11`) to comments,
  filenames, or test titles. This repository uses plain, conventional naming.
- Do **not** reference a `docs/` directory or ADRs — those were removed; the
  docs are `README.md`, `AGENTS.md`, `examples/README.md`, `SECURITY.md`, and
  `CHANGELOG.md`.
- Do **not** edit `tool/api_snapshot.txt` by hand. Change the public API and
  run `dart run tool/api_contract_gate.dart --update`, then review the diff.
- Do **not** add consumer-facing CI steps. CI is release-only (manual
  `release-matrix` workflow); quality gates run locally via
  `dart run tool/release_checklist.dart`.

## Command cheat sheet

| Task | Command |
|---|---|
| Analyze | `dart analyze` |
| Dart tests | `dart test packages/gecko_db/test` |
| Tool tests | `dart test tool/*_test.dart` |
| Rust tests | `cd rust && cargo test` |
| All local release gates | `dart run tool/release_checklist.dart` |
| Coverage gate | `dart run tool/coverage_gate.dart <lcov>` |
| Traceability | `dart run tool/traceability_check.dart` |
| API snapshot | `dart run tool/api_contract_gate.dart --update` |
| Native perf gate | `dart run tool/perf_gate.dart --indexed` |
| Comparative bench | `cd benchmark && dart run comparative.dart` |
