//! The value wire codec — a byte-for-byte Rust port of the Dart
//! `DefaultWireCodec` (step 2).
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
            _ =>
                self
                    .type_rank()
                    .cmp(&other.type_rank())
                    .then_with(|| self.to_compare_string().cmp(&other.to_compare_string())),
        }
    }

    /// Dart `Filter._deepEquals`: structural equality across List/Map. Maps
    /// compare **order-independently** (every key of `a` must be present in
    /// `b` with a deep-equal value), matching the Dart implementation; the
    /// codec preserves insertion order on the wire but order must not affect
    /// equality. Scalars compare type-strictly (`Int64(5) != F64(5.0)`),
    /// which is the current `PartialEq` behavior.
    pub fn deep_equals(&self, other: &RowValue) -> bool {
        match (self, other) {
            (RowValue::List(a), RowValue::List(b)) => {
                a.len() == b.len() &&
                    a
                        .iter()
                        .zip(b.iter())
                        .all(|(x, y)| x.deep_equals(y))
            }
            (RowValue::Map(a), RowValue::Map(b)) => {
                if a.len() != b.len() {
                    return false;
                }
                a.iter().all(|(ka, va)| {
                    b.iter()
                        .find(|(kb, _)| ka.deep_equals(kb))
                        .is_some_and(|(_, vb)| va.deep_equals(vb))
                })
            }
            _ => self == other,
        }
    }

    /// Whether this value, as a field value, would match an equality filter
    /// against [target]. Mirrors `Filter.matchesValue` for the equals op.
    pub fn equals(&self, target: &RowValue) -> bool {
        self.deep_equals(target)
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

/// A 64/128-bit numeric value extracted from a [`RowValue`] for sorting.
#[derive(Debug, Clone, Copy)]
enum NumVal {
    I(i64),
    I128(i128),
    F(f64),
}

/// sort comparison over two decoded field values — a byte-for-byte port of
/// Dart `compareFieldValues` (`sorting.dart`), NOT the range-filter `compare`.
/// The contracts differ: `compare` uses the Dart `Filter._compare` fallback
/// (type-rank), while sorting uses Dart `num.compareTo` for all numerics, then
/// string/bool natural order, same-runtimeType `Comparable` natural order, a
/// `(x ?? '').toString()` rule when nulls are involved, and a plain
/// `toString()` fallback otherwise.
pub fn sort_compare(a: &RowValue, b: &RowValue) -> std::cmp::Ordering {
    use RowValue::*;
    // num vs num → numeric (Dart num.compareTo).
    if let (Some(x), Some(y)) = (num_of(a), num_of(b)) {
        return compare_num(x, y);
    }
    // String vs String → lexical.
    if let (String(x), String(y)) = (a, b) {
        return x.cmp(y);
    }
    // bool vs bool → false < true.
    if let (Bool(x), Bool(y)) = (a, b) {
        return x.cmp(y);
    }
    // DateTime vs DateTime → natural (Dart Comparable, same runtimeType).
    if let (DateTime(x), DateTime(y)) = (a, b) {
        return x.cmp(y);
    }
    // Nulls involved → (x ?? '').toString() comparison ('' for null).
    if matches!(a, Null) || matches!(b, Null) {
        return sortable_string(a).cmp(&sortable_string(b));
    }
    // Otherwise → toString() fallback.
    sortable_string(a).cmp(&sortable_string(b))
}

fn num_of(v: &RowValue) -> Option<NumVal> {
    match v {
        RowValue::Int64(n) => Some(NumVal::I(*n)),
        RowValue::BigInt(n) => Some(NumVal::I128(*n)),
        RowValue::F64(d) => Some(NumVal::F(*d)),
        _ => None,
    }
}

fn compare_num(a: NumVal, b: NumVal) -> std::cmp::Ordering {
    match (a, b) {
        (NumVal::I(x), NumVal::I(y)) => x.cmp(&y),
        (NumVal::I128(x), NumVal::I128(y)) => x.cmp(&y),
        (NumVal::I(x), NumVal::I128(y)) => (x as i128).cmp(&y),
        (NumVal::I128(x), NumVal::I(y)) => x.cmp(&(y as i128)),
        (NumVal::F(x), NumVal::F(y)) => x.total_cmp(&y),
        (NumVal::F(x), NumVal::I(y)) => x.total_cmp(&(y as f64)),
        (NumVal::I(x), NumVal::F(y)) => (x as f64).total_cmp(&y),
        (NumVal::F(x), NumVal::I128(y)) => x.total_cmp(&(y as f64)),
        (NumVal::I128(x), NumVal::F(y)) => (x as f64).total_cmp(&y),
    }
}

/// The string Dart `x.toString()` produces for a value, with `Null → ""` (the
/// `(x ?? '').toString()` rule in `compareFieldValues`).
pub fn sortable_string(v: &RowValue) -> String {
    match v {
        RowValue::Null => String::new(),
        other => other.to_compare_string(),
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
/// Order-preserving index-value element (Priority 5). See the section below.
pub const TAG_ORDERED: u8 = 0x0A;
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

    /// The current cursor position (bytes consumed so far). Used by callers
    /// that slice into the underlying buffer after walking part of it.
    pub fn position(&self) -> usize {
        self.pos
    }

    /// Reads a single byte. Public so the worker can parse durable-index
    /// keys (whose trailing record-key element is raw bytes, not a codec
    /// value — a full `read_value` would reject it).
    pub fn read_u8(&mut self) -> Result<u8> {
        let b = *self.bytes
            .get(self.pos)
            .ok_or_else(|| DecodeError("Unexpected end of input".into()))?;
        self.pos += 1;
        Ok(b)
    }

    fn read_n(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.pos + n > self.bytes.len() {
            return Err(
                DecodeError(format!("Needed {n} bytes but only {} remain", self.remaining()))
            );
        }
        let slice = &self.bytes[self.pos..self.pos + n];
        self.pos += n;
        Ok(slice)
    }

    /// Reads a big-endian u32. Public for the same reason as [Self::read_u8].
    pub fn read_u32_be(&mut self) -> Result<u32> {
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
        std::str
            ::from_utf8(b)
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
                // A list element is at least one byte (its tag byte), so the
                // remaining input bounds how many elements can possibly be
                // present. Capping the pre-allocation by the remaining bytes
                // prevents a hostile count (up to 2^32-1) from requesting a
                // multi-GB allocation before the bounds checks fail.
                let cap = count.min(self.remaining());
                let mut out = Vec::with_capacity(cap);
                for _ in 0..count {
                    out.push(self.read_value()?);
                }
                Ok(RowValue::List(out))
            }
            TAG_MAP => {
                let count = self.read_u32_be()? as usize;
                // Each map entry is a key + value, so at least two bytes.
                let cap = count.min(self.remaining() / 2);
                let mut out = Vec::with_capacity(cap);
                for _ in 0..count {
                    let k = self.read_value()?;
                    let v = self.read_value()?;
                    out.push((k, v));
                }
                Ok(RowValue::Map(out))
            }
            TAG_ORDERED => {
                let subtag = self.read_u8()?;
                match subtag {
                    ORD_NULL => Ok(RowValue::Null),
                    ORD_BOOL => Ok(RowValue::Bool(self.read_u8()? != 0)),
                    // Numeric payloads are sign-flipped / total-order encoded,
                    // so decoding inverts the transform.
                    ORD_INT64 => {
                        let stored = self.read_i64_be()?;
                        Ok(RowValue::Int64(
                            ((stored as u64) ^ 0x8000_0000_0000_0000u64) as i64
                        ))
                    }
                    ORD_DATETIME => {
                        let stored = self.read_i64_be()?;
                        Ok(RowValue::DateTime(
                            ((stored as u64) ^ 0x8000_0000_0000_0000u64) as i64
                        ))
                    }
                    ORD_BIGINT => {
                        let stored = self.read_i128_be()?;
                        Ok(RowValue::BigInt(
                            ((stored as u128) ^ 0x8000_0000_0000_0000_0000_0000_0000_0000u128)
                                as i128
                        ))
                    }
                    ORD_F64 => {
                        let stored = self.read_f64_be()?.to_bits();
                        let bits = if stored & 0x8000_0000_0000_0000 == 0 {
                            !stored
                        } else {
                            stored ^ 0x8000_0000_0000_0000
                        };
                        Ok(RowValue::F64(f64::from_bits(bits)))
                    }
                    ORD_STRING => read_ord_string(self, true),
                    ORD_BYTES => read_ord_string(self, false),
                    // List/map fallbacks embed a full codec value.
                    ORD_LIST | ORD_MAP => self.read_value(),
                    other => Err(DecodeError(format!("unknown ordered subtag 0x{other:02x}"))),
                }
            }
            other => Err(DecodeError(format!("Unknown type tag byte: 0x{:02x}", other))),
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
fn read_string_key<'a>(reader: &mut ValueReader<'a>) -> Result<Option<&'a [u8]>> {
    let tag = reader.read_u8()?;
    if tag != TAG_STRING {
        // Preserve read_value's validation behavior for malformed/non-string
        // map keys before the caller skips their associated value.
        reader.pos = reader.pos.saturating_sub(1);
        let _ = reader.read_value()?;
        return Ok(None);
    }
    let len = reader.read_u32_be()? as usize;
    let bytes = reader.read_n(len)?;
    std::str::from_utf8(bytes).map_err(|_| DecodeError("Invalid UTF-8 in string value".into()))?;
    Ok(Some(bytes))
}

fn find_field_range_internal(bytes: &[u8], field: &str) -> Result<Option<(usize, usize)>> {
    let mut reader = ValueReader::new(bytes);
    if reader.read_u8()? != TAG_MAP {
        return Ok(None);
    }
    let count = reader.read_u32_be()? as usize;
    let wanted = field.as_bytes();
    for _ in 0..count {
        let key = read_string_key(&mut reader)?;
        let value_start = reader.position();
        if key == Some(wanted) {
            skip_value(&mut reader)?;
            return Ok(Some((value_start, reader.position())));
        }
        skip_value(&mut reader)?;
    }
    Ok(None)
}

pub fn find_field(bytes: &[u8], field: &str) -> Result<Option<RowValue>> {
    let Some((start, end)) = find_field_range_internal(bytes, field)? else {
        return Ok(None);
    };
    Ok(Some(decode_value(&bytes[start..end])?))
}

/// Returns the exact encoded value slice for [field] without allocating the
/// field name or decoding the value. Present `null` is represented by a
/// non-empty slice, distinct from a missing field.
pub fn find_field_bytes<'a>(bytes: &'a [u8], field: &str) -> Result<Option<&'a [u8]>> {
    let Some((start, end)) = find_field_range_internal(bytes, field)? else {
        return Ok(None);
    };
    Ok(Some(&bytes[start..end]))
}

/// Finds several encoded field-value ranges in one map walk. The first
/// occurrence of a duplicate field wins, matching [find_field]. Present null
/// values have a range and remain distinct from missing fields (`None`). The
/// scan stops once every requested field has been found, preserving the
/// allocation-free early-return behavior of single-field lookup.
///
/// A per-call lookup plan maps each encoded field name to every requested
/// slot (a query can mention one field more than once), turning the walk from
/// O(F × Q) key comparisons into O(F + Q) hash lookups for F map entries and
/// Q requested fields. Malformed rows (a non-map, a truncated entry) yield
/// whatever ranges were found, exactly like the single-field lookup.
pub fn find_fields_ranges(
    bytes: &[u8],
    fields: &[String],
    ranges: &mut [Option<(usize, usize)>],
) -> Result<()> {
    if fields.len() != ranges.len() {
        return Err(DecodeError("field and range lengths differ".into()));
    }
    ranges.fill(None);
    if fields.is_empty() {
        return Ok(());
    }
    // Compile field name → all requested slots once; the lookup borrows
    // `fields`, which outlives this call.
    let mut slots_by_field: std::collections::HashMap<&[u8], Vec<usize>> =
        std::collections::HashMap::with_capacity(fields.len());
    for (slot, field) in fields.iter().enumerate() {
        slots_by_field.entry(field.as_bytes()).or_default().push(slot);
    }
    let mut reader = ValueReader::new(bytes);
    if reader.read_u8()? != TAG_MAP {
        return Ok(());
    }
    let count = reader.read_u32_be()? as usize;
    let mut remaining = fields.len();
    for _ in 0..count {
        let key = read_string_key(&mut reader)?;
        let value_start = reader.position();
        skip_value(&mut reader)?;
        let value_end = reader.position();
        if let Some(key) = key {
            if let Some(slots) = slots_by_field.get(key) {
                for &slot in slots {
                    if ranges[slot].is_none() {
                        ranges[slot] = Some((value_start, value_end));
                        remaining -= 1;
                    }
                }
            }
        }
        if remaining == 0 {
            break;
        }
    }
    Ok(())
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
        TAG_ORDERED => {
            let subtag = r.read_u8()?;
            match subtag {
                ORD_NULL => {}
                ORD_BOOL => {
                    r.read_u8()?;
                }
                ORD_INT64 | ORD_DATETIME | ORD_F64 => {
                    r.read_n(8)?;
                }
                ORD_BIGINT => {
                    r.read_n(16)?;
                }
                ORD_STRING | ORD_BYTES => {
                    loop {
                        let b = r.read_u8()?;
                        if b == 0x00 {
                            let n = r.read_u8()?;
                            if n == 0x00 {
                                break;
                            }
                        }
                    }
                }
                ORD_LIST | ORD_MAP => skip_value(r)?,
                other => {
                    return Err(
                        DecodeError(format!("unknown ordered subtag while skipping: 0x{other:02x}"))
                    );
                }
            }
        }
        other => {
            return Err(
                DecodeError(format!("Unknown type tag byte while skipping: 0x{:02x}", other))
            );
        }
    }
    Ok(())
}

/// Like [find_field], but returns the byte range `(start, end)` of the
/// field's encoded value within [bytes] instead of decoding it. The slice
/// `bytes[start..end]` is the self-delimiting `RowValue` payload (tag +
/// payload), so a caller can hand it back to `decode_value` or emit it as-is.
/// Returns None if the row is not a map or the field is absent. Used by the
/// distinct aggregate pushdown so per-row transfer is one value slice, not
/// the whole row.
pub fn find_field_range(bytes: &[u8], field: &str) -> Result<Option<(usize, usize)>> {
    find_field_range_internal(bytes, field)
}

// ── order-preserving index-value encoding (Priority 5) ────────────────────
//
// The durable `__gecko_index` key is the 4-element codec list
// `[table, field, ordValue, recordId]`. The `ordValue` element uses a
// versioned, order-preserving, self-delimiting encoding so a range scan over
// the index visits exactly the rows whose field value falls in the requested
// span: byte order equals semantic order for the supported scalar types. The
// element is `0x0A | <subtag> | <payload>`; `read_value`/`skip_value` parse
// it, so the key remains a valid codec list (the repair path and
// `durable_index_table` depend on that).
//
// Sub-tag layout (deterministic cross-type order; same-type order is exact):
//   0x00 null | 0x01 bool | 0x02 int64 | 0x03 datetime | 0x04 bigint
//   | 0x05 f64 | 0x06 string | 0x07 bytes | 0x08 list | 0x09 map
//
// Numeric payloads are sign-flipped (i64/i128/datetime) or total-order
// (f64, matching `sort_compare`'s `total_cmp` bit order). Strings and bytes
// use a prefix-free "escaped terminator" encoding: byte `0x00` becomes
// `00 01`, every other byte passes through unchanged, and the value ends
// with `00 00`. Lexicographic byte order therefore equals semantic string
// order AND a semantic string prefix is a contiguous byte range. Lists and
// maps fall back to their raw codec bytes (not order-preserving; rarely
// indexed or sorted).
const ORD_NULL: u8 = 0x00;
const ORD_BOOL: u8 = 0x01;
const ORD_INT64: u8 = 0x02;
const ORD_DATETIME: u8 = 0x03;
const ORD_BIGINT: u8 = 0x04;
const ORD_F64: u8 = 0x05;
const ORD_STRING: u8 = 0x06;
const ORD_BYTES: u8 = 0x07;
const ORD_LIST: u8 = 0x08;
const ORD_MAP: u8 = 0x09;

fn flip_i64(n: i64) -> [u8; 8] {
    (n as u64 ^ 0x8000_0000_0000_0000).to_be_bytes()
}

fn flip_i128(n: i128) -> [u8; 16] {
    (n as u128 ^ 0x8000_0000_0000_0000_0000_0000_0000_0000).to_be_bytes()
}

/// Total-order byte encoding of an f64 matching `f64::total_cmp`'s bit order
/// (negative NaN < negative infinity < … < positive infinity < positive NaN).
fn total_order_f64(d: f64) -> [u8; 8] {
    let bits = d.to_bits();
    let ord = if bits & 0x8000_0000_0000_0000 != 0 {
        !bits
    } else {
        bits ^ 0x8000_0000_0000_0000
    };
    ord.to_be_bytes()
}

/// Escaped-terminator encoding of a byte string (see the section comment).
fn push_ord_string(out: &mut Vec<u8>, bytes: &[u8]) {
    for &b in bytes {
        if b == 0x00 {
            out.extend_from_slice(&[0x00, 0x01]);
        } else {
            out.push(b);
        }
    }
    out.extend_from_slice(&[0x00, 0x00]);
}

/// Encodes a decoded value back to DefaultWireCodec bytes (the codec is
/// decode-only on this side; used for the list/map ordered fallback and by
/// tests). Mirrors the Dart `DefaultWireCodec.encode`.
pub fn encode_value(value: &RowValue) -> Vec<u8> {
    use RowValue::*;
    let mut out = Vec::new();
    match value {
        Null => out.push(TAG_NULL),
        Bool(b) => {
            out.push(TAG_BOOL);
            out.push(if *b { 1 } else { 0 });
        }
        Int64(n) => {
            out.push(TAG_INT64);
            out.extend_from_slice(&n.to_be_bytes());
        }
        BigInt(n) => {
            out.push(TAG_BIGINT);
            out.extend_from_slice(&n.to_be_bytes());
        }
        F64(d) => {
            out.push(TAG_F64);
            out.extend_from_slice(&d.to_be_bytes());
        }
        DateTime(n) => {
            out.push(TAG_DATETIME);
            out.extend_from_slice(&n.to_be_bytes());
        }
        String(s) => {
            out.push(TAG_STRING);
            out.extend_from_slice(&(s.len() as u32).to_be_bytes());
            out.extend_from_slice(s.as_bytes());
        }
        Bytes(b) => {
            out.push(TAG_BYTES);
            out.extend_from_slice(&(b.len() as u32).to_be_bytes());
            out.extend_from_slice(b);
        }
        List(items) => {
            out.push(TAG_LIST);
            out.extend_from_slice(&(items.len() as u32).to_be_bytes());
            for item in items {
                out.extend_from_slice(&encode_value(item));
            }
        }
        Map(entries) => {
            out.push(TAG_MAP);
            out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
            for (k, v) in entries {
                out.extend_from_slice(&encode_value(k));
                out.extend_from_slice(&encode_value(v));
            }
        }
    }
    out
}

/// The order-preserving payload (subtag + payload) for a decoded value.
pub fn order_encode_value(value: &RowValue) -> Vec<u8> {
    use RowValue::*;
    let mut out = Vec::new();
    match value {
        Null => out.push(ORD_NULL),
        Bool(b) => {
            out.push(ORD_BOOL);
            out.push(if *b { 1 } else { 0 });
        }
        Int64(n) => {
            out.push(ORD_INT64);
            out.extend_from_slice(&flip_i64(*n));
        }
        DateTime(n) => {
            out.push(ORD_DATETIME);
            out.extend_from_slice(&flip_i64(*n));
        }
        BigInt(n) => {
            out.push(ORD_BIGINT);
            out.extend_from_slice(&flip_i128(*n));
        }
        F64(d) => {
            out.push(ORD_F64);
            out.extend_from_slice(&total_order_f64(*d));
        }
        String(s) => {
            out.push(ORD_STRING);
            push_ord_string(&mut out, s.as_bytes());
        }
        Bytes(b) => {
            out.push(ORD_BYTES);
            push_ord_string(&mut out, b);
        }
        List(_) => {
            out.push(ORD_LIST);
            out.extend_from_slice(&encode_value(value));
        }
        Map(_) => {
            out.push(ORD_MAP);
            out.extend_from_slice(&encode_value(value));
        }
    }
    out
}

/// Appends the order-preserving encoding of a raw codec-encoded field value
/// to [out] (the slice a `find_field_range` returns). Scalar values never
/// allocate a decoded `RowValue`; [order_encode_slice] wraps this for the
/// standalone case.
pub fn push_order_encode_slice(out: &mut Vec<u8>, raw: &[u8]) -> Result<()> {
    let mut r = ValueReader::new(raw);
    let tag = r.read_u8()?;
    match tag {
        TAG_NULL => out.push(ORD_NULL),
        TAG_BOOL => {
            out.push(ORD_BOOL);
            out.push(r.read_u8()?);
        }
        TAG_INT64 => {
            out.push(ORD_INT64);
            out.extend_from_slice(&flip_i64(r.read_i64_be()?));
        }
        TAG_DATETIME => {
            out.push(ORD_DATETIME);
            out.extend_from_slice(&flip_i64(r.read_i64_be()?));
        }
        TAG_BIGINT => {
            out.push(ORD_BIGINT);
            out.extend_from_slice(&flip_i128(r.read_i128_be()?));
        }
        TAG_F64 => {
            out.push(ORD_F64);
            out.extend_from_slice(&total_order_f64(r.read_f64_be()?));
        }
        TAG_STRING => {
            let len = r.read_u32_be()? as usize;
            let bytes = r.read_n(len)?;
            out.push(ORD_STRING);
            push_ord_string(out, bytes);
        }
        TAG_BYTES => {
            let len = r.read_u32_be()? as usize;
            let bytes = r.read_n(len)?;
            out.push(ORD_BYTES);
            push_ord_string(out, bytes);
        }
        TAG_LIST => {
            out.push(ORD_LIST);
            out.extend_from_slice(raw);
        }
        TAG_MAP => {
            out.push(ORD_MAP);
            out.extend_from_slice(raw);
        }
        other => return Err(DecodeError(format!("cannot order-encode tag 0x{other:02x}"))),
    }
    Ok(())
}

/// Order-preserving encoding of a raw codec-encoded field value.
pub fn order_encode_slice(raw: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(raw.len() + 8);
    push_order_encode_slice(&mut out, raw)?;
    Ok(out)
}

/// The full order-preserving value element (the `0x0A` tag plus payload) used
/// inside a durable-index key for a decoded value.
pub fn ordered_index_element(value: &RowValue) -> Vec<u8> {
    let mut out = vec![TAG_ORDERED];
    out.extend_from_slice(&order_encode_value(value));
    out
}

/// Reads an escaped-terminator string/bytes payload (see `push_ord_string`).
fn read_ord_string(r: &mut ValueReader, as_text: bool) -> Result<RowValue> {
    let mut out = Vec::new();
    loop {
        let b = r.read_u8()?;
        if b == 0x00 {
            let n = r.read_u8()?;
            if n == 0x00 {
                break; // terminator
            }
            out.push(0x00); // 0x00 0x01 escape
        } else {
            out.push(b);
        }
    }
    if as_text {
        std::str
            ::from_utf8(&out)
            .map(|s| RowValue::String(s.to_string()))
            .map_err(|_| DecodeError("Invalid UTF-8 in ordered string value".into()))
    } else {
        Ok(RowValue::Bytes(out))
    }
}


/// Rewrites the storage-derived fields in a Dart-authored change-record map.
/// The record's other fields and insertion order are copied byte-for-byte.
/// [previous] is supplied only when the caller requested storage-derived
/// `previousVersion`; an absent previous row is encoded as `null`.
pub fn rewrite_change_record(
    bytes: &[u8],
    sequence: u64,
    previous: Option<Option<&[u8]>>
) -> Result<Vec<u8>> {
    let mut reader = ValueReader::new(bytes);
    if reader.read_u8()? != TAG_MAP {
        return Err(DecodeError("change record must be a map".into()));
    }
    let count = reader.read_u32_be()? as usize;
    let mut out = Vec::with_capacity(bytes.len() + 16);
    out.extend_from_slice(&bytes[..5]);
    let mut saw_sequence = false;
    for _ in 0..count {
        let key_start = reader.position();
        let key = reader.read_value()?;
        let key_end = reader.position();
        let value_start = reader.position();
        skip_value(&mut reader)?;
        let value_end = reader.position();
        out.extend_from_slice(&bytes[key_start..key_end]);
        match key {
            RowValue::String(ref name) if name == "localMutationId" => {
                out.push(TAG_INT64);
                out.extend_from_slice(&(sequence as i64).to_be_bytes());
                saw_sequence = true;
            }
            RowValue::String(ref name) if name == "previousVersion" => {
                if let Some(previous) = previous {
                    match previous {
                        Some(row) => out.extend_from_slice(row),
                        None => out.push(TAG_NULL),
                    }
                } else {
                    out.extend_from_slice(&bytes[value_start..value_end]);
                }
            }
            _ => out.extend_from_slice(&bytes[value_start..value_end]),
        }
    }
    if reader.remaining() != 0 {
        return Err(DecodeError("trailing bytes after change record".into()));
    }
    if !saw_sequence {
        return Err(DecodeError("change record is missing localMutationId".into()));
    }
    Ok(out)
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
        assert_eq!(decode_value(&encode_int64(42)).unwrap(), RowValue::Int64(42));
        assert_eq!(decode_value(&encode_string("hi")).unwrap(), RowValue::String("hi".into()));
        let null = vec![TAG_NULL];
        assert_eq!(decode_value(&null).unwrap(), RowValue::Null);
    }

    #[test]
    fn decodes_a_row_map() {
        let row = encode_map(
            &[
                ("id".into(), encode_string("r0")),
                ("age".into(), encode_int64(31)),
                ("group".into(), encode_string("g0")),
            ]
        );
        let v = decode_value(&row).unwrap();
        assert_eq!(v.find_field("age"), Some(&RowValue::Int64(31)));
        assert_eq!(v.find_field("missing"), None);
    }

    #[test]
    fn find_field_skips_non_matching_values() {
        // A wide row where find_field should skip the heavy 'blob' value.
        let blob = vec![TAG_BYTES, 0, 0, 0, 4, b'b', b'l', b'o', b'b'];
        let row = encode_map(
            &[
                ("id".into(), encode_string("r0")),
                ("blob".into(), { blob.clone() }),
                ("flag".into(), vec![TAG_BOOL, 1]),
            ]
        );
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
        assert_eq!(RowValue::Int64(1).compare(&RowValue::Int64(2)), Ordering::Less);
        assert_eq!(
            RowValue::String("a".into()).compare(&RowValue::String("b".into())),
            Ordering::Less
        );
        // null is less than everything.
        assert_eq!(RowValue::Null.compare(&RowValue::Int64(0)), Ordering::Less);
    }

    #[test]
    fn find_field_range_slices_self_delimiting_value() {
        // A wide row; find_field_range('flag') must return the exact byte
        // range that decodes to the flag value, independent of the heavy
        // 'blob' value that precedes it.
        let blob = vec![TAG_BYTES, 0, 0, 0, 4, b'b', b'l', b'o', b'b'];
        let row = encode_map(
            &[
                ("id".into(), encode_string("r0")),
                ("blob".into(), { blob.clone() }),
                ("flag".into(), vec![TAG_BOOL, 1]),
            ]
        );
        let range = find_field_range(&row, "flag").unwrap();
        assert!(range.is_some());
        let (start, end) = range.unwrap();
        // The slice must decode to the same value as find_field.
        let sliced = decode_value(&row[start..end]).unwrap();
        assert_eq!(sliced, RowValue::Bool(true));
        // The slice must equal the raw encoded bytes for a bool(true).
        assert_eq!(&row[start..end], &[TAG_BOOL, 1]);
        assert_eq!(find_field_bytes(&row, "flag").unwrap(), Some(&row[start..end]));
        assert_eq!(find_field_bytes(&row, "missing").unwrap(), None);

        // A missing field returns None.
        assert_eq!(find_field_range(&row, "nope").unwrap(), None);
        // A non-map value returns None.
        assert_eq!(find_field_range(&encode_int64(7), "x").unwrap(), None);
        let _ = blob;
    }

    // ── unknown-tag / truncation / allocation-hardening ────────────────────

    #[test]
    fn unknown_tag_sweep_rejects_every_unassigned_tag() {
        // 0x0B..=0xFF are unassigned (0x0A is the Priority 5 ordered-index
        // value tag); both read_value and skip_value must return a typed
        // DecodeError, never panic or loop.
        for tag in 0x0bu8..=0xff {
            let bytes = [tag];
            let err = decode_value(&bytes).unwrap_err();
            assert!(
                err.0.contains("Unknown type tag"),
                "tag 0x{tag:02x} should be rejected, got: {err:?}"
            );
            let mut reader = ValueReader::new(&bytes);
            assert!(skip_value(&mut reader).is_err(), "tag 0x{tag:02x} skip");
            // A tag nested inside a map must also be rejected.
            let mut map = vec![TAG_MAP, 0, 0, 0, 1];
            map.push(tag);
            assert!(decode_value(&map).is_err(), "tag 0x{tag:02x} in map");
        }
    }

    // ── order-preserving index-value encoding (Priority 5) ─────────────────

    #[test]
    fn order_encoding_preserves_semantic_order() {
        use std::cmp::Ordering;
        // int64: MIN < negative < zero < positive < MAX (sign-flip).
        let ints = [i64::MIN, -5, -1, 0, 1, 7, i64::MAX];
        for w in ints.windows(2) {
            let a = order_encode_value(&RowValue::Int64(w[0]));
            let b = order_encode_value(&RowValue::Int64(w[1]));
            assert_eq!(a.cmp(&b), Ordering::Less, "int64 {} < {}", w[0], w[1]);
        }
        // f64 total order: -inf < -1.5 < -0.0 < 0.0 < 1.5 < inf < NaN.
        let floats = [f64::NEG_INFINITY, -1.5, -0.0, 0.0, 1.5, f64::INFINITY, f64::NAN];
        for w in floats.windows(2) {
            let a = order_encode_value(&RowValue::F64(w[0]));
            let b = order_encode_value(&RowValue::F64(w[1]));
            assert_eq!(a.cmp(&b), Ordering::Less, "f64 total order");
        }
        // strings: empty < a < aa < ab < b < b<NUL> < b<NUL>c < c.
        let strings = ["", "a", "aa", "ab", "b", "b\u{0}", "b\u{0}c", "c"];
        for w in strings.windows(2) {
            let a = order_encode_value(&RowValue::String(w[0].into()));
            let b = order_encode_value(&RowValue::String(w[1].into()));
            assert_eq!(a.cmp(&b), Ordering::Less, "string {:?} < {:?}", w[0], w[1]);
        }
        // bytes use the same scheme.
        let bytes = [
            vec![],
            vec![0x00],
            vec![0x00, 0x01],
            vec![0x01],
            vec![0xff],
            vec![0xff, 0x00],
        ];
        for w in bytes.windows(2) {
            let a = order_encode_value(&RowValue::Bytes(w[0].clone()));
            let b = order_encode_value(&RowValue::Bytes(w[1].clone()));
            assert_eq!(a.cmp(&b), Ordering::Less, "bytes {:?} < {:?}", w[0], w[1]);
        }
        // bool: false < true; null sorts before everything.
        assert!(
            order_encode_value(&RowValue::Bool(false)) < order_encode_value(&RowValue::Bool(true))
        );
        assert!(order_encode_value(&RowValue::Null) < order_encode_value(&RowValue::Int64(i64::MIN)));
        // datetime orders like int64.
        assert!(order_encode_value(&RowValue::DateTime(-3)) < order_encode_value(&RowValue::DateTime(0)));
        // bigint sign-flip.
        assert!(order_encode_value(&RowValue::BigInt(-100)) < order_encode_value(&RowValue::BigInt(0)));
        assert!(order_encode_value(&RowValue::BigInt(0)) < order_encode_value(&RowValue::BigInt(100)));
    }

    #[test]
    fn ordered_element_round_trips_through_decode() {
        let values = [
            RowValue::Null,
            RowValue::Bool(false),
            RowValue::Bool(true),
            RowValue::Int64(-42),
            RowValue::Int64(0),
            RowValue::Int64(i64::MAX),
            RowValue::DateTime(123456789),
            RowValue::BigInt(-1000000000000000000000i128),
            RowValue::F64(3.25),
            RowValue::String("héllo".into()),
            RowValue::String("\u{0}embedded".into()),
            RowValue::Bytes(vec![0, 255, 1]),
        ];
        for value in values {
            let element = ordered_index_element(&value);
            assert_eq!(element[0], TAG_ORDERED, "{value:?}");
            let decoded = decode_value(&element).unwrap();
            match (&decoded, &value) {
                (RowValue::F64(d), RowValue::F64(v)) => {
                    assert_eq!(d.total_cmp(v), std::cmp::Ordering::Equal, "{value:?}");
                }
                _ => assert_eq!(decoded, value, "{value:?}"),
            }
            // skip_value must advance exactly the element length.
            let mut reader = ValueReader::new(&element);
            skip_value(&mut reader).unwrap();
            assert_eq!(reader.remaining(), 0);
        }
    }

    #[test]
    fn ordered_string_prefix_is_a_contiguous_exact_range() {
        // All strings starting with "ab" share the byte prefix
        // [ORD_STRING] + enc("ab") WITHOUT the terminator; the successor of
        // that prefix captures exactly those strings and nothing else.
        let mut prefix = vec![ORD_STRING];
        push_ord_string(&mut prefix, b"ab");
        prefix.truncate(prefix.len() - 2); // drop the 00 00 terminator
        let mut end = prefix.clone();
        let last = end.pop().unwrap();
        end.push(last + 1);

        let in_range = ["ab", "abc", "ab\u{0}z"];
        for s in in_range {
            let enc = order_encode_value(&RowValue::String(s.into()));
            assert!(prefix <= enc && enc < end, "{s:?} must be in the range");
        }
        let out_of_range = ["a", "ac", "b", "", "aa"];
        for s in out_of_range {
            let enc = order_encode_value(&RowValue::String(s.into()));
            assert!(!(prefix <= enc && enc < end), "{s:?} must NOT be in the range");
        }
    }

    #[test]
    fn order_encode_slice_matches_value_encoding() {
        let values = [
            RowValue::Null,
            RowValue::Bool(true),
            RowValue::Int64(-3),
            RowValue::Int64(9),
            RowValue::F64(2.5),
            RowValue::DateTime(5),
            RowValue::BigInt(-7),
            RowValue::String("abc".into()),
            RowValue::Bytes(vec![0, 9]),
        ];
        for value in values {
            let raw = encode_value(&value);
            assert_eq!(
                order_encode_slice(&raw).unwrap(),
                order_encode_value(&value),
                "{value:?}"
            );
        }
    }

    #[test]
    fn truncation_sweep_never_panics_or_loops() {
        // Build a deeply structured value (map of list of maps of scalars)
        // and truncate at every byte offset; decode must return Ok or a typed
        // DecodeError, never panic, hang, or overrun.
        let blob = vec![TAG_BYTES, 0, 0, 0, 3, 1, 2, 3];
        let inner = vec![TAG_LIST, 0, 0, 0, 2, TAG_INT64, 0, 0, 0, 0, 0, 0, 0, 5, TAG_BOOL, 1];
        let mut map = vec![TAG_MAP, 0, 0, 0, 2];
        map.extend(encode_string("a"));
        map.extend_from_slice(&blob);
        map.extend(encode_string("b"));
        map.extend_from_slice(&inner);
        let bytes = map;
        for cut in 0..bytes.len() {
            let result = decode_value(&bytes[..cut]);
            match result {
                Ok(_) => {}
                Err(error) =>
                    assert!(error.0.contains("end of input") || error.0.contains("Needed")),
            }
        }
        // Full input decodes fine.
        assert!(decode_value(&bytes).is_ok());
    }

    #[test]
    fn hostile_list_count_is_bounded_by_remaining_bytes() {
        // A list tag with count = u32::MAX but almost no payload must not try
        // to pre-allocate ~2^32 elements (a multi-GB Vec) before failing; it
        // must return a typed DecodeError promptly.
        let bytes = vec![TAG_LIST, 0xff, 0xff, 0xff, 0xff, TAG_INT64];
        let err = decode_value(&bytes).unwrap_err();
        assert!(err.0.contains("end of input") || err.0.contains("Needed"));
    }

    #[test]
    fn hostile_map_count_is_bounded_by_remaining_bytes() {
        let bytes = vec![TAG_MAP, 0xff, 0xff, 0xff, 0xff, TAG_NULL, TAG_NULL];
        let err = decode_value(&bytes).unwrap_err();
        assert!(err.0.contains("end of input") || err.0.contains("Needed"));
    }

    #[test]
    fn skip_value_skips_exactly_the_right_payloads() {
        // bool skips exactly 1 payload byte.
        let mut r = ValueReader::new(&[TAG_BOOL, 1, TAG_NULL]);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), 2);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), 3);
        // int64 skips 8.
        let int64_bytes = vec![TAG_INT64, 0, 0, 0, 0, 0, 0, 0, 0, TAG_NULL];
        let mut r = ValueReader::new(&int64_bytes);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), 9);
        // bigint skips 16.
        let bigint_bytes = vec![
            TAG_BIGINT,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            TAG_NULL
        ];
        let mut r = ValueReader::new(&bigint_bytes);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), 17);
        // string skips length prefix + bytes.
        let s = vec![TAG_STRING, 0, 0, 0, 3, b'a', b'b', b'c', TAG_NULL];
        let mut r = ValueReader::new(&s);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), 8);
        // list skips count + elements (tag 1 + count 4 + null 1 + bool 2 = 8).
        let l = vec![TAG_LIST, 0, 0, 0, 2, TAG_NULL, TAG_BOOL, 1, TAG_NULL];
        let mut r = ValueReader::new(&l);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), 8);
        // map skips count + key/value pairs.
        let mut m = vec![TAG_MAP, 0, 0, 0, 1];
        m.extend(encode_string("k"));
        let mut int64_payload = vec![TAG_INT64, 0, 0, 0, 0, 0, 0, 0, 0];
        m.append(&mut int64_payload);
        m.push(TAG_NULL);
        let mut r = ValueReader::new(&m);
        skip_value(&mut r).unwrap();
        assert_eq!(r.position(), m.len() - 1);
        // Truncated string skip errors, does not panic.
        let mut r = ValueReader::new(&[TAG_STRING, 0, 0, 0, 5, b'a']);
        assert!(skip_value(&mut r).is_err());
        let _ = s;
    }

    #[test]
    fn finish_rejects_trailing_bytes() {
        let mut bytes = encode_int64(7);
        bytes.push(TAG_NULL);
        let err = decode_value(&bytes).unwrap_err();
        assert!(err.0.contains("Trailing bytes"));
        // A nested read (read_value twice) advances past the first value.
        let mut r = ValueReader::new(&[TAG_NULL, TAG_NULL]);
        assert_eq!(r.read_value().unwrap(), RowValue::Null);
        assert_eq!(r.read_value().unwrap(), RowValue::Null);
    }

    #[test]
    fn find_field_duplicate_name_first_wins() {
        // Two entries with the same key; find_field returns the FIRST.
        let row = encode_map(
            &[
                ("dup".into(), encode_int64(1)),
                ("dup".into(), encode_int64(2)),
            ]
        );
        let found = find_field(&row, "dup").unwrap();
        assert_eq!(found, Some(RowValue::Int64(1)));
        let range = find_field_bytes(&row, "dup").unwrap().unwrap();
        assert_eq!(decode_value(range).unwrap(), RowValue::Int64(1));
        let full = decode_value(&row).unwrap();
        assert_eq!(full.find_field("dup"), Some(&RowValue::Int64(1)));
    }

    // ── compare / equals semantics ─────────────────────────────────────────

    #[test]
    fn compare_cross_type_uses_type_rank_not_numeric() {
        use std::cmp::Ordering;
        // Int64 always < F64 regardless of numeric magnitude (type-rank).
        assert_eq!(RowValue::Int64(5).compare(&RowValue::F64(5.0)), Ordering::Less);
        assert_eq!(RowValue::Int64(i64::MAX).compare(&RowValue::F64(-1e300)), Ordering::Less);
        // Int64 vs BigInt compares numerically (special-cased in `compare`),
        // so equal values are Equal; BigInt vs F64 falls back to type-rank.
        assert_eq!(RowValue::Int64(0).compare(&RowValue::BigInt(0)), Ordering::Equal);
        assert_eq!(RowValue::Int64(1).compare(&RowValue::BigInt(0)), Ordering::Greater);
        assert_eq!(RowValue::BigInt(0).compare(&RowValue::F64(0.0)), Ordering::Less);
        // Within the same variant, natural ordering.
        assert_eq!(RowValue::Int64(1).compare(&RowValue::Int64(2)), Ordering::Less);
        // Cross-type string compare falls back to type-rank, not content.
        assert_eq!(RowValue::String("zzz".into()).compare(&RowValue::Int64(1)), Ordering::Greater);
        // DateTime vs Int64: type-rank puts DateTime after numbers.
        assert_eq!(RowValue::DateTime(0).compare(&RowValue::Int64(0)), Ordering::Greater);
    }

    #[test]
    fn equals_is_type_strict_across_numeric_variants() {
        // `Int64(5) != F64(5.0) != BigInt(5)` — equality is type-strict, unlike
        // sort_compare's numeric comparison.
        assert!(!RowValue::Int64(5).equals(&RowValue::F64(5.0)));
        assert!(!RowValue::Int64(5).equals(&RowValue::BigInt(5)));
        assert!(!RowValue::F64(5.0).equals(&RowValue::BigInt(5)));
        assert!(RowValue::Int64(5).equals(&RowValue::Int64(5)));
        assert!(RowValue::F64(5.0).equals(&RowValue::F64(5.0)));
        // bool != int.
        assert!(!RowValue::Bool(true).equals(&RowValue::Int64(1)));
        // null == null, null != 0.
        assert!(RowValue::Null.equals(&RowValue::Null));
        assert!(!RowValue::Null.equals(&RowValue::Int64(0)));
    }

    #[test]
    fn deep_equals_maps_are_order_independent() {
        let a = RowValue::Map(
            vec![
                (RowValue::String("x".into()), RowValue::Int64(1)),
                (RowValue::String("y".into()), RowValue::Int64(2))
            ]
        );
        let b = RowValue::Map(
            vec![
                (RowValue::String("y".into()), RowValue::Int64(2)),
                (RowValue::String("x".into()), RowValue::Int64(1))
            ]
        );
        assert!(a.deep_equals(&b), "map equality must ignore key order");
        assert!(a.equals(&b));
        // Different values / sizes are not equal.
        let c = RowValue::Map(
            vec![
                (RowValue::String("x".into()), RowValue::Int64(1)),
                (RowValue::String("y".into()), RowValue::Int64(3))
            ]
        );
        assert!(!a.deep_equals(&c));
        let d = RowValue::Map(vec![(RowValue::String("x".into()), RowValue::Int64(1))]);
        assert!(!a.deep_equals(&d));
        // Nested maps are compared order-independently too.
        let nested_a = RowValue::Map(
            vec![(
                RowValue::String("inner".into()),
                RowValue::Map(
                    vec![
                        (RowValue::String("p".into()), RowValue::Bool(true)),
                        (RowValue::String("q".into()), RowValue::Null)
                    ]
                ),
            )]
        );
        let nested_b = RowValue::Map(
            vec![(
                RowValue::String("inner".into()),
                RowValue::Map(
                    vec![
                        (RowValue::String("q".into()), RowValue::Null),
                        (RowValue::String("p".into()), RowValue::Bool(true))
                    ]
                ),
            )]
        );
        assert!(nested_a.deep_equals(&nested_b));
    }

    #[test]
    fn deep_equals_lists_are_element_wise() {
        let a = RowValue::List(vec![RowValue::Int64(1), RowValue::Null]);
        let b = RowValue::List(vec![RowValue::Int64(1), RowValue::Null]);
        assert!(a.deep_equals(&b));
        let c = RowValue::List(vec![RowValue::Null, RowValue::Int64(1)]);
        assert!(!a.deep_equals(&c), "list order matters");
    }
}
