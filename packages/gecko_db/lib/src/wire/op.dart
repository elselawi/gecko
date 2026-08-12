/// The wire contract for batched operations.
///
/// This is the **only** thing that crosses the FFI boundary per transaction.
/// A full batch of [`Op`]s is serialized in one call and applied in one
/// `WriteTransaction`. The wire format is versioned; a version mismatch
/// surfaces as a typed error, never a cryptic message-handling failure.
library;

import 'dart:typed_data';
import 'dart:convert';

/// Thrown when an [`Op`] payload cannot be decoded or is malformed/unknown.
class OpDecodeException implements Exception {
  const OpDecodeException(this.message);
  final String message;
  @override
  String toString() => 'OpDecodeException: $message';
}

/// The operation kinds a batch may contain.
enum OpKind { put, delete, rangeScan, get, deleteRange, clear }

/// A single table operation within a batch.
///
/// [op] identifies the kind; table is the collection/table name; [key] and
/// [value] are wire-encoded row bytes where relevant; [start] and [end] bound
/// range scans. Serialization is byte-stable and idempotent.
class Op {
  const Op({
    required this.op,
    required this.table,
    this.key,
    this.value,
    this.start,
    this.end,
  });

  final OpKind op;
  final String table;
  final Uint8List? key;
  final Uint8List? value;
  final Uint8List? start;
  final Uint8List? end;

  /// Wire format version for `Op` batches.
  static const int wireVersion = 1;

  /// Serializes an [`Op`] batch to bytes (version-prefixed).
  static List<int> encodeBatch(List<Op> ops) {
    final out = BytesBuilder();
    out.addByte(wireVersion);
    _writeVarint(out, ops.length);
    for (final op in ops) {
      out.addByte(op.op.index);
      _writeString(out, op.table);
      _writeBytes(out, op.key);
      _writeBytes(out, op.value);
      _writeBytes(out, op.start);
      _writeBytes(out, op.end);
    }
    return out.toBytes();
  }

  /// Decodes a version-prefixed batch, rejecting unknown versions/types.
  static List<Op> decodeBatch(List<int> bytes) {
    final r = _OpReader(bytes);
    final version = r.readByte();
    if (version != wireVersion) {
      throw OpDecodeException(
        'Unsupported wire version $version (expected $wireVersion)',
      );
    }
    final count = r.readVarint();
    if (count < 0) {
      throw const OpDecodeException('Negative op count');
    }
    final ops = <Op>[];
    for (var i = 0; i < count; i++) {
      final kindIndex = r.readByte();
      if (kindIndex < 0 || kindIndex >= OpKind.values.length) {
        throw OpDecodeException('Unknown op kind index: $kindIndex');
      }
      final table = r.readString();
      final key = r.readBytes();
      final value = r.readBytes();
      final start = r.readBytes();
      final end = r.readBytes();
      ops.add(
        Op(
          op: OpKind.values[kindIndex],
          table: table,
          key: key,
          value: value,
          start: start,
          end: end,
        ),
      );
    }
    if (r.remaining != 0) {
      throw const OpDecodeException('Trailing bytes after batch');
    }
    return ops;
  }

  @override
  bool operator ==(Object other) =>
      other is Op &&
      other.op == op &&
      other.table == table &&
      _eq(other.key, key) &&
      _eq(other.value, value) &&
      _eq(other.start, start) &&
      _eq(other.end, end);

  @override
  int get hashCode => Object.hash(
    op,
    table,
    _hash(key),
    _hash(value),
    _hash(start),
    _hash(end),
  );

  /// Content-based hash for byte fields, consistent with [_eq]: two byte
  /// arrays that compare equal (via [Uint8List] value equality) must have the
  /// same hash. [Uint8List.hashCode] is identity-based, so we fold the bytes.
  static int _hash(Uint8List? b) {
    if (b == null) return 0;
    var h = 0;
    for (final byte in b) {
      h = (h * 31 + byte) & 0x7FFFFFFF;
    }
    return h;
  }

  static bool _eq(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return identical(a, b);
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7F) | 0x80);
    v >>= 7;
  }
  out.addByte(v);
}

void _writeString(BytesBuilder out, String s) {
  final bytes = utf8.encode(s);
  _writeVarint(out, bytes.length);
  out.add(bytes);
}

void _writeBytes(BytesBuilder out, Uint8List? b) {
  if (b == null) {
    // Presence flag then length, so null is unambiguous and cheap.
    out.addByte(0); // null
    return;
  }
  out.addByte(1); // present
  _writeVarint(out, b.length);
  out.add(b);
}

class _OpReader {
  _OpReader(List<int> bytes)
    : _bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  /// The batch buffer as a typed array (normalized once at construction; the
  /// zero-copy transport already delivers `Uint8List`, so no copy occurs).
  final Uint8List _bytes;
  int _pos = 0;

  int get remaining => _bytes.length - _pos;

  int readByte() {
    if (_pos >= _bytes.length) {
      throw const OpDecodeException('Unexpected end of input');
    }
    return _bytes[_pos++];
  }

  int readVarint() {
    var value = 0;
    var shift = 0;
    while (true) {
      final b = readByte();
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) {
        throw const OpDecodeException('Varint overflow');
      }
    }
    return value;
  }

  String readString() {
    final len = readVarint();
    if (len < 0 || len > _bytes.length - _pos) {
      throw const OpDecodeException('String length out of range');
    }
    // Bulk typed-array view: decode the UTF-8 span directly instead of
    // building a byte-per-element list (utf8.decode never mutates the input).
    final out = utf8.decode(Uint8List.sublistView(_bytes, _pos, _pos + len));
    _pos += len;
    return out;
  }

  Uint8List? readBytes() {
    final present = readByte();
    if (present == 0) return null;
    final len = readVarint();
    if (len < 0 || len > _bytes.length - _pos) {
      throw const OpDecodeException('Bytes length out of range');
    }
    // Bulk typed-array view: zero-copy slice of the decode buffer (the buffer
    // is private to this decode and discarded immediately after). Callers
    // must treat the returned bytes as immutable — as with every raw value
    // crossing the wire — and must not mutate them in place.
    final out = Uint8List.sublistView(_bytes, _pos, _pos + len);
    _pos += len;
    return out;
  }
}
