// Predicate wire serialization for the Rust query fast path (step 2).
//
// Serializes a query's [`FilterGroup`] into a self-delimiting byte payload that
// the Rust `predicate::decode_predicate` evaluator consumes. The format mirrors
// the `Op` batch wire style (version-prefixed, uvarint counts, length-prefixed
// strings) and is byte-stable; the Rust side is the evaluator
// (`rust/src/predicate.rs`).
//
//   version : u8                                  (= 1)
//   count   : uvarint
//   per filter:
//     op      : u8   (0 = eq, 1 = range, 2 = prefix)
//     field   : string (uvarint len + UTF-8)
//     eq      → value  : a full encoded RowValue (the codec bytes)
//     range   → hasMin:u8, [min: RowValue bytes if hasMin],
//               hasMax:u8, [max: RowValue bytes if hasMax]
//     prefix  → prefix : string
//
// An empty filter list serializes to `version + count(0)` and matches every
// row (matches Dart's `FilterGroup`).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../wire/wire_codec.dart';
import 'filter.dart';

/// The predicate wire format version. Must match `PREDICATE_WIRE_VERSION` in
/// `rust/src/predicate.rs`.
const int predicateWireVersion = 1;

/// Op codes — must match `PredicateOp` in `rust/src/predicate.rs`.
const int _opEquals = 0;
const int _opRange = 1;
const int _opPrefix = 2;

/// Serializes [filters] (an AND-composed list) into the Rust predicate wire
/// payload. Values are encoded with [codec] (the row wire codec, so the bytes
/// the Rust evaluator decodes are identical to what the Dart codec would
/// produce for a stored row value).
List<int> encodePredicate(
  List<Filter> filters, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  final out = BytesBuilder();
  out.addByte(predicateWireVersion);
  _writeVarint(out, filters.length);
  for (final f in filters) {
    if (f.isIndexUsable) {
      // Equality.
      out.addByte(_opEquals);
      _writeString(out, f.field);
      // The value bytes are a self-delimiting RowValue under the codec —
      // Rust's PredicateReader reads them with value_codec::ValueReader, so
      // no length envelope is needed (unlike Op's opt-bytes, which use a
      // presence byte because None is a valid state there).
      out.add(codec.encode(f.value));
    } else if (f.isRangeFilter) {
      out.addByte(_opRange);
      _writeString(out, f.field);
      out.addByte(f.min == null ? 0 : 1);
      if (f.min != null) {
        out.add(codec.encode(f.min));
      }
      out.addByte(f.max == null ? 0 : 1);
      if (f.max != null) {
        out.add(codec.encode(f.max));
      }
    } else if (f.isPrefixFilter) {
      out.addByte(_opPrefix);
      _writeString(out, f.field);
      _writeString(out, f.prefix!);
    } else {
      // Unreachable: every Filter is one of the three kinds. Ignored from
      // coverage because it is a defensive guard that never executes.
      // coverage:ignore-start
      throw StateError('Unknown filter kind: $f');
      // coverage:ignore-end
    }
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
