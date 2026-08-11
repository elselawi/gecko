//! Wire format for gecko_db batched operations.
//!
//! This module mirrors the Dart-side contract in `gecko_db`'s `src/wire/op.dart`
//! byte-for-byte so a cross-language golden-bytes test (/3) can verify
//! the two encoders agree exactly. The format is versioned; an unknown version
//! is a typed error, never a silent misparse.
//!
//! Format (big-endian):
//!   version : u8                                    (= 1)
//!   count   : uvarint
//!   per op  : kind(u8) table(string) key(b) value(b) start(b) end(b)
//!   string  : uvarint byte_len, then UTF-8 bytes — matches the Dart encoding of
//!             `table` (String is UTF-8, not a JS UTF-16 re-encoding).
//!   b       : presence(u8 = 0 → none | 1 → present), uvarint len, bytes

pub const WIRE_VERSION: u8 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum OpKind {
    Put = 0,
    Delete = 1,
    RangeScan = 2,
    Get = 3,
    DeleteRange = 4,
    Clear = 5,
}

impl OpKind {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => OpKind::Put,
            1 => OpKind::Delete,
            2 => OpKind::RangeScan,
            3 => OpKind::Get,
            4 => OpKind::DeleteRange,
            5 => OpKind::Clear,
            _ => {
                return None;
            }
        })
    }
}

#[derive(Debug, Clone)]
pub struct Op {
    pub kind: OpKind,
    pub table: String,
    pub key: Option<Vec<u8>>,
    pub value: Option<Vec<u8>>,
    pub start: Option<Vec<u8>>,
    pub end: Option<Vec<u8>>,
}

/// A typed, actionable decode failure — mirrors `OpDecodeException`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireError(pub String);

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "WireError: {}", self.0)
    }
}
impl std::error::Error for WireError {}

type Result<T> = std::result::Result<T, WireError>;

pub fn push_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
}

fn write_string(out: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    push_varint(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

fn write_opt_bytes(out: &mut Vec<u8>, b: &Option<Vec<u8>>) {
    match b {
        None => out.push(0),
        Some(bytes) => {
            out.push(1);
            push_varint(out, bytes.len() as u64);
            out.extend_from_slice(bytes);
        }
    }
}

impl Op {
    pub fn encode_batch(ops: &[Op]) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(WIRE_VERSION);
        push_varint(&mut out, ops.len() as u64);
        for op in ops {
            out.push(op.kind as u8);
            write_string(&mut out, &op.table);
            write_opt_bytes(&mut out, &op.key);
            write_opt_bytes(&mut out, &op.value);
            write_opt_bytes(&mut out, &op.start);
            write_opt_bytes(&mut out, &op.end);
        }
        out
    }

    pub fn decode_batch(bytes: &[u8]) -> Result<Vec<Op>> {
        let mut r = Reader::new(bytes);
        let version = r.read_u8()?;
        if version != WIRE_VERSION {
            return Err(
                WireError(format!("Unsupported wire version {version} (expected {WIRE_VERSION})"))
            );
        }
        let count = r.read_varint()?;
        // Each op is at least 5 bytes (kind + empty table string + 4 presence
        // bytes), so the remaining input bounds how many ops can possibly be
        // present. Capping the pre-allocation prevents a hostile count (up to
        // u64::MAX) from requesting a giant allocation before the bounds
        // checks fail.
        let cap = (count as usize).min(r.remaining());
        let mut ops = Vec::with_capacity(cap);
        for _ in 0..count {
            let kind = OpKind::from_u8(r.read_u8()?).ok_or_else(||
                WireError("Unknown op kind".into())
            )?;
            let table = r.read_string()?;
            let key = r.read_opt_bytes()?;
            let value = r.read_opt_bytes()?;
            let start = r.read_opt_bytes()?;
            let end = r.read_opt_bytes()?;
            ops.push(Op {
                kind,
                table,
                key,
                value,
                start,
                end,
            });
        }
        if r.remaining() != 0 {
            return Err(WireError("Trailing bytes after batch".into()));
        }
        Ok(ops)
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Reader { bytes, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    fn read_u8(&mut self) -> Result<u8> {
        let b = *self.bytes
            .get(self.pos)
            .ok_or_else(|| WireError("Unexpected end of input".into()))?;
        self.pos += 1;
        Ok(b)
    }

    fn read_varint(&mut self) -> Result<u64> {
        let mut value: u64 = 0;
        let mut shift = 0;
        loop {
            let b = self.read_u8()?;
            value |= ((b & 0x7f) as u64) << shift;
            if (b & 0x80) == 0 {
                break;
            }
            shift += 7;
            if shift > 63 {
                return Err(WireError("Varint overflow".into()));
            }
        }
        Ok(value)
    }

    fn read_string(&mut self) -> Result<String> {
        let len = self.read_varint()? as usize;
        if len > self.remaining() {
            return Err(WireError("String length out of range".into()));
        }
        let s = std::str
            ::from_utf8(&self.bytes[self.pos..self.pos + len])
            .map_err(|_| WireError("Invalid UTF-8".into()))?;
        self.pos += len;
        Ok(s.to_string())
    }

    fn read_opt_bytes(&mut self) -> Result<Option<Vec<u8>>> {
        if self.read_u8()? == 0 {
            return Ok(None);
        }
        let len = self.read_varint()? as usize;
        if len > self.remaining() {
            return Err(WireError("Bytes length out of range".into()));
        }
        let out = self.bytes[self.pos..self.pos + len].to_vec();
        self.pos += len;
        Ok(Some(out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<Op> {
        vec![
            Op {
                kind: OpKind::Put,
                table: "users".into(),
                key: Some(vec![0x05, 0x00]),
                value: Some(vec![1, 2, 3]),
                start: None,
                end: None,
            },
            Op {
                kind: OpKind::RangeScan,
                table: "orders".into(),
                key: None,
                value: None,
                start: Some(vec![9]),
                end: Some(vec![5, 5, 5]),
            },
            Op {
                kind: OpKind::Clear,
                table: "logs".into(),
                key: None,
                value: None,
                start: None,
                end: None,
            }
        ]
    }

    #[test]
    fn round_trips_all_variants() {
        for kind in 0..=5 {
            let op = Op {
                kind: OpKind::from_u8(kind).unwrap(),
                table: "t".into(),
                key: None,
                value: None,
                start: None,
                end: None,
            };
            let back = Op::decode_batch(&Op::encode_batch(&[op])).unwrap();
            assert_eq!(back[0].kind, OpKind::from_u8(kind).unwrap());
        }
    }

    #[test]
    fn byte_stable_golden() {
        let ops = sample();
        let a = Op::encode_batch(&ops);
        let b = Op::encode_batch(&ops);
        assert_eq!(a, b);
        // Determinism lock: re-encoding must reproduce identical bytes.
        assert_eq!(b, a);
    }

    #[test]
    fn reject_unknown_version() {
        let mut bytes = Op::encode_batch(&sample());
        bytes[0] = 0xff;
        assert!(
            matches!(
            Op::decode_batch(&bytes),
            Err(WireError(ref m)) if m.contains("version")
        )
        );
    }

    #[test]
    fn reject_unknown_kind() {
        // version, count=1, kind=99, table len 0, then four null presence bytes.
        let bytes = vec![WIRE_VERSION, 1, 99, 0, 0, 0, 0, 0];
        assert!(matches!(Op::decode_batch(&bytes), Err(WireError(_))));
    }

    #[test]
    fn reject_truncated() {
        let good = Op::encode_batch(&sample());
        let truncated = &good[..good.len() / 2];
        assert!(matches!(Op::decode_batch(truncated), Err(WireError(_))));
    }

    #[test]
    fn reject_trailing() {
        let mut good = Op::encode_batch(&sample());
        good.extend_from_slice(&[0xaa, 0xbb]);
        assert!(matches!(Op::decode_batch(&good), Err(WireError(_))));
    }

    #[test]
    fn varint_boundaries_round_trip() {
        // Encode a batch with `value` ops (all Clear) and decode; the count
        // crosses every LEB128 boundary.
        for value in [0u64, 1, 127, 128, 16383, 16384, 2097151, 2097152] {
            let ops: Vec<Op> = (0..value)
                .map(|_| Op {
                    kind: OpKind::Clear,
                    table: "t".into(),
                    key: None,
                    value: None,
                    start: None,
                    end: None,
                })
                .collect();
            let decoded = Op::decode_batch(&Op::encode_batch(&ops)).unwrap();
            assert_eq!(decoded.len() as u64, value);
        }
    }

    #[test]
    fn varint_overflow_is_a_typed_error() {
        // Ten continuation bytes push the shift past 63 → typed overflow.
        let bytes = vec![
            WIRE_VERSION,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0xff,
            0x01
        ];
        let err = Op::decode_batch(&bytes).unwrap_err();
        assert!(err.0.contains("Varint overflow"), "got: {err:?}");
    }

    #[test]
    fn hostile_varint_count_is_bounded_not_allocated() {
        // A huge-but-valid count (0x01 << 63) must not panic with a capacity
        // overflow; it must return a typed error promptly.
        let mut bytes = vec![WIRE_VERSION, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01];
        bytes.push(0); // at least one byte remains so remaining() > 0
        let err = Op::decode_batch(&bytes).unwrap_err();
        assert!(err.0.contains("end of input"), "got: {err:?}");
    }

    #[test]
    fn invalid_utf8_table_name_is_a_typed_error() {
        // version, count=1, kind=Put(0), then table string with invalid UTF-8.
        // string = varint len(1) + 0xFF.
        let mut bytes = vec![WIRE_VERSION, 1, 0, 1, 0xff];
        // then four null presence bytes.
        bytes.extend_from_slice(&[0, 0, 0, 0]);
        let err = Op::decode_batch(&bytes).unwrap_err();
        assert!(err.0.contains("UTF-8"), "got: {err:?}");
    }

    #[test]
    fn presence_byte_leniency_any_nonzero_is_present() {
        // A Put op whose value presence byte is 0x02 (non-canonical) must
        // decode as present, matching the Dart-side tolerance.
        let mut bytes = vec![WIRE_VERSION, 1, 0]; // Put
        // table "" (len 0)
        bytes.push(0);
        // key: absent (0)
        bytes.push(0);
        // value: present with NON-CANONICAL presence byte 0x02, len 1, [9]
        bytes.extend_from_slice(&[0x02, 1, 9]);
        // start, end absent
        bytes.extend_from_slice(&[0, 0]);
        let ops = Op::decode_batch(&bytes).unwrap();
        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].kind, OpKind::Put);
        assert_eq!(ops[0].value, Some(vec![9]));
    }

    #[test]
    fn count_over_claim_is_a_truncation_error() {
        // version, count=100, but no ops follow → typed error, no panic.
        let bytes = vec![WIRE_VERSION, 100];
        let err = Op::decode_batch(&bytes).unwrap_err();
        assert!(err.0.contains("end of input"), "got: {err:?}");
    }

    #[test]
    fn empty_batch_decodes_to_no_ops() {
        let ops = Op::decode_batch(&[WIRE_VERSION, 0]).unwrap();
        assert!(ops.is_empty());
    }

    #[test]
    fn large_payload_round_trips() {
        // An ~8 MB value round-trips byte-for-byte.
        let big: Vec<u8> = (0..8 * 1024 * 1024).map(|i| (i % 251) as u8).collect();
        let op = Op {
            kind: OpKind::Put,
            table: "big".into(),
            key: Some(vec![1, 2, 3]),
            value: Some(big.clone()),
            start: None,
            end: None,
        };
        let bytes = Op::encode_batch(&[op]);
        let decoded = Op::decode_batch(&bytes).unwrap();
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0].value.as_deref(), Some(big.as_slice()));
    }

    #[test]
    fn semantically_invalid_but_decodable_ops_are_ok() {
        // Validation is the worker's job, not the codec's: an op that decodes
        // but is semantically invalid (e.g. a Put with a key but null value)
        // must decode fine here and be rejected later by the worker.
        let op = Op {
            kind: OpKind::Put,
            table: "items".into(),
            key: Some(vec![1]),
            value: None,
            start: None,
            end: None,
        };
        let bytes = Op::encode_batch(&[op]);
        let decoded = Op::decode_batch(&bytes).unwrap();
        assert_eq!(decoded[0].kind, OpKind::Put);
        assert_eq!(decoded[0].key, Some(vec![1]));
        assert_eq!(decoded[0].value, None);
        // A Get op with extra optional fields also decodes fine.
        let get = Op {
            kind: OpKind::Get,
            table: "items".into(),
            key: Some(vec![1]),
            value: Some(vec![9]),
            start: Some(vec![0]),
            end: Some(vec![1]),
        };
        let decoded = Op::decode_batch(&Op::encode_batch(&[get])).unwrap();
        assert_eq!(decoded[0].kind, OpKind::Get);
    }
}
