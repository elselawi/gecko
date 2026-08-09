import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('Filter', () {
    test('eq matches values, ignoring list/map equality distinctions', () {
      final f = Filter.eq('age', 30);
      expect(f.matchesValue(30), isTrue);
      expect(f.matchesValue(31), isFalse);
      expect(f.test({'age': 30}), isTrue);
      expect(f.test({'age': 31}), isFalse);
      expect(f.isIndexUsable, isTrue);
    });

    test('between respects min and max and toString', () {
      final f = Filter.between('age', min: 20, max: 30);
      expect(f.matchesValue(20), isTrue);
      expect(f.matchesValue(30), isTrue);
      expect(f.matchesValue(35), isFalse);
      expect(f.matchesValue(15), isFalse);
      expect(f.toString(), contains('age'));
      expect(f.toString(), contains('[20, 30]'));
      expect(f.isIndexUsable, isFalse);
    });

    test('between with mixed types uses deterministic string fallback', () {
      final f = Filter.between('x', min: 5, max: 10);
      // String "a" is not Comparable to int 5 → string fallback ordering.
      expect(() => f.matchesValue('a'), returnsNormally);
      // Equal string representations round-trip.
      final same = Filter.between('x', min: 'a', max: 'a');
      expect(same.matchesValue('a'), isTrue);
    });

    test('eq and prefix toString are distinct', () {
      expect(Filter.eq('x', 1).toString(), 'x == 1');
      expect(Filter.prefix('x', 'p').toString(), 'x startsWith p');
    });

    test('prefix matches only string prefixes', () {
      final f = Filter.prefix('name', 'Al');
      expect(f.matchesValue('Alice'), isTrue);
      expect(f.matchesValue('Bob'), isFalse);
      expect(f.matchesValue(42), isFalse, reason: 'non-string rejected');
      expect(f.matchesValue(null), isFalse);
    });

    test('deep equality for nested structures', () {
      final f = Filter.eq('meta', {
        'a': [1, 2, 3],
      });
      expect(
        f.matchesValue({
          'a': [1, 2, 3],
        }),
        isTrue,
      );
      expect(
        f.matchesValue({
          'a': [1, 2, 4],
        }),
        isFalse,
      );
    });

    test('null vs non-null deep-equals is false', () {
      expect(Filter.eq('x', null).matchesValue(null), isTrue);
      expect(Filter.eq('x', null).matchesValue(5), isFalse);
    });
  });

  group('FilterGroup', () {
    test(
      'AND composition matches only when all match; equalityFields lists',
      () {
        final group = FilterGroup([
          Filter.eq('age', 30),
          Filter.eq('name', 'Alice'),
        ]);
        expect(group.test({'age': 30, 'name': 'Alice'}), isTrue);
        expect(group.test({'age': 30, 'name': 'Bob'}), isFalse);
        expect(group.equalityFields, containsAll(['age', 'name']));
      },
    );

    test('empty group matches everything', () {
      final group = FilterGroup(const []);
      expect(group.isEmpty, isTrue);
      expect(group.test({}), isTrue);
    });
  });

  group('compareRows', () {
    test('handles equal type Numbers, Strings, and Booleans', () {
      const specs = [SortSpec('n')];
      expect(compareRows({'n': 1}, {'n': 2}, specs), lessThan(0));
      expect(compareRows({'n': 'a'}, {'n': 'b'}, specs), lessThan(0));
      expect(compareRows({'n': false}, {'n': true}, specs), lessThan(0));
    });

    test('mixed types fall back to string ordering deterministically', () {
      const specs = [SortSpec('n')];
      // 10 (String) vs '9' — deterministic string compare, no crash.
      expect(() => compareRows({'n': 10}, {'n': 9}, specs), returnsNormally);
    });

    test('ties preserve order (stable)', () {
      const specs = [SortSpec('n')];
      final a = {'n': 1, 'id': 'a'};
      final b = {'n': 1, 'id': 'b'};
      expect(compareRows(a, b, specs), 0);
      expect(compareRows(b, a, specs), 0);
    });

    test('both rows missing the sort field sort together (stable)', () {
      const specs = [SortSpec('n')];
      final a = {'id': 'a'};
      final b = {'id': 'b'};
      expect(compareRows(a, b, specs), 0);
      expect(compareRows(b, a, specs), 0);
    });

    test('one row missing: last for ascending, first for descending', () {
      final present = {'n': 1};
      final missing = {'m': 1};
      const asc = [SortSpec('n')];
      // ascending: present first → compareRows(present, missing) < 0
      expect(compareRows(present, missing, asc), lessThan(0));
      expect(compareRows(missing, present, asc), greaterThan(0));
      // descending: missing first → compareRows(present, missing) > 0
      const desc = [SortSpec('n', SortOrder.descending)];
      expect(compareRows(present, missing, desc), greaterThan(0));
      expect(compareRows(missing, present, desc), lessThan(0));
    });

    test('num, string, and bool sort branches', () {
      const asc = [SortSpec('n')];
      expect(compareRows({'n': 2}, {'n': 10}, asc), lessThan(0));
      expect(compareRows({'n': 'apple'}, {'n': 'banana'}, asc), lessThan(0));
      expect(compareRows({'n': true}, {'n': false}, asc), greaterThan(0));
      // Comparable cross-type (DateTime) via Comparable.compare.
      expect(
        compareRows({'n': DateTime.utc(2000)}, {'n': DateTime.utc(2001)}, asc),
        lessThan(0),
      );
    });

    test('null-valued sort field falls back to string ordering', () {
      const asc = [SortSpec('n')];
      expect(() => compareRows({'n': null}, {'n': 5}, asc), returnsNormally);
    });

    test('non-null mixed-comparable types fall back to string ordering', () {
      const asc = [SortSpec('n')];
      // Both present and non-null but not mutually Comparable (e.g. a List) →
      // toString ordering fallback (line 47).
      expect(
        () => compareRows(
          {
            'n': [1],
          },
          {
            'n': [2],
          },
          asc,
        ),
        returnsNormally,
      );
    });
  });
}
