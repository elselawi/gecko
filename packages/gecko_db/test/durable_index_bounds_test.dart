// Unit tests for the durable-index bound helpers (order-preserving elements,
// Priority 5).
//
// The bounds must form lexicographic ranges that match exactly the durable
// `__gecko_index` keys whose composite is `[table, field, value, recordId]`,
// with the VALUE element in the order-preserving encoding from
// `rust/src/value_codec.rs`, and `_incrementLastByte` must carry on 0xFF
// (including the all-0xFF edge).
import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/query/durable_index_bounds.dart'
    show eqBounds, fieldBounds, prefixBounds, rangeBounds, orderedIndexElement;
import 'package:gecko_db/src/wire/wire_codec.dart';
import 'package:test/test.dart';

void main() {
  group('durable_index_bounds.eqBounds', () {
    test('start is the byte prefix of every matching 4-element key', () {
      final (start, end) = eqBounds('items', 'group', 'g0');
      // Three real recordIds — all must fall inside [start..=end].
      for (final id in <Object?>['r0', 'r42', 9999, null]) {
        final key = _key('items', 'group', 'g0', id);
        expect(
          _lexCompare(key, start) >= 0,
          isTrue,
          reason: 'key for id=$id must be >= start',
        );
        expect(
          _lexCompare(key, end) <= 0,
          isTrue,
          reason: 'key for id=$id must be <= end',
        );
      }
    });

    test('a different value is excluded from the range', () {
      final (start, end) = eqBounds('items', 'group', 'g0');
      final other = _key('items', 'group', 'g1', 'r0');
      // The next value's first key sorts strictly after end (recordId is
      // always appended, so no key equals end itself).
      expect(
        _lexCompare(other, end),
        greaterThan(0),
        reason: 'a key for a different value must be excluded',
      );
      expect(
        _lexCompare(other, start),
        greaterThan(0),
        reason: 'a different value sorts after start too',
      );
    });

    test('a different table/field is excluded', () {
      final (start, end) = eqBounds('items', 'group', 'g0');
      final otherTable = _key('other', 'group', 'g0', 'r0');
      final otherField = _key('items', 'name', 'g0', 'r0');
      for (final other in [otherTable, otherField]) {
        expect(
          _lexCompare(other, start),
          isNot(0),
          reason: 'different table/field must not equal start',
        );
      }
    });

    test('_incrementLastByte carries on trailing 0xFF (value = max int64)', () {
      // int64 max = 0x7FFF…FF; the flipped big-endian encoding of -1 is
      // 0xFF…FF, so the bounds for -1 exercise the full 0xFF carry path.
      final (start, end) = eqBounds('t', 'f', -1);
      final key = _key('t', 'f', -1, 'id');
      expect(_lexCompare(key, start), greaterThanOrEqualTo(0));
      expect(_lexCompare(key, end), lessThanOrEqualTo(0));
    });
  });

  group('durable_index_bounds.rangeBounds', () {
    test('tight int range includes only values in [min, max]', () {
      final (start, end) = rangeBounds('t', 'age', 20, 30);
      for (final v in <int>[20, 21, 25, 29, 30]) {
        final key = _key('t', 'age', v, 'r0');
        expect(
          _lexCompare(key, start) >= 0 && _lexCompare(key, end) <= 0,
          isTrue,
          reason: '$v is in [20, 30] and must be inside the bounds',
        );
      }
      for (final v in <int>[-100, -1, 0, 19, 31, 100]) {
        final key = _key('t', 'age', v, 'r0');
        expect(
          _lexCompare(key, start) < 0 || _lexCompare(key, end) > 0,
          isTrue,
          reason: '$v is outside [20, 30] and must be excluded',
        );
      }
    });

    test('open-ended bounds fall back to the full field span', () {
      final (loNull, hiNull) = rangeBounds('t', 'age', null, null);
      final (allLo, allHi) = fieldBounds('t', 'age');
      expect(_lexCompare(loNull, allLo), 0);
      expect(_lexCompare(hiNull, allHi), 0);
      final (loOnly, _) = rangeBounds('t', 'age', null, 30);
      expect(
        _lexCompare(loOnly, allLo),
        0,
        reason: 'no min => start is the field prefix',
      );
      final (_, hiOnly) = rangeBounds('t', 'age', 20, null);
      expect(
        _lexCompare(hiOnly, allHi),
        0,
        reason: 'no max => end is the field prefix + 1',
      );
    });
  });

  group('durable_index_bounds.prefixBounds', () {
    test('string prefix is a contiguous exact range', () {
      final (start, end) = prefixBounds('t', 'name', 'g1');
      for (final s in ['g1', 'g10', 'g123', 'g1a', 'g1z']) {
        final key = _key('t', 'name', s, 'r0');
        expect(
          _lexCompare(key, start) >= 0 && _lexCompare(key, end) <= 0,
          isTrue,
          reason: '"$s" starts with g1 and must be inside the bounds',
        );
      }
      for (final s in ['g', 'g0', 'g2', 'h1', 'G1', 'gg']) {
        final key = _key('t', 'name', s, 'r0');
        expect(
          _lexCompare(key, start) < 0 || _lexCompare(key, end) > 0,
          isTrue,
          reason: '"$s" does not start with g1 and must be excluded',
        );
      }
    });
  });

  group('durable_index_bounds ordered elements', () {
    test('int elements sort by semantic value (negatives included)', () {
      expect(
        _lexCompare(orderedIndexElement(-10), orderedIndexElement(-1)),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement(-1), orderedIndexElement(0)),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement(0), orderedIndexElement(1)),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement(1), orderedIndexElement(999)),
        lessThan(0),
      );
      expect(_lexCompare(orderedIndexElement(1), orderedIndexElement(1)), 0);
    });

    test('f64 elements use total order', () {
      expect(
        _lexCompare(
          orderedIndexElement(-double.infinity),
          orderedIndexElement(-1.5),
        ),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement(-1.5), orderedIndexElement(0.0)),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement(0.0), orderedIndexElement(1.5)),
        lessThan(0),
      );
    });

    test('string elements sort lexically and are self-delimiting', () {
      expect(
        _lexCompare(orderedIndexElement('a'), orderedIndexElement('b')),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement('ab'), orderedIndexElement('abc')),
        lessThan(0),
      );
      expect(
        _lexCompare(orderedIndexElement('abc'), orderedIndexElement('ac')),
        lessThan(0),
      );
    });

    test('elements are prefix-free (terminator prevents overlap)', () {
      final a = orderedIndexElement('ab');
      final b = orderedIndexElement('abc');
      expect(
        _startsWith(b, a),
        isFalse,
        reason: 'escaped terminator keeps values self-delimiting',
      );
      expect(_startsWith(a, b), isFalse);
    });
  });
}

/// Builds a durable-index key in the Priority 5 layout:
/// `[0x06, u32(4)] | encode(table) | encode(field) | orderedIndexElement(value)
/// | encode(recordId)`.
List<int> _key(String table, String field, Object? value, Object? id) {
  final codec = const DefaultWireCodec();
  return <int>[
    0x06,
    0,
    0,
    0,
    4,
    ...codec.encode(table),
    ...codec.encode(field),
    ...orderedIndexElement(value, codec: codec),
    ...codec.encode(id),
  ];
}

bool _startsWith(List<int> a, List<int> b) {
  if (a.length < b.length) return false;
  for (var i = 0; i < b.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Lexicographic byte comparison: <0 if a<b, 0 if equal, >0 if a>b.
int _lexCompare(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = (a[i] & 0xFF) - (b[i] & 0xFF);
    if (d != 0) return d;
  }
  return a.length - b.length;
}
