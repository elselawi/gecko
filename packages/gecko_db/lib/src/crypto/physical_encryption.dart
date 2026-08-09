/// Workstream 4: physical encryption key management.
///
/// Physical encryption wraps every native file page with AES-256-GCM. The key
/// is 32 bytes and is never written to disk; it is supplied either directly
/// through [`DatabaseConfig.physicalEncryptionKey`] or resolved through a
/// [`KeyProvider`] before the file is opened. If no key can be obtained, the
/// open fails with a typed `keyUnavailable` error *before* the file is
/// touched, so a missing key can never silently create a plaintext database.
library;

import 'dart:convert';
import 'dart:io';

import '../errors/errors.dart';
import '../errors/native_error.dart';
import '../native/external_library_loader.dart' show resolveExternalLibrary;
import '../native/generated/api.dart';
import '../native/generated/frb_generated.dart' show RustLib;

/// Key generation assigned to a freshly encrypted database file.
const int initialPhysicalKeyGeneration = 1;

/// How a key string/file is decoded into the raw 32 key bytes.
enum KeyEncoding {
  /// The value is the raw 32 bytes.
  raw,

  /// Lower/upper-case hex, whitespace allowed (e.g. `a1b2…`).
  hex,

  /// Standard base64.
  base64,
}

/// Supplies the 32-byte physical encryption key at open time.
///
/// Implementations must never log or expose the key bytes. Returning `null`
/// signals "key unavailable" and the open fails with a typed
/// `GeckoErrorType.keyUnavailable` error before the file is created.
abstract class KeyProvider {
  /// Human-readable provider name for diagnostics (never the key itself).
  String get name;

  /// Returns the 32-byte key, or `null` when the key is not available.
  Future<List<int>?> obtain();
}

/// A key that is fixed in code (development, tests, or an already-loaded
/// in-memory secret). Do not hardcode production keys.
class FixedKeyProvider implements KeyProvider {
  FixedKeyProvider(List<int> key) : _key = List<int>.unmodifiable(key);

  final List<int> _key;

  @override
  String get name => 'fixed';

  @override
  Future<List<int>?> obtain() async => _key;
}

/// Reads the key from an environment variable (e.g. for CI or container
/// deployments). Never persists the key.
class EnvironmentKeyProvider implements KeyProvider {
  EnvironmentKeyProvider({
    this.environmentVariable = 'GECKO_DB_PHYSICAL_KEY',
    this.encoding = KeyEncoding.hex,
  });

  final String environmentVariable;
  final KeyEncoding encoding;

  @override
  String get name => 'environment:$environmentVariable';

  @override
  Future<List<int>?> obtain() async {
    final value = Platform.environment[environmentVariable];
    if (value == null || value.trim().isEmpty) return null;
    return decodeKey(value.trim(), encoding: encoding);
  }
}

/// Reads the key from a file (e.g. a Docker secret or a provisioned key file).
/// The file must contain exactly the encoded key and nothing else.
class FileKeyProvider implements KeyProvider {
  FileKeyProvider(this.path, {this.encoding = KeyEncoding.hex});

  final String path;
  final KeyEncoding encoding;

  @override
  String get name => 'file:$path';

  @override
  Future<List<int>?> obtain() async {
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    if (encoding == KeyEncoding.raw) return bytes;
    return decodeKey(
      utf8.decode(bytes, allowMalformed: true).trim(),
      encoding: encoding,
    );
  }
}

/// Decodes a textual key. Throws a typed [GeckoError] (`cryptoBackend`) on
/// malformed input or wrong length.
List<int> decodeKey(String value, {KeyEncoding encoding = KeyEncoding.hex}) {
  final List<int> bytes;
  try {
    bytes = switch (encoding) {
      KeyEncoding.raw => throw const FormatException('raw encoding is binary'),
      KeyEncoding.hex => _decodeHex(value),
      KeyEncoding.base64 => base64Decode(value),
    };
  } on FormatException {
    throw GeckoError(
      GeckoErrorType.cryptoBackend,
      'Physical key is not valid ${encoding.name}',
      details: <String, Object?>{'encoding': encoding.name},
    );
  }
  if (bytes.length != 32) {
    throw GeckoError(
      GeckoErrorType.cryptoBackend,
      'Physical encryption key must be exactly 32 bytes (AES-256), got '
      '${bytes.length}',
      details: <String, Object?>{'length': bytes.length},
    );
  }
  return bytes;
}

List<int> _decodeHex(String value) {
  final cleaned = value.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(cleaned)) {
    throw const FormatException('invalid hex');
  }
  final out = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    out.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
  }
  return out;
}

/// Validates that [key] is exactly 32 bytes; throws a typed [GeckoError]
/// otherwise.
void validatePhysicalKey(List<int> key, {String label = 'key'}) {
  if (key.length != 32) {
    throw GeckoError(
      GeckoErrorType.cryptoBackend,
      'Physical encryption $label must be exactly 32 bytes (AES-256), got '
      '${key.length}',
      details: <String, Object?>{'length': key.length},
    );
  }
}

/// Ensures the native library is loaded in the calling isolate so that
/// [`rotatePhysicalKey`] can run without a previously opened database.
Future<void> _ensureNativeLoaded(String? nativeLibraryPath) async {
  try {
    await RustLib.init(
      externalLibrary: await resolveExternalLibrary(
        nativeLibraryPath: nativeLibraryPath,
      ),
    );
  } catch (_) {
    // Already initialized in this isolate (FRB guards re-init); ignore.
  }
}

/// Atomically re-encrypts a *closed* encrypted database file from [oldKey] to
/// [newKey] (key rotation).
///
/// The database must not be open anywhere when this is called. Returns the
/// new key generation (`[oldGeneration] + 1`); pass that generation when
/// reopening with the new key so any interrupted rotation is recovered to the
/// new key. If rotation is interrupted, reopening with the old key (and
/// [oldGeneration]) recovers to the old key instead.
///
/// Physical rotation writes a fully encrypted sibling then swaps it in; it
/// never leaves plaintext on disk.
Future<int> rotatePhysicalKey({
  required String path,
  required List<int> oldKey,
  required List<int> newKey,
  int oldGeneration = initialPhysicalKeyGeneration,
  String? nativeLibraryPath,
}) async {
  validatePhysicalKey(oldKey, label: 'old key');
  validatePhysicalKey(newKey, label: 'new key');
  await _ensureNativeLoaded(nativeLibraryPath);
  try {
    await NativeWorker.rekeyEncryptedFile(
      path: path,
      oldKey: oldKey,
      newKey: newKey,
      oldGen: oldGeneration,
    );
  } catch (error) {
    throw mapNativeError(error);
  }
  return oldGeneration + 1;
}
