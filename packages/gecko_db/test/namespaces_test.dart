import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

/// boundary: the `__gecko_*` reserved-namespace policy. User table names must
/// never collide with engine metadata tables, and rejection must be a typed
/// error, never a `StateError`.
void main() {
  group('isReservedName', () {
    test('returns true for any name with the reserved prefix', () {
      expect(isReservedName('__gecko_x'), isTrue);
      expect(isReservedName('__gecko_change_log'), isTrue);
      expect(isReservedName('__gecko_'), isTrue);
    });

    test('returns false for ordinary user table names', () {
      expect(isReservedName('users'), isFalse);
      expect(isReservedName('_gecko_users'), isFalse);
      expect(isReservedName('__geckousers'), isFalse);
      expect(isReservedName(''), isFalse);
    });

    test('constant matches the prefix the predicate uses', () {
      expect(geckoReservedPrefix, '__gecko_');
      expect(isReservedName('$geckoReservedPrefix users'), isTrue);
    });
  });

  group('ensureUserTableName', () {
    test('accepts and returns normal names unchanged', () {
      expect(ensureUserTableName('users'), 'users');
      expect(ensureUserTableName('orders'), 'orders');
    });

    test('rejects reserved names with a typed invalidOperation error', () {
      expect(
        () => ensureUserTableName('__gecko_x'),
        throwsA(
          isA<GeckoError>()
              .having((e) => e.type, 'type', GeckoErrorType.invalidOperation)
              .having((e) => e.message, 'message', contains('__gecko_')),
        ),
      );
    });

    test('rejects an empty name with a typed error', () {
      expect(
        () => ensureUserTableName(''),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
    });

    test('never throws a StateError (untyped failures are not an API)', () {
      expect(
        () => ensureUserTableName('__gecko_sys'),
        throwsA(isA<GeckoError>()),
      );
    });
  });
}
