// Durable index key bound helpers.
//
// The durable `__gecko_index` table stores one entry per (table, field, value,
// recordId) with the composite key `encode([table, field, value, recordId])`
// (a `DefaultWireCodec` 4-element list). The VALUE element uses the
// order-preserving encoding from `rust/src/value_codec.rs` (Priority 5):
// `0x0A | <subtag> | <payload>` where byte order equals semantic order for
// the supported scalar types. Because the element is self-delimiting and
// order-preserving:
//
//   * an equality bound is the exact range `[prefix(value), successor)`,
//   * a range bound `min..max` is the exact range
//     `[prefix(min), successor(prefix(max))]`,
//   * a string-prefix bound is the exact range over the escaped prefix bytes
//     (a semantic string prefix is a contiguous byte range).
//
// Every key for a fixed (table, field) shares the byte prefix
// `0x06 00 00 00 04 | encode(table) | encode(field)`, so these exact bounds
// make range/prefix scans visit only the matching rows instead of the whole
// field span (the v1 codec was not semantic-order-preserving, which forced
// the previous broad `fieldBounds` spans).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../wire/wire_codec.dart';

// Ordered sub-tags (mirror `rust/src/value_codec.rs`).
const int _ordNull = 0x00;
const int _ordBool = 0x01;
const int _ordInt64 = 0x02;
const int _ordDateTime = 0x03;
const int _ordBigInt = 0x04;
const int _ordF64 = 0x05;
const int _ordString = 0x06;
const int _ordBytes = 0x07;
const int _ordList = 0x08;
const int _ordMap = 0x09;
const int _tagOrdered = 0x0A;

/// The full order-preserving value element (`0x0A` tag + payload) for [value],
/// matching `rust/src/value_codec.rs::ordered_index_element`.
List<int> orderedIndexElement(
  Object? value, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  final out = <int>[_tagOrdered];
  out.addAll(_ordPayload(value, codec));
  return out;
}

List<int> _ordPayload(Object? value, WireCodec codec) {
  if (value == null) return const [_ordNull];
  if (value is bool) return [_ordBool, value ? 1 : 0];
  if (value is int) return [_ordInt64, ..._flip64(value)];
  if (value is DateTime) {
    return [_ordDateTime, ..._flip64(value.toUtc().microsecondsSinceEpoch)];
  }
  if (value is BigInt) return [_ordBigInt, ..._flip128(value)];
  if (value is double) return [_ordF64, ..._totalOrder64(value)];
  if (value is String) {
    final out = <int>[_ordString];
    _pushOrdString(out, utf8.encode(value));
    return out;
  }
  if (value is Uint8List) {
    final out = <int>[_ordBytes];
    _pushOrdString(out, value);
    return out;
  }
  if (value is List) return [_ordList, ...codec.encode(value)];
  if (value is Map) return [_ordMap, ...codec.encode(value)];
  throw ArgumentError.value(value, 'value', 'unsupported ordered index value');
}

/// 8-byte sign-flipped big-endian encoding of an int64 (web-safe: only `& 0xFF`
/// and `>>` are used, matching `DefaultWireCodec.encodeInt64`).
List<int> _flip64(int value) {
  final bytes = List<int>.filled(8, 0);
  var v = value;
  for (var i = 7; i >= 0; i--) {
    bytes[i] = v & 0xFF;
    v >>= 8;
  }
  bytes[0] ^= 0x80;
  return bytes;
}

/// 16-byte sign-flipped big-endian encoding of an int128.
List<int> _flip128(BigInt value) {
  final out = List<int>.filled(16, 0);
  var v = value ^ (BigInt.one << 127);
  v = v & ((BigInt.one << 128) - BigInt.one);
  for (var i = 15; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v = v >> 8;
  }
  return out;
}

/// 8-byte total-order encoding of an f64 matching Rust `f64::total_cmp`
/// (negative NaN < -inf < ... < +inf < positive NaN).
List<int> _totalOrder64(double value) {
  final b = ByteData(8)..setFloat64(0, value); // big-endian by default
  final raw = List<int>.generate(8, (i) => b.getUint8(i));
  if ((raw[0] & 0x80) != 0) {
    return [for (final byte in raw) ~byte & 0xFF];
  }
  return [raw[0] ^ 0x80, ...raw.sublist(1)];
}

/// Escaped-terminator byte-string encoding (see the module comment).
void _pushOrdString(List<int> out, List<int> bytes) {
  for (final b in bytes) {
    if (b == 0x00) {
      out.addAll(const [0x00, 0x01]);
    } else {
      out.add(b);
    }
  }
  out.addAll(const [0x00, 0x00]);
}

/// The shared `[table, field]` index-key prefix (`0x06 | u32(4) | table |
/// field`).
List<int> _fieldPrefix(String table, String field, WireCodec codec) {
  final out = <int>[0x06, 0, 0, 0, 4];
  out.addAll(codec.encode(table));
  out.addAll(codec.encode(field));
  return out;
}

/// The byte bounds for a durable-index range scan matching every key with the
/// given (table, field, value) triple, regardless of recordId.
///
/// Returns `(start, end)` where `start` is the shared byte prefix and `end`
/// is the exclusive-style upper bound (incremented last byte with carry).
(List<int>, List<int>) eqBounds(
  String table,
  String field,
  Object? value, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  final prefix = _fieldPrefix(table, field, codec);
  prefix.addAll(orderedIndexElement(value, codec: codec));
  final end = _incrementLastByte(prefix);
  return (prefix, end);
}

/// The exact bounds for `min <= value <= max` on an indexed field (open-ended
/// when a bound is null). Unlike the v1 broad field span, the order-preserving
/// value element makes this a tight range: only values in `[min, max]` encode
/// inside it.
(List<int>, List<int>) rangeBounds(
  String table,
  String field,
  Object? min,
  Object? max, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  final prefix = _fieldPrefix(table, field, codec);
  final start = min == null
      ? List<int>.of(prefix)
      : (List<int>.of(prefix)
        ..addAll(orderedIndexElement(min, codec: codec)));
  final end = max == null
      ? _incrementLastByte(prefix)
      : _incrementLastByte(
          List<int>.of(prefix)..addAll(orderedIndexElement(max, codec: codec)),
        );
  return (start, end);
}

/// The exact bounds for `field startsWith prefix` on an indexed String field:
/// the escaped prefix bytes (without a terminator) form a contiguous range
/// containing exactly the strings that start with [prefix].
(List<int>, List<int>) prefixBounds(
  String table,
  String field,
  String prefix, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  final shared = _fieldPrefix(table, field, codec);
  shared.add(_tagOrdered);
  shared.add(_ordString);
  _pushOrdString(shared, utf8.encode(prefix));
  // Drop the 00 00 terminator so longer strings that extend the prefix stay
  // inside the range.
  shared.removeRange(shared.length - 2, shared.length);
  final end = _incrementLastByte(shared);
  return (shared, end);
}

/// The byte bounds covering EVERY durable-index key for the given (table,
/// field) pair, regardless of value or recordId — i.e. the range
/// `[table, field, *, *]`. Used by the index-ordered sort to stream all
/// values of a sort field in index-key order and as the fallback for
/// open-ended bounds.
(List<int>, List<int>) fieldBounds(
  String table,
  String field, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  final prefix = _fieldPrefix(table, field, codec);
  final end = _incrementLastByte(prefix);
  return (prefix, end);
}

/// Increments the last byte of [bytes] with carry: produces a byte sequence
/// that sorts immediately after every longer key sharing the prefix. Trailing
/// 0xFF bytes carry by being dropped (a shorter upper bound still sorts after
/// any longer key with the shared prefix — standard prefix-scan semantics).
List<int> _incrementLastByte(List<int> bytes) {
  final out = List<int>.of(bytes);
  var i = out.length - 1;
  while (i >= 0) {
    if (out[i] < 0xFF) {
      out[i] += 1;
      return out.sublist(0, i + 1);
    }
    out.removeLast();
    i--;
  }
  // All 0xFF bytes: return the original as a safe no-match fallback.
  return bytes;
}
