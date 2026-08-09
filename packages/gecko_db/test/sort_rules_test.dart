import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('Sort rules: deterministic byte ordering', () {
    test('integers sort by byte order (fixed-width big-endian)', () {
      final values = [-5, -1, 0, 1, 7, 42];
      final encoded = values
          .map(sortBytesFor)
          .map((b) => List<int>.from(b))
          .toList();
      final sorted = values.toList()
        ..sort(
          (a, b) => _compareBytes(
            encoded[values.indexOf(a)],
            encoded[values.indexOf(b)],
          ),
        );
      expect(sorted, [-5, -1, 0, 1, 7, 42]);
    });

    test('strings sort byte-wise', () {
      final values = ['a', 'b', 'aa', 'ab', ''];
      final encoded = values.map(sortBytesFor).toList();
      final sorted = List<String>.from(values)
        ..sort(
          (a, b) => _compareBytes(
            encoded[values.indexOf(a)],
            encoded[values.indexOf(b)],
          ),
        );
      expect(sorted, ['', 'a', 'aa', 'ab', 'b']);
    });

    test('mixed types throw for unregistered types', () {
      expect(() => sortBytesFor(Object()), throwsArgumentError);
    });

    test('null rounds to a fixed byte', () {
      expect(sortBytesFor(null), equals([0]));
    });

    test('booleans sort false < true', () {
      expect(
        _compareBytes(sortBytesFor(false), sortBytesFor(true)),
        lessThan(0),
      );
    });

    test('BigInt sorts consistently with int for the same value', () {
      final small = BigInt.from(42);
      final big = BigInt.from(1) << 80;
      final negative = -BigInt.from(7);
      // Ordering must hold: negative < small < big.
      expect(
        _compareBytes(sortBytesFor(negative), sortBytesFor(small)),
        lessThan(0),
      );
      expect(
        _compareBytes(sortBytesFor(small), sortBytesFor(big)),
        lessThan(0),
      );
      // An int and a BigInt of equal magnitude must order consistently.
      expect(
        _compareBytes(sortBytesFor(42), sortBytesFor(BigInt.from(42))),
        lessThan(0),
      );
    });

    test('doubles sort in numeric order including negatives', () {
      final values = [-1.5, -0.0, 0.0, 0.5, 2.0];
      final encoded = values.map(sortBytesFor).toList();
      final sorted = List<double>.from(values)
        ..sort(
          (a, b) => _compareBytes(
            encoded[values.indexOf(a)],
            encoded[values.indexOf(b)],
          ),
        );
      expect(sorted, [-1.5, -0.0, 0.0, 0.5, 2.0]);
    });

    test(
      'NaN orders after all finite values and infinity orders numerically',
      () {
        final inf = sortBytesFor(double.infinity);
        final negInf = sortBytesFor(-double.infinity);
        final zero = sortBytesFor(0.0);
        final nan = sortBytesFor(double.nan);

        expect(_compareBytes(negInf, zero), lessThan(0));
        expect(_compareBytes(zero, inf), lessThan(0));
        expect(_compareBytes(inf, nan), lessThan(0), reason: 'NaN sorts last');
      },
    );

    test('DateTime ordering matches underlying int ordering', () {
      final a = DateTime.fromMicrosecondsSinceEpoch(1000, isUtc: true);
      final b = DateTime.fromMicrosecondsSinceEpoch(2000, isUtc: true);
      expect(_compareBytes(sortBytesFor(a), sortBytesFor(b)), lessThan(0));
    });
  });

  group('Wire codec round-trip (sortable helpers)', () {
    const codec = DefaultWireCodec();
    test('standardSortRules covers expected scalars', () {
      expect(
        standardSortRules.keys,
        containsAll(['int', 'String', 'double', 'bool', 'DateTime', 'BigInt']),
      );
      for (final rule in standardSortRules.values) {
        expect(rule.isSortable, isTrue);
      }
    });

    test('SortRule exposes name, isSortable, and toString', () {
      expect(SortRule.bigEndian.name, 'bigEndian');
      expect(SortRule.bigEndian.isSortable, isTrue);
      expect(SortRule.unordered.name, 'unordered');
      expect(SortRule.unordered.isSortable, isFalse);
      expect(SortRule.bigEndian.toString(), 'SortRule.bigEndian');
      expect(SortRule.unordered.toString(), 'SortRule.unordered');
    });

    test(
      'DateTime sorts by microsecond epoch (epoch-close value stays exact)',
      () {
        final a = DateTime.fromMicrosecondsSinceEpoch(
          1700000000123456,
          isUtc: true,
        );
        final b = DateTime.fromMicrosecondsSinceEpoch(
          1700000000123457,
          isUtc: true,
        );
        expect(_compareBytes(sortBytesFor(a), sortBytesFor(b)), lessThan(0));
        expect(codec.decode(codec.encode(a)) as DateTime, a);
      },
    );
  });
}

int _compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length.compareTo(b.length);
}
