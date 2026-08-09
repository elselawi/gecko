import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('applyPatch', () {
    test('sets a field, preserving an explicit null as distinct', () {
      final result = applyPatch(
        {'name': 'A', 'age': 30},
        [const FieldPatch.set('nickname', null)],
      );
      expect(
        result.row.containsKey('nickname'),
        isTrue,
        reason: 'explicit null is present',
      );
      expect(result.row['nickname'], isNull);
      expect(result.row['name'], 'A', reason: 'unrelated field untouched');
      expect(result.changedFields, contains('nickname'));
    });

    test('remove makes a field missing (distinct from null)', () {
      final result = applyPatch(
        {'name': 'A', 'age': 30},
        [const FieldPatch.remove('age')],
      );
      expect(
        result.row.containsKey('age'),
        isFalse,
        reason: 'removed → missing',
      );
      expect(result.row['name'], 'A');
      expect(result.changedFields, contains('age'));
    });

    test('only changed fields are reported', () {
      final result = applyPatch(
        {'a': 1, 'b': 2},
        [const FieldPatch.set('a', 1), const FieldPatch.set('b', 9)],
      );
      expect(result.changedFields, ['b'], reason: 'a unchanged');
    });

    test('deep list/map comparison detects real changes', () {
      final result = applyPatch(
        {
          'list': [1, 2],
        },
        [
          const FieldPatch.set('list', [1, 2]),
        ], // structurally equal
      );
      expect(result.changedFields, isEmpty, reason: 'structurally unchanged');

      final changed = applyPatch(
        {
          'list': [1, 2],
        },
        [
          const FieldPatch.set('list', [1, 3]),
        ],
      );
      expect(changed.changedFields, ['list']);
    });

    test('rejects a patch on an unknown field when schema-provided', () {
      final schema = RowSchema.of({'a': const FieldSpec(name: 'a')});
      expect(
        () => applyPatch(
          {'a': 1},
          [const FieldPatch.set('zz', 1)],
          schema: schema,
        ),
        throwsA(
          isA<GeckoError>()
              .having((e) => e.type, 'type', GeckoErrorType.schemaValidation)
              .having((e) => e.message, 'message', contains('zz')),
        ),
      );
    });

    test('allows a patch on an unknown field when schema is null', () {
      final result = applyPatch({'a': 1}, [const FieldPatch.set('zz', 5)]);
      expect(result.row['zz'], 5);
    });

    test('validateFields: false allows unknown fields even with a schema', () {
      final schema = RowSchema.of({'a': const FieldSpec(name: 'a')});
      final result = applyPatch(
        {'a': 1},
        [const FieldPatch.set('zz', 5)],
        schema: schema,
        validateFields: false,
      );
      expect(result.row['zz'], 5);
    });

    test('a null set on a required field is rejected', () {
      final schema = RowSchema.of({
        'a': const FieldSpec(name: 'a', required: true),
      });
      expect(
        () => applyPatch(
          {'a': 1},
          [const FieldPatch.set('a', null)],
          schema: schema,
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.schemaValidation,
          ),
        ),
      );
    });
  });

  group('applyDefaults', () {
    test('fills declared defaults for missing fields only', () {
      final schema = RowSchema.of({
        'a': const FieldSpec(name: 'a', hasDefault: true, defaultValue: 0),
        'b': const FieldSpec(name: 'b'),
      });
      final out = applyDefaults({'b': 2}, schema) as Map;
      expect(out['a'], 0, reason: 'default filled');
      expect(out['b'], 2, reason: 'explicit value preserved');
    });

    test('does not overwrite an explicit null with a default', () {
      final schema = RowSchema.of({
        'a': const FieldSpec(name: 'a', hasDefault: true, defaultValue: 0),
      });
      final out = applyDefaults({'a': null}, schema) as Map;
      expect(out.containsKey('a'), isTrue);
      expect(out['a'], isNull, reason: 'explicit null kept');
    });

    test('leaves non-map rows and unknown fields alone', () {
      final schema = RowSchema.of({
        'a': const FieldSpec(name: 'a', hasDefault: true, defaultValue: 0),
      });
      expect(applyDefaults(42, schema), 42, reason: 'non-map passthrough');
      final out = applyDefaults({'z': 9}, schema) as Map;
      expect(out['z'], 9, reason: 'unknown field untouched');
      expect(
        out.containsKey('a'),
        isTrue,
        reason: 'default still added for declared',
      );
    });

    test('deep map equality is detected by _same (via applyPatch)', () {
      // A map-valued field: structurally-equal map is unchanged.
      final same = applyPatch(
        {
          'm': {
            'x': 1,
            'y': [1, 2],
          },
        },
        [
          const FieldPatch.set('m', {
            'x': 1,
            'y': [1, 2],
          }),
        ],
      );
      expect(same.changedFields, isEmpty);

      // A differing map IS a change.
      final diff = applyPatch(
        {
          'm': {'x': 1},
        },
        [
          const FieldPatch.set('m', {'x': 2}),
        ],
      );
      expect(diff.changedFields, ['m']);
    });

    test('a null->value or value->null change is detected', () {
      // Changing a null field to a value IS a change.
      final nullToValue = applyPatch(
        {'a': null},
        [const FieldPatch.set('a', 5)],
      );
      expect(nullToValue.changedFields, ['a']);

      // Changing a value field to null IS a change.
      final valueToNull = applyPatch(
        {'a': 5},
        [const FieldPatch.set('a', null)],
      );
      expect(valueToNull.changedFields, ['a']);
    });
  });

  group('FieldPatch accessors', () {
    test('set vs remove flags', () {
      const s = FieldPatch.set('a', 1);
      const r = FieldPatch.remove('a');
      expect(s.isSet, isTrue);
      expect(s.isRemove, isFalse);
      expect(r.isSet, isFalse);
      expect(r.isRemove, isTrue);
      expect(s.value, 1);
      expect(s.field, 'a');
    });
  });
}
