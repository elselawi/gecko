import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test('compatibility handshake round-trips deterministically', () {
    const handshake = CompatibilityHandshake(
      packageVersion: geckoPackageVersion,
      wireVersion: geckoWireVersion,
      formatVersion: geckoFormatVersion,
      nativeBuildId: '0.0.1+rust',
    );

    final encoded = handshake.encode();
    expect(CompatibilityHandshake.decode(encoded).toJson(), handshake.toJson());
    expect(encoded, handshake.encode());
  });

  test('incompatible native package is a typed upgrade error', () {
    const handshake = CompatibilityHandshake(
      packageVersion: '9.9.9',
      wireVersion: geckoWireVersion,
      formatVersion: geckoFormatVersion,
      nativeBuildId: '9.9.9+rust',
    );

    expect(
      () => handshake.validateCompatibility(),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.upgradeRequired,
        ),
      ),
    );
  });

  test('malformed handshake is a typed checksum error', () {
    expect(
      () => CompatibilityHandshake.decode('[]'),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.checksumMismatch,
        ),
      ),
    );
  });

  test('non-JSON handshake text is a typed checksum error', () {
    expect(
      () => CompatibilityHandshake.decode('this is not json'),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.checksumMismatch,
        ),
      ),
    );
  });

  test('wrongly-typed handshake fields are a typed checksum error', () {
    expect(
      () => CompatibilityHandshake.decode(
        '{"handshakeVersion":"one","packageVersion":1,"wireVersion":2,'
        '"formatVersion":3,"nativeBuildId":"x"}',
      ),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.checksumMismatch,
        ),
      ),
    );
  });
}
