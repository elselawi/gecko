/// Maps errors crossing the FRB/native boundary into the public taxonomy.
library;

import 'errors.dart';

/// Converts a native/FRB failure into a typed public [`GeckoError`].
///
/// Native methods currently use FRB's `String` error channel. The Rust side
/// emits a JSON-encoded error envelope; this mapper also handles wrapper
/// exceptions that contain that JSON in their string representation.
GeckoError mapNativeError(Object error) {
  if (error is GeckoError) return error;
  final raw = error is String ? error : error.toString();
  final candidates = <String>[raw];
  final start = raw.indexOf('{');
  final end = raw.lastIndexOf('}');
  if (start >= 0 && end > start) {
    candidates.add(raw.substring(start, end + 1));
  }
  for (final candidate in candidates) {
    try {
      return GeckoError.fromJson(candidate);
    } on FormatException {
      // Try the next representation, then return a typed unknown error.
    }
  }
  final lower = raw.toLowerCase();
  final type = lower.contains('locked') || lower.contains('already open')
      ? GeckoErrorType.databaseLocked
      : lower.contains('dynamic library') ||
            lower.contains('failed to load') ||
            lower.contains('could not open')
      ? GeckoErrorType.invalidOperation
      : GeckoErrorType.unknown;
  return GeckoError(
    type,
    'Native gecko_db operation failed: $raw',
    details: type == GeckoErrorType.databaseLocked
        ? const <String, Object?>{'retryable': true}
        : null,
  );
}
