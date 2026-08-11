/// Reserved-name policy.
///
/// All engine-internal metadata lives in reserved `__gecko_*` tables inside the
/// same `redb` file, written in the same transaction as the data that triggers
/// it. User tables must never collide with this namespace, so a user table name
/// that starts with the reserved prefix is rejected with a typed error.
library;

import 'errors/errors.dart';

/// The reserved table-name prefix for engine-internal metadata tables
/// (change tracking, sync state, indexes, attachments, migrations, crypto
/// metadata, etc.).
const String geckoReservedPrefix = '__gecko_';

/// Reserved metadata tables used by the sync adapter.
const String geckoChangeLogTable = '__gecko_change_log';
const String geckoSyncMetaTable = '__gecko_sync_meta';
const String geckoSyncStateTable = '__gecko_sync_state';
const String geckoSyncDedupeTable = '__gecko_sync_dedupe';
const String geckoConflictTable = '__gecko_conflicts';
const String geckoAttachmentTable = '__gecko_attachments';
const String geckoBlobTable = '__gecko_blobs';
const String geckoSchemaTable = '__gecko_schema';
const String geckoIndexTable = '__gecko_index';
const String geckoMaintenanceTable = '__gecko_maintenance';
const String geckoLsnKey = 'lsn';
const String geckoWatermarkKey = 'watermark';
const String geckoRemoteVersionKey = 'remoteVersion';
const String geckoSchemaVersionKey = 'version';

/// Maintenance-marker keys in [geckoMaintenanceTable]. The value is one of
/// `idle`, `compacting`, `committed`, or `failed`; a durable `compacting`
/// marker on open means a previous session crashed mid-compaction.
const String geckoMaintenanceStateKey = 'state';
const String geckoMaintenanceIdle = 'idle';
const String geckoMaintenanceCompacting = 'compacting';
const String geckoMaintenanceCommitted = 'committed';
const String geckoMaintenanceFailed = 'failed';

/// True if [name] is reserved for internal use (starts with `__gecko_`).
///
/// The reserved namespace must remain visible to the engine's own metadata
/// tables, so this is a pure predicate: internal code calls it to confirm a
/// table is reserved; public API surface calls [ensureUserTableName] to reject
/// user collisions.
bool isReservedName(String name) => name.startsWith(geckoReservedPrefix);

/// Throws [`GeckoError`] with [GeckoErrorType.invalidOperation] if [name] is a
/// reserved table name, so a consumer cannot collide with engine metadata.
///
/// Returns the (unmodified) [name] on success, for convenience in fluent call
/// sites. The error is a typed `invalidOperation`, never a `StateError`.
String ensureUserTableName(String name) {
  if (name.isEmpty) {
    throw GeckoError(
      GeckoErrorType.invalidOperation,
      'Table name must not be empty',
      details: <String, Object?>{'name': name},
    );
  }
  if (isReservedName(name)) {
    throw GeckoError(
      GeckoErrorType.invalidOperation,
      'Table name "$name" uses the reserved "$geckoReservedPrefix" prefix; '
      'that namespace is reserved for internal gecko_db metadata',
      details: <String, Object?>{'name': name},
    );
  }
  return name;
}
