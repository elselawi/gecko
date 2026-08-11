//! Sort-spec wire format + comparator 
//!
//! The Dart query engine serializes its sort specs (`Query.sort(List<SortSpec>)`)
//! into a version-prefixed payload that Rust decodes here, so an `ORDER BY`
//! query can sort (or stream in index order) entirely in Rust. The format
//! mirrors the `Op`/predicate wire style:
//!
//!   version  : u8        (= 1)
//!   count    : uvarint
//!   per spec : field : string (uvarint len + UTF-8), descending : u8 (0/1)

use crate::value_codec::{self, RowValue};

pub const SORT_SPEC_WIRE_VERSION: u8 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct SortSpec {
    pub field: String,
    pub descending: bool,
}

#[derive(Debug, Clone, Default)]
pub struct SortSpecs {
    pub specs: Vec<SortSpec>,
}

impl SortSpecs {
    pub fn is_empty(&self) -> bool {
        self.specs.is_empty()
    }
}

type Result<T> = std::result::Result<T, String>;

/// Decodes a sort-spec payload serialized by Dart (`encodeSortSpecs`).
pub fn decode_sort_specs(bytes: &[u8]) -> Result<SortSpecs> {
    let mut r = Reader::new(bytes);
    let version = r.read_u8()?;
    if version != SORT_SPEC_WIRE_VERSION {
        return Err(format!(
            "Unsupported sort-spec wire version {version} (expected {SORT_SPEC_WIRE_VERSION})"
        ));
    }
    let count = r.read_varint()? as usize;
    let mut specs = Vec::with_capacity(count);
    for _ in 0..count {
        let field = r.read_string()?;
        let descending = r.read_u8()? != 0;
        specs.push(SortSpec { field, descending });
    }
    if r.remaining() != 0 {
        return Err("Trailing bytes after sort-specs".into());
    }
    Ok(SortSpecs { specs })
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
            .ok_or_else(|| "Unexpected end of sort-specs".to_string())?;
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
                return Err("Sort-spec varint overflow".into());
            }
        }
        Ok(value)
    }

    fn read_string(&mut self) -> Result<String> {
        let len = self.read_varint()? as usize;
        if len > self.remaining() {
            return Err("Sort-spec string length out of range".into());
        }
        let s = std::str::from_utf8(&self.bytes[self.pos..self.pos + len])
            .map_err(|_| "Invalid UTF-8 in sort-spec".to_string())?;
        self.pos += len;
        Ok(s.to_string())
    }
}

/// compares two decoded rows by [specs] — a port of Dart `compareRows`
/// (`sorting.dart`). Rows missing a sort field sort LAST for ascending, FIRST
/// for descending (matches the documented order + the durable-index ordering).
/// Ties return Equal so callers preserve stable input order.
pub fn compare_rows(a: &RowValue, b: &RowValue, specs: &[SortSpec]) -> std::cmp::Ordering {
    for spec in specs {
        let a_v = a.find_field(&spec.field);
        let b_v = b.find_field(&spec.field);
        match (a_v, b_v) {
            (Some(x), Some(y)) => {
                let c = value_codec::sort_compare(x, y);
                if c != std::cmp::Ordering::Equal {
                    return if spec.descending { c.reverse() } else { c };
                }
            }
            (Some(_), None) => {
                // a present, b missing.
                return if spec.descending {
                    std::cmp::Ordering::Greater
                } else {
                    std::cmp::Ordering::Less
                };
            }
            (None, Some(_)) => {
                // a missing, b present.
                return if spec.descending {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                };
            }
            (None, None) => {}
        }
    }
    std::cmp::Ordering::Equal
}

/// Encodes a sort-spec list (used by the worker for the fallback path and by
/// unit tests; Dart is the real encoder).
pub fn encode_sort_specs(specs: &[SortSpec]) -> Vec<u8> {
    fn push_varint(out: &mut Vec<u8>, mut value: u64) {
        loop {
            let byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                out.push(byte | 0x80);
            } else {
                out.push(byte);
                break;
            }
        }
    }
    let mut out = vec![SORT_SPEC_WIRE_VERSION];
    push_varint(&mut out, specs.len() as u64);
    for spec in specs {
        let field = spec.field.as_bytes();
        push_varint(&mut out, field.len() as u64);
        out.extend_from_slice(field);
        out.push(if spec.descending { 1 } else { 0 });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::value_codec::{RowValue, TAG_MAP, TAG_STRING};

    fn map_row(entries: &[(&str, &str)]) -> RowValue {
        RowValue::Map(
            entries
                .iter()
                .map(|(k, v)| {
                    (
                        RowValue::String(k.to_string()),
                        RowValue::String(v.to_string()),
                    )
                })
                .collect(),
        )
    }

    fn spec(field: &str, descending: bool) -> SortSpec {
        SortSpec {
            field: field.into(),
            descending,
        }
    }

    #[test]
    fn sort_spec_wire_round_trips() {
        let specs = [spec("name", false), spec("age", true), spec("nick", false)];
        let bytes = encode_sort_specs(&specs);
        let decoded = decode_sort_specs(&bytes).unwrap();
        assert_eq!(decoded.specs, specs);
        // Empty list round-trips.
        assert!(decode_sort_specs(&encode_sort_specs(&[]))
            .unwrap()
            .is_empty());
        // Bad version rejected.
        assert!(decode_sort_specs(&[99, 0]).is_err());
        // Trailing garbage rejected.
        let mut bad = encode_sort_specs(&[spec("a", false)]);
        bad.push(0x00);
        assert!(decode_sort_specs(&bad).is_err());
    }

    #[test]
    fn compare_rows_matches_dart_ordering() {
        use std::cmp::Ordering;
        let specs = [spec("name", false)];
        // Present before missing (ascending).
        assert_eq!(
            compare_rows(
                &map_row(&[("name", "a")]),
                &map_row(&[("other", "x")]),
                &specs
            ),
            Ordering::Less
        );
        assert_eq!(
            compare_rows(
                &map_row(&[("other", "x")]),
                &map_row(&[("name", "a")]),
                &specs
            ),
            Ordering::Greater
        );
        // Lexical ascending.
        assert_eq!(
            compare_rows(
                &map_row(&[("name", "a")]),
                &map_row(&[("name", "b")]),
                &specs
            ),
            Ordering::Less
        );
        // Descending reverses value order but missing still first.
        let desc = [spec("name", true)];
        assert_eq!(
            compare_rows(
                &map_row(&[("name", "b")]),
                &map_row(&[("name", "a")]),
                &desc
            ),
            Ordering::Less
        );
        assert_eq!(
            compare_rows(
                &map_row(&[("other", "x")]),
                &map_row(&[("name", "a")]),
                &desc
            ),
            Ordering::Less
        );
        // Ties (equal values) → Equal (stable).
        assert_eq!(
            compare_rows(
                &map_row(&[("name", "a")]),
                &map_row(&[("name", "a")]),
                &specs
            ),
            Ordering::Equal
        );
        // Multi-field: name ties break on age (descending).
        let multi = [spec("name", false), spec("age", true)];
        let a = RowValue::Map(vec![
            (RowValue::String("n".into()), RowValue::String("x".into())),
            (RowValue::String("age".into()), RowValue::Int64(1)),
        ]);
        let b = RowValue::Map(vec![
            (RowValue::String("n".into()), RowValue::String("x".into())),
            (RowValue::String("age".into()), RowValue::Int64(2)),
        ]);
        assert_eq!(compare_rows(&a, &b, &multi), Ordering::Greater); // age 1 > age 2 desc
        let _ = (TAG_MAP, TAG_STRING); // suppress unused import noise
    }

    #[test]
    fn sort_compare_numeric_matches_dart() {
        use std::cmp::Ordering;
        // int vs double compares numerically (3 > 2.5), unlike the range
        // comparator's type-rank fallback.
        assert_eq!(
            crate::value_codec::sort_compare(&RowValue::Int64(3), &RowValue::F64(2.5)),
            Ordering::Greater
        );
        assert_eq!(
            crate::value_codec::sort_compare(&RowValue::Int64(2), &RowValue::F64(2.5)),
            Ordering::Less
        );
        // Null sorts by '' string fallback.
        assert_eq!(
            crate::value_codec::sort_compare(&RowValue::Null, &RowValue::Int64(5)),
            Ordering::Less
        );
        assert_eq!(
            crate::value_codec::sort_compare(&RowValue::String("a".into()), &RowValue::Null),
            Ordering::Greater
        );
    }
}
