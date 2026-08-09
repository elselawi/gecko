import 'dart:convert';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test('native JSON error preserves type, message, and details', () {
    final native = jsonEncode(
      const GeckoError(
        GeckoErrorType.databaseLocked,
        'database is locked',
        details: {'path': 'db.redb'},
      ).toJson(),
    );

    final mapped = mapNativeError(native);
    expect(mapped.type, GeckoErrorType.databaseLocked);
    expect(mapped.message, 'database is locked');
    expect(mapped.details, {'path': 'db.redb'});
  });

  test('native wrapper text containing JSON is mapped', () {
    final native =
        'FRB error: ${jsonEncode(const GeckoError(GeckoErrorType.upgradeRequired, 'native is newer').toJson())}';

    expect(mapNativeError(native).type, GeckoErrorType.upgradeRequired);
  });

  test('unstructured native failures become typed unknown errors', () {
    final mapped = mapNativeError(StateError('worker failed'));
    expect(mapped, isA<GeckoError>());
    expect(mapped.type, GeckoErrorType.unknown);
    expect(mapped.message, contains('worker failed'));
  });
}
