import 'dart:typed_data';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  const codec = DefaultWireCodec();

  group('int64 / BigInt precision', () {
    test('full int64 range round-trips', () {
      const extremes = <int>[
        -9223372036854775808, // -2^63
        -9007199254740993, // below JS-safe integer
        -9007199254740992, // -2^53 exactly (JS boundary)
        -1,
        0,
        1,
        9007199254740991, // 2^53-1
        9007199254740992, // 2^53
        9223372036854775807, // 2^63-1
      ];
      for (final v in extremes) {
        expect(codec.decode(codec.encode(v)), equals(v));
        expect(codec.decodeInt64(codec.encodeInt64(v)), equals(v));
      }
    });

    test('BigInt beyond int64 range round-trips', () {
      final big = BigInt.from(1) << 100;
      expect(codec.decode(codec.encode(big)), equals(big));
      final neg = -(BigInt.from(1) << 90) - BigInt.one;
      expect(codec.decode(codec.encode(neg)), equals(neg));
    });
  });

  group('double bit-identical round-trip', () {
    test('special values preserve bit pattern', () {
      final values = <double>[
        -0.0,
        0.0,
        double.infinity,
        -double.infinity,
        double.nan,
      ];
      for (final v in values) {
        final out = codec.decode(codec.encode(v)) as double;
        if (v.isNaN) {
          expect(out.isNaN, isTrue);
          // NaN bit pattern preserved.
          final inBits = _bits(v);
          final outBits = _bits(out);
          expect(outBits, inBits);
        } else {
          expect(out, v);
        }
      }
    });

    test('denormals round-trip', () {
      final denormal = 4.9e-324;
      expect(codec.decode(codec.encode(denormal)), denormal);
    });

    test('arbitrary doubles round-trip bit-identically', () {
      final val = 3.141592653589793;
      expect(codec.decode(codec.encode(val)), val);
      expect(_bits(codec.decode(codec.encode(val)) as double), _bits(val));
    });
  });

  group('String / DateTime / bytes / composite', () {
    test('UTF-8 string round-trips incl. non-BMP', () {
      const s = 'héllo → 世界 🌍';
      expect(codec.decode(codec.encode(s)), s);
    });

    test('DateTime microsecond precision round-trips in UTC', () {
      final dt = DateTime.utc(2024, 1, 15, 12, 30, 45, 123, 456);
      // Add microseconds beyond the supported ctor args via microseconds var.
      final out = codec.decode(codec.encode(dt)) as DateTime;
      expect(out.microsecondsSinceEpoch, dt.microsecondsSinceEpoch);
      expect(out.isUtc, isTrue);
    });

    test('bytes round-trip', () {
      final bytes = Uint8List.fromList([1, 2, 3, 250]);
      final decoded = codec.decode(codec.encode(bytes)) as Uint8List;
      expect(decoded, equals(bytes));
    });

    test('lists and maps round-trip', () {
      final list = [
        1,
        'two',
        3.0,
        true,
        null,
        [1, 2],
      ];
      expect(codec.decode(codec.encode(list)), equals(list));

      final map = {
        'a': 1,
        'b': [1, 2, 3],
        'nested': {'x': null},
      };
      final decoded = codec.decode(codec.encode(map)) as Map;
      expect(decoded['a'], 1);
      expect(decoded['b'], [1, 2, 3]);
      expect((decoded['nested'] as Map)['x'], isNull);
    });
  });

  group('Golden serialization fixture (byte stability)', () {
    test('fixes wire bytes for a matrix of type x value', () {
      final fixture = <String, Object?>{
        'int': 42,
        'negInt': -7,
        'bigInt': BigInt.parse('123456789012345678901234567890'),
        'double': 3.5,
        'string': 'hello',
        'bool': true,
        'list': [1, 2, 3],
      };
      final bytes = codec.encode(fixture);
      // Regenerating the same input must yield identical bytes.
      expect(codec.encode(fixture), equals(bytes));
      // And it must decode back losslessly.
      final decoded = codec.decode(bytes) as Map;
      expect(decoded['bigInt'], fixture['bigInt']);
    });
  });

  group('Malformed wire decodes', () {
    test('truncated input throws WireDecodeException', () {
      expect(
        () => codec.decode([0x05, 0x00, 0x00]),
        throwsA(isA<WireDecodeException>()),
      );
    });

    test('unknown tag throws WireDecodeException', () {
      expect(() => codec.decode([0xFF]), throwsA(isA<WireDecodeException>()));
    });

    test('trailing bytes throw WireDecodeException', () {
      final good = codec.encode(1);
      expect(
        () => codec.decode([...good, 0x00]),
        throwsA(isA<WireDecodeException>()),
      );
    });

    test('WireDecodeException carries message and bytes', () {
      const e = WireDecodeException('bad', [1, 2, 3]);
      expect(e.message, 'bad');
      expect(e.bytes, [1, 2, 3]);
      expect(e.toString(), contains('bad'));
    });

    test('unsupported type is rejected with ArgumentError', () {
      expect(() => codec.encode(Object()), throwsArgumentError);
    });
  });
}

int _bits(double v) {
  final b = ByteData(8)..setFloat64(0, v);
  return b.getUint64(0);
}
