---
status: accepted
date: 2026-08-10
deciders: gecko_db maintainers
---

# ADR-0022: M6.5 Rust-only physical encryption simplification

**Builds on:** ADR-0009 (physical page encryption and key management),
ADR-0021 (M6 measured architecture decisions)

## Context

The current pre-release tree has two encryption mechanisms:

1. logical value encryption in Dart (`EncryptedRawBackend`,
   `CryptoBackend`, and `Aes256GcmCryptoBackend`); and
2. physical page encryption below redb in Rust
   (`EncryptingStorageBackend`).

The logical wrapper encrypts and decrypts every logical value crossing the raw
backend boundary. It also wraps snapshots, prevents the native query engine
from seeing the ordinary native snapshot surface, and creates a separate
configuration, registry, provider, and test matrix. M6 measured an indexed
native equality workload at **4.4 ms median without logical encryption** versus
**121.6 ms with it** (approximately **27.5×** overhead).

There are no released consumers and therefore no compatibility burden for the
unfinished logical-encryption API. This is the correct point to remove the
split design rather than preserve it through a release.

## Decision

### 1. One encryption mechanism

gecko_db will provide one encryption mechanism: the existing Rust
AES-256-GCM physical page layer below redb. It encrypts and authenticates the
complete native database file, including rows, indexes, change metadata, redb
metadata, and page layout.

The database query engine remains unaware of encryption. The same Rust query
path is used with or without encryption:

```text
Dart API/query builder
  -> worker isolate / FRB
  -> Rust query engine
  -> Rust encrypted storage backend when a key is configured
  -> redb
```

Logical per-value encryption is removed. The Dart encryption implementation is
not ported to Rust; deleting that layer is the simplification and performance
improvement.

### 2. Raw-key, native-only configuration

The target pre-release configuration is:

- `encryptionKey == null`: native file encryption is off;
- `encryptionKey != null`: native physical encryption is on;
- the key is supplied as exactly 32 raw bytes for AES-256-GCM;
- no key provider, text encoding, algorithm name, registry, callback, or
  user-replaceable crypto backend exists;
- providing a key for an in-memory or Web database fails with a typed
  unsupported-operation error rather than silently ignoring the key.

The previous physical-key configuration is replaced by the simpler
`encryptionKey` name before the first release. This is a deliberate pre-release
API correction, not a compatibility migration.

Applications remain responsible for obtaining and protecting key material
(for example, from platform secure storage). The database accepts raw key
bytes; it does not define an extensible key-provider framework.

### 3. Retain public key rotation

`rotatePhysicalKey` remains public and continues to accept raw old/new 32-byte
keys. Rust retains atomic sibling-file rotation, generation handling, and
recovery to either the old or new key after interruption. Rotation is not
removed or moved into the logical-value layer.

The rotation API is retained because it is a storage lifecycle operation, not
an algorithm customization point, and its measured cost is paid only when an
application explicitly rotates a database key.

### 4. No compatibility migration for logical-encrypted databases

The product has not shipped. Existing development databases using the old
logical wrapper are disposable or can be recreated. M6.5 therefore does not
add a logical-encryption migration, dual-reader, compatibility envelope, or
format bridge.

Existing Rust physical-encryption files remain the compatibility target,
subject to the current physical format/version checks. If the physical page
format changes, that change requires its own format ADR and migration plan.

## M6.5 implementation plan

M6.5 is a staged cleanup and qualification milestone, not a new cryptographic
implementation.

1. **Lock the public contract.** Update the API decision and snapshot plan to
   use one optional raw `encryptionKey`; define the native-only rejection for
   Web and in-memory; retain `rotatePhysicalKey`; remove all custom-crypto and
   provider commitments.
2. **Remove Dart logical encryption.** Delete `EncryptedRawBackend`, the
   logical envelope format, `CryptoBackend`, `CryptoPage`,
   `Aes256GcmCryptoBackend`, and their registry/decryption branches.
3. **Simplify configuration.** Remove `cryptoBackendName`, logical/physical
   encryption layering, `KeyProvider`, key encodings, and provider resolution.
   Rename the retained physical key fields to the single raw-key contract and
   keep only the generation value required for rotation/reopen recovery.
4. **Simplify native open.** Validate the raw key before opening the file,
   pass it directly to Rust physical storage, reject key use on Web/in-memory,
   and preserve typed wrong-key, missing-key, corruption, and read-only errors.
5. **Preserve rotation.** Keep the public `rotatePhysicalKey` entry point,
   raw 32-byte validation, generation increment, closed-file requirement,
   atomic sibling swap, crash recovery, and no-key-material logging/storage
   guarantees.
6. **Delete obsolete public exports and tests.** Remove logical crypto,
   custom backend, provider, and wrapper exports; update the API snapshot and
   replace logical-encryption tests with native physical-encryption tests.
7. **Qualify the simplified security model.** Test encryption-off plaintext
   behavior, encryption-on raw-file secrecy, wrong keys, tampering, missing
   keys, reopen, compaction, snapshots, indexes, query pushdown, rotation,
   interrupted rotation, and native-only rejection on unsupported backends.
8. **Update examples and documentation.** Use the single raw-key option in
   the consumer fixture and all guides; remove custom-provider and logical
   encryption references; document that key storage is the application's
   responsibility and that encryption is opt-in.
9. **Measure before/after.** Replace the M6 logical-wrapper comparison with an
   M6.5 benchmark comparing plaintext native and Rust physical encryption for
   writes, indexed reads, scans, compaction, and rotation. Confirm that M4/M5
   query routes remain available in encrypted native databases.
10. **Release-gate the cleanup.** Run API/traceability checks, full Dart and
    Rust tests, coverage, security review, offline lint, artifact/binding
    checks, crash/reopen tests, and the native/Web/in-memory matrix before M7.

## Consequences

- The public encryption model becomes one boolean-like choice: no raw key or a
  raw 32-byte key.
- Native encrypted and unencrypted databases share one query implementation;
  M4/M5 optimizations do not need an encrypted-wrapper branch.
- Native encryption should be substantially faster than the current logical
  wrapper because Dart no longer encrypts/decrypts every logical row. Physical
  page encryption still has an intentional page-level cost when enabled.
- In-memory and Web databases have no encryption mode in M6.5. This is a clear
  limitation rather than a second encryption implementation.
- The current pre-release public API changes materially, but no released data
  migration is required.
- Custom cryptography is intentionally not an extension point. A future
  alternative algorithm would require a new ADR, format version, and security
  review.
- M7 must not begin deleting unrelated Dart query/model behavior until M6.5
  has removed the obsolete encryption branches and stabilized the simplified
  API contract.

## Supersedes / Superseded by

This ADR supersedes the logical-encryption retention decision in ADR-0021 and
supersedes the logical-encryption portions of ADR-0009 for the pre-release
product contract. ADR-0009 remains the historical and technical record of the
Rust physical page format and key-rotation implementation.
