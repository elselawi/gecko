/// The gecko_db public error taxonomy.
///
/// Every remotely-contractual failure is a typed [`GeckoError`] subclass.
/// Raw Rust panics, `StateError`, and untyped `Exception`s are **not** an API.
/// Later phases attach their own leaves (e.g. a `SyncStateError`) to
/// this same root rather than inventing parallel taxonomies.
library;

import 'dart:convert';

import 'package:collection/collection.dart';

/// The typed root of every failure gecko_db can surface to a consumer.
///
/// [type] is the machine-readable variant, [message] is human-readable, and
/// [details] may carry structured context (e.g. the offending field name).
///
/// Instances round-trip across the Dart↔native boundary without losing type or
/// message. This is enforced by dedicated tests in 
class GeckoError implements Exception {
  const GeckoError(this.type, this.message, {this.details});

  const GeckoError.unknown(String message, {Map<String, Object?>? details})
    : this(GeckoErrorType.unknown, message, details: details);

  /// The machine-readable error variant.
  final GeckoErrorType type;

  /// A human-readable, actionable description of the failure.
  final String message;

  /// Optional structured context (offending field, expected vs actual, etc.).
  final Map<String, Object?>? details;

  @override
  String toString() => 'GeckoError(${type.name}): $message';

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.name,
    'message': message,
    if (details != null) 'details': details,
  };

  static GeckoError fromJson(Object? json) {
    if (json is! String) {
      throw const FormatException('GeckoError must serialize to a JSON string');
    }
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('GeckoError JSON must be an object');
    }
    final typeName = decoded['type'] as String?;
    final type = GeckoErrorType.values
        .where((v) => v.name == typeName)
        .firstOrNull;
    if (type == null) {
      throw FormatException('Unknown GeckoError type: $typeName');
    }
    return GeckoError(
      type,
      decoded['message'] as String? ?? 'Unknown error',
      details: (decoded['details'] as Map?)?.cast<String, Object?>(),
    );
  }
}

/// The canonical, nameable set of error variants.
enum GeckoErrorType {
  // Core taxonomy ().
  unknown,
  keyNotFound,
  collectionNotFound,
  schemaValidation,
  transactionAborted,
  decryption,
  databaseAlreadyOpen,
  databaseLocked,
  upgradeRequired,
  checksumMismatch,
  invalidOperation,

  // Open-leaf markers for the extensible error taxonomy.
  syncState,
  conflict,
  attachment,
  migration,
}
