import 'dart:convert';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('Error taxonomy', () {
    test('every typed error variant is nameable and constructible', () {
      for (final type in GeckoErrorType.values) {
        final e = GeckoError(
          type,
          'message for ${type.name}',
          details: {'field': 'x'},
        );
        expect(e.type, type);
        expect(e.message, contains(type.name));
        expect(e.details, isNotNull);
        expect(e.toString(), contains(type.name));
      }
    });

    test('errors round-trip through JSON without losing type or message', () {
      final samples = <GeckoError>[
        GeckoError(
          GeckoErrorType.keyNotFound,
          'no such key',
          details: {'k': 1},
        ),
        const GeckoError(GeckoErrorType.databaseLocked, 'db is locked'),
        GeckoError.unknown('raw failure', details: {'cause': 'panic'}),
      ];
      for (final e in samples) {
        final back = GeckoError.fromJson(jsonEncode(e.toJson()));
        expect(back.type, e.type, reason: 'type preserved');
        expect(back.message, e.message, reason: 'message preserved');
        if (e.details != null) {
          expect(back.details, e.details, reason: 'details preserved');
        }
      }
    });

    test('fromJson rejects unknown type names', () {
      expect(
        () => GeckoError.fromJson(
          jsonEncode({'type': 'notReal', 'message': 'x'}),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson rejects non-object input', () {
      expect(() => GeckoError.fromJson('[]'), throwsA(isA<FormatException>()));
    });

    test('all subclasses are instances of GeckoError', () {
      final e = GeckoError(GeckoErrorType.schemaValidation, 'bad shape');
      expect(e, isA<Exception>());
      expect(e, isA<GeckoError>());
    });
  });
}
