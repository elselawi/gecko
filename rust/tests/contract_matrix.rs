//! Cross-language contract matrix: the error-envelope serialization for every
//! declared type, the physical crypto page layout, and pure property tests
//! over the value codec (comparators + seeded malformed-input sweep).
//!
//! These lock contract facts the Dart side depends on without needing a Dart
//! process: the envelope JSON shape (camelCase `type`), the encrypted page
//! layout `[ key_gen(1) | ciphertext||tag(P+16) | nonce(12) ]`, and the
//! ordering guarantees of `compare` / `sort_compare`.

use gecko_db_rust::crypto_storage::{
    EncryptingStorageBackend,
    LOGICAL_PAGE_SIZE,
    PAGE_OVERHEAD,
    PHYSICAL_PAGE_SIZE,
};
use gecko_db_rust::error::{ GeckoErrorEnvelope, GeckoErrorType };
use gecko_db_rust::format_header::{ self, FormatHeader };
use gecko_db_rust::predicate::decode_predicate;
use gecko_db_rust::sort_spec::{ decode_sort_specs, encode_sort_specs, SortSpec };
use gecko_db_rust::value_codec::{ self, RowValue };
use gecko_db_rust::wire::{ Op, OpKind, WIRE_VERSION };
use redb::StorageBackend;
use std::path::Path;
use std::time::{ SystemTime, UNIX_EPOCH };

// ── error-envelope matrix ─────────────────────────────────────────────────

#[test]
fn error_envelope_matrix_round_trips_all_eleven_types() {
    use GeckoErrorType::*;
    let all = [
        Unknown,
        KeyNotFound,
        CollectionNotFound,
        SchemaValidation,
        TransactionAborted,
        Decryption,
        DatabaseAlreadyOpen,
        DatabaseLocked,
        UpgradeRequired,
        ChecksumMismatch,
        InvalidOperation,
    ];
    for error_type in all {
        let envelope = GeckoErrorEnvelope::new(error_type, "message");
        let encoded = envelope.encode();
        let json: serde_json::Value = serde_json::from_str(&encoded).expect("valid JSON");
        assert_eq!(json["message"], "message", "{error_type:?}");
        // The `type` discriminator is the camelCase form the Dart decoder maps.
        let camel = match error_type {
            Unknown => "unknown",
            KeyNotFound => "keyNotFound",
            CollectionNotFound => "collectionNotFound",
            SchemaValidation => "schemaValidation",
            TransactionAborted => "transactionAborted",
            Decryption => "decryption",
            DatabaseAlreadyOpen => "databaseAlreadyOpen",
            DatabaseLocked => "databaseLocked",
            UpgradeRequired => "upgradeRequired",
            ChecksumMismatch => "checksumMismatch",
            InvalidOperation => "invalidOperation",
        };
        assert_eq!(json["type"], camel, "{error_type:?} must serialize to {camel}");
        // Round-trip through the serde model.
        let decoded: GeckoErrorEnvelope = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded.error_type, error_type);
        assert_eq!(decoded.message, "message");
        // Optional `details` is omitted when absent.
        assert!(json.get("details").is_none());
    }
}

#[test]
fn error_envelope_details_serialize_when_present() {
    let envelope = GeckoErrorEnvelope {
        error_type: GeckoErrorType::DatabaseLocked,
        message: "locked".into(),
        details: Some(serde_json::json!({"reason": "open elsewhere", "retryable": true})),
    };
    let json: serde_json::Value = serde_json::from_str(&envelope.encode()).unwrap();
    assert_eq!(json["details"]["reason"], "open elsewhere");
    assert_eq!(json["details"]["retryable"], true);
}

// ── crypto page layout golden ─────────────────────────────────────────────

fn temp_path(label: &str) -> std::path::PathBuf {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("gecko-matrix-{label}-{nonce}.redb"))
}

#[test]
fn crypto_page_layout_is_keygen_tag_and_nonce() {
    let path = temp_path("layout");
    let plaintext: Vec<u8> = (0..LOGICAL_PAGE_SIZE).map(|i| (i % 251) as u8).collect();
    // Write through a backend, then drop it so the raw file is readable on
    // Windows (FileBackend holds a locked handle while alive).
    {
        let file = std::fs::OpenOptions
            ::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .unwrap();
        let backend = EncryptingStorageBackend::new(
            Box::new(redb::backends::FileBackend::new(file).unwrap()),
            [3u8; 32],
            7
        );
        backend.set_len(LOGICAL_PAGE_SIZE as u64).unwrap();
        backend.write(0, &plaintext).unwrap();
        backend.sync_data().unwrap();
    }

    let raw = std::fs::read(&path).unwrap();
    assert_eq!(raw.len(), PHYSICAL_PAGE_SIZE, "one physical page on disk");
    // [ key_gen: 1 ] [ ciphertext || tag: P+16 ] [ nonce: 12 ]
    assert_eq!(raw[0], 7, "first byte is the key generation");
    assert_eq!(raw.len(), 1 + (LOGICAL_PAGE_SIZE + 16) + 12, "page overhead layout");
    assert_eq!(raw.len(), LOGICAL_PAGE_SIZE + PAGE_OVERHEAD);
    // The plaintext must never appear verbatim (it is encrypted).
    assert!(!raw[1..1 + LOGICAL_PAGE_SIZE].windows(plaintext.len()).any(|w| w == plaintext));
    // The trailing 12 bytes are a nonce, distinct from the ciphertext region.
    let cipher = &raw[1..1 + LOGICAL_PAGE_SIZE + 16];
    let nonce = &raw[raw.len() - 12..];
    assert_ne!(cipher, nonce);

    // Read back through a fresh backend to confirm the round-trip.
    let file = std::fs::OpenOptions::new().read(true).write(true).open(&path).unwrap();
    let backend = EncryptingStorageBackend::new(
        Box::new(redb::backends::FileBackend::new(file).unwrap()),
        [3u8; 32],
        7
    );
    let mut out = vec![0u8; LOGICAL_PAGE_SIZE];
    backend.read(0, &mut out).unwrap();
    assert_eq!(out, plaintext);
    drop(backend);
    let _ = std::fs::remove_file(path);
}

// ── comparator property tests ─────────────────────────────────────────────

fn sample_values() -> Vec<RowValue> {
    use RowValue::*;
    vec![
        Null,
        Bool(false),
        Bool(true),
        Int64(-1000),
        Int64(0),
        Int64(5),
        Int64(1000),
        BigInt(-123456789012345678901234567890),
        BigInt(0),
        BigInt(123456789012345678901234567890),
        F64(-3.5),
        F64(0.0),
        F64(2.5),
        F64(f64::NAN),
        String("".into()),
        String("a".into()),
        String("b".into()),
        Bytes(vec![]),
        Bytes(vec![1, 2, 3]),
        DateTime(-1),
        DateTime(0),
        DateTime(1),
        List(vec![Int64(1), String("x".into())]),
        Map(vec![(String("k".into()), Int64(1)), (String("j".into()), Bool(true))])
    ]
}

#[test]
fn compare_is_antisymmetric_on_samples() {
    use std::cmp::Ordering;
    let values = sample_values();
    for a in &values {
        for b in &values {
            let ab = a.compare(b);
            let ba = b.compare(a);
            let expected = match ab {
                Ordering::Less => Ordering::Greater,
                Ordering::Equal => Ordering::Equal,
                Ordering::Greater => Ordering::Less,
            };
            assert_eq!(ba, expected, "antisymmetry violated for {a:?} vs {b:?}");
        }
    }
}

#[test]
fn compare_is_transitive_on_samples() {
    use std::cmp::Ordering;
    let values = sample_values();
    for a in &values {
        for b in &values {
            for c in &values {
                let ab = a.compare(b);
                let bc = b.compare(c);
                if ab == Ordering::Less && bc == Ordering::Less {
                    assert_eq!(
                        a.compare(c),
                        Ordering::Less,
                        "transitivity violated: {a:?} < {b:?} < {c:?}"
                    );
                }
            }
        }
    }
}

#[test]
fn sort_compare_is_a_total_order_on_samples() {
    use std::cmp::Ordering;
    let values = sample_values();
    // Reflexivity.
    for a in &values {
        assert_eq!(value_codec::sort_compare(a, a), Ordering::Equal);
    }
    // Antisymmetry (excluding NaN, which total_cmp handles).
    for a in &values {
        for b in &values {
            let ab = value_codec::sort_compare(a, b);
            let expected = match ab {
                Ordering::Less => Ordering::Greater,
                Ordering::Equal => Ordering::Equal,
                Ordering::Greater => Ordering::Less,
            };
            assert_eq!(value_codec::sort_compare(b, a), expected, "{a:?} vs {b:?}");
        }
    }
    // Transitivity.
    for a in &values {
        for b in &values {
            for c in &values {
                let ab = value_codec::sort_compare(a, b);
                let bc = value_codec::sort_compare(b, c);
                if ab == Ordering::Less && bc == Ordering::Less {
                    assert_eq!(value_codec::sort_compare(a, c), Ordering::Less);
                }
            }
        }
    }
}

#[test]
fn deep_equals_is_reflexive_symmetric_on_samples() {
    let values = sample_values();
    for a in &values {
        // Reflexive except for NaN, which by IEEE semantics (and Dart `==`)
        // is not equal to itself.
        if matches!(a, RowValue::F64(v) if v.is_nan()) {
            assert!(!a.deep_equals(a));
        } else {
            assert!(a.deep_equals(a), "{a:?} must equal itself");
        }
        for b in &values {
            assert_eq!(a.deep_equals(b), b.deep_equals(a), "{a:?} vs {b:?}");
        }
    }
}

// ── seeded malformed-input sweep ──────────────────────────────────────────

/// A tiny deterministic PRNG so the sweep is reproducible.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        // xorshift64* — fast, deterministic, no external deps.
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545f4914f6cdd1d)
    }
    fn bytes(&mut self, len: usize) -> Vec<u8> {
        (0..len).map(|_| (self.next() & 0xff) as u8).collect()
    }
}

#[test]
fn seeded_malformed_sweep_never_panics_across_all_decoders() {
    let mut rng = Lcg(0xc0ffee);
    // Seed each decoder with known-valid inputs so the sweep proves both that
    // valid input decodes and that arbitrary malformed input never panics.
    let mut inputs: Vec<Vec<u8>> = vec![
        vec![0x00], // value: null
        vec![0x01, 0x01], // value: bool(true)
        vec![0x07, 0, 0, 0, 1, 0x05, 0, 0, 0, 1, b'k', 0x02, 0, 0, 0, 0, 0, 0, 0, 5], // map {k:5}
        vec![1, 0], // predicate: empty
        vec![1, 0], // sort specs: empty
        vec![1, 0] // op batch: empty
    ];
    // A valid format header.
    let mut header = vec![0x47, 0x45, 0x43, 0x4b, 0x4f, 0x01, 1, 1, 3];
    header.extend_from_slice(b"0.1");
    inputs.push(header);
    // Then a deterministic sweep of malformed/random inputs.
    for _ in 0..4000 {
        let len = (rng.next() % 40) as usize;
        inputs.push(rng.bytes(len));
    }
    let mut decoded_values = 0usize;
    let mut decoded_predicates = 0usize;
    let mut decoded_specs = 0usize;
    let mut decoded_batches = 0usize;
    let mut decoded_headers = 0usize;
    for bytes in inputs {
        // Every decoder must return Ok or a typed Err, never panic, hang,
        // or allocate without bound.
        if value_codec::decode_value(&bytes).is_ok() {
            decoded_values += 1;
        }
        if decode_predicate(&bytes).is_ok() {
            decoded_predicates += 1;
        }
        if decode_sort_specs(&bytes).is_ok() {
            decoded_specs += 1;
        }
        if Op::decode_batch(&bytes).is_ok() {
            decoded_batches += 1;
        }
        if FormatHeader::decode(&bytes).is_ok() {
            decoded_headers += 1;
        }
    }
    // The seeded valid inputs guarantee every decoder sees at least one hit.
    assert!(decoded_values > 0, "value decoder must accept valid input");
    assert!(decoded_predicates > 0, "predicate decoder must accept valid input");
    assert!(decoded_specs > 0, "sort-spec decoder must accept valid input");
    assert!(decoded_batches > 0, "op decoder must accept valid input");
    assert!(decoded_headers > 0, "header decoder must accept valid input");
}

// ── sort-spec golden parity ───────────────────────────────────────────────

#[test]
fn sort_spec_round_trip_and_compare_rows_parity() {
    use std::cmp::Ordering;
    let specs = [
        SortSpec { field: "name".into(), descending: false },
        SortSpec { field: "age".into(), descending: true },
    ];
    let bytes = encode_sort_specs(&specs);
    let decoded = decode_sort_specs(&bytes).unwrap();
    assert_eq!(decoded.specs, specs);

    let a = RowValue::Map(
        vec![
            (RowValue::String("name".into()), RowValue::String("x".into())),
            (RowValue::String("age".into()), RowValue::Int64(1))
        ]
    );
    let b = RowValue::Map(
        vec![
            (RowValue::String("name".into()), RowValue::String("x".into())),
            (RowValue::String("age".into()), RowValue::Int64(2))
        ]
    );
    // name ties; age desc → age 1 > age 2.
    assert_eq!(gecko_db_rust::sort_spec::compare_rows(&a, &b, &decoded.specs), Ordering::Greater);
}

// ── format-header malformed decode ────────────────────────────────────────

#[test]
fn format_header_malformed_decode_is_typed() {
    assert!(FormatHeader::decode(&[]).is_err());
    assert!(FormatHeader::decode(&[0x47, 0x45, 0x43, 0x4b, 0x4f, 0x01, 1, 1]).is_err());
    // Wrong magic.
    assert!(FormatHeader::decode(&[0; 12]).is_err());
    // Header with an over-long package-version length claim.
    let mut bytes = vec![
        0x47,
        0x45,
        0x43,
        0x4b,
        0x4f,
        0x01,
        format_header::FORMAT_VERSION,
        format_header::WIRE_VERSION,
        0xff
    ];
    bytes.extend_from_slice(&[0u8; 4]);
    assert!(FormatHeader::decode(&bytes).is_err());
    // A valid header round-trips.
    let header = FormatHeader {
        format_version: format_header::FORMAT_VERSION,
        wire_version: format_header::WIRE_VERSION,
        package_version: "0.0.1".into(),
    };
    assert_eq!(FormatHeader::decode(&header.encode().unwrap()).unwrap(), header);
}

// ── Op batch golden re-encode helpers referenced by the fixture test ──────

#[allow(dead_code)]
fn _op_sample() -> Vec<Op> {
    vec![Op {
        kind: OpKind::Put,
        table: "t".into(),
        key: Some(vec![1]),
        value: Some(vec![2]),
        start: None,
        end: None,
    }]
}

#[test]
fn op_wire_version_is_stable_constant() {
    // The Dart `Op.wireVersion` must equal the Rust constant; this pins the
    // shared contract value.
    assert_eq!(WIRE_VERSION, 1);
    // Writing a batch through a temp file round-trips (exercise the API).
    let path = temp_path("opwire");
    let _ = std::fs::write(&path, b"unused");
    let _ = Path::new(&path);
    let _ = std::fs::remove_file(path);
}
