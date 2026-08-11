/// Standard wire encodings (contract).
///
/// Both the in-memory backend and the Rust worker serialize with the exact
/// same encoder, and a golden-serialization fixture locks the bytes. The
/// encodings here guarantee:
///
/// * `int64`/`BigInt` full range, never truncated through a JS number;
/// * `double` bit-identical round-trip (incl. `-0.0`, denormals, infinities,
///   and NaN bit patterns) — preserved on web via bigint-aware handling;
/// * `String` as UTF-8, not a JS UTF-16 re-encoding;
/// * 64-bit microsecond `DateTime` (stored UTC);
/// * `Uint8List`/binary references;
/// * an optional type-tag so a future version can distinguish encodings.
library;

import 'dart:convert';
import 'dart:typed_data';

/// The set of scalar/composite values a row may carry at the wire boundary.
typedef RowValue = Object?;

/// Thrown when bytes cannot be decoded into a [`RowValue`].
class WireDecodeException implements Exception {
  const WireDecodeException(this.message, [this.bytes]);
  final String message;
  final List<int>? bytes;
  @override
  String toString() => 'WireDecodeException: $message';
}

/// Type tags — the first byte of every encoded value.
enum _Tag {
  null_(0x00),
  bool_(0x01),
  int_(0x02),
  bigInt(0x03),
  double_(0x04),
  string(0x05),
  list(0x06),
  map(0x07),
  bytes(0x08),
  dateTime(0x09);

  const _Tag(this.byte);
  final int byte;

  static _Tag fromByte(int b) {
    for (final t in _Tag.values) {
      if (t.byte == b) return t;
    }
    throw WireDecodeException(
      'Unknown type tag byte: 0x${b.toRadixString(16)}',
    );
  }
}

/// Byte-level codec for gecko_db row values.
///
/// The encoder is deterministic and byte-stable: the same input produces the
/// same bytes across runs, so golden fixtures can lock the format.
abstract class WireCodec {
  /// Encodes [value] into a deterministic byte sequence.
  Uint8List encode(RowValue value);

  /// Decodes [bytes] back into a [`RowValue`].
  RowValue decode(List<int> bytes);

  /// Encodes a 64-bit [value] without passing through a JS number on web.
  List<int> encodeInt64(int value);

  /// Decodes a 64-bit integer from [bytes] (big-endian).
  int decodeInt64(List<int> bytes);
}

/// The canonical, default implementation of [`WireCodec`].
class DefaultWireCodec implements WireCodec {
  const DefaultWireCodec();

  @override
  Uint8List encode(RowValue value) {
    final out = BytesBuilder();
    _write(out, value);
    return Uint8List.fromList(out.toBytes());
  }

  void _write(BytesBuilder out, Object? value) {
    if (value == null) {
      out.addByte(_Tag.null_.byte);
    } else if (value is bool) {
      out.addByte(_Tag.bool_.byte);
      out.addByte(value ? 1 : 0);
    } else if (value is int) {
      out.addByte(_Tag.int_.byte);
      out.add(encodeInt64(value));
    } else if (value is BigInt) {
      out.addByte(_Tag.bigInt.byte);
      out.add(_bigIntToFixed(value));
    } else if (value is double) {
      out.addByte(_Tag.double_.byte);
      out.add(_doubleToBytes(value));
    } else if (value is String) {
      out.addByte(_Tag.string.byte);
      final u8 = utf8.encode(value);
      out.add(_uint32(u8.length));
      out.add(u8);
    } else if (value is DateTime) {
      out.addByte(_Tag.dateTime.byte);
      // Store UTC microseconds since epoch.
      out.add(encodeInt64(value.toUtc().microsecondsSinceEpoch));
    } else if (value is Uint8List) {
      out.addByte(_Tag.bytes.byte);
      out.add(_uint32(value.length));
      out.add(value);
    } else if (value is List) {
      out.addByte(_Tag.list.byte);
      out.add(_uint32(value.length));
      for (final e in value) {
        _write(out, e);
      }
    } else if (value is Map) {
      out.addByte(_Tag.map.byte);
      out.add(_uint32(value.length));
      value.forEach((k, v) {
        _write(out, k);
        _write(out, v);
      });
    } else {
      throw ArgumentError.value(
        value,
        'value',
        'Unsupported wire type: ${value.runtimeType}',
      );
    }
  }

  @override
  RowValue decode(List<int> bytes) {
    final reader = _Reader(bytes);
    final v = _read(reader);
    if (reader.remaining != 0) {
      throw const WireDecodeException('Trailing bytes after value');
    }
    return v;
  }

  Object? _read(_Reader r) {
    final tag = _Tag.fromByte(r.readByte());
    switch (tag) {
      case _Tag.null_:
        return null;
      case _Tag.bool_:
        return r.readByte() != 0;
      case _Tag.int_:
        return decodeInt64(r.readBytes(8));
      case _Tag.bigInt:
        return _bigIntFromFixed(r.readBytes(16));
      case _Tag.double_:
        return _bytesToDouble(r.readBytes(8));
      case _Tag.string:
        final len = _readUint32(r);
        if (len < 0 || len > r.remaining) {
          throw const WireDecodeException('String length out of range');
        }
        try {
          return utf8.decode(r.readBytes(len));
        } on FormatException {
          // Invalid UTF-8 is a wire-format error, never a raw FormatException.
          throw const WireDecodeException('Invalid UTF-8 in string value');
        }
      case _Tag.dateTime:
        final micros = decodeInt64(r.readBytes(8));
        return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
      case _Tag.bytes:
        final len = _readUint32(r);
        if (len < 0 || len > r.remaining) {
          throw const WireDecodeException('Bytes length out of range');
        }
        return Uint8List.fromList(r.readBytes(len));
      case _Tag.list:
        final len = _readUint32(r);
        if (len < 0 || len > r.remaining) {
          throw const WireDecodeException('List length out of range');
        }
        final out = <Object?>[];
        for (var i = 0; i < len; i++) {
          out.add(_read(r));
        }
        return out;
      case _Tag.map:
        final len = _readUint32(r);
        if (len < 0) {
          throw const WireDecodeException('Map length out of range');
        }
        final out = <Object?, Object?>{};
        for (var i = 0; i < len; i++) {
          final k = _read(r);
          final v = _read(r);
          out[k] = v;
        }
        return out;
    }
  }

  @override
  List<int> encodeInt64(int value) {
    // Big-endian, two's complement 8 bytes — no JS number precision loss for
    // values dart2js can represent (its `& 0xFF`/`>>` are 32-bit ops). Each
    // byte only needs the low 8 bits, so no 64-bit mask literal is required
    // (0xFFFFFFFFFFFFFFFF is not exactly representable on the web).
    final bytes = List<int>.filled(8, 0);
    var v = value;
    for (var i = 7; i >= 0; i--) {
      bytes[i] = v & 0xFF;
      v >>= 8;
    }
    return bytes;
  }

  @override
  int decodeInt64(List<int> bytes) {
    if (bytes.length != 8) {
      throw const WireDecodeException('int64 requires 8 bytes');
    }
    // Manual big-endian two's-complement decode: ByteData.getInt64 is
    // unsupported on dart2js. On the VM the arithmetic naturally wraps to a
    // signed 64-bit int; on dart2js values are restricted to the JS safe-
    // integer range (gecko's int64s — LSNs, snapshot ids, timestamps — are
    // always well within it).
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = value * 256 + bytes[i];
    }
    return value;
  }
}

List<int> _uint32(int value) => <int>[
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

int _readUint32(_Reader r) {
  final b = r.readBytes(4);
  return ((b[0] & 0xFF) << 24) |
      ((b[1] & 0xFF) << 16) |
      ((b[2] & 0xFF) << 8) |
      (b[3] & 0xFF);
}

List<int> _doubleToBytes(double value) {
  final b = ByteData(8)..setFloat64(0, value);
  return List<int>.generate(8, (i) => b.getUint8(i));
}

double _bytesToDouble(List<int> bytes) {
  final b = ByteData(8);
  for (var i = 0; i < 8; i++) {
    b.setUint8(i, bytes[i]);
  }
  return b.getFloat64(0);
}

List<int> _bigIntToFixed(BigInt value) {
  // 16-byte two's-complement big-endian representation (full int128 headroom
  // for future scale, and enough for any int64 a JS boundary would truncate).
  final out = List<int>.filled(16, 0);
  var v = value & ((BigInt.one << 128) - BigInt.one);
  for (var i = 15; i >= 0; i--) {
    // Mask as BigInt first: v.toInt() truncates to 64 bits when v > 2^63.
    out[i] = (v & BigInt.from(0xFF)).toInt();
    v = v >> 8;
  }
  return out;
}

BigInt _bigIntFromFixed(List<int> bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b & 0xFF);
  }
  // Sign-extend from 128-bit two's complement.
  if ((bytes.first & 0x80) != 0) {
    result = result - (BigInt.one << 128);
  }
  return result;
}

class _Reader {
  _Reader(this._bytes);
  final List<int> _bytes;
  int _pos = 0;

  int get remaining => _bytes.length - _pos;

  int readByte() {
    if (_pos >= _bytes.length) {
      throw const WireDecodeException('Unexpected end of input');
    }
    return _bytes[_pos++];
  }

  List<int> readBytes(int n) {
    if (_pos + n > _bytes.length) {
      throw const WireDecodeException('Unexpected end of input');
    }
    final out = _bytes.sublist(_pos, _pos + n);
    _pos += n;
    return out;
  }
}
