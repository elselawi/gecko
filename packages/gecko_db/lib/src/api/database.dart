/// Tier 1/2/3 public API contract surface.
///
/// Phase 0 defines these as abstract interfaces with no implementation, so
/// later phases don't reshape the foundation underneath already-tested code.
/// Everything here is deliberately abstract — no concrete logic leaks into the
/// contracts.
library;

import 'dart:async';

import 'attachment.dart';
import 'bulk.dart';
import 'change.dart';
import 'change_tracking.dart';
import 'conflict.dart';
import 'diagnostics.dart';
import 'collection.dart';
import 'schema.dart';
import '../crypto/physical_encryption.dart';
import '../model/row_schema.dart';
import 'maintenance.dart';
import 'transaction.dart';
import '../database_impl.dart';

DateTime _defaultDatabaseClock() => DateTime.now();

/// A callback run inside a write transaction.
///
/// Since this is a local-first database, [txn] may be used to perform
/// multi-record atomic work spanning multiple collections.
typedef WriteCallback = FutureOr<void> Function(Transaction txn);

/// Configuration knobs for opening a [`Database`].
class DatabaseConfig {
  const DatabaseConfig({
    this.readOnly = false,
    this.inMemory = false,
    this.encryptionKey,
    this.cryptoBackendName = 'aes256Gcm',
    this.physicalEncryptionKey,
    this.physicalKeyGeneration = 1,
    this.keyProvider,
    this.nativeLibraryPath,
    this.inFlightBatchLimit,
    this.lruCapacity,
    this.lruMaxWeight,
    this.clock = _defaultDatabaseClock,
    this.changeLogMaxEntries = 1000,
    this.maxKnownSchemaVersion = 0,
    this.slowQueryThresholdMicros = 0,
    this.compactionSnapshotDrainTimeout = const Duration(seconds: 5),
  });

  /// Open for read-only access. Defaults to false.
  final bool readOnly;

  /// Open an ephemeral in-memory database (tests, examples, dev). Defaults to
  /// false — the production path is the native file backend. In-memory
  /// databases are not persisted and cannot be physically encrypted.
  final bool inMemory;

  /// Optional encryption key (Phase 11). When supplied, logical values are
  /// encrypted before reaching the selected RawBackend.
  final List<int>? encryptionKey;

  /// Registered crypto backend name. `aes256Gcm` is the built-in default;
  /// custom names must be registered with `CryptoBackend.register`.
  final String cryptoBackendName;

  /// Optional 32-byte AES-256 key for *physical* page encryption (Workstream
  /// 4). When supplied (or resolved through [keyProvider]), every native file
  /// page is authenticated-encrypted below redb, so raw-file scans never find
  /// plaintext. Physical and logical ([encryptionKey]) encryption compose.
  final List<int>? physicalEncryptionKey;

  /// Key generation for [physicalEncryptionKey]. Freshly encrypted files use
  /// generation 1; after [`rotatePhysicalKey`] the new key uses the returned
  /// generation so interrupted rotations recover to the correct key.
  final int physicalKeyGeneration;

  /// Optional key source used when [physicalEncryptionKey] is null. The key
  /// is resolved *before* the file is opened; if it is unavailable the open
  /// fails with a typed `keyUnavailable` error and no file is created.
  final KeyProvider? keyProvider;

  /// Explicit path to a prebuilt native library. When null, the platform
  /// native resolver (Phase 1) selects one automatically.
  final String? nativeLibraryPath;

  /// Backpressure bound: max in-flight write batches before callers await
  /// queue drain (Phase 2). Null → engine default.
  final int? inFlightBatchLimit;

  /// Point-read cache entry bound. Null → engine default.
  final int? lruCapacity;

  /// Optional total-resident-byte bound for the point-read cache. Null →
  /// unbounded (entry-count bound only).
  final int? lruMaxWeight;

  /// Advisory wall-clock source for change metadata. Ordering is always the
  /// persisted LSN, never this clock.
  final DateTime Function() clock;

  /// Maximum number of durable change-log entries retained before compaction.
  /// Pending entries are never pruned.
  final int changeLogMaxEntries;

  /// Highest schema version this build understands. Opening a database
  /// stamped with a newer version fails with a typed `upgradeRequired` error
  /// instead of proceeding. 0 → treat any stamped version as possibly
  /// unversioned (no compatibility gate).
  final int maxKnownSchemaVersion;

  /// Slow-query logging threshold in microseconds (Workstream 5). 0 (default)
  /// disables slow-query logging entirely; when set, queries taking at least
  /// this long are recorded with their plan (indexed vs full-scan) and are
  /// visible through diagnostics. Near-zero overhead when disabled.
  final int slowQueryThresholdMicros;

  /// How long [MaintenanceApi.compact] waits for in-flight MVCC snapshots
  /// (snapshot-bound cursors/transactions) to drain before failing with a
  /// typed timeout error. Readers that start while compaction is queued are
  /// allowed to finish; compaction then proceeds.
  final Duration compactionSnapshotDrainTimeout;
}

/// Signature of the concrete opener used by [`Database.open`]. Kept as a named
/// type so the public entry point's delegation is stable and testable.
typedef DatabaseOpener =
    Future<Database> Function(String path, DatabaseConfig config);

/// The core database handle. Tier 1 entry point: `collection<T>` + watch.
abstract class Database {
  /// Opens (or creates) the database at [path].
  ///
  /// The supported public entry point. By default this opens the native file
  /// backend at [path]; pass `DatabaseConfig(inMemory: true)` for an ephemeral
  /// in-memory database (tests/examples). Delegates to the concrete
  /// implementation (imported here — Dart resolves circular imports fine, and
  /// the public barrel already pulls the implementation's `dart:io`
  /// dependencies).
  static Future<Database> open(
    String path, {
    DatabaseConfig config = const DatabaseConfig(),
  }) => DatabaseImpl.open(path, config: config, useInMemory: config.inMemory);

  /// The filesystem path this database is tied to.
  String get path;

  /// Whether this database is read-only.
  bool get isReadOnly;

  /// Opens a typed collection, binding the row mapping functions.
  ///
  /// [name] must not begin with the reserved `__gecko_` prefix.
  /// [toRow] / [fromRow] are the hand-written mapping pair (no codegen).
  /// [id] extracts a stable record identifier from a model instance.
  Collection<T> collection<T>(
    String name, {
    required Object? Function(T) toRow,
    required T Function(Object? row) fromRow,
    Object? Function(T)? id,
    RowSchema? schema,
    List<String>? indexFields,
    Iterable<String>? prefixFields,
  });

  /// Atomically runs [body] inside a write transaction spanning one or more
  /// collections, rolling back on any thrown error (Phase 7).
  Future<void> writeTxn(WriteCallback body);

  /// Additive sync-facing surface, backed by the same database file.
  SyncHookApi get sync;

  /// Additive conflict-resolution surface backed by the same database file.
  ConflictApi get conflicts;

  /// Additive attachment-metadata surface backed by the same database file.
  AttachmentApi get attachments;

  /// Additive schema-versioning/migration surface backed by the same database
  /// file (Phase 10).
  SchemaApi get schema;

  /// Applies known bulk mutations in one atomic commit. One coalesced change
  /// event is emitted for the whole batch.
  Future<BulkWriteResult> bulkWrite(List<BulkMutation> mutations);

  /// Opt-in performance/health diagnostics.
  DiagnosticsApi get diagnostics;

  /// Compaction/maintenance controller and storage size reporting
  /// (Workstream 5).
  MaintenanceApi get maintenance;

  /// Global, cross-collection change feed (Phase 4). Primarily for
  /// diagnostics and future sync-engine consumption.
  Stream<ChangeSet> watchAll();

  /// Closes the database, draining pending work and releasing the file.
  Future<void> close();
}
