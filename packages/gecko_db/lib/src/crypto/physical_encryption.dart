/// Native physical encryption key validation and rotation.
///
/// The database uses one fixed Rust AES-256-GCM implementation. Encryption is
/// enabled by supplying exactly 32 raw key bytes to
/// `DatabaseConfig.encryptionKey` and is disabled when no key is supplied.
/// Key storage is owned by the application; gecko_db does not define key
/// providers or crypto plugins.
library;

import '../errors/errors.dart';
import '../errors/native_error.dart';
import '../native/external_library_loader.dart' show resolveExternalLibrary;
import '../native/generated/api.dart';
import '../native/generated/frb_generated.dart' show RustLib;

/// Key generation assigned to a freshly encrypted database file.
const int initialPhysicalKeyGeneration = 1;

/// Validates that [key] is exactly 32 raw bytes for AES-256-GCM.
void validateEncryptionKey(List<int> key, {String label = 'encryption key'}) {
  if (key.length != 32) {
    throw GeckoError(
      GeckoErrorType.invalidOperation,
      '$label must be exactly 32 raw bytes (AES-256), got ${key.length}',
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
  validateEncryptionKey(oldKey, label: 'old key');
  validateEncryptionKey(newKey, label: 'new key');
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
