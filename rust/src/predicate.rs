//! Predicate wire format + evaluator (step 2).
//!
//! A predicate is an AND-composed list of field filters that Rust evaluates
//! against a row's encoded bytes WITHOUT round-tripping the row back to Dart.
//! This is the "push the predicate down" half of the native query fast path:
//! an unindexed full scan returns only the matching `(id, row)` pairs in one
//! FRB hop, so non-matching rows are never decoded in Dart.
//!
//! The predicate is serialized by the Dart query engine
//! (`QueryImpl._encodePredicate`) and deserialized here. The format mirrors
//! the `Op` batch wire style (version-prefixed, uvarint counts, length-prefixed
//! strings) so it shares the `wire::Reader` discipline:
//!
//!   version : u8                                  (= 1)
//!   count   : uvarint
//!   per filter:
//!     op      : u8   (0 = eq, 1 = range, 2 = prefix)
//!     field   : string (uvarint len + UTF-8)
//!     eq      → value : a full encoded RowValue (the codec bytes)
//!     range   → hasMin:u8, [min: RowValue bytes if hasMin],
//!               hasMax:u8, [max: RowValue bytes if hasMax]
//!     prefix  → prefix : string

use crate::value_codec::{self, RowValue, ValueReader};
use crate::wire::WireError;

#[cfg(test)]
use crate::value_codec::TAG_STRING;
#[cfg(test)]
use crate::wire::push_varint;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum PredicateOp {
    Equals = 0,
    Range = 1,
    Prefix = 2,
}

impl PredicateOp {
    fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => PredicateOp::Equals,
            1 => PredicateOp::Range,
            2 => PredicateOp::Prefix,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone)]
pub enum Filter {
    /// field == value (structural deep equality, like Dart `Filter._deepEquals`).
    Equals { field: String, value: RowValue },
    /// min <= field <= max (bounds optional, like Dart `Filter.between`).
    Range {
        field: String,
        min: Option<RowValue>,
        max: Option<RowValue>,
    },
    /// field is a String starting with prefix (like Dart `Filter.prefix`).
    Prefix { field: String, prefix: String },
}

impl Filter {
    /// Evaluates this filter against one row's encoded bytes, decoding ONLY
    /// the field it references (via [value_codec::find_field]). Non-matching
    /// rows never pay for decoding fields the predicate doesn't reference.
    pub fn test_bytes(&self, row_bytes: &[u8]) -> bool {
        match self {
            Filter::Equals { field, value } => match value_codec::find_field(row_bytes, field) {
                Ok(Some(found)) => found.equals(value),
                _ => false,
            },
            Filter::Range { field, min, max } => match value_codec::find_field(row_bytes, field) {
                Ok(Some(found)) => {
                    if let Some(mn) = min {
                        if found.compare(mn) == std::cmp::Ordering::Less {
                            return false;
                        }
                    }
                    if let Some(mx) = max {
                        if found.compare(mx) == std::cmp::Ordering::Greater {
                            return false;
                        }
                    }
                    true
                }
                _ => false,
            },
            Filter::Prefix { field, prefix } => match value_codec::find_field(row_bytes, field) {
                Ok(Some(RowValue::String(s))) => s.starts_with(prefix.as_str()),
                _ => false,
            },
        }
    }

    /// The field this filter references (used for index-usability analysis).
    pub fn field(&self) -> &str {
        match self {
            Filter::Equals { field, .. }
            | Filter::Range { field, .. }
            | Filter::Prefix { field, .. } => field,
        }
    }
}

/// An AND-composed predicate.
#[derive(Debug, Clone, Default)]
pub struct Predicate {
    pub filters: Vec<Filter>,
}

impl Predicate {
    /// True iff every filter matches the row's encoded bytes. An empty
    /// predicate matches everything (matches Dart's `FilterGroup`).
    pub fn test_bytes(&self, row_bytes: &[u8]) -> bool {
        self.filters.iter().all(|f| f.test_bytes(row_bytes))
    }

    pub fn is_empty(&self) -> bool {
        self.filters.is_empty()
    }
}

pub const PREDICATE_WIRE_VERSION: u8 = 1;

type Result<T> = std::result::Result<T, WireError>;

/// Decodes a predicate from the Dart-serialized bytes.
pub fn decode_predicate(bytes: &[u8]) -> Result<Predicate> {
    let mut r = PredicateReader::new(bytes);
    let version = r.read_u8()?;
    if version != PREDICATE_WIRE_VERSION {
        return Err(WireError(format!(
            "Unsupported predicate wire version {version} (expected {PREDICATE_WIRE_VERSION})"
        )));
    }
    let count = r.read_varint()? as usize;
    let mut filters = Vec::with_capacity(count);
    for _ in 0..count {
        let op = PredicateOp::from_u8(r.read_u8()?)
            .ok_or_else(|| WireError("Unknown predicate op".into()))?;
        let field = r.read_string()?;
        let filter = match op {
            PredicateOp::Equals => {
                let value = r.read_value()?;
                Filter::Equals { field, value }
            }
            PredicateOp::Range => {
                let has_min = r.read_u8()? != 0;
                let min = if has_min { Some(r.read_value()?) } else { None };
                let has_max = r.read_u8()? != 0;
                let max = if has_max { Some(r.read_value()?) } else { None };
                Filter::Range { field, min, max }
            }
            PredicateOp::Prefix => {
                let prefix = r.read_string()?;
                Filter::Prefix { field, prefix }
            }
        };
        filters.push(filter);
    }
    if r.remaining() != 0 {
        return Err(WireError("Trailing bytes after predicate".into()));
    }
    Ok(Predicate { filters })
}

struct PredicateReader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> PredicateReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        PredicateReader { bytes, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.bytes.len() - self.pos
    }

    fn read_u8(&mut self) -> Result<u8> {
        let b = *self
            .bytes
            .get(self.pos)
            .ok_or_else(|| WireError("Unexpected end of predicate".into()))?;
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
                return Err(WireError("Predicate varint overflow".into()));
            }
        }
        Ok(value)
    }

    fn read_string(&mut self) -> Result<String> {
        let len = self.read_varint()? as usize;
        if len > self.remaining() {
            return Err(WireError("Predicate string length out of range".into()));
        }
        let s = std::str::from_utf8(&self.bytes[self.pos..self.pos + len])
            .map_err(|_| WireError("Invalid UTF-8 in predicate".into()))?;
        self.pos += len;
        Ok(s.to_string())
    }

    /// Reads one full encoded RowValue (the codec bytes) by decoding it. The
    /// value's bytes are self-delimiting under the codec, so this advances the
    /// cursor to the next filter boundary.
    fn read_value(&mut self) -> Result<RowValue> {
        let mut vr = ValueReader::new(&self.bytes[self.pos..]);
        let v = vr
            .read_value()
            .map_err(|e| WireError(format!("predicate value decode: {e}")))?;
        // Advance the outer cursor past the consumed value bytes.
        self.pos += self.bytes.len().saturating_sub(self.pos) - vr.remaining();
        Ok(v)
    }
}

/// Encodes a predicate (used by the unit tests; the Dart side is the real
/// encoder). Kept here so the format is documented on both sides and a
/// round-trip test can lock it.
#[cfg(test)]
pub(crate) fn encode_predicate(filters: &[Filter]) -> Vec<u8> {
    let mut out = Vec::new();
    out.push(PREDICATE_WIRE_VERSION);
    push_varint(&mut out, filters.len() as u64);
    for f in filters {
        match f {
            Filter::Equals { field, value } => {
                out.push(PredicateOp::Equals as u8);
                write_string(&mut out, field);
                write_value(&mut out, value);
            }
            Filter::Range { field, min, max } => {
                out.push(PredicateOp::Range as u8);
                write_string(&mut out, field);
                out.push(if min.is_some() { 1 } else { 0 });
                if let Some(mn) = min {
                    write_value(&mut out, mn);
                }
                out.push(if max.is_some() { 1 } else { 0 });
                if let Some(mx) = max {
                    write_value(&mut out, mx);
                }
            }
            Filter::Prefix { field, prefix } => {
                out.push(PredicateOp::Prefix as u8);
                write_string(&mut out, field);
                write_string(&mut out, prefix);
            }
        }
    }
    out
}

#[cfg(test)]
fn write_string(out: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    push_varint(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

#[cfg(test)]
fn write_value(out: &mut Vec<u8>, v: &RowValue) {
    // Minimal encoder for the test fixtures; mirrors the Dart codec for the
    // scalar types a predicate is likely to target.
    use RowValue::*;
    match v {
        Null => out.push(value_codec::TAG_NULL),
        Bool(b) => {
            out.push(value_codec::TAG_BOOL);
            out.push(if *b { 1 } else { 0 });
        }
        Int64(n) => {
            out.push(value_codec::TAG_INT64);
            out.extend_from_slice(&n.to_be_bytes());
        }
        F64(d) => {
            out.push(value_codec::TAG_F64);
            out.extend_from_slice(&d.to_be_bytes());
        }
        String(s) => {
            out.push(TAG_STRING);
            let bytes = s.as_bytes();
            out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
            out.extend_from_slice(bytes);
        }
        _ => panic!("test encoder only handles scalar predicate values"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(field: &str, value_bytes: &[u8]) -> Vec<u8> {
        // Minimal row map encoder for fixtures: 0x07 | u32(1) | <field string> | <value>
        let mut out = vec![value_codec::TAG_MAP];
        out.extend_from_slice(&1u32.to_be_bytes());
        // key (string)
        out.push(TAG_STRING);
        let fb = field.as_bytes();
        out.extend_from_slice(&(fb.len() as u32).to_be_bytes());
        out.extend_from_slice(fb);
        // value
        out.extend_from_slice(value_bytes);
        out
    }

    fn int64(n: i64) -> Vec<u8> {
        let mut out = vec![value_codec::TAG_INT64];
        out.extend_from_slice(&n.to_be_bytes());
        out
    }

    fn string(s: &str) -> Vec<u8> {
        let mut out = vec![TAG_STRING];
        let bytes = s.as_bytes();
        out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        out.extend_from_slice(bytes);
        out
    }

    #[test]
    fn empty_predicate_matches_everything() {
        let pred = decode_predicate(&encode_predicate(&[])).unwrap();
        assert!(pred.is_empty());
        assert!(pred.test_bytes(&row("x", &int64(1))));
    }

    #[test]
    fn equality_filter_matches_only_equal() {
        let pred = decode_predicate(&encode_predicate(&[Filter::Equals {
            field: "age".into(),
            value: RowValue::Int64(31),
        }]))
        .unwrap();
        assert!(pred.test_bytes(&row("age", &int64(31))));
        assert!(!pred.test_bytes(&row("age", &int64(30))));
        // Missing field → no match.
        assert!(!pred.test_bytes(&row("other", &int64(31))));
    }

    #[test]
    fn range_filter_respects_bounds() {
        let pred = decode_predicate(&encode_predicate(&[Filter::Range {
            field: "age".into(),
            min: Some(RowValue::Int64(20)),
            max: Some(RowValue::Int64(25)),
        }]))
        .unwrap();
        assert!(pred.test_bytes(&row("age", &int64(20))));
        assert!(pred.test_bytes(&row("age", &int64(23))));
        assert!(pred.test_bytes(&row("age", &int64(25))));
        assert!(!pred.test_bytes(&row("age", &int64(19))));
        assert!(!pred.test_bytes(&row("age", &int64(26))));
    }

    #[test]
    fn prefix_filter_matches_string_start() {
        let pred = decode_predicate(&encode_predicate(&[Filter::Prefix {
            field: "name".into(),
            prefix: "ab".into(),
        }]))
        .unwrap();
        assert!(pred.test_bytes(&row("name", &string("abby"))));
        assert!(!pred.test_bytes(&row("name", &string("bob"))));
        // Non-string field value → no match.
        assert!(!pred.test_bytes(&row("name", &int64(0))));
    }

    #[test]
    fn and_composition_all_must_match() {
        let pred = decode_predicate(&encode_predicate(&[
            Filter::Equals {
                field: "g".into(),
                value: RowValue::String("g0".into()),
            },
            Filter::Range {
                field: "n".into(),
                min: Some(RowValue::Int64(10)),
                max: None,
            },
        ]))
        .unwrap();
        // A two-field row.
        let mut r = vec![value_codec::TAG_MAP];
        r.extend_from_slice(&2u32.to_be_bytes());
        // g = "g0"
        r.extend(string("g"));
        r.extend(string("g0"));
        // n = 11
        r.extend(string("n"));
        r.extend(int64(11));
        assert!(pred.test_bytes(&r));
        // n = 9 → should fail the range.
        let mut r2 = vec![value_codec::TAG_MAP];
        r2.extend_from_slice(&2u32.to_be_bytes());
        r2.extend(string("g"));
        r2.extend(string("g0"));
        r2.extend(string("n"));
        r2.extend(int64(9));
        assert!(!pred.test_bytes(&r2));
    }
}
