---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0021: M6 measured architecture decisions

## Context

M6 had two open architecture questions from the query-path work:

1. whether the Dart worker isolate should be removed or bypassed because its
   port/serialization boundary is slower than a direct FRB call; and
2. whether the optional Dart logical-encryption wrapper should be removed from
   native hot paths or moved below the Rust boundary.

The worker-isolate decision below remains accepted. The encryption decision is
superseded for the pre-release product by ADR-0022, which chooses removal of
logical encryption rather than retention of the wrapper.

The decisions must preserve the single-writer rule, UI-thread safety, crash and
reopen behavior, encryption coverage, and the existing public API contracts.

## Measurements

Measurements were taken on the Windows reference machine with Dart 3.10.8 and
the current release native artifact.

### Worker-isolate boundary

`dart run benchmark/boundary.dart --json`:

| Stage | Median/current sample |
|---|---:|
| Plain Dart async call | 1.0 µs |
| Direct FRB call | 25.1 µs |
| Direct Rust no-op | 17.7 µs |
| Worker-isolate round trip | **57.3 µs** |
| Isolate premium over FRB | **32.3 µs** |
| Cold raw read | 101.5 µs |
| Hot cached read | 0.53 µs |

At 1k rows, the native indexed-equality query profiler measured 2.20 ms for
10 matching rows; at 100k rows it measured 9.10 ms for 1,000 matching rows.
The boundary premium is real, but it is not the dominant cost of the current
100k indexed query: decode and predicate work account for more time than the
backend boundary after the M2–M5 pushdowns.

### Logical encryption

`dart run benchmark/m6_architecture.dart` seeded 10,000 rows and measured an
indexed equality query over 1,000 matching rows:

| Configuration | Best | Median |
|---|---:|---:|
| Native plain | 2.57 ms | **4.42 ms** |
| Native + Dart logical encryption | 113.5 ms | **121.6 ms** |

The logical wrapper adds approximately **27.5×** in this workload. The result
is expected: the wrapper encrypts values before every write and decrypts each
returned value through the Dart `RawSnapshot` adapter. Physical page encryption
is a separate Rust storage layer and is not replaced by this logical wrapper.

## Decisions

### 1. Retain the worker isolate as the default

The worker isolate remains mandatory for the existing native client. M6 does
not add an opt-in direct-FFI mode.

The ~32µs premium is accepted because the isolate provides:

- UI-thread offload for FFI and database work;
- one owner for the native worker and the single-writer invariant;
- deterministic shutdown/finalizer qualification seams;
- crash/reopen and hot-restart behavior already covered by the test suite; and
- a stable transport boundary shared by native and web worker dispatch.

A direct-FFI mode remains deferred. It may be reconsidered only after a
measured application workload demonstrates that the boundary, rather than
query decode or storage work, is the limiting factor. Any future mode must be
explicitly opt-in and preserve ownership, error, shutdown, and crash contracts.
The 1k `<1ms` indexed target remains deferred because the FRB/isolate floor
alone is approximately 57µs before storage and model work.

### 2. Superseded: remove logical encryption in M6.5

M6 originally retained `EncryptedRawBackend` because it also worked over the
in-memory backend and avoided an immediate pre-release API change. That
recommendation is superseded by ADR-0022: there are no released consumers,
and the measured **27.5×** overhead is not justified by preserving a second
cryptographic layer.

M6.5 will remove the Dart logical wrapper, custom crypto registry, and provider
abstractions. The supported product contract becomes one optional raw 32-byte
key for Rust physical encryption on native file databases. Public raw-key
rotation remains. The detailed implementation and qualification steps are in
ADR-0022.

## Consequences

- No worker-isolate or default execution-path change is introduced by M6.
- The worker-isolate overhead is documented as an intentional trade-off rather
  than treated as an accidental regression.
- The logical-encryption measurement is now the evidence for ADR-0022's
  pre-release removal decision; it is not a recommendation to retain that
  wrapper.
- M6.5 will change the unfinished pre-release encryption API before release;
  it does not require a released-consumer migration.

## Superseded / Superseded by

The worker-isolate decision remains accepted. The logical-encryption retention
portion is superseded by [ADR-0022](0022-m6-5-rust-only-encryption-simplification.md).

## Validation

- Boundary and architecture profilers ran successfully.
- Full package tests, tool tests, Rust tests, analysis, clippy/fmt, coverage,
  offline lint, security review, traceability, and API/binding gates passed for
  M6. M6.5 has its own implementation and release-gate checklist.
