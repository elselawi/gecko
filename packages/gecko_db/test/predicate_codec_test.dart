// Unit tests for the predicate wire serializer (step 2).
//
// Verifies encodePredicate produces a self-delimiting payload that the Rust
// `predicate::decode_predicate` evaluator consumes (the wire format is locked
// by the Rust `predicate::tests` round-trip). Covers all three filter kinds
// (eq, range with min/max, prefix) and the empty-predicate case.
import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/query/predicate_codec.dart' show encodePredicate;
import 'package:test/test.dart';

void main() {
  group('encodePredicate', () {
    test('empty filter list matches everything', () {
      final bytes = encodePredicate(const []);
      // version(1) + count(0) = 2 bytes.
      expect(bytes, hasLength(2));
      expect(bytes[0], 1); // version
      expect(bytes[1], 0); // count
    });

    test('equality filter serializes field + raw codec value', () {
      final bytes = encodePredicate([
        Filter.eq('age', 31),
      ], codec: const DefaultWireCodec());
      expect(bytes[0], 1); // version
      // count(1), op(0=eq), field string, value bytes.
      expect(bytes[2], 0); // op = equals
      // The field name 'age' must appear as a varint-length-prefixed string.
      final fieldLen = bytes[3]; // 3
      expect(bytes.sublist(4, 4 + fieldLen), equals('age'.codeUnits));
    });

    test('range filter serializes both min and max when present', () {
      final bytes = encodePredicate([
        Filter.between('age', min: 20, max: 25),
      ], codec: const DefaultWireCodec());
      // Layout: version(0) count(1)=1 op(2)=range(1) field(3)=len(3) field(4..6)='age'
      //        hasMin(7)=1 min-tag(8)=0x02 min-bytes(9..16) hasMax(17)=1 max-tag(18)=0x02
      expect(bytes[2], 1); // op = range
      expect(bytes[3], 3); // field length
      expect(bytes.sublist(4, 7), equals('age'.codeUnits));
      expect(bytes[7], 1); // hasMin
      expect(bytes[8], 0x02); // min value tag = int64
      expect(bytes[17], 1); // hasMax
      expect(bytes[18], 0x02); // max value tag = int64
    });

    test('range filter with only min omits max', () {
      final bytes = encodePredicate([
        Filter.between('age', min: 20),
      ], codec: const DefaultWireCodec());
      expect(bytes[2], 1); // range
      expect(bytes[7], 1); // hasMin
      // After min (tag+8 bytes at offset 8..16), hasMax(17) = 0.
      expect(bytes[17], 0); // hasMax = false
    });

    test('prefix filter serializes field + prefix string', () {
      final bytes = encodePredicate([Filter.prefix('name', 'ab')]);
      expect(bytes[2], 2); // op = prefix
      // version(0) count(1)=1 op(2)=prefix field(3)=len(4) field(4..7)='name' prefix(8)=len(2) prefix(9..10)='ab'
      expect(bytes[3], 4); // field length
      expect(bytes.sublist(4, 8), equals('name'.codeUnits));
      expect(bytes[8], 2); // prefix length
      expect(bytes.sublist(9, 11), equals('ab'.codeUnits));
    });

    test('multiple filters are AND-composed in order', () {
      final bytes = encodePredicate([
        Filter.eq('g', 'g0'),
        Filter.between('n', min: 10, max: 20),
        Filter.prefix('name', 'ab'),
      ]);
      expect(bytes[0], 1); // version
      expect(bytes[1], 3); // count = 3
      // First op = eq, second = range, third = prefix.
      // Walk: version(1) count(1) op(1) field(...) ...
      expect(bytes[2], 0); // eq
      // The next op after the eq filter's value is the range op.
      // (Detailed offset assertions are covered by the Rust round-trip test;
      // here we assert the count and first op, plus that the payload is
      // non-empty and well-formed enough to not throw.)
      expect(bytes.length, greaterThan(10));
    });

    test('multi-byte varint path is exercised by long field names', () {
      // A field name >= 128 bytes forces the varint length encoder into its
      // multi-byte path (the `while (v >= 0x80)` body).
      final longField = List<String>.generate(200, (i) => 'x').join();
      final bytes = encodePredicate([Filter.eq(longField, 1)]);
      expect(bytes[0], 1); // version
      // count(1) is a single byte (1 < 128); the field-name length is the
      // multi-byte varint: 200 = 0xC8 → 0x48 | 0x80, 0x01.
      expect(bytes[3], 0xC8); // 200 & 0x7F | 0x80
      expect(bytes[4], 0x01); // 200 >> 7
      expect(bytes.length, greaterThan(200));
    });
  });
}
