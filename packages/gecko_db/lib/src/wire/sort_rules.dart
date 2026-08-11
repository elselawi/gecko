/// Key sort ordering rules (contract, not convenience).
///
/// This is the **one place** key ordering is decided, and secondary
/// indexes inherit it. Fixed-width big-endian integers and byte-wise strings
/// guarantee deterministic, cross-platform ordering so indexed/range scans
/// behave identically everywhere.
library;

import 'dart:typed_data';

/// How a scalar is encoded into sortable key bytes.
class SortRule {
  const SortRule._(this.name, this.isSortable);

  /// A rule whose encoded bytes compare in plain unsigned byte order.
  static const SortRule bigEndian = SortRule._('bigEndian', true);

  /// A rule that is stored but **not** directly sortable by byte order; the
  /// engine must fall back to decoding for ordering these (rare).
  static const SortRule unordered = SortRule._('unordered', false);

  /// Symbolic name for diagnostics / future index metadata.
  final String name;

  /// Whether the encoded bytes compare in plain byte order.
  final bool isSortable;

  @override
  String toString() => 'SortRule.$name';
}

const Map<String, SortRule> standardSortRules = <String, SortRule>{
  'String': SortRule.bigEndian,
  'int': SortRule.bigEndian,
  'BigInt': SortRule.bigEndian,
  'double': SortRule.bigEndian,
  'bool': SortRule.bigEndian,
  'DateTime': SortRule.bigEndian,
  'null': SortRule.bigEndian,
};

/// Encodes a scalar [key] into byte-wise sortable bytes.
///
/// Fixed-width big-endian encodings make numeric ordering match unsigned byte
/// order, so a byte-wise comparison over the result sorts correctly.
List<int> sortBytesFor(Object? key) {
  if (key == null) return <int>[0];
  if (key is int) return _intBytes(key);
  if (key is bool) return <int>[key ? 2 : 1];
  if (key is String) return _stringBytes(key);
  if (key is double || key is num) return _doubleBytes((key as num).toDouble());
  if (key is DateTime) return _intBytes(key.microsecondsSinceEpoch);
  if (key is BigInt) return _bigIntBytes(key);
  throw ArgumentError.value(
    key,
    'key',
    'No sort rule registered for this key type: ${key.runtimeType}',
  );
}

/// Encodes an integer as a width-tagged big-endian byte sequence using
/// offset-binary (bias 2^63) so ordering is preserved across the whole signed
/// range: negatives map below 2^63, non-negatives map at/above it.
List<int> _intBytes(int value) {
  final biased = BigInt.from(value) + (BigInt.one << 63);
  return <int>[1, ..._bigEndianBytes(biased)];
}

List<int> _doubleBytes(double value) {
  // IEEE-754 64-bit pattern, as a signed int64 (may be non-NaN or NaN).
  final bits = value == value
      ? _doubleToBits(value)
      : (value.isNegative ? -0x7FF8000000000000 : 0x7FF8000000000000);
  // Orderable mapping: negatives (~bits) sort below the positive half
  // (bits with the sign bit forced on). Read as an *unsigned* 64-bit value so
  // byte ordering matches numeric ordering — the raw int64 is negative for
  // positive doubles, so we reinterpret it via BigInt (never arithmetic shift
  // a negative Dart int into the byte encoder).
  final ordered = bits < 0 ? ~bits : (bits ^ 0x8000000000000000);
  final unsigned = BigInt.from(ordered) & ((BigInt.one << 64) - BigInt.one);
  return <int>[2, ..._bigEndianBytes(unsigned)];
}

int _doubleToBits(double value) {
  // Reinterpret double bits via a byte buffer. Uses explicit big-endian so the
  // result is identical on every host, and assembles bytes manually because
  // ByteData.getInt64 is unsupported on dart2js.
  final b = ByteData(8)..setFloat64(0, value, Endian.big);
  var bits = 0;
  for (var i = 0; i < 8; i++) {
    bits = bits * 256 + b.getUint8(i);
  }
  return bits;
}

List<int> _stringBytes(String value) {
  final utf8 =
      value.codeUnits; // UTF-16 units; suffices for ordering stability.
  final out = <int>[3];
  for (final c in utf8) {
    out.add((c >> 8) & 0xFF);
    out.add(c & 0xFF);
  }
  out.addAll(<int>[0, 0]); // terminator
  return out;
}

List<int> _bigIntBytes(BigInt value) {
  final unsigned =
      (value << 1) ^ (value >> (value.bitLength < 64 ? 64 : value.bitLength));
  return <int>[4, ..._unsignedBigEndianBigInt(unsigned)];
}

List<int> _unsignedBigEndianBigInt(BigInt value) {
  return _bigEndianBytes(value);
}

List<int> _bigEndianBytes(BigInt value) {
  var v = value;
  final bytes = <int>[];
  while (v > BigInt.zero) {
    bytes.insert(0, (v & BigInt.from(0xFF)).toInt());
    v = v >> 8;
  }
  while (bytes.length < 16) {
    bytes.insert(0, 0);
  }
  return bytes;
}
