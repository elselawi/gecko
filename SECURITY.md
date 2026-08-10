# Security

## Reporting a vulnerability

Please **do not open a public GitHub issue** for security vulnerabilities.
Report them privately to the maintainers so they can be fixed before
disclosure.

- **Email / private channel**: reach the maintainers privately with the
  subject prefix `[gecko_db-security]`.
- Include: the affected version(s), a minimal reproduction, the impact, and
  (if known) a suggested fix. Avoid including production keys/secrets.

## Handling

1. Maintainers triage within **5 business days** and reply with a timeline.
2. A fix ships in a PATCH/MINOR release; the advisory is recorded in
   `CHANGELOG.md` without exposing exploit details.
3. Responsible disclosure is preferred: public announcements follow the fix
   release, unless the issue is already public.

## Security posture (what gecko_db does and does not claim)

**Claimed and tested:**
- Data at rest is protected by authenticated encryption (Rust physical
  AES-256-GCM page encryption, ADR-0009) when a raw 32-byte native key is
  configured; raw-file scans find no plaintext. Encryption is off by default
  and is native-only in the M6.5 target contract.
- Wrong keys, missing keys, and corrupted/tampered pages fail with typed
  errors before any data is returned.
- Keys are never written to disk by the engine, never logged, and never
  included in error envelopes.
- Key rotation is atomic with crash recovery to either the old or the new key.
- Tenant separation: files are sealed under their tenant key; cross-key open
  fails authentication.
- The application owns key storage; gecko_db does not accept custom crypto
  implementations or key-provider plugins. Public raw-key rotation remains
  atomic and crash-recoverable.

**Explicitly NOT claimed:**
- **Physical secure deletion** — logical deletion is supported; physical media
  overwrite/TRIM is not implemented and must not be assumed (see ADR-0009).
- Protection against a hostile OS or process with full access to memory/disk
  (keys in memory can be read by such an attacker).
- Side-channel resistance against sophisticated local hardware attackers.

## Dependencies

Dependencies are pinned and audited as part of the release pipeline
(`rust/Cargo.lock`, the pub lockfile). The native artifact provenance is
documented in `tool/artifact_manifest.dart`.
