/// Phase 10 schema-versioning & migration contracts.
///
/// The database file carries an explicit schema version stamped in a reserved
/// `__gecko_*` table (no second persistence system). Migrations are ordered,
/// transactional steps; a step that throws rolls back only that step, leaving
/// prior committed steps applied. Additive steps (new nullable/defaulted
/// fields) use Phase 3's missing/null/default distinction to avoid a full-table
/// rewrite. Large-data steps rewrite in bounded chunks rather than holding the
/// whole dataset in memory.
library;

import 'dart:async';

/// Diagnostics collected after a failed migration step.
class MigrationFailure {
  const MigrationFailure({
    required this.stepName,
    required this.error,
    this.record,
  });

  final String stepName;
  final Object error;

  /// The record being migrated when the step failed (when known).
  final Object? record;

  @override
  String toString() =>
      'MigrationFailure(step=$stepName, record=$record, error=$error)';
}

/// A single ordered, transactional schema-migration step.
class MigrationStep {
  const MigrationStep({
    required this.name,
    required this.fromVersion,
    required this.toVersion,
    this.rewritesRecords = false,
    this.collection,
    this.upgrade,
  });

  /// Stable step name used by diagnostics.
  final String name;

  /// Schema version this step migrates *from*.
  final int fromVersion;

  /// Schema version this step migrates *to*.
  final int toVersion;

  /// Whether this step rewrites records (non-additive). When false the step is
  /// an additive fast path that does not rewrite existing rows.
  final bool rewritesRecords;

  /// The collection this step migrates (required when [rewritesRecords]).
  final String? collection;

  /// Optional per-record upgrade transform used by record-rewriting steps.
  /// Return a non-null value to rewrite the record; return null to keep a
  /// record untouched (skipped) during the incremental pass.
  final Object? Function(Object? row)? upgrade;
}

/// A registered migration program (an ordered chain of steps).
class MigrationPlan {
  const MigrationPlan({required this.steps, required this.targetVersion});
  final List<MigrationStep> steps;
  final int targetVersion;
}

/// A rewriter callback that streams the collection's records in bounded chunks
/// to a destination table. The engine supplies the source rows; the callback
/// returns rewritten rows for each record.
typedef RecordRewriter = FutureOr<Object?> Function(Object? id, Object? row);

/// Database-backed Phase 10 schema-versioning surface.
abstract class SchemaApi {
  /// The schema version currently stamped in the database file.
  Future<int> readVersion();

  /// Stamps [version] atomically (idempotent: a no-op if already current).
  Future<void> stamp(int version);

  /// Runs the ordered [plan] steps whose `fromVersion` matches consecutive
  /// versions, each wrapped so a failure rolls back only that step. Returns a
  /// (stepsApplied, targetVersion) summary.
  Future<(int stepsApplied, int targetVersion)> migrate(MigrationPlan plan);

  /// Runs one [step], atomically. When the step rewrites records it does so in
  /// bounded, streaming chunks (never loading the whole dataset).
  Future<void> migrateStep(MigrationStep step);

  /// True when [version] is greater than the running code understands. The
  /// engine refuses to open such a database (typed `upgradeRequired`).
  bool requiresUpgrade(int version, {int maxKnownVersion});
}
