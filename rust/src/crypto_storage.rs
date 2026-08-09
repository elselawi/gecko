//! Length-preserving physical-page encryption below redb (Workstream 4).
//!
//! redb's `StorageBackend` seam lets us substitute our own file layer. Each
//! *logical* page of `LOGICAL_PAGE_SIZE` bytes is stored as one *physical*
//! page of `PHYSICAL_PAGE_SIZE` bytes:
//!
//! ```text
//! [ key generation: 1 ] [ AES-256-GCM ciphertext || tag: P+16 ] [ nonce: 12 ]
//! ```
//!
//! The file layout stays page-aligned and length is preserved up to a fixed
//! per-page overhead. Every write draws a fresh random 12-byte nonce, so nonce
//! reuse cannot happen across writes, restarts, or tenants. A never-written
//! page (all zeros, e.g. after `set_len`) reads back as zeros. Wrong keys,
//! corruption, or a tampered tag fail authentication with a typed storage
//! error before any data is returned.
//!
//! The key-generation byte is not itself authenticated: a tampered generation
//! byte selects the wrong key and the GCM tag then fails, so integrity is
//! still enforced end-to-end.
//!
//! Key rotation (`rekey_file`) never mutates the live file in place: it builds
//! a complete encrypted sibling and atomically swaps it in, with a plaintext
//! marker that lets an interrupted rotation be recovered to *either* the old
//! or the new key.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use redb::StorageBackend;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::Mutex;

/// redb's logical page size (matches the worker's redb builder page size).
pub const LOGICAL_PAGE_SIZE: usize = 4096;
/// Key-generation marker (1) + GCM tag (16) + random nonce (12).
pub const PAGE_OVERHEAD: usize = 1 + 16 + 12;
/// Physical page size on disk.
pub const PHYSICAL_PAGE_SIZE: usize = LOGICAL_PAGE_SIZE + PAGE_OVERHEAD;

/// First key generation used when a file is first encrypted.
pub const INITIAL_KEY_GEN: u8 = 1;

const ROTATION_MARKER_PREFIX: &str = "gecko_rekey_v1";
const ROTATION_TMP_FOOTER: &[u8] = b"gecko_rekey_done\n";
// Suffixes are appended to the existing file extension, e.g. for
// `database.redb` the marker is `database.redb.rotating` and the sibling is
// `database.redb.rekey.tmp`.
const ROTATION_MARKER_SUFFIX: &str = ".rotating";
const ROTATION_TMP_SUFFIX: &str = ".rekey.tmp";

fn encrypt_with(cipher: &Aes256Gcm, key_gen: u8, plaintext: &[u8]) -> io::Result<Vec<u8>> {
    debug_assert_eq!(plaintext.len(), LOGICAL_PAGE_SIZE);
    let mut nonce_bytes = [0u8; 12];
    getrandom::getrandom(&mut nonce_bytes)
        .map_err(|e| io::Error::other(format!("entropy source failed: {e}")))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let aad = [key_gen];
    let ciphertext = cipher
        .encrypt(
            nonce,
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| io::Error::other("AES-GCM encryption failed"))?;
    let mut out = Vec::with_capacity(PHYSICAL_PAGE_SIZE);
    out.push(key_gen);
    out.extend_from_slice(&ciphertext); // ct || tag
    out.extend_from_slice(&nonce_bytes);
    Ok(out)
}

fn decrypt_with(cipher: &Aes256Gcm, key_gen: u8, physical: &[u8]) -> io::Result<Vec<u8>> {
    debug_assert_eq!(physical.len(), PHYSICAL_PAGE_SIZE);
    // A never-written page is all zeros (set_len initializes to zero).
    if physical.iter().all(|b| *b == 0) {
        return Ok(vec![0u8; LOGICAL_PAGE_SIZE]);
    }
    if physical[0] != key_gen {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "page uses a different key generation (wrong key or mid-rotation)",
        ));
    }
    let nonce = Nonce::from_slice(&physical[physical.len() - 12..]);
    let ct_and_tag = &physical[1..physical.len() - 12];
    let aad = [key_gen];
    cipher
        .decrypt(
            nonce,
            Payload {
                msg: ct_and_tag,
                aad: &aad,
            },
        )
        .map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "page authentication failed (wrong key or corrupted page)",
            )
        })
}

/// An authenticated, length-preserving `StorageBackend` that encrypts every
/// redb page with AES-256-GCM.
pub struct EncryptingStorageBackend {
    inner: Box<dyn StorageBackend>,
    cipher: Mutex<Aes256Gcm>,
    key_gen: u8,
}

impl std::fmt::Debug for EncryptingStorageBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EncryptingStorageBackend")
            .field("key_gen", &self.key_gen)
            .finish()
    }
}

impl EncryptingStorageBackend {
    /// Wraps [inner] with AES-256-GCM under [key] (32 bytes) for key
    /// generation [key_gen] (>= 1).
    pub fn new(inner: Box<dyn StorageBackend>, key: [u8; 32], key_gen: u8) -> Self {
        debug_assert!(key_gen >= 1);
        let cipher = Aes256Gcm::new_from_slice(&key).expect("32-byte key");
        Self {
            inner,
            cipher: Mutex::new(cipher),
            key_gen,
        }
    }

    fn encrypt_page(&self, plaintext: &[u8]) -> io::Result<Vec<u8>> {
        let cipher = self.cipher.lock().unwrap();
        encrypt_with(&cipher, self.key_gen, plaintext)
    }

    fn decrypt_page(&self, physical: &[u8]) -> io::Result<Vec<u8>> {
        let cipher = self.cipher.lock().unwrap();
        decrypt_with(&cipher, self.key_gen, physical)
    }

    fn read_physical_page(&self, page: u64) -> io::Result<Vec<u8>> {
        // Never read beyond the underlying file length: redb's FileBackend
        // loops on zero-length reads at EOF on Windows, and a not-yet-written
        // page (or a page past a freshly set_len'd tail) must read as zeros.
        let start = page * PHYSICAL_PAGE_SIZE as u64;
        let file_len = self.inner.len()?;
        if start >= file_len {
            return Ok(vec![0u8; PHYSICAL_PAGE_SIZE]);
        }
        let available = (file_len - start).min(PHYSICAL_PAGE_SIZE as u64) as usize;
        let mut buf = vec![0u8; PHYSICAL_PAGE_SIZE];
        if available > 0 {
            let mut read_buf = vec![0u8; available];
            self.inner.read(start, &mut read_buf)?;
            buf[..available].copy_from_slice(&read_buf);
        }
        Ok(buf)
    }

    fn write_physical_page(&self, page: u64, physical: &[u8]) -> io::Result<()> {
        self.inner.write(page * PHYSICAL_PAGE_SIZE as u64, physical)
    }
}

/// Maps a logical length to the physical file length (rounds up to a page).
fn physical_len(logical: u64) -> u64 {
    let pages = logical.div_ceil(LOGICAL_PAGE_SIZE as u64);
    pages * PHYSICAL_PAGE_SIZE as u64
}

impl StorageBackend for EncryptingStorageBackend {
    fn len(&self) -> io::Result<u64> {
        let phys = self.inner.len()?;
        Ok(phys / PHYSICAL_PAGE_SIZE as u64 * LOGICAL_PAGE_SIZE as u64)
    }

    fn read(&self, offset: u64, out: &mut [u8]) -> io::Result<()> {
        if out.is_empty() {
            return Ok(());
        }
        let page_size = LOGICAL_PAGE_SIZE as u64;
        let start = offset;
        let end = offset + out.len() as u64;
        let first_page = start / page_size;
        let last_page = (end - 1) / page_size;
        let mut copied = 0usize;
        for page in first_page..=last_page {
            let physical = self.read_physical_page(page)?;
            let plain = self.decrypt_page(&physical)?;
            let page_start = page * page_size;
            let in_seg_start = start.saturating_sub(page_start) as usize;
            let in_seg_end = (if end > page_start + page_size {
                page_size
            } else {
                end - page_start
            }) as usize;
            let seg = &plain[in_seg_start..in_seg_end];
            out[copied..copied + seg.len()].copy_from_slice(seg);
            copied += seg.len();
        }
        debug_assert_eq!(copied, out.len());
        Ok(())
    }

    fn write(&self, offset: u64, data: &[u8]) -> io::Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        let page_size = LOGICAL_PAGE_SIZE as u64;
        let start = offset;
        let end = offset + data.len() as u64;
        let first_page = start / page_size;
        let last_page = (end - 1) / page_size;
        let mut data_offset = 0usize;
        for page in first_page..=last_page {
            let page_start = page * page_size;
            let in_seg_start = start.saturating_sub(page_start) as usize;
            let in_seg_end = (if end > page_start + page_size {
                page_size
            } else {
                end - page_start
            }) as usize;
            // Read-modify-write unless the write covers the whole page.
            let mut plain = if in_seg_start == 0 && in_seg_end == page_size as usize {
                vec![0u8; page_size as usize]
            } else {
                let physical = self.read_physical_page(page)?;
                self.decrypt_page(&physical)?
            };
            plain[in_seg_start..in_seg_end]
                .copy_from_slice(&data[data_offset..data_offset + (in_seg_end - in_seg_start)]);
            data_offset += in_seg_end - in_seg_start;
            let physical = self.encrypt_page(&plain)?;
            self.write_physical_page(page, &physical)?;
        }
        debug_assert_eq!(data_offset, data.len());
        Ok(())
    }

    fn set_len(&self, len: u64) -> io::Result<()> {
        self.inner.set_len(physical_len(len))
    }

    fn sync_data(&self) -> io::Result<()> {
        self.inner.sync_data()
    }

    fn close(&self) -> io::Result<()> {
        self.inner.close()
    }
}

/// Outcome of recovering an interrupted rotation.
#[derive(Debug, PartialEq, Eq)]
pub enum RotationRecovery {
    /// No marker found; nothing to do.
    None,
    /// Rotation rolled forward to the new key (the sibling was complete).
    RolledForwardNewKey,
    /// Rotation rolled back to the old key (the sibling was incomplete/absent).
    RolledBackOldKey,
}

/// Returns the rotation marker path for [path].
fn rotation_marker_path(path: &Path) -> std::path::PathBuf {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    path.with_extension(format!("{ext}{ROTATION_MARKER_SUFFIX}"))
}

/// Returns the rekey sibling path for [path].
fn rotation_tmp_path(path: &Path) -> std::path::PathBuf {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    path.with_extension(format!("{ext}{ROTATION_TMP_SUFFIX}"))
}

/// Reads the rotation marker, if any: `(old_gen, new_gen)`.
fn read_rotation_marker(path: &Path) -> io::Result<Option<(u8, u8)>> {
    let marker_path = rotation_marker_path(path);
    if !marker_path.exists() {
        return Ok(None);
    }
    let mut content = String::new();
    File::open(&marker_path)?.read_to_string(&mut content)?;
    let mut lines = content.lines();
    let prefix = lines.next().unwrap_or_default();
    if prefix != ROTATION_MARKER_PREFIX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unrecognized rotation marker",
        ));
    }
    let old_gen: u8 = lines
        .next()
        .and_then(|l| l.trim().parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "malformed rotation marker"))?;
    let new_gen: u8 = lines
        .next()
        .and_then(|l| l.trim().parse().ok())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "malformed rotation marker"))?;
    Ok(Some((old_gen, new_gen)))
}

/// Checks whether [path] is a complete rekey sibling (has the completion
/// footer appended after the last physical page).
fn rekey_sibling_complete(path: &Path) -> bool {
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    let Ok(len) = file.metadata().map(|m| m.len()) else {
        return false;
    };
    if len < ROTATION_TMP_FOOTER.len() as u64 {
        return false;
    }
    let mut buf = vec![0u8; ROTATION_TMP_FOOTER.len()];
    if file
        .seek(SeekFrom::Start(len - ROTATION_TMP_FOOTER.len() as u64))
        .is_err()
        || file.read_exact(&mut buf).is_err()
    {
        return false;
    }
    buf == ROTATION_TMP_FOOTER
}

/// Truncates a freshly swapped-in file to the page-aligned length (removing
/// the rekey completion footer appended during rotation).
fn truncate_to_page_aligned(path: &Path) -> io::Result<()> {
    let len = File::open(path)?.metadata()?.len();
    let aligned = len / PHYSICAL_PAGE_SIZE as u64 * PHYSICAL_PAGE_SIZE as u64;
    if len != aligned {
        OpenOptions::new()
            .write(true)
            .open(path)?
            .set_len(aligned)?;
    }
    Ok(())
}

/// Recovers an interrupted rotation. When a marker exists and the caller
/// provides the *new* key generation, a complete sibling is rolled forward;
/// otherwise the rotation rolls back to the old key. This yields recovery to
/// either the old or the new key, depending on which the caller holds.
pub fn recover_rotation(path: &Path, caller_key_gen: u8) -> io::Result<RotationRecovery> {
    let Some((_old_gen, new_gen)) = read_rotation_marker(path)? else {
        return Ok(RotationRecovery::None);
    };
    let marker_path = rotation_marker_path(path);
    let tmp_path = rotation_tmp_path(path);
    let sibling_complete = rekey_sibling_complete(&tmp_path);
    if caller_key_gen == new_gen && sibling_complete {
        // The caller holds the new key and the sibling is complete: roll forward.
        std::fs::rename(&tmp_path, path).map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("could not swap rekeyed file into place: {error}"),
            )
        })?;
        std::fs::remove_file(&marker_path).ok();
        truncate_to_page_aligned(path)?;
        Ok(RotationRecovery::RolledForwardNewKey)
    } else {
        // Roll back: discard the incomplete/undesired sibling and the marker.
        std::fs::remove_file(&tmp_path).ok();
        std::fs::remove_file(&marker_path).ok();
        Ok(RotationRecovery::RolledBackOldKey)
    }
}

/// Atomically re-encrypts a closed encrypted database file from [old_key] to
/// [new_key]. The new key generation is `old_gen + 1`.
///
/// Guarantees:
/// - The live file is never modified in place; a complete encrypted sibling is
///   built first, then swapped in.
/// - A crash at any point leaves the main file either entirely old-key or
///   entirely new-key (never mixed), and `recover_rotation` resolves the
///   marker on the next open.
pub fn rekey_file(
    path: &Path,
    old_key: [u8; 32],
    new_key: [u8; 32],
    old_gen: u8,
) -> io::Result<()> {
    let new_gen = old_gen.wrapping_add(1);
    let old_cipher = Aes256Gcm::new_from_slice(&old_key).expect("32-byte key");
    let new_cipher = Aes256Gcm::new_from_slice(&new_key).expect("32-byte key");

    let mut source = File::open(path)?;
    let len = source.metadata()?.len();
    if len % PHYSICAL_PAGE_SIZE as u64 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "file length is not a multiple of the physical page size",
        ));
    }
    let pages = len / PHYSICAL_PAGE_SIZE as u64;

    let tmp_path = rotation_tmp_path(path);
    let mut tmp = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp_path)?;
    tmp.set_len(pages * PHYSICAL_PAGE_SIZE as u64)?;

    let mut physical = vec![0u8; PHYSICAL_PAGE_SIZE];
    let mut plaintext = vec![0u8; LOGICAL_PAGE_SIZE];
    for page in 0..pages {
        source.seek(SeekFrom::Start(page * PHYSICAL_PAGE_SIZE as u64))?;
        source.read_exact(&mut physical)?;
        // Never-written pages stay zeros in the sibling.
        if physical.iter().all(|b| *b == 0) {
            continue;
        }
        plaintext = decrypt_with(&old_cipher, old_gen, &physical)?;
        let re_encrypted = encrypt_with(&new_cipher, new_gen, &plaintext)?;
        tmp.seek(SeekFrom::Start(page * PHYSICAL_PAGE_SIZE as u64))?;
        tmp.write_all(&re_encrypted)?;
    }
    // Completion footer proves the sibling is fully written before the swap.
    tmp.seek(SeekFrom::End(0))?;
    tmp.write_all(ROTATION_TMP_FOOTER)?;
    tmp.sync_all()?;
    drop(tmp);

    let marker_path = rotation_marker_path(path);
    let mut marker = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&marker_path)?;
    writeln!(marker, "{ROTATION_MARKER_PREFIX}\n{old_gen}\n{new_gen}")?;
    marker.sync_all()?;
    drop(marker);

    // Swap the sibling over the live file, then clear the marker.
    std::fs::rename(&tmp_path, path).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("could not swap rekeyed file into place: {error}"),
        )
    })?;
    std::fs::remove_file(&marker_path).ok();
    truncate_to_page_aligned(path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use redb::backends::InMemoryBackend;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn key(seed: u8) -> [u8; 32] {
        [seed; 32]
    }

    fn plaintext(len: usize, seed: u8) -> Vec<u8> {
        (0..len).map(|i| (i as u8).wrapping_mul(seed)).collect()
    }

    fn temp_path(label: &str) -> std::path::PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("gecko-crypto-{label}-{nonce}.redb"))
    }

    #[test]
    fn page_round_trips_and_is_length_preserving() {
        let backend = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 1);
        let plain = plaintext(LOGICAL_PAGE_SIZE, 3);
        let physical = backend.encrypt_page(&plain).unwrap();
        assert_eq!(physical.len(), PHYSICAL_PAGE_SIZE);
        let decrypted = backend.decrypt_page(&physical).unwrap();
        assert_eq!(decrypted, plain);
    }

    #[test]
    fn tampering_with_the_payload_fails_authentication() {
        let backend = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 1);
        let physical = backend
            .encrypt_page(&plaintext(LOGICAL_PAGE_SIZE, 3))
            .unwrap();
        let mut tampered = physical.clone();
        tampered[1 + LOGICAL_PAGE_SIZE / 2] ^= 0x01;
        assert!(backend.decrypt_page(&tampered).is_err());
    }

    #[test]
    fn wrong_key_fails_authentication() {
        let backend = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 1);
        let physical = backend
            .encrypt_page(&plaintext(LOGICAL_PAGE_SIZE, 3))
            .unwrap();
        let wrong = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(2), 1);
        assert!(wrong.decrypt_page(&physical).is_err());
    }

    #[test]
    fn wrong_key_generation_is_detected() {
        let backend = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 2);
        let physical = backend
            .encrypt_page(&plaintext(LOGICAL_PAGE_SIZE, 3))
            .unwrap();
        let other = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 1);
        assert!(other.decrypt_page(&physical).is_err());
    }

    #[test]
    fn never_written_zero_page_reads_as_zeros() {
        let backend = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 1);
        let zeros = vec![0u8; PHYSICAL_PAGE_SIZE];
        let plain = backend.decrypt_page(&zeros).unwrap();
        assert!(plain.iter().all(|b| *b == 0));
    }

    #[test]
    fn nonces_are_unique_across_writes() {
        let backend = EncryptingStorageBackend::new(Box::new(InMemoryBackend::new()), key(1), 1);
        let mut seen = std::collections::HashSet::new();
        for seed in 0..50u8 {
            let physical = backend
                .encrypt_page(&plaintext(LOGICAL_PAGE_SIZE, seed))
                .unwrap();
            let nonce = &physical[physical.len() - 12..];
            assert!(seen.insert(nonce.to_vec()), "nonce reused");
        }
    }

    #[test]
    fn storage_read_write_across_page_and_partial_boundaries() {
        let inner = InMemoryBackend::new();
        inner.set_len((PHYSICAL_PAGE_SIZE * 4) as u64).unwrap();
        let backend = EncryptingStorageBackend::new(Box::new(inner), key(1), 1);
        let payload = plaintext(100, 7);
        backend
            .write(LOGICAL_PAGE_SIZE as u64 - 40, &payload)
            .unwrap();
        let mut out = vec![0u8; 100];
        backend
            .read(LOGICAL_PAGE_SIZE as u64 - 40, &mut out)
            .unwrap();
        assert_eq!(out, payload);
        let page = plaintext(LOGICAL_PAGE_SIZE, 9);
        backend.write(LOGICAL_PAGE_SIZE as u64, &page).unwrap();
        let mut read_back = vec![0u8; LOGICAL_PAGE_SIZE];
        backend
            .read(LOGICAL_PAGE_SIZE as u64, &mut read_back)
            .unwrap();
        assert_eq!(read_back, page);
    }

    #[test]
    fn rekey_file_round_trips_and_rejects_old_key_after() {
        let path = temp_path("rekey");
        // Build a small encrypted file via the backend over a real file.
        {
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path)
                .unwrap();
            let backend = EncryptingStorageBackend::new(
                Box::new(redb::backends::FileBackend::new(file).unwrap()),
                key(1),
                1,
            );
            backend.set_len(LOGICAL_PAGE_SIZE as u64 * 3).unwrap();
            let payload = plaintext(LOGICAL_PAGE_SIZE * 2, 11);
            backend.write(0, &payload).unwrap();
            backend.sync_data().unwrap();
        }
        // Rotation must be on a closed file.
        rekey_file(&path, key(1), key(2), 1).unwrap();
        assert!(!rotation_marker_path(&path).exists());
        assert!(!rotation_tmp_path(&path).exists());

        // Old key no longer authenticates.
        let old_cipher = Aes256Gcm::new_from_slice(&key(1)).unwrap();
        let mut first_page = vec![0u8; PHYSICAL_PAGE_SIZE];
        let mut f = File::open(&path).unwrap();
        f.read_exact(&mut first_page).unwrap();
        assert!(decrypt_with(&old_cipher, 1, &first_page).is_err());

        // New key reads the data back.
        let new_cipher = Aes256Gcm::new_from_slice(&key(2)).unwrap();
        let plain = decrypt_with(&new_cipher, 2, &first_page).unwrap();
        assert_eq!(&plain[..64], &plaintext(LOGICAL_PAGE_SIZE * 2, 11)[..64]);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn recover_rotation_rolls_back_with_old_key_and_forwards_with_new_key() {
        let path = temp_path("recover");
        {
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path)
                .unwrap();
            let backend = EncryptingStorageBackend::new(
                Box::new(redb::backends::FileBackend::new(file).unwrap()),
                key(1),
                1,
            );
            backend.set_len(LOGICAL_PAGE_SIZE as u64 * 2).unwrap();
            let payload = plaintext(LOGICAL_PAGE_SIZE, 5);
            backend.write(0, &payload).unwrap();
            backend.sync_data().unwrap();
        }
        // Write a marker + a complete sibling, then crash "before the swap".
        let tmp_path = rotation_tmp_path(&path);
        let marker_path = rotation_marker_path(&path);
        {
            let mut source = File::open(&path).unwrap();
            let mut tmp = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(true)
                .open(&tmp_path)
                .unwrap();
            let mut buf = vec![0u8; PHYSICAL_PAGE_SIZE];
            for _page in 0..2u64 {
                source.read_exact(&mut buf).unwrap();
                tmp.write_all(&buf).unwrap();
            }
            tmp.write_all(ROTATION_TMP_FOOTER).unwrap();
            let mut marker = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&marker_path)
                .unwrap();
            writeln!(marker, "{ROTATION_MARKER_PREFIX}\n1\n2").unwrap();
        }
        // Recover with the NEW key -> roll forward (tmp replaces main).
        assert_eq!(
            recover_rotation(&path, 2).unwrap(),
            RotationRecovery::RolledForwardNewKey
        );
        assert!(!tmp_path.exists());
        assert!(!marker_path.exists());
        // Main file still decrypts with the old key (it was the old file).
        let old_cipher = Aes256Gcm::new_from_slice(&key(1)).unwrap();
        let mut first = vec![0u8; PHYSICAL_PAGE_SIZE];
        let mut f = File::open(&path).unwrap();
        f.read_exact(&mut first).unwrap();
        assert_eq!(
            decrypt_with(&old_cipher, 1, &first).unwrap(),
            plaintext(LOGICAL_PAGE_SIZE, 5)
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn recover_rotation_rolls_back_when_sibling_incomplete() {
        let path = temp_path("recover-incomplete");
        {
            let file = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .open(&path)
                .unwrap();
            let backend = EncryptingStorageBackend::new(
                Box::new(redb::backends::FileBackend::new(file).unwrap()),
                key(1),
                1,
            );
            backend.set_len(LOGICAL_PAGE_SIZE as u64 * 2).unwrap();
            backend.write(0, &plaintext(LOGICAL_PAGE_SIZE, 5)).unwrap();
            backend.sync_data().unwrap();
        }
        let tmp_path = rotation_tmp_path(&path);
        let marker_path = rotation_marker_path(&path);
        // Incomplete sibling (no footer) + marker.
        {
            let mut tmp = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(true)
                .open(&tmp_path)
                .unwrap();
            tmp.write_all(&[0u8; 10]).unwrap();
            let mut marker = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&marker_path)
                .unwrap();
            writeln!(marker, "{ROTATION_MARKER_PREFIX}\n1\n2").unwrap();
        }
        assert_eq!(
            recover_rotation(&path, 2).unwrap(),
            RotationRecovery::RolledBackOldKey
        );
        assert!(!tmp_path.exists());
        assert!(!marker_path.exists());
        let _ = std::fs::remove_file(path);
    }
}
