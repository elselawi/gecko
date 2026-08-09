/// Versioned on-disk/wire compatibility header (Phase 0 contract).
///
/// This header is deliberately independent of the native worker so the Dart
/// side can validate artifacts before handing bytes to FFI. The native worker
/// must emit/consume the same fixed layout before a file is opened.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../errors/errors.dart';

/// Current on-disk format version.
const int geckoFormatVersion = 1;

/// Current Dart/native wire protocol version.
const int geckoWireVersion = 1;

/// A deterministic compatibility header.
class FormatHeader {
  const FormatHeader({
    this.formatVersion = geckoFormatVersion,
    this.wireVersion = geckoWireVersion,
    required this.packageVersion,
  });

  static const List<int> magic = <int>[0x47, 0x45, 0x43, 0x4B, 0x4F, 0x01];

  final int formatVersion;
  final int wireVersion;
  final String packageVersion;

  Uint8List encode() {
    final version = utf8.encode(packageVersion);
    if (version.length > 255 ||
        formatVersion < 0 ||
        formatVersion > 255 ||
        wireVersion < 0 ||
        wireVersion > 255) {
      throw GeckoError(
        GeckoErrorType.invalidOperation,
        'Format header values are outside the supported wire range',
      );
    }
    return Uint8List.fromList(<int>[
      ...magic,
      formatVersion,
      wireVersion,
      version.length,
      ...version,
    ]);
  }

  static FormatHeader decode(List<int> bytes) {
    if (bytes.length < magic.length + 3 || !_startsWith(bytes, magic)) {
      throw GeckoError(
        GeckoErrorType.checksumMismatch,
        'Invalid gecko_db format header magic or truncated header',
      );
    }
    final packageLength = bytes[magic.length + 2];
    final expectedLength = magic.length + 3 + packageLength;
    if (bytes.length != expectedLength) {
      throw GeckoError(
        GeckoErrorType.checksumMismatch,
        'Invalid gecko_db format header length',
      );
    }
    final formatVersion = bytes[magic.length];
    final wireVersion = bytes[magic.length + 1];
    final packageVersion = utf8.decode(bytes.sublist(magic.length + 3));
    return FormatHeader(
      formatVersion: formatVersion,
      wireVersion: wireVersion,
      packageVersion: packageVersion,
    );
  }

  /// Throws `upgradeRequired` when the header is not readable by this client.
  void validateCompatibility({
    int expectedFormatVersion = geckoFormatVersion,
    int expectedWireVersion = geckoWireVersion,
  }) {
    if (formatVersion != expectedFormatVersion ||
        wireVersion != expectedWireVersion) {
      throw GeckoError(
        GeckoErrorType.upgradeRequired,
        'Database format $formatVersion/wire $wireVersion requires an upgrade '
        '(expected format $expectedFormatVersion/wire $expectedWireVersion)',
        details: <String, Object?>{
          'formatVersion': formatVersion,
          'wireVersion': wireVersion,
          'expectedFormatVersion': expectedFormatVersion,
          'expectedWireVersion': expectedWireVersion,
        },
      );
    }
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }
}
