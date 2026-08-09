import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test('format header round-trips deterministically', () {
    const header = FormatHeader(packageVersion: '0.0.1');
    final bytes = header.encode();
    expect(FormatHeader.decode(bytes).packageVersion, '0.0.1');
    expect(FormatHeader.decode(bytes).formatVersion, geckoFormatVersion);
    expect(FormatHeader.decode(bytes).wireVersion, geckoWireVersion);
    expect(header.encode(), bytes);
  });

  test('header rejects bad magic and malformed lengths', () {
    expect(() => FormatHeader.decode([0, 1, 2]), throwsA(isA<GeckoError>()));
    final valid = const FormatHeader(packageVersion: 'x').encode();
    expect(
      () => FormatHeader.decode(valid.sublist(0, valid.length - 1)),
      throwsA(isA<GeckoError>()),
    );
  });

  test('compatibility mismatch is typed UpgradeRequiredError variant', () {
    const header = FormatHeader(packageVersion: '0.0.1');
    expect(
      () => header.validateCompatibility(expectedWireVersion: 99),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.upgradeRequired,
        ),
      ),
    );
  });

  test('header rejects unsupported values', () {
    expect(
      () => const FormatHeader(packageVersion: 'x').encode(),
      returnsNormally,
    );
  });
}
