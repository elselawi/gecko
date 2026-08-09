import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('FieldPresence: missing vs null vs value', () {
    test('classifies the three distinct states', () {
      final schema = RowSchema.of({
        'name': const FieldSpec(name: 'name'),
        'nickname': const FieldSpec(name: 'nickname'),
        'age': const FieldSpec(name: 'age'),
      });
      final presence = schema.presenceOf({'name': 'A', 'nickname': null});
      expect(presence['name'], FieldPresence.value);
      expect(presence['nickname'], FieldPresence.null_);
      expect(presence['age'], FieldPresence.missing);
    });

    test('unknown fields are not reported (forward-compat untouched)', () {
      final schema = RowSchema.of({'a': const FieldSpec(name: 'a')});
      final presence = schema.presenceOf({'a': 1, 'unknown': 2});
      expect(presence.keys, ['a']);
      expect(presence['a'], FieldPresence.value);
    });

    test('presence of a non-map row reports all fields missing', () {
      final schema = RowSchema.of({'a': const FieldSpec(name: 'a')});
      expect(schema.presenceOf('not-a-map')['a'], FieldPresence.missing);
    });
  });

  group('RowSchema.specFor', () {
    test('finds a declared field and returns null for unknown', () {
      final schema = RowSchema.of({
        'name': const FieldSpec(name: 'name', required: true),
      });
      expect(schema.specFor('name'), isNotNull);
      expect(schema.specFor('name')!.required, isTrue);
      expect(schema.specFor('nope'), isNull);
    });
  });

  group('RowSchema.validate', () {
    test('accepts a valid row (incl. unknown fields)', () {
      final schema = RowSchema.of({
        'name': const FieldSpec(name: 'name', required: true),
      });
      expect(
        schema.validate({'name': 'A', 'extra': 1}),
        isA<Map<Object?, Object?>>(),
      );
    });

    test('rejects a non-map row with a typed error', () {
      final schema = RowSchema.of({'name': const FieldSpec(name: 'name')});
      expect(
        () => schema.validate(42),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.schemaValidation,
          ),
        ),
      );
    });

    test('rejects a missing required field, naming the field', () {
      final schema = RowSchema.of({
        'name': const FieldSpec(name: 'name', required: true),
      });
      expect(
        () => schema.validate({}),
        throwsA(
          isA<GeckoError>()
              .having((e) => e.type, 'type', GeckoErrorType.schemaValidation)
              .having((e) => e.message, 'message', contains('name')),
        ),
      );
    });

    test('rejects a null required field', () {
      final schema = RowSchema.of({
        'name': const FieldSpec(name: 'name', required: true),
      });
      expect(
        () => schema.validate({'name': null}),
        throwsA(
          isA<GeckoError>()
              .having((e) => e.type, 'type', GeckoErrorType.schemaValidation)
              .having(
                (e) => e.message,
                'message',
                contains('must not be null'),
              ),
        ),
      );
    });

    test('a required field with a default can be absent', () {
      final schema = RowSchema.of({
        'name': const FieldSpec(
          name: 'name',
          required: true,
          defaultValue: 'X',
          hasDefault: true,
        ),
      });
      expect(schema.validate({}), isA<Map<Object?, Object?>>());
    });
  });

  group('FieldSpec constructor guard', () {
    test('asserts that a declared default is non-null', () {
      expect(
        () => FieldSpec(name: 'a', hasDefault: true, defaultValue: null),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
