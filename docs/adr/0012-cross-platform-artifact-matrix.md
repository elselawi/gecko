---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0012: Cross-Platform Artifact Matrix and Bundled Distribution

## Context

Workstream 7 requires shipping native artifacts consumers can install "without
Rust, FFI, or build steps" across Windows, macOS, Linux, Android, iOS, and
Web. Before this ADR, only the Windows x64 DLL existed, built ad hoc; there was
no reproducible cross-target build, no per-target checksum manifest, no
bundled-artifact path for the resolver, and no release matrix CI. The plan
also requires that a release be blocked if any target is skipped without being
explicitly marked unsupported.

## Decision

1. **Target registry + cross-target build tool.** `tool/build_artifacts.dart`
   owns the single source of truth for release targets (name, Rust triple,
   artifact file name, target/arch keys, and NDK clang for Android). It can
   `list`, `build <target>`, `all` (host-buildable targets), `bundle`, and
   `verify` (SHA-256 against a manifest). Android cross-builds set
   `CARGO_TARGET_*_LINKER` plus `CC/CXX/AR/RANLIB` to the NDK llvm tools.
   wasm builds enable `getrandom`'s `js` feature (needed on
   `wasm32-unknown-unknown`).
2. **Manifests + checksums.** Every build writes a manifest with the artifact
   name, target, architecture, triple, version, SHA-256, size, and build
   provenance (commit, workflow, rust toolchain, FRB version, host platform,
   source-date-epoch). `verify` re-hashes the artifact against the manifest.
3. **Bundled distribution.** `bundle` copies each built artifact plus its
   manifest into `packages/gecko_db/lib/native/<target>/<arch>/`. The
   resolver's `bundledArtifactPath()` (resolved via `package:` URIs, so it
   must live under `lib/`) is used as the **no-build-steps fallback** in the
   worker open path when the consumer does not supply a `nativeLibraryPath`.
   Explicit paths and the pinned resolver still win when provided.
4. **CI release matrix.** `.github/workflows/release-matrix.yml` builds every
   target on its native runner, verifies bindings, produces manifests, runs
   the consumer fixture and the shared conformance suite, and uploads
   artifacts. iOS device builds and the FRB web glue (wasm-bindgen) + OPFS
   worker are **explicitly marked CI-pending** in `docs/compatibility.md`
   rather than silently skipped, per the release gate.

## Consequences

- Windows (x64) and all four Android ABIs are built, checksum-verified, and
  bundled in-repo today; the resolver loads them with zero configuration.
- Linux/macOS artifacts build from the same tool on their native CI runners;
  the tool refuses to build a non-host target locally instead of producing a
  wrong artifact.
- Web ships the raw wasm artifact now; FRB web glue + OPFS remain explicitly
  pending with a documented in-memory fallback.
- Bundling binaries under `lib/` grows the package; it is the honest price of
  the "install and use, no monkey business" promise and is checksum-verified
  at load time.
- The compatibility table is the release gate's source of truth: any target
  not built must be explicitly marked.
