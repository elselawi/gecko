# gecko_db compatibility matrix

Single source of truth for version compatibility (Workstream 6). The Dart
side enforces these through the compatibility handshake
(`lib/src/wire/compatibility.dart`) and the format header
(`lib/src/wire/format_header.dart`).

## Current matrix

| Component | Version | Where pinned |
|---|---|---|
| Package (Dart) | `0.0.1` | `pubspec.yaml` / `geckoPackageVersion` |
| Handshake contract | `1` | `geckoHandshakeVersion` |
| Wire format | `1` | `geckoWireVersion` (`format_header.dart`) |
| On-disk file format | `1` (redb 4.1.0) | `geckoFormatVersion` |
| Native build id | `0.0.1+rust` | `rust/src/api.rs` (`NATIVE_BUILD_ID`) |
| Dart SDK | `^3.10.8` | `pubspec.yaml` |
| Flutter | Dart 3.10-compatible Flutter | pubspec sdk constraint |
| flutter_rust_bridge | `2.12.0` | `pubspec.yaml` / `Cargo.toml` |
| redb (Rust) | `4.1.0` | `rust/Cargo.toml` |
| AES-256-GCM (physical encryption) | `aes-gcm 0.10` | `rust/Cargo.toml` |

## Supported platforms

| Platform | Architecture | Native artifact | Status |
|---|---|---|---|
| Windows | x64 | `gecko_db_rust.dll` | ✅ built + verified (bundled in `lib/native/windows/x64/`; CI job `release-matrix` windows-x64) |
| Linux | x64 | `libgecko_db_rust.so` | ⬜ CI job written (`release-matrix` linux-x64); needs a Linux runner to execute |
| macOS | x64 / arm64 | `libgecko_db_rust.dylib` | ⬜ CI jobs written (`release-matrix` macos); need macOS runners to execute |
| Android | arm64-v8a, armeabi-v7a, x86, x86_64 | `gecko_db_rust.so` | ✅ all 4 ABIs built + verified locally and bundled (`lib/native/android/*/`); CI job `release-matrix` android |
| iOS | device + simulator | FRB iOS plugin artifact | ⬜ **explicitly CI-pending** — requires the FRB iOS plugin scaffold (Xcode); marked unsupported until it lands |
| Web | wasm32 | `gecko_db_rust.js` + `gecko_db_rust_bg.wasm` | ✅ **FRB web glue + OPFS persistence implemented and live-validated** (ADR-0013): `Database.open(':memory:')` runs the redb engine on wasm on the main thread; file-backed databases persist via OPFS inside a Web Worker. Glue bundled in `lib/native/web/wasm32/`; reference worker pattern in `tool/web_smoke/opfs_worker.dart`. CI job: chromium + CDP smoke driver (see `tool/web_smoke/README.md`) |
| Pure Dart CLI/server | desktop | — | ✅ no artifact needed |

> **Release gate:** a release is blocked if any target is skipped without being
> explicitly marked above. iOS is explicitly marked CI-pending (not silently
> skipped). Web is implemented and validated; the CI job runs on GitHub
> runners once the release matrix executes.

## Compatibility rules

- **Forward reads**: a database written by an older supported version opens
  cleanly.
- **Backward reads**: a database stamped with a newer format/wire version than
  this build understands fails with a typed `upgradeRequired` /
  `checksumMismatch` error before any data is returned — never a silent misread.
- **Native handshake**: the worker's build id must match the package's pinned
  matrix, or the worker is rejected before use.
- **Encrypted files**: sealed under the tenant key; wrong key / corrupt page →
  typed authentication failure before data.

## Verification

- `tool/gen_golden_ops.dart` locks the wire-format bytes (regenerate only with
  an ADR).
- `tool/artifact_manifest.dart` documents the native artifact provenance
  (sha256, target, toolchain, FRB version).
- `tool/workstream0_contract_test.dart` guards the public API snapshot.
- `packages/gecko_db/test/phase10_migrations_test.dart` covers the
  `upgradeRequired` open-time gate.
