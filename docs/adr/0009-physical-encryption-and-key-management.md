---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0009: Physical Page Encryption and Key Management

## Context

Design Principle 0.5 promises encrypted data at rest, but before Workstream 4
the implementation only offered *logical* value encryption: values were
encrypted above the storage layer, while keys, value lengths, table structure,
the change log, and the redb B-tree layout itself remained plaintext in the
native file. A raw-file scan could still reveal structure and metadata, and a
user-supplied key could not protect the file from someone with read access to
disk.

Workstream 4 requires a *physical* layer: every byte written by the storage
engine should be authenticated-encrypted below redb, with length preservation,
typed failures on wrong/corrupt keys, atomic key rotation with crash recovery
to either key, tenant separation, nonce-uniqueness guarantees, and honest
documentation of secure deletion. The pre-release simplification in ADR-0022
removes the unfinished key-provider and logical-encryption layers.

## Decision

### 1. Physical page encryption below redb via the `StorageBackend` seam

redb 4.1.0 exposes a public `StorageBackend` trait
(`len/read/write/set_len/sync_data/close`) and `Builder::create_with_backend`,
so we substitute an `EncryptingStorageBackend` between redb and the file. Each
redb *logical* page of 4096 bytes (redb's fixed page size) is stored as one
*physical* page of 4125 bytes:

```text
[ key generation: 1 ] [ AES-256-GCM ciphertext || tag: 4112 ] [ random nonce: 12 ]
```

- **Authenticated encryption:** AES-256-GCM over the full page, tag appended,
  key-generation byte bound as AAD.
- **Length preservation:** page-aligned layout with a fixed 29-byte overhead;
  `set_len`/`len` translate logical ↔ physical.
- **Never-written pages:** an all-zero physical page reads back as zeros (redb
  reads beyond its written tail as zeros); zero pages are never authenticated.
- **Partial writes** (the redb header is smaller than a page) use
  read-modify-encrypt-write with a fresh nonce.
- **Reads never exceed the underlying file length** (on Windows redb's
  `FileBackend.read` loops on zero-length reads at EOF).
- redb's own page checksums run on the *decrypted* page, so physical
  encryption and redb's integrity layer compose.

### 2. Key rotation with recovery to either key

Rotation (`rekey_file`) never mutates the live file in place:

1. Build a fully encrypted sibling `<db>.redb.rekey.tmp` with the new key and a
   completion footer (`gecko_rekey_done\n`).
2. `fsync` the sibling, then write a plaintext marker `<db>.redb.rotating`
   containing the old and new key generations (no secrets).
3. Atomically swap the sibling over the live file; truncate the footer; remove
   the marker.

On the next open, `recover_rotation` resolves the marker:

- Opening with the **new** key generation (marker's new generation) and a
  *complete* sibling rolls forward (swap + cleanup) — recovery to the new key.
- Opening with the **old** key generation (or with an *incomplete* sibling)
  rolls back (discard sibling + marker) — recovery to the old key.

At every crash point the live file is entirely old-key or entirely new-key,
never mixed. Rotation therefore requires the database to be closed and is
exposed as `rotatePhysicalKey` (pure Rust path, no redb handle).

### 3. Raw-key fail-before-open contract (M6.5 target)

The pre-release product accepts exactly one raw 32-byte AES-256 key through
`DatabaseConfig.encryptionKey`. There is no public key-provider abstraction,
text encoding, crypto registry, or custom encryption implementation. The
application owns secure key storage and passes the already-resolved bytes to
gecko_db.

Keys are never logged or persisted by the engine and are validated *before*
the file is opened. A missing or invalid key fails with a typed error and no
file is created. No key means ordinary plaintext pages; a key is supported
only for the native file backend. Web and in-memory encryption are rejected
explicitly. The retained generation value is used only for physical rotation
recovery.

### 4. Tenant separation and nonce uniqueness

- **Nonces:** every write draws a fresh 12-byte random nonce
  (`getrandom`); uniqueness is verified across writes, restarts, pages,
  tenants, and rotations. Redb writes full pages, so every physical write is a
  fresh encryption.
- **Tenants:** files are sealed under their tenant's key; opening another
  tenant's file with a different key fails GCM authentication before any data
  is returned.

### 5. Honest scope

- Secure deletion is **not** claimed: logical deletion is supported, but
  physical media overwrite/TRIM is out of scope until a compaction workstream
  (WS 5) can prove page-level recycling. This ADR's documentation states that
  explicitly.
- Encrypted files are read-write only for now (redb has no
  `open_read_only_with_backend`); read-only encrypted open is a tracked
  follow-up.
- Streaming encrypted migration/compaction and the `__gecko_crypto_meta`
  overflow table are deferred to Workstream 5, which owns the compaction
  state machine; the page layout leaves the metadata slot (key generation byte)
  so meta can be extended without a format bump.

## Consequences

- A raw-file scan of an encrypted database reveals no sentinel plaintext, no
  value structure, and no key material (validated by raw-file scan tests).
- Wrong keys, missing keys, corrupted pages, and tampered tags fail with typed
  errors before any data is returned.
- The physical layer is the sole supported encryption mechanism in the
  pre-release product; logical per-value encryption is removed by ADR-0022.
- Native query execution is unchanged when encryption is enabled because Rust
  decrypts pages below redb before query/index evaluation.
- The 29-byte-per-page overhead (~0.7%) and per-page AES-GCM cost trade
  security for modest space/time; redb's checksum layer still applies on
  decrypted pages.
- Key rotation is atomic with recovery to either key, at the cost of requiring
  the database to be closed during rotation and a one-file-size burst of I/O
  (the sibling).
- The key-generation byte is not itself authenticated; a tampered generation
  selects the wrong key and the GCM tag then fails, preserving end-to-end
  integrity.
- `DatabaseConfig`, the public exports, and the FRB API grow
  (`openEncrypted`, `rekeyEncryptedFile`); these are ADR-gated contract
  changes captured in `tool/api_snapshot.txt`.
