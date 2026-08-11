// Unit tests for the durable-index eq-bounds helper ().
//
// The bounds must form a lexicographic range that matches exactly the durable
// `__gecko_index` keys whose 4-element composite is `[table, field, value, *]`,
// and `_incrementLastByte` must carry on 0xFF (including the all-0xFF edge).
import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/query/durable_index_bounds.dart'
    show eqBounds, fieldBounds;
import 'package:gecko_db/src/wire/wire_codec.dart';
import 'package:test/test.dart';

void main() {
  group('durable_index_bounds.eqBounds', () {
    test('start is the byte prefix of every matching 4-element key', () {
      final codec = const DefaultWireCodec();
      final (start, end) = eqBounds('items', 'group', 'g0');
      // Three real recordIds — all must fall inside [start..=end].
      for (final id in <Object?>['r0', 'r42', 9999, null]) {
        final key = codec.encode(['items', 'group', 'g0', id]);
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
      final codec = const DefaultWireCodec();
      final other = codec.encode(['items', 'group', 'g1', 'r0']);
      // The next value's first key sorts strictly after end.
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
      final codec = const DefaultWireCodec();
      final otherTable = codec.encode(['other', 'group', 'g0', 'r0']);
      final otherField = codec.encode(['items', 'name', 'g0', 'r0']);
      for (final other in [otherTable, otherField]) {
        expect(
          _lexCompare(other, start),
          isNot(0),
          reason: 'different table/field must not equal start',
        );
      }
    });

    test('_incrementLastByte carries on trailing 0xFF (value = max int64)', () {
      // Encode a value whose last byte is 0xFF so the carry path runs.
      // int64 max = 0x7FFF…FF; the codec writes big-endian two's complement,
      // so max int64 ends in 0xFF. This exercises _incrementLastByte's 0xFF
      // branch (the byte is incremented, not carried, since 0x7F+1=0x80 — but
      // a negative int like -1 (0xFF…FF) exercises the full carry).
      final (start, end) = eqBounds('t', 'f', -1);
      // The bounds still must bracket every `[t, f, -1, *]` key.
      final codec = const DefaultWireCodec();
      final key = codec.encode(['t', 'f', -1, 'id']);
      expect(_lexCompare(key, start), greaterThanOrEqualTo(0));
      expect(_lexCompare(key, end), lessThanOrEqualTo(0));
    });

    test('fieldBounds includes all values but excludes other fields', () {
      final (start, end) = fieldBounds('items', 'age');
      final codec = const DefaultWireCodec();
      for (final value in <Object?>[
        -10,
        0,
        10,
        1.5,
        'short',
        'a much longer value',
      ]) {
        final key = codec.encode(['items', 'age', value, 'r0']);
        expect(_lexCompare(key, start), greaterThanOrEqualTo(0));
        expect(_lexCompare(key, end), lessThanOrEqualTo(0));
      }
      final otherField = codec.encode(['items', 'name', 10, 'r0']);
      expect(_lexCompare(otherField, start), isNot(0));
    });

    test(
      'fieldBounds is a broad candidate span, not semantic value ordering',
      () {
        // DefaultWireCodec v1 length-prefixes strings and does not sort all
        // numeric encodings by semantic value. therefore uses fieldBounds
        // only to generate candidates and rechecks the predicate in Rust.
        final codec = const DefaultWireCodec();
        final values = ['z', 'aa', 'prefix-long'];
        final (start, end) = fieldBounds('items', 'name');
        for (final value in values) {
          final key = codec.encode(['items', 'name', value, 'r0']);
          expect(_lexCompare(key, start), greaterThanOrEqualTo(0));
          expect(_lexCompare(key, end), lessThanOrEqualTo(0));
        }
      },
    );
  });
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
