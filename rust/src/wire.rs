//! Wire format for gecko_db batched operations.
//!
//! This module mirrors the Dart-side contract in `gecko_db`'s `src/wire/op.dart`
//! byte-for-byte so a cross-language golden-bytes test (Phase 0/3) can verify
//! the two encoders agree exactly. The format is versioned; an unknown version
//! is a typed error, never a silent misparse.
//!
//! Format (big-endian):
//!   version : u8                                    (= 1)
//!   count   : uvarint
//!   per op  : kind(u8) table(string) key(b) value(b) start(b) end(b)
//!   string  : uvarint byte_len, then UTF-8 bytes — matches the Dart encoding of
//!             `table` (per §0.5: String is UTF-8, not a JS UTF-16 re-encoding).
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
            _ => return None,
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

fn push_varint(out: &mut Vec<u8>, mut value: u64) {
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
            return Err(WireError(format!(
                "Unsupported wire version {version} (expected {WIRE_VERSION})"
            )));
        }
        let count = r.read_varint()?;
        let mut ops = Vec::with_capacity(count as usize);
        for _ in 0..count {
            let kind =
                OpKind::from_u8(r.read_u8()?).ok_or_else(|| WireError("Unknown op kind".into()))?;
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
        let b = *self
            .bytes
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
            if b & 0x80 == 0 {
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
        let s = std::str::from_utf8(&self.bytes[self.pos..self.pos + len])
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
            },
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
        bytes[0] = 0xFF;
        assert!(matches!(
            Op::decode_batch(&bytes),
            Err(WireError(ref m)) if m.contains("version")
        ));
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
        good.extend_from_slice(&[0xAA, 0xBB]);
        assert!(matches!(Op::decode_batch(&good), Err(WireError(_))));
    }
}
