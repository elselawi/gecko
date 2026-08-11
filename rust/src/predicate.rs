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

use crate::value_codec::{ self, RowValue, ValueReader };
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
            _ => {
                return None;
            }
        })
    }
}

#[derive(Debug, Clone)]
pub enum Filter {
    /// field == value (structural deep equality, like Dart `Filter._deepEquals`).
    Equals {
        field: String,
        value: RowValue,
    },
    /// min <= field <= max (bounds optional, like Dart `Filter.between`).
    Range {
        field: String,
        min: Option<RowValue>,
        max: Option<RowValue>,
    },
    /// field is a String starting with prefix (like Dart `Filter.prefix`).
    Prefix {
        field: String,
        prefix: String,
    },
}

impl Filter {
    /// Evaluates this filter against one row's encoded bytes, decoding ONLY
    /// the field it references (via [value_codec::find_field]). Non-matching
    /// rows never pay for decoding fields the predicate doesn't reference.
    pub fn test_bytes(&self, row_bytes: &[u8]) -> bool {
        match self {
            Filter::Equals { field, value } =>
                match value_codec::find_field(row_bytes, field) {
                    Ok(Some(found)) => found.equals(value),
                    _ => false,
                }
            Filter::Range { field, min, max } =>
                match value_codec::find_field(row_bytes, field) {
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
                }
            Filter::Prefix { field, prefix } =>
                match value_codec::find_field(row_bytes, field) {
                    Ok(Some(RowValue::String(s))) => s.starts_with(prefix.as_str()),
                    _ => false,
                }
        }
    }

    /// Evaluates using pre-extracted field bytes. The bytes are decoded only
    /// for the filter currently being evaluated, preserving filter order and
    /// short-circuit behavior while allowing a caller to scan a row once.
    pub fn test_bytes_from_ranges(
        &self,
        row_bytes: &[u8],
        ranges: &[Option<(usize, usize)>],
    ) -> bool {
        let Some(range) = ranges.first().copied().flatten() else {
            return false;
        };
        let value = match value_codec::decode_value(&row_bytes[range.0..range.1]) {
            Ok(value) => value,
            Err(_) => return false,
        };
        match self {
            Filter::Equals { value: target, .. } => value.equals(target),
            Filter::Range { min, max, .. } => {
                if let Some(mn) = min {
                    if value.compare(mn) == std::cmp::Ordering::Less {
                        return false;
                    }
                }
                if let Some(mx) = max {
                    if value.compare(mx) == std::cmp::Ordering::Greater {
                        return false;
                    }
                }
                true
            }
            Filter::Prefix { prefix, .. } => match value {
                RowValue::String(found) => found.starts_with(prefix),
                _ => false,
            },
        }
    }

    /// The field this filter references (used for index-usability analysis).
    pub fn field(&self) -> &str {
        match self {
            | Filter::Equals { field, .. }
            | Filter::Range { field, .. }
            | Filter::Prefix { field, .. } => field,
        }
    }
}

/// An AND-composed predicate.
#[derive(Debug, Clone)]
pub struct Predicate {
    pub filters: Vec<Filter>,
    fields: Vec<String>,
    filter_slots: Vec<usize>,
}

/// Reusable per-query storage for the encoded ranges referenced by a compiled
/// [Predicate]. The worker creates one scratch value per operation and reuses
/// it for every row, so predicate evaluation does not allocate field state per
/// row.
#[derive(Debug, Clone)]
pub struct PredicateScratch {
    ranges: Vec<Option<(usize, usize)>>,
}

impl Predicate {
    fn new(filters: Vec<Filter>) -> Self {
        let mut fields = Vec::<String>::new();
        let mut filter_slots = Vec::with_capacity(filters.len());
        for filter in &filters {
            let field = filter.field();
            let slot = fields
                .iter()
                .position(|candidate| candidate == field)
                .unwrap_or_else(|| {
                    fields.push(field.to_owned());
                    fields.len() - 1
                });
            filter_slots.push(slot);
        }
        Self {
            filters,
            fields,
            filter_slots,
        }
    }

    pub fn scratch(&self) -> PredicateScratch {
        PredicateScratch {
            ranges: vec![None; self.fields.len()],
        }
    }

    /// True iff every filter matches the row's encoded bytes. An empty
    /// predicate matches everything (matches Dart's `FilterGroup`).
    pub fn test_bytes(&self, row_bytes: &[u8]) -> bool {
        self.filters.iter().all(|f| f.test_bytes(row_bytes))
    }

    /// True iff every filter matches using ranges collected from one row walk.
    pub fn test_bytes_from_ranges(
        &self,
        row_bytes: &[u8],
        ranges: &[Option<(usize, usize)>],
    ) -> bool {
        if self.filters.is_empty() {
            return true;
        }
        self.filters
            .iter()
            .enumerate()
            .all(|(index, filter)| filter.test_bytes_from_ranges(row_bytes, &ranges[index..=index]))
    }

    /// Tests a row using a reusable scratch buffer. The field-name plan is
    /// compiled once when the wire predicate is decoded.
    pub fn test_bytes_with_scratch(
        &self,
        row_bytes: &[u8],
        scratch: &mut PredicateScratch,
    ) -> bool {
        if self.filters.is_empty() {
            return true;
        }
        if value_codec::find_fields_ranges(row_bytes, &self.fields, &mut scratch.ranges).is_err() {
            return false;
        }
        self.filters.iter().enumerate().all(|(index, filter)| {
            let slot = self.filter_slots[index];
            filter.test_bytes_from_ranges(row_bytes, &scratch.ranges[slot..=slot])
        })
    }

    pub fn test_bytes_single_pass(&self, row_bytes: &[u8]) -> bool {
        let mut scratch = self.scratch();
        self.test_bytes_with_scratch(row_bytes, &mut scratch)
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
        return Err(
            WireError(
                format!(
                    "Unsupported predicate wire version {version} (expected {PREDICATE_WIRE_VERSION})"
                )
            )
        );
    }
    let count = r.read_varint()? as usize;
    // Each filter is at least two bytes (an op byte + an empty field string),
    // so the remaining input bounds how many filters can possibly be present.
    // Capping the pre-allocation prevents a hostile count (up to u64::MAX)
    // from requesting a giant allocation before the bounds checks fail.
    let cap = (count as usize).min(r.remaining() / 2);
    let mut filters = Vec::with_capacity(cap);
    for _ in 0..count {
        let op = PredicateOp::from_u8(r.read_u8()?).ok_or_else(||
            WireError("Unknown predicate op".into())
        )?;
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
    Ok(Predicate::new(filters))
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
        let b = *self.bytes
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
            if (b & 0x80) == 0 {
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
        let s = std::str
            ::from_utf8(&self.bytes[self.pos..self.pos + len])
            .map_err(|_| WireError("Invalid UTF-8 in predicate".into()))?;
        self.pos += len;
        Ok(s.to_string())
    }

    /// Reads one full encoded RowValue (the codec bytes) by decoding it. The
    /// value's bytes are self-delimiting under the codec, so this advances the
    /// cursor to the next filter boundary.
    fn read_value(&mut self) -> Result<RowValue> {
        let mut vr = ValueReader::new(&self.bytes[self.pos..]);
        let v = vr.read_value().map_err(|e| WireError(format!("predicate value decode: {e}")))?;
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
        out.extend_from_slice(&(1u32).to_be_bytes());
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
        let pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Equals {
                        field: "age".into(),
                        value: RowValue::Int64(31),
                    },
                ]
            )
        ).unwrap();
        assert!(pred.test_bytes(&row("age", &int64(31))));
        assert!(!pred.test_bytes(&row("age", &int64(30))));
        // Missing field → no match.
        assert!(!pred.test_bytes(&row("other", &int64(31))));
    }

    #[test]
    fn range_filter_respects_bounds() {
        let pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Range {
                        field: "age".into(),
                        min: Some(RowValue::Int64(20)),
                        max: Some(RowValue::Int64(25)),
                    },
                ]
            )
        ).unwrap();
        assert!(pred.test_bytes(&row("age", &int64(20))));
        assert!(pred.test_bytes(&row("age", &int64(23))));
        assert!(pred.test_bytes(&row("age", &int64(25))));
        assert!(!pred.test_bytes(&row("age", &int64(19))));
        assert!(!pred.test_bytes(&row("age", &int64(26))));
    }

    #[test]
    fn prefix_filter_matches_string_start() {
        let pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Prefix {
                        field: "name".into(),
                        prefix: "ab".into(),
                    },
                ]
            )
        ).unwrap();
        assert!(pred.test_bytes(&row("name", &string("abby"))));
        assert!(!pred.test_bytes(&row("name", &string("bob"))));
        // Non-string field value → no match.
        assert!(!pred.test_bytes(&row("name", &int64(0))));
    }

    #[test]
    fn and_composition_all_must_match() {
        let pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Equals {
                        field: "g".into(),
                        value: RowValue::String("g0".into()),
                    },
                    Filter::Range {
                        field: "n".into(),
                        min: Some(RowValue::Int64(10)),
                        max: None,
                    },
                ]
            )
        ).unwrap();
        // A two-field row.
        let mut r = vec![value_codec::TAG_MAP];
        r.extend_from_slice(&(2u32).to_be_bytes());
        // g = "g0"
        r.extend(string("g"));
        r.extend(string("g0"));
        // n = 11
        r.extend(string("n"));
        r.extend(int64(11));
        assert!(pred.test_bytes(&r));
        // n = 9 → should fail the range.
        let mut r2 = vec![value_codec::TAG_MAP];
        r2.extend_from_slice(&(2u32).to_be_bytes());
        r2.extend(string("g"));
        r2.extend(string("g0"));
        r2.extend(string("n"));
        r2.extend(int64(9));
        assert!(!pred.test_bytes(&r2));
    }

    fn f64(n: f64) -> Vec<u8> {
        let mut out = vec![value_codec::TAG_F64];
        out.extend_from_slice(&n.to_be_bytes());
        out
    }

    fn bigint(n: i128) -> Vec<u8> {
        let mut out = vec![value_codec::TAG_BIGINT];
        out.extend_from_slice(&n.to_be_bytes());
        out
    }

    fn write_field_str(out: &mut Vec<u8>, s: &str) {
        write_string(out, s);
    }

    /// Manually encodes an Equals predicate (needed for List/Map targets the
    /// test `write_value` encoder refuses).
    fn manual_equals(field: &str, value_bytes: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(PREDICATE_WIRE_VERSION);
        push_varint(&mut out, 1);
        out.push(PredicateOp::Equals as u8);
        write_field_str(&mut out, field);
        out.extend_from_slice(value_bytes);
        out
    }

    #[test]
    fn equals_is_type_strict_on_numeric_mismatch() {
        // Predicate target Int64(5) must NOT match a stored F64(5.0) or
        // BigInt(5) — equality is type-strict (matches the codec `equals`).
        let int_pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Equals {
                        field: "age".into(),
                        value: RowValue::Int64(5),
                    },
                ]
            )
        ).unwrap();
        assert!(int_pred.test_bytes(&row("age", &int64(5))));
        assert!(!int_pred.test_bytes(&row("age", &f64(5.0))));
        assert!(!int_pred.test_bytes(&row("age", &bigint(5))));
    }

    #[test]
    fn equals_is_structural_for_list_and_map_values() {
        // A map equality target: the stored value must be a map with the same
        // entries (order-independent).
        let mut target = vec![value_codec::TAG_MAP];
        target.extend_from_slice(&(2u32).to_be_bytes());
        target.extend(string("x"));
        target.extend(int64(1));
        target.extend(string("y"));
        target.extend(string("z"));
        let pred = decode_predicate(&manual_equals("cfg", &target)).unwrap();

        // Same map, reversed key order → matches (order-independent).
        let mut stored = vec![value_codec::TAG_MAP];
        stored.extend_from_slice(&(2u32).to_be_bytes());
        stored.extend(string("y"));
        stored.extend(string("z"));
        stored.extend(string("x"));
        stored.extend(int64(1));
        assert!(pred.test_bytes(&row("cfg", &stored)));
        // Different value → no match.
        let mut stored2 = vec![value_codec::TAG_MAP];
        stored2.extend_from_slice(&(1u32).to_be_bytes());
        stored2.extend(string("x"));
        stored2.extend(int64(2));
        assert!(!pred.test_bytes(&row("cfg", &stored2)));

        // A list equality target.
        let mut list_target = vec![value_codec::TAG_LIST];
        list_target.extend_from_slice(&(2u32).to_be_bytes());
        list_target.extend(int64(1));
        list_target.extend(string("a"));
        let list_pred = decode_predicate(&manual_equals("tags", &list_target)).unwrap();
        let mut stored_list = vec![value_codec::TAG_LIST];
        stored_list.extend_from_slice(&(2u32).to_be_bytes());
        stored_list.extend(int64(1));
        stored_list.extend(string("a"));
        assert!(list_pred.test_bytes(&row("tags", &stored_list)));
        // List order matters.
        let mut reversed = vec![value_codec::TAG_LIST];
        reversed.extend_from_slice(&(2u32).to_be_bytes());
        reversed.extend(string("a"));
        reversed.extend(int64(1));
        assert!(!list_pred.test_bytes(&row("tags", &reversed)));
    }

    #[test]
    fn range_with_min_greater_than_max_never_matches() {
        // min=10, max=5 — no value can satisfy both bounds.
        let pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Range {
                        field: "age".into(),
                        min: Some(RowValue::Int64(10)),
                        max: Some(RowValue::Int64(5)),
                    },
                ]
            )
        ).unwrap();
        assert!(!pred.test_bytes(&row("age", &int64(10))));
        assert!(!pred.test_bytes(&row("age", &int64(5))));
        assert!(!pred.test_bytes(&row("age", &int64(7))));
        // A missing field still fails.
        assert!(!pred.test_bytes(&row("other", &int64(7))));
    }

    #[test]
    fn cross_type_range_uses_type_rank_ordering() {
        // Range over an Int64 field with an F64 bound uses `compare`
        // (type-rank): an Int64 stored value is always < any F64 bound.
        let pred = decode_predicate(
            &encode_predicate(
                &[
                    Filter::Range {
                        field: "age".into(),
                        min: Some(RowValue::F64(-1e300)),
                        max: None,
                    },
                ]
            )
        ).unwrap();
        // Int64(0) type-ranks below F64, so it is NOT >= F64(-1e300) under
        // the type-rank comparator → no match.
        assert!(!pred.test_bytes(&row("age", &int64(0))));
        // The same stored value as F64 matches.
        assert!(pred.test_bytes(&row("age", &f64(-1e300))));
    }

    #[test]
    fn malformed_predicate_decode_is_a_typed_error() {
        // Bad version.
        assert!(decode_predicate(&[9, 0]).is_err());
        // Count over-claim: version + count=5 but no filters.
        assert!(decode_predicate(&[PREDICATE_WIRE_VERSION, 5]).is_err());
        // Truncated field (count=1, op=0, then nothing).
        assert!(decode_predicate(&[PREDICATE_WIRE_VERSION, 1, 0]).is_err());
        // Trailing garbage.
        let mut good = encode_predicate(
            &[
                Filter::Equals {
                    field: "a".into(),
                    value: RowValue::Int64(1),
                },
            ]
        );
        good.push(0xaa);
        assert!(decode_predicate(&good).is_err());
        // Invalid UTF-8 in a field name.
        let mut bad = vec![PREDICATE_WIRE_VERSION, 1, 0, 1, 0xff];
        // value bytes for the equals target (int64 1)
        bad.extend_from_slice(&int64(1));
        let err = decode_predicate(&bad).unwrap_err();
        assert!(err.0.contains("UTF-8"), "got: {err:?}");
        // Unknown op byte.
        let unknown = vec![PREDICATE_WIRE_VERSION, 1, 99];
        assert!(decode_predicate(&unknown).is_err());
    }

    #[test]
    fn range_has_min_max_any_nonzero_byte_is_true() {
        // Non-canonical presence bytes (0x02) must be treated as present.
        let mut bytes = vec![PREDICATE_WIRE_VERSION, 1, PredicateOp::Range as u8];
        write_string(&mut bytes, "age");
        bytes.push(0x02); // has_min (non-canonical)
        bytes.extend_from_slice(&int64(1));
        bytes.push(0x02); // has_max (non-canonical)
        bytes.extend_from_slice(&int64(10));
        let pred = decode_predicate(&bytes).unwrap();
        assert!(pred.test_bytes(&row("age", &int64(5))));
        assert!(!pred.test_bytes(&row("age", &int64(0))));
        assert!(!pred.test_bytes(&row("age", &int64(11))));
    }
}
