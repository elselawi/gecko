/// conflict-resolution contracts.
///
/// Strategies are pure functions. They receive immutable local, remote, and
/// optional common-base versions and return a value-only [Resolution]. They
/// never perform storage I/O or depend on clocks, isolates, or global state.
library;

import 'change_tracking.dart';
import '../errors/errors.dart';
import '../model/row_schema.dart';

/// The result requested from a conflict strategy.
enum ResolutionKind { useLocal, useRemote, mergedValue, delete, manualReview }

/// An immutable version supplied to a conflict strategy.
class ConflictVersion {
  const ConflictVersion({
    this.value,
    this.deleted = false,
    this.sequence,
    this.version,
  });

  const ConflictVersion.deleted({this.sequence, this.version})
    : value = null,
      deleted = true;

  /// The decoded record value. Null is a valid value when [deleted] is false.
  final Object? value;

  /// Whether this version represents a record deletion.
  final bool deleted;

  /// Optional local ordering sequence. Strategies must prefer this over wall
  /// clock values when ordering versions.
  final int? sequence;

  /// Optional server/version token supplied by the sync transport.
  final Object? version;

  ConflictVersion copyWith({
    Object? value,
    bool? deleted,
    int? sequence,
    Object? version,
  }) => ConflictVersion(
    value: value ?? this.value,
    deleted: deleted ?? this.deleted,
    sequence: sequence ?? this.sequence,
    version: version ?? this.version,
  );

  @override
  String toString() =>
      'ConflictVersion(deleted=$deleted, sequence=$sequence, value=$value)';
}

/// A strategy's pure decision.
class Resolution {
  const Resolution._(this.kind, [this.value]);

  const Resolution.useLocal() : this._(ResolutionKind.useLocal);
  const Resolution.useRemote() : this._(ResolutionKind.useRemote);
  const Resolution.mergedValue(Object? value)
    : this._(ResolutionKind.mergedValue, value);
  const Resolution.delete() : this._(ResolutionKind.delete);
  const Resolution.manualReview() : this._(ResolutionKind.manualReview);

  final ResolutionKind kind;

  /// The value for [ResolutionKind.mergedValue].
  final Object? value;

  bool get isDeferred => kind == ResolutionKind.manualReview;

  @override
  String toString() => 'Resolution(${kind.name}, value: $value)';
}

/// A pure conflict strategy callback supplied by the application or a
/// community package.
typedef ConflictStrategyHandler =
    Resolution Function(
      ConflictVersion local,
      ConflictVersion remote,
      ConflictVersion? base,
    );

/// A stable collection/id pair and the remote version being reconciled.
class ConflictRequest {
  const ConflictRequest({
    required this.record,
    required this.remote,
    this.base,
    this.schema,
  });

  final RecordRef record;
  final ConflictVersion remote;
  final ConflictVersion? base;

  /// Optional collection schema checked before a resolved value is committed.
  final RowSchema? schema;
}

/// A conflict retained for later manual review.
class PreservedConflict {
  const PreservedConflict({
    required this.conflictId,
    required this.record,
    required this.local,
    required this.remote,
    this.base,
    this.resolution,
    this.resolutionTimestamp,
    this.resolutionSource,
  });

  final String conflictId;
  final RecordRef record;
  final ConflictVersion local;
  final ConflictVersion remote;
  final ConflictVersion? base;
  final Resolution? resolution;
  final DateTime? resolutionTimestamp;
  final String? resolutionSource;

  bool get isResolved => resolution != null;
}

/// The result of one transactional resolution attempt.
class ConflictResolutionResult {
  const ConflictResolutionResult({
    required this.record,
    required this.local,
    required this.remote,
    required this.base,
    required this.resolution,
    this.preservedConflict,
  });

  final RecordRef record;
  final ConflictVersion local;
  final ConflictVersion remote;
  final ConflictVersion? base;
  final Resolution resolution;
  final PreservedConflict? preservedConflict;

  bool get deferred => resolution.kind == ResolutionKind.manualReview;
}

/// Database-backed conflict resolution surface.
abstract class ConflictApi {
  /// Reads the local version and resolves [request] atomically.
  Future<ConflictResolutionResult> resolve(
    ConflictRequest request, {
    String strategy = ConflictStrategy.lastWriteWins,
  });

  /// Returns unresolved preserved conflicts in deterministic order.
  Future<List<PreservedConflict>> readPending();

  /// Reads one preserved conflict, or null when it no longer exists.
  Future<PreservedConflict?> read(String conflictId);

  /// Applies a manual decision and removes the preserved conflict atomically.
  Future<ConflictResolutionResult> resolvePreserved(
    String conflictId,
    Resolution resolution, {
    RowSchema? schema,
  });
}

/// Public registry for pure conflict strategies.
///
/// Registration is last-wins, which deliberately permits an application to
/// replace a shipped default. An empty name is rejected; a non-empty name is a
/// valid plugin name. Resolving a name that has not been registered fails with
/// a typed conflict error.
abstract final class ConflictStrategy {
  static final Map<String, ConflictStrategyHandler> _registry = {};
  static bool _defaultsInstalled = false;

  static const String lastWriteWins = 'lastWriteWins';
  static const String fieldLevelMerge = 'fieldLevelMerge';
  static const String manualReview = 'manualReview';
  static const String threeWayMerge = 'threeWayMerge';

  /// Registers [handler]. Registration order is last-wins.
  static void register(String name, ConflictStrategyHandler handler) {
    _installDefaults();
    if (name.trim().isEmpty) {
      throw const GeckoError(
        GeckoErrorType.conflict,
        'Conflict strategy name must not be empty',
      );
    }
    _registry[name] = handler;
  }

  /// Resolves a pure strategy by name.
  static Resolution resolve(
    String name,
    ConflictVersion local,
    ConflictVersion remote, [
    ConflictVersion? base,
  ]) {
    _installDefaults();
    final handler = _registry[name];
    if (handler == null) {
      throw GeckoError(
        GeckoErrorType.conflict,
        'Conflict strategy "$name" is not registered',
        details: <String, Object?>{'strategy': name},
      );
    }
    final result = handler(local, remote, base);
    if (result.kind == ResolutionKind.mergedValue && result.value is Function) {
      throw const GeckoError(
        GeckoErrorType.conflict,
        'A conflict strategy returned an invalid resolution value',
      );
    }
    return result;
  }

  /// Restores the four shipped defaults. Useful for test isolation and for an
  /// application that wants to undo a default override.
  static void restoreDefaults() {
    _registry
      ..clear()
      ..addAll(_defaultStrategies());
    _defaultsInstalled = true;
  }

  static bool isRegistered(String name) {
    _installDefaults();
    return _registry.containsKey(name);
  }

  static void _installDefaults() {
    if (_defaultsInstalled) return;
    restoreDefaults();
  }

  static Map<String, ConflictStrategyHandler> _defaultStrategies() => {
    lastWriteWins: _lastWriteWins,
    fieldLevelMerge: _fieldLevelMerge,
    manualReview: (_, __, ___) => const Resolution.manualReview(),
    threeWayMerge: _threeWayMerge,
  };

  static Resolution _lastWriteWins(
    ConflictVersion local,
    ConflictVersion remote,
    ConflictVersion? base,
  ) {
    if (local.sequence != null && remote.sequence != null) {
      return remote.sequence! >= local.sequence!
          ? const Resolution.useRemote()
          : const Resolution.useLocal();
    }
    // A transport version may be an int or a comparable DateTime. If no
    // ordering token is available, remote wins deterministically rather than
    // consulting the wall clock.
    final remoteVersion = remote.version;
    final localVersion = local.version;
    if (remoteVersion is int && localVersion is int) {
      return remoteVersion >= localVersion
          ? const Resolution.useRemote()
          : const Resolution.useLocal();
    }
    if (remoteVersion is DateTime && localVersion is DateTime) {
      return !remoteVersion.isBefore(localVersion)
          ? const Resolution.useRemote()
          : const Resolution.useLocal();
    }
    return const Resolution.useRemote();
  }

  static Resolution _fieldLevelMerge(
    ConflictVersion local,
    ConflictVersion remote,
    ConflictVersion? base,
  ) {
    // Delete-wins is the safe, deterministic default for a two-way merge.
    if (local.deleted || remote.deleted) return const Resolution.delete();
    if (local.value is! Map || remote.value is! Map) {
      return _lastWriteWins(local, remote, base);
    }
    final merged = <Object?, Object?>{};
    merged.addAll(Map<Object?, Object?>.from(local.value as Map));
    merged.addAll(Map<Object?, Object?>.from(remote.value as Map));
    return Resolution.mergedValue(merged);
  }

  static Resolution _threeWayMerge(
    ConflictVersion local,
    ConflictVersion remote,
    ConflictVersion? base,
  ) {
    if (base == null || local.value is! Map || remote.value is! Map) {
      return _fieldLevelMerge(local, remote, base);
    }
    if (local.deleted || remote.deleted) {
      // If only one side changed from the common base, retain the changed
      // side. If both diverged, deletion wins and no edit is silently lost:
      // the preserved conflict path is available through manualReview.
      if (local.deleted && remote.value == base.value) {
        return const Resolution.delete();
      }
      if (remote.deleted && local.value == base.value) {
        return const Resolution.delete();
      }
      return const Resolution.delete();
    }
    final localMap = Map<Object?, Object?>.from(local.value as Map);
    final remoteMap = Map<Object?, Object?>.from(remote.value as Map);
    final baseMap = base.value is Map
        ? Map<Object?, Object?>.from(base.value as Map)
        : <Object?, Object?>{};
    final keys = <Object?>{
      ...baseMap.keys,
      ...localMap.keys,
      ...remoteMap.keys,
    };
    final merged = <Object?, Object?>{};
    for (final key in keys) {
      final baseValue = baseMap[key];
      final localValue = localMap[key];
      final remoteValue = remoteMap[key];
      final localChanged =
          !_deepEqual(localValue, baseValue) ||
          localMap.containsKey(key) != baseMap.containsKey(key);
      final remoteChanged =
          !_deepEqual(remoteValue, baseValue) ||
          remoteMap.containsKey(key) != baseMap.containsKey(key);
      if (!localChanged && remoteChanged) {
        if (remoteMap.containsKey(key)) merged[key] = remoteValue;
      } else if (localChanged && !remoteChanged) {
        if (localMap.containsKey(key)) merged[key] = localValue;
      } else if (localChanged && remoteChanged) {
        // Same-field divergence is documented as remote-wins; this branch is
        // deterministic and can be replaced by a plugin for another policy.
        if (remoteMap.containsKey(key)) merged[key] = remoteValue;
      } else if (baseMap.containsKey(key)) {
        merged[key] = baseValue;
      }
    }
    return Resolution.mergedValue(merged);
  }
}

bool _deepEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEqual(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}
