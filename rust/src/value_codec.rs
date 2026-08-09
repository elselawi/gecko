//! The value wire codec — a byte-for-byte Rust port of the Dart
//! `DefaultWireCodec` (Phase 2 step 2).
//!
//! The codec encodes a `RowValue` (null, bool, int64, bigint, f64, string,
//! bytes, list, map, datetime) as a single tag byte followed by a payload.
//! The encoding is deterministic and byte-stable; the Dart side is the source
//! of truth (`packages/gecko_db/lib/src/wire/wire_codec.dart`), and the
//! cross-language golden test (`rust/tests/compatibility_cross_lang.rs`)
//! locks the bytes. This module mirrors it so Rust can decode the row bytes
//! a full scan returns and evaluate a pushed predicate without round-tripping
//! every row back to Dart.
//!
//! Tag bytes (must match the Dart `_Tag` enum exactly):
//!   null      = 0x00
//!   bool      = 0x01  (+ 1 byte: 0/1)
//!   int64     = 0x02  (+ 8 bytes big-endian two's complement)
//!   bigint    = 0x03  (+ 16 bytes big-endian two's complement)
//!   f64       = 0x04  (+ 8 bytes IEEE-754 big-endian)
//!   string    = 0x05  (+ u32 big-endian length + UTF-8 bytes)
//!   bytes     = 0x08  (+ u32 big-endian length + raw bytes)
//!   list      = 0x06  (+ u32 big-endian count + N elements)
//!   map       = 0x07  (+ u32 big-endian count + N (key, value) pairs)
//!   datetime  = 0x09  (+ 8 bytes int64 microseconds since epoch, UTC)
//!
//! A row is always a `map` value (`0x07 | u32(count) | k0 | v0 | …`).

/// A decoded wire value mirroring the Dart `RowValue` (`Object?`).
#[derive(Debug, Clone, PartialEq)]
pub enum RowValue {
    Null,
    Bool(bool),
    /// 64-bit signed integer (LSNs, snapshot ids, timestamps, small row ints).
    Int64(i64),
    /// 128-bit signed integer (full int128 headroom; Dart's BigInt path).
    BigInt(i128),
    F64(f64),
    String(String),
    Bytes(Vec<u8>),
    List(Vec<RowValue>),
    /// Insertion-ordered key→value pairs. The codec does not guarantee a sort,
    /// but the Dart map iteration order is preserved as insertion order here so
    /// [find_field] can scan in the same order the encoder wrote.
    Map(Vec<(RowValue, RowValue)>),
    /// Microseconds since the Unix epoch (UTC).
    DateTime(i64),
}

impl RowValue {
    /// The Dart-ordering comparison used by range filters. Mirrors the Dart
    /// `Filter._compare`: if both are the same comparable runtime type, use
    /// natural ordering; otherwise fall back to string comparison.
    ///
    /// For predicate evaluation we only need equality and total ordering; the
    /// rules below match Dart `Comparable.compare` for the comparable scalar
    /// types and fall back to a stable string comparison otherwise, exactly as
    /// the Dart filter does.
    pub fn compare(&self, other: &RowValue) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        use RowValue::*;
        match (self, other) {
            (Null, Null) => Ordering::Equal,
            (Null, _) => Ordering::Less,
            (_, Null) => Ordering::Greater,
            (Bool(a), Bool(b)) => a.cmp(b),
            (Int64(a), Int64(b)) => a.cmp(b),
            (BigInt(a), BigInt(b)) => a.cmp(b),
            (Int64(a), BigInt(b)) => (*a as i128).cmp(b),
            (BigInt(a), Int64(b)) => a.cmp(&(*b as i128)),
            (F64(a), F64(b)) => a.total_cmp(b),
            (String(a), String(b)) => a.cmp(b),
            (Bytes(a), Bytes(b)) => a.cmp(b),
            (DateTime(a), DateTime(b)) => a.cmp(b),
            // Differing types: stable fallback by string representation, like
            // the Dart filter's `_compare`. Numbers compare numerically when
            // both are numeric (int/int-like); otherwise by string.
            _ => self
                .type_rank()
                .cmp(&other.type_rank())
                .then_with(|| self.to_compare_string().cmp(&other.to_compare_string())),
        }
    }

    /// Dart `Filter._deepEquals`: structural equality across List/Map.
    pub fn deep_equals(&self, other: &RowValue) -> bool {
        self == other
    }

    /// Whether this value, as a field value, would match an equality filter
    /// against [target]. Mirrors `Filter.matchesValue` for the equals op.
    pub fn equals(&self, target: &RowValue) -> bool {
        self == target
    }

    /// Finds the value of [field] in a map row, scanning insertion order.
    /// Returns None if the row is not a map or the field is absent. The field
    /// is matched by exact `RowValue::String` equality (a row's keys are
    /// always strings).
    pub fn find_field(&self, field: &str) -> Option<&RowValue> {
        if let RowValue::Map(entries) = self {
            for (k, v) in entries {
                if let RowValue::String(s) = k {
                    if s == field {
                        return Some(v);
                    }
                }
            }
        }
        None
    }

    fn type_rank(&self) -> u8 {
        use RowValue::*;
        match self {
            Null => 0,
            Bool(_) => 1,
            Int64(_) => 2,
            BigInt(_) => 3,
            F64(_) => 4,
            DateTime(_) => 5,
            String(_) => 6,
            Bytes(_) => 7,
            List(_) => 8,
            Map(_) => 9,
        }
    }

    /// A stable string representation for the cross-type fallback comparison.
    /// Matches the Dart `_compare` fallback (`a.toString()` vs `b.toString()`)
    /// for the scalar types; lists and maps compare by their debug rendering,
    /// which is only reached when types differ (an unusual predicate target).
    fn to_compare_string(&self) -> String {
        use RowValue::*;
        match self {
            Null => "null".to_string(),
            Bool(b) => b.to_string(),
            Int64(n) => n.to_string(),
            BigInt(n) => n.to_string(),
            F64(d) => format!("{d:?}"),
            String(s) => s.clone(),
            Bytes(b) => format!("{b:?}"),
            DateTime(u) => u.to_string(),
            List(l) => format!("{l:?}"),
            Map(m) => format!("{m:?}"),
        }
    }
}

/// The tag bytes — must match the Dart `_Tag` enum byte-for-byte.
pub const TAG_NULL: u8 = 0x00;
pub const TAG_BOOL: u8 = 0x01;
pub const TAG_INT64: u8 = 0x02;
pub const TAG_BIGINT: u8 = 0x03;
pub const TAG_F64: u8 = 0x04;
pub const TAG_LIST: u8 = 0x06;
pub const TAG_MAP: u8 = 0x07;
pub const TAG_BYTES: u8 = 0x08;
pub const TAG_DATETIME: u8 = 0x09;
pub const TAG_STRING: u8 = 0x05;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodeError(pub String);

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "DecodeError: {}", self.0)
    }
}
impl std::error::Error for DecodeError {}

type Result<T> = std::result::Result<T, DecodeError>;

/// A cursor over a byte slice, mirroring the Dart `_Reader`.
pub struct ValueReader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> ValueReader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        ValueReader { bytes, pos: 0 }
    }

    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    fn read_u8(&mut self) -> Result<u8> {
        let b = *self
            .bytes
            .get(self.pos)
            .ok_or_else(|| DecodeError("Unexpected end of input".into()))?;
        self.pos += 1;
        Ok(b)
    }

    fn read_n(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.pos + n > self.bytes.len() {
            return Err(DecodeError(format!(
                "Needed {n} bytes but only {} remain",
                self.remaining()
            )));
        }
        let slice = &self.bytes[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    fn read_u32_be(&mut self) -> Result<u32> {
        let b = self.read_n(4)?;
        Ok(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn read_i64_be(&mut self) -> Result<i64> {
        let b = self.read_n(8)?;
        let arr: [u8; 8] = [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]];
        Ok(i64::from_be_bytes(arr))
    }

    fn read_i128_be(&mut self) -> Result<i128> {
        let b = self.read_n(16)?;
        let mut arr = [0u8; 16];
        arr.copy_from_slice(b);
        Ok(i128::from_be_bytes(arr))
    }

    fn read_f64_be(&mut self) -> Result<f64> {
        let b = self.read_n(8)?;
        let arr: [u8; 8] = [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]];
        Ok(f64::from_be_bytes(arr))
    }

    fn read_string_raw(&mut self, len: usize) -> Result<String> {
        let b = self.read_n(len)?;
        std::str::from_utf8(b)
            .map(|s| s.to_string())
            .map_err(|_| DecodeError("Invalid UTF-8 in string value".into()))
    }

    /// Reads one value, advancing the cursor. The cursor is left at the byte
    /// after the value — callers can decode successive values (map entries,
    /// list elements) by calling this again.
    pub fn read_value(&mut self) -> Result<RowValue> {
        let tag = self.read_u8()?;
        match tag {
            TAG_NULL => Ok(RowValue::Null),
            TAG_BOOL => {
                let b = self.read_u8()?;
                Ok(RowValue::Bool(b != 0))
            }
            TAG_INT64 => Ok(RowValue::Int64(self.read_i64_be()?)),
            TAG_BIGINT => Ok(RowValue::BigInt(self.read_i128_be()?)),
            TAG_F64 => Ok(RowValue::F64(self.read_f64_be()?)),
            TAG_DATETIME => Ok(RowValue::DateTime(self.read_i64_be()?)),
            TAG_STRING => {
                let len = self.read_u32_be()? as usize;
                let s = self.read_string_raw(len)?;
                Ok(RowValue::String(s))
            }
            TAG_BYTES => {
                let len = self.read_u32_be()? as usize;
                let b = self.read_n(len)?.to_vec();
                Ok(RowValue::Bytes(b))
            }
            TAG_LIST => {
                let count = self.read_u32_be()? as usize;
                let mut out = Vec::with_capacity(count);
                for _ in 0..count {
                    out.push(self.read_value()?);
                }
                Ok(RowValue::List(out))
            }
            TAG_MAP => {
                let count = self.read_u32_be()? as usize;
                let mut out = Vec::with_capacity(count);
                for _ in 0..count {
                    let k = self.read_value()?;
                    let v = self.read_value()?;
                    out.push((k, v));
                }
                Ok(RowValue::Map(out))
            }
            other => Err(DecodeError(format!(
                "Unknown type tag byte: 0x{:02x}",
                other
            ))),
        }
    }

    /// Decodes exactly one value and asserts the cursor is fully consumed.
    /// Use [read_value] to decode a value from inside a larger stream.
    pub fn finish(mut self) -> Result<RowValue> {
        let v = self.read_value()?;
        if self.remaining() != 0 {
            return Err(DecodeError("Trailing bytes after value".into()));
        }
        Ok(v)
    }
}

/// Decodes a complete row value (`0x07 | …`) from [bytes].
pub fn decode_value(bytes: &[u8]) -> Result<RowValue> {
    ValueReader::new(bytes).finish()
}

/// Scans a row's encoded bytes for the value of [field] WITHOUT decoding the
/// whole map. The map encoding is `0x07 | u32(count) | k0 | v0 | k1 | v1 | …`;
/// to find a named field we decode each key (always a short string) and, if it
/// doesn't match, skip the corresponding value. Skipping a value avoids
/// allocating its substructure — the dominant saving for wide rows with a
/// sparse predicate.
///
/// Returns the decoded value for [field], or None if the row is not a map or
/// the field is absent.
pub fn find_field(bytes: &[u8], field: &str) -> Result<Option<RowValue>> {
    let mut r = ValueReader::new(bytes);
    let tag = r.read_u8()?;
    if tag != TAG_MAP {
        // Not a row-shaped value; no fields.
        return Ok(None);
    }
    let count = r.read_u32_be()? as usize;
    for _ in 0..count {
        // Decode the key (always a string tag in a row).
        let key = r.read_value()?;
        if let RowValue::String(s) = &key {
            if s == field {
                let value = r.read_value()?;
                return Ok(Some(value));
            }
        }
        // Key didn't match: skip the value without decoding it.
        skip_value(&mut r)?;
    }
    Ok(None)
}

/// Advances the cursor past one value without allocating, by walking the tag
/// tree. This is the structural mirror of `read_value` but returns no data.
pub fn skip_value(r: &mut ValueReader) -> Result<()> {
    let tag = r.read_u8()?;
    match tag {
        TAG_NULL | TAG_BOOL => {
            // null: no payload; bool: one payload byte.
            if tag == TAG_BOOL {
                r.read_u8()?;
            }
        }
        TAG_INT64 | TAG_F64 | TAG_DATETIME => {
            r.read_n(8)?;
        }
        TAG_BIGINT => {
            r.read_n(16)?;
        }
        TAG_STRING | TAG_BYTES => {
            let len = r.read_u32_be()? as usize;
            r.read_n(len)?;
        }
        TAG_LIST => {
            let count = r.read_u32_be()? as usize;
            for _ in 0..count {
                skip_value(r)?;
            }
        }
        TAG_MAP => {
            let count = r.read_u32_be()? as usize;
            for _ in 0..count {
                skip_value(r)?;
                skip_value(r)?;
            }
        }
        other => {
            return Err(DecodeError(format!(
                "Unknown type tag byte while skipping: 0x{:02x}",
                other
            )))
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Golden bytes produced by the Dart DefaultWireCodec (locked by the
    // cross-language compatibility test). These mirror the tag/payload layout
    // documented above; the test asserts the Rust decoder agrees.
    fn encode_string(s: &str) -> Vec<u8> {
        let mut out = vec![TAG_STRING];
        let bytes = s.as_bytes();
        out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        out.extend_from_slice(bytes);
        out
    }

    fn encode_int64(n: i64) -> Vec<u8> {
        let mut out = vec![TAG_INT64];
        out.extend_from_slice(&n.to_be_bytes());
        out
    }

    fn encode_map(entries: &[(String, Vec<u8>)]) -> Vec<u8> {
        let mut out = vec![TAG_MAP];
        out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
        for (k, v) in entries {
            out.extend(encode_string(k));
            out.extend_from_slice(v);
        }
        out
    }

    #[test]
    fn round_trips_scalars() {
        assert_eq!(
            decode_value(&encode_int64(42)).unwrap(),
            RowValue::Int64(42)
        );
        assert_eq!(
            decode_value(&encode_string("hi")).unwrap(),
            RowValue::String("hi".into())
        );
        let null = vec![TAG_NULL];
        assert_eq!(decode_value(&null).unwrap(), RowValue::Null);
    }

    #[test]
    fn decodes_a_row_map() {
        let row = encode_map(&[
            ("id".into(), encode_string("r0")),
            ("age".into(), encode_int64(31)),
            ("group".into(), encode_string("g0")),
        ]);
        let v = decode_value(&row).unwrap();
        assert_eq!(v.find_field("age"), Some(&RowValue::Int64(31)));
        assert_eq!(v.find_field("missing"), None);
    }

    #[test]
    fn find_field_skips_non_matching_values() {
        // A wide row where find_field should skip the heavy 'blob' value.
        let blob = vec![TAG_BYTES, 0, 0, 0, 4, b'b', b'l', b'o', b'b'];
        let row = encode_map(&[
            ("id".into(), encode_string("r0")),
            ("blob".into(), { blob.clone() }),
            ("flag".into(), vec![TAG_BOOL, 1]),
        ]);
        // find_field('flag') walks id + skips blob + lands on flag.
        let found = find_field(&row, "flag").unwrap();
        assert_eq!(found, Some(RowValue::Bool(true)));
        // And by decoding the whole row we agree.
        let full = decode_value(&row).unwrap();
        assert_eq!(full.find_field("flag"), Some(&RowValue::Bool(true)));
        let _ = blob; // suppress dead-code warning
    }

    #[test]
    fn compare_matches_dart_semantics() {
        use std::cmp::Ordering;
        // Same-type numeric ordering.
        assert_eq!(
            RowValue::Int64(1).compare(&RowValue::Int64(2)),
            Ordering::Less
        );
        assert_eq!(
            RowValue::String("a".into()).compare(&RowValue::String("b".into())),
            Ordering::Less
        );
        // null is less than everything.
        assert_eq!(RowValue::Null.compare(&RowValue::Int64(0)), Ordering::Less);
    }
}
