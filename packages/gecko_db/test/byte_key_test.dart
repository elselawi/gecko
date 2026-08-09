import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('ByteKey', () {
    test('value equality, not identity', () {
      final a = ByteKey([1, 2, 3]);
      final b = ByteKey([1, 2, 3]);
      final c = ByteKey([1, 2, 4]);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, b.hashCode);
    });

    test('bytes getter returns a defensive copy', () {
      final k = ByteKey([1, 2, 3]);
      final b = k.bytes;
      b[0] = 99; // mutate the returned copy
      expect(k.bytes, [1, 2, 3], reason: 'mutation must not leak');
      expect(k.length, 3);
      // Each call returns a fresh, distinct list (defensive copy).
      expect(identical(b, k.bytes), isFalse);
    });

    test('byte-wise ordering is deterministic', () {
      final a = ByteKey([1]);
      final b = ByteKey([1, 0]);
      final c = ByteKey([2]);
      // Shorter prefix sorts first; then byte value.
      expect(a.compareTo(b), lessThan(0));
      expect(b.compareTo(c), lessThan(0));
      expect(a.compareTo(a), 0);
      expect(c.compareTo(a), greaterThan(0));
    });

    test('isEmpty and toString', () {
      expect(ByteKey([]).isEmpty, isTrue);
      expect(ByteKey([1]).isEmpty, isFalse);
      expect(ByteKey([0x0A]).toString(), contains('0a'));
    });
  });
}
