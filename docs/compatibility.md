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

| Platform | Native artifact | Status |
|---|---|---|
| Windows (x64) | `gecko_db_rust.dll` | ✅ built and tested locally |
| macOS | `libgecko_db_rust.dylib` | ⬜ matrix pending (WS 7) |
| Linux | `libgecko_db_rust.so` | ⬜ matrix pending (WS 7) |
| Android | ABI plugin artifacts | ⬜ pending (WS 7) |
| iOS | framework artifacts | ⬜ pending (WS 7) |
| Web | OPFS worker | ⬜ pending (Phase 1) |

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
