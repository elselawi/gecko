// Audit-driven wire/op codec edge tests (audited-test-gaps 2.4).
//
// Pins: exact type tags, bool/UTF-8 leniency, pre-epoch DateTime, fixed-size
// BigInt, non-string map keys, invalid UTF-8 typed errors, and the op codec's
// raw-FormatException leak for invalid table names.

import 'dart:typed_data';

import 'package:collection/collection.dart' show ListEquality;
import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  const codec = DefaultWireCodec();
  const listEquals = ListEquality<Object?>();

  group('2.4 wire codec tags and leniency', () {
    test('List<int> encodes with tag 0x06, Uint8List with tag 0x08', () {
      final asList = codec.encode(<int>[1, 2]);
      final asBytes = codec.encode(Uint8List.fromList([1, 2]));
      expect(asList[0], 0x06, reason: 'plain List<int> must use the list tag');
      expect(asBytes[0], 0x08, reason: 'Uint8List must use the bytes tag');
      // An empty Uint8List still carries the bytes tag and round-trips.
      final empty = codec.encode(Uint8List(0));
      expect(empty[0], 0x08);
      final decoded = codec.decode(empty) as Uint8List;
      expect(decoded, isEmpty);
    });

    test('bool payload leniency: any nonzero byte decodes as true', () {
      for (final payload in [0x02, 0x7F, 0xFF]) {
        final decoded = codec.decode([0x01, payload]);
        expect(
          decoded,
          isTrue,
          reason: 'bool payload 0x${payload.toRadixString(16)}',
        );
      }
      expect(codec.decode([0x01, 0x00]), isFalse);
    });

    test('DateTime pre-epoch values round-trip', () {
      final preEpoch = DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999);
      final out = codec.decode(codec.encode(preEpoch)) as DateTime;
      expect(out.microsecondsSinceEpoch, preEpoch.microsecondsSinceEpoch);
      expect(
        out.microsecondsSinceEpoch,
        lessThan(0),
        reason: 'pre-epoch must stay negative',
      );
      final ancient = DateTime.utc(1900, 1, 1);
      expect(
        (codec.decode(codec.encode(ancient)) as DateTime)
            .microsecondsSinceEpoch,
        ancient.microsecondsSinceEpoch,
      );
    });

    test('BigInt is always exactly 16 bytes', () {
      for (final big in [
        BigInt.zero,
        BigInt.one,
        BigInt.from(-1),
        BigInt.parse('123456789012345678901234567890'),
        -(BigInt.from(1) << 127),
      ]) {
        final encoded = codec.encode(big);
        expect(encoded.length, 17, reason: '1 tag byte + fixed 16 payload');
        expect(encoded[0], 0x03);
      }
    });

    test('BigInt decode rejects short payloads with a typed error', () {
      // Tag 0x03 with only 15 payload bytes.
      final short = <int>[0x03, ...List.filled(15, 0)];
      expect(() => codec.decode(short), throwsA(isA<WireDecodeException>()));
      // 17 payload bytes → trailing bytes error.
      final long = <int>[0x03, ...List.filled(17, 0)];
      expect(() => codec.decode(long), throwsA(isA<WireDecodeException>()));
    });

    test('non-string map keys round-trip', () {
      final map = <Object?, Object?>{
        1: 'int-key',
        true: 'bool-key',
        null: 'null-key',
        BigInt.from(7): 'bigint-key',
        2.5: 'double-key',
        Uint8List.fromList([9]): 'bytes-key',
        DateTime.utc(2024): 'date-key',
        <Object?>[1, 2]: 'list-key',
      };
      final decoded = codec.decode(codec.encode(map)) as Map;
      expect(decoded[1], 'int-key');
      expect(decoded[true], 'bool-key');
      expect(decoded[null], 'null-key');
      expect(decoded[BigInt.from(7)], 'bigint-key');
      expect(decoded[2.5], 'double-key');
      // Uint8List keys compare by identity in a Map, so find them structurally.
      final bytesKeyEntry = decoded.entries
          .where(
            (e) =>
                e.key is Uint8List &&
                (e.key as Uint8List).length == 1 &&
                (e.key as Uint8List)[0] == 9,
          )
          .single;
      expect(bytesKeyEntry.value, 'bytes-key');
      expect(decoded[DateTime.utc(2024)], 'date-key');
      // A List key cannot be looked up by a fresh list (identity equality),
      // so find it structurally via the entries.
      final listKeyEntry = decoded.entries
          .where(
            (e) =>
                e.key is List &&
                listEquals.equals(e.key as List, <Object?>[1, 2]),
          )
          .single;
      expect(listKeyEntry.value, 'list-key');
    });

    test('map iteration order is byte-stable', () {
      final map = <Object?, Object?>{'a': 1, 'b': 2, 'c': 3};
      final first = codec.encode(map);
      final second = codec.encode({...map});
      expect(first, second, reason: 'identical maps must encode identically');
      // Re-decoding preserves insertion order.
      final decoded = codec.decode(first) as Map;
      expect(decoded.keys.toList(), ['a', 'b', 'c']);
    });

    test('invalid UTF-8 in a string decodes to a typed error', () {
      // string tag 0x05, length 1, byte 0xFF (invalid UTF-8).
      final bytes = <int>[0x05, 0, 0, 0, 1, 0xFF];
      expect(() => codec.decode(bytes), throwsA(isA<WireDecodeException>()));
    });

    test('deeply nested lists round-trip to a safe depth', () {
      // No explicit depth guard today; a depth that stays within the Dart
      // stack must round-trip (the "no guard" behavior is pinned by this
      // completing rather than throwing).
      Object? nested;
      for (var i = 0; i < 100; i++) {
        nested = [nested];
      }
      final decoded = codec.decode(codec.encode(nested)) as List<Object?>;
      expect(decoded, isA<List<Object?>>());
    });

    test('unknown tag bytes are rejected with a typed error', () {
      for (final tag in [0x0A, 0x7F, 0xFF]) {
        expect(() => codec.decode([tag]), throwsA(isA<WireDecodeException>()));
      }
    });

    test('trailing bytes after a value are rejected', () {
      expect(
        () => codec.decode(<int>[0x00, 0x00]),
        throwsA(isA<WireDecodeException>()),
      );
    });
  });

  group('2.4 op codec', () {
    test('invalid UTF-8 table name leaks a raw FormatException (pinned)', () {
      // version=1, count=1, kind=Put(0), table string len 1 + 0xFF, then four
      // null presence bytes.
      final bytes = <int>[1, 1, 0, 1, 0xFF, 0, 0, 0, 0];
      expect(
        () => Op.decodeBatch(bytes),
        throwsA(isA<FormatException>()),
        reason: 'the table-name decode currently surfaces FormatException',
      );
    });

    test('non-canonical presence byte (0x02) is tolerated as present', () {
      // version=1, count=1, Put, table "" , key absent, value present with
      // presence 0x02, len 1, [9], start/end absent.
      final bytes = <int>[1, 1, 0, 0, 0, 0x02, 1, 9, 0, 0];
      final ops = Op.decodeBatch(bytes);
      expect(ops, hasLength(1));
      expect(ops.single.value, [9]);
    });

    test('put with a null value round-trips', () {
      final op = Op(op: OpKind.put, table: 'items', key: codec.encode('k'));
      final decoded = Op.decodeBatch(Op.encodeBatch([op])).single;
      expect(decoded.op, OpKind.put);
      expect(decoded.table, 'items');
      expect(decoded.value, isNull);
      expect(decoded.key, codec.encode('k'));
    });

    test('op batch with no ops decodes to an empty list', () {
      expect(Op.decodeBatch([1, 0]), isEmpty);
    });

    test('unknown op kind index is a typed OpDecodeException', () {
      final bytes = <int>[1, 1, 99, 0, 0, 0, 0, 0];
      expect(() => Op.decodeBatch(bytes), throwsA(isA<OpDecodeException>()));
    });
  });
}
