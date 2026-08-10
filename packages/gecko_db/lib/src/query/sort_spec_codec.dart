// Sort-spec wire serialization for the Rust query fast path (M4).
//
// Serializes a query's sort specs into a self-delimiting byte payload that
// the Rust `sort_spec::decode_sort_specs` consumer decodes. The format
// mirrors the `Op` batch wire style (version-prefixed, uvarint counts).
//
//   version  : u8        (= 1)
//   count    : uvarint
//   per spec : field : string (uvarint len + UTF-8), descending : u8 (0/1)
library;

import 'dart:convert';
import 'dart:typed_data';

import '../api/query.dart';

/// The sort-spec wire format version. Must match `SORT_SPEC_WIRE_VERSION` in
/// `rust/src/sort_spec.rs`.
const int sortSpecWireVersion = 1;

/// Serializes [specs] into the Rust sort-spec wire payload.
List<int> encodeSortSpecs(List<SortSpec> specs) {
  final out = BytesBuilder();
  out.addByte(sortSpecWireVersion);
  _writeVarint(out, specs.length);
  for (final spec in specs) {
    _writeString(out, spec.field);
    out.addByte(spec.order == SortOrder.descending ? 1 : 0);
  }
  return out.toBytes();
}

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.addByte(v & 0x7F);
}

void _writeString(BytesBuilder out, String s) {
  final bytes = utf8.encode(s);
  _writeVarint(out, bytes.length);
  out.add(bytes);
}
