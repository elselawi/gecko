/// Dart/native compatibility handshake contract.
///
/// The handshake is exchanged before a native worker is used. It deliberately
/// carries both protocol versions and the native build identity so an
/// incompatible artifact fails with an actionable typed error instead of a
/// message-channel failure.
library;

import 'dart:convert';

import '../errors/errors.dart';
import 'format_header.dart';

/// Version of the handshake JSON contract itself.
const int geckoHandshakeVersion = 1;

/// Package version pinned by the current compatibility matrix.
const String geckoPackageVersion = '0.0.1';

/// A deterministic Dart/native compatibility handshake.
class CompatibilityHandshake {
  const CompatibilityHandshake({
    this.handshakeVersion = geckoHandshakeVersion,
    required this.packageVersion,
    required this.wireVersion,
    required this.formatVersion,
    required this.nativeBuildId,
  });

  final int handshakeVersion;
  final String packageVersion;
  final int wireVersion;
  final int formatVersion;
  final String nativeBuildId;

  Map<String, Object?> toJson() => <String, Object?>{
    'handshakeVersion': handshakeVersion,
    'packageVersion': packageVersion,
    'wireVersion': wireVersion,
    'formatVersion': formatVersion,
    'nativeBuildId': nativeBuildId,
  };

  /// Encodes the handshake with stable field insertion order.
  String encode() => jsonEncode(toJson());

  static CompatibilityHandshake decode(String encoded) {
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException catch (error) {
      throw GeckoError(
        GeckoErrorType.checksumMismatch,
        'Invalid native compatibility handshake JSON: $error',
      );
    }
    if (decoded is! Map) {
      throw const GeckoError(
        GeckoErrorType.checksumMismatch,
        'Native compatibility handshake must be a JSON object',
      );
    }
    try {
      return CompatibilityHandshake(
        handshakeVersion: _intField(decoded, 'handshakeVersion'),
        packageVersion: _stringField(decoded, 'packageVersion'),
        wireVersion: _intField(decoded, 'wireVersion'),
        formatVersion: _intField(decoded, 'formatVersion'),
        nativeBuildId: _stringField(decoded, 'nativeBuildId'),
      );
    } on FormatException catch (error) {
      throw GeckoError(
        GeckoErrorType.checksumMismatch,
        'Invalid native compatibility handshake: $error',
      );
    }
  }

  /// Validates the pinned package/wire/format compatibility matrix.
  ///
  /// [nativeBuildId] is intentionally reported rather than compared: build
  /// identity is diagnostic metadata, while compatibility is determined by
  /// this versioned matrix.
  void validateCompatibility({
    int expectedHandshakeVersion = geckoHandshakeVersion,
    String expectedPackageVersion = geckoPackageVersion,
    int expectedWireVersion = geckoWireVersion,
    int expectedFormatVersion = geckoFormatVersion,
  }) {
    if (handshakeVersion != expectedHandshakeVersion ||
        packageVersion != expectedPackageVersion ||
        wireVersion != expectedWireVersion ||
        formatVersion != expectedFormatVersion ||
        nativeBuildId.trim().isEmpty) {
      throw GeckoError(
        GeckoErrorType.upgradeRequired,
        'Native gecko_db artifact is incompatible with this package '
        '(native package $packageVersion, wire $wireVersion, format '
        '$formatVersion; expected package $expectedPackageVersion, wire '
        '$expectedWireVersion, format $expectedFormatVersion)',
        details: <String, Object?>{
          'handshakeVersion': handshakeVersion,
          'packageVersion': packageVersion,
          'wireVersion': wireVersion,
          'formatVersion': formatVersion,
          'nativeBuildId': nativeBuildId,
          'expectedHandshakeVersion': expectedHandshakeVersion,
          'expectedPackageVersion': expectedPackageVersion,
          'expectedWireVersion': expectedWireVersion,
          'expectedFormatVersion': expectedFormatVersion,
        },
      );
    }
  }

  static int _intField(Map<dynamic, dynamic> map, String name) {
    final value = map[name];
    if (value is int) return value;
    throw FormatException('"$name" must be an integer');
  }

  static String _stringField(Map<dynamic, dynamic> map, String name) {
    final value = map[name];
    if (value is String) return value;
    throw FormatException('"$name" must be a string');
  }
}
