---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0028: M7.5 file-backed Rust engine consolidation

## Context

M7.1 completed the native execution ownership work, but the repository still
contains a public in-memory mode and a complete Dart `InMemoryBackend` used as a
semantic reference. That mode creates a second storage/query/index engine and
prevents the product contract from being uniformly Rust-owned.

The supported persistent targets are already:

- native desktop/mobile: Rust/redb through the worker isolate and a native file;
- Web: Rust/Wasm/redb through the Web Worker and OPFS.

M7.5 is a pre-release product-contract change. It must not be implemented as a
mechanical deletion before native temporary-file, Web OPFS, lifecycle, cleanup,
and parity coverage exists.

## Decision

1. **Every supported database is file-backed.** Native uses a temporary or
   persistent filesystem path. Web uses a temporary or persistent OPFS file
   through the existing Web Worker path.
2. **Remove the public in-memory surface.** The target API removes
   `DatabaseConfig.inMemory`, `useInMemory`, `mem://`, `:memory:`, the public
   `InMemoryBackend` export, and related documentation/examples. No silent
   fallback from a missing native artifact to the Dart backend is allowed.
3. **Delete the Dart storage engine.** `InMemoryBackend`, its immutable Dart
   storage snapshots, Dart-only storage execution, and the transitional Dart
   `SecondaryIndex` execution path are removed after equivalent native/Web
   contract coverage is established. Public query authoring, result mapping,
   migrations, relationship policy, errors, and reactive lifecycle remain in
   Dart.
4. **Use temporary native files for tests and benchmarks.** Test fixtures own
   their temporary directories and clean them in success, failure, and crash
   paths. Rust ephemeral redb support is not added solely to preserve the old
   `:memory:` API.
5. **Preserve Web OPFS semantics.** The current Web Worker, OPFS handle
   registration, Wasm glue, persistence/reopen behavior, and browser smoke
   coverage remain. Web encryption remains explicitly unsupported under the
   M6.5 native-only physical-encryption contract.
6. **Treat this as a pre-release breaking change.** No compatibility shim for
   the removed in-memory API is retained after M7.5. The API snapshot,
   examples, migration documentation, benchmarks, and tests are updated in the
   same workstream.
7. **Do not move reactivity or callbacks into Rust.** Rust owns storage,
   indexes, predicates, sorting, aggregates, snapshots, and relationship
   retrieval primitives. Dart retains query registration/lifecycle semantics,
   model mapping, migration callbacks, relationship declarations/policies,
   typed-error mapping, and change-feed publication until a later design.

## Migration and sequencing

M7.5 is implemented in slices:

1. inventory and lock public/API/documentation dependencies;
2. add native temporary-file fixtures and replace the shared in-memory suite;
3. qualify persistent and temporary Web OPFS paths and cleanup;
4. remove public in-memory configuration and exports;
5. remove the Dart storage backend, reference snapshots, and Dart-only index
   execution branches;
6. convert differential, benchmark, and release fixtures;
7. run lifecycle, crash/reopen, migration, relationship, encryption, Web,
   artifact, API, coverage, security, and release gates.

Each deletion must have a native temporary-file or Web/OPFS replacement. The
in-memory differential backend is not removed until the replacement contract
suite is green.

## Consequences

- The product has one storage/query/index authority: Rust/redb.
- Tests become closer to release behavior and exercise file cleanup and locks.
- Some existing unit tests become slower because they open temporary native
  files; batching and per-test temporary directories are required.
- Web smoke and OPFS lifecycle become mandatory release coverage rather than an
  optional alternative to in-memory execution.
- This ADR does not remove code by itself; implementation begins with the
  dependency inventory and fixture migration.
