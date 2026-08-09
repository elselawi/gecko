/// Concrete [`Database`] implementation for Phase 2.
///
/// Wires the [`RawEngine`] (and its in-memory backend by default) behind the
/// public soft-contract. Native (`redb`) backing and the worker thread arrive
/// in the same phase's later steps / the native phase; the interface here is
/// backend-agnostic via [`RawBackend`].
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path_util;

import 'backend/byte_key.dart';
import 'backend/encrypted_raw_backend.dart';
import 'backend/in_memory_backend.dart';
import 'backend/raw_backend.dart';
import 'errors/errors.dart';
import 'model/row_patch.dart';
import 'model/row_schema.dart';
import 'namespaces.dart';
import 'backend/native_raw_backend.dart';
import 'native/native_resolver.dart' show isWeb;
import 'query/query_impl.dart';
import 'raw/raw_engine.dart';
import 'relation/relationship_manager.dart';
import 'wire/wire_codec.dart';
import 'api/attachment.dart';
import 'api/bulk.dart';
import 'api/change.dart';
import 'api/change_tracking.dart';
import 'api/collection.dart';
import 'api/collection_diff.dart';
import 'api/crypto.dart';
import 'crypto/physical_encryption.dart';
import 'api/conflict.dart';
import 'api/database.dart';
import 'api/diagnostics.dart';
import 'api/maintenance.dart';
import 'api/query.dart';
import 'api/schema.dart';
import 'api/sync_state.dart';
import 'api/transaction.dart';

/// Opens a [`Database`] metadata record key used to detect double-open.
String _registryKey(String path) {
  if (path.startsWith('mem://')) return path;
  // On the web there is no filesystem: paths are logical OPFS names (or
  // `:memory:`), and dart:io File/Platform are unavailable.
  if (isWeb) return path;
  final normalized = path_util.normalize(File(path).absolute.path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

final Map<String, DatabaseImpl> _openDatabases = <String, DatabaseImpl>{};
final Set<String> _openingDatabases = <String>{};

/// The Phase 2 concrete [`Database`].
class DatabaseImpl implements Database {
  DatabaseImpl._(
    this.path,
    this._engine,
    this._clock,
    this._changeLogMaxEntries,
    this._maxKnownSchemaVersion,
    this._readOnly,
    this._compactionSnapshotDrainTimeout,
  );

  @override
  final String path;
  final RawEngine _engine;
  final bool _readOnly;
  final DateTime Function() _clock;
  final int _changeLogMaxEntries;
  final int _maxKnownSchemaVersion;
  final Duration _compactionSnapshotDrainTimeout;
  final _AsyncMutex _txnMutex = _AsyncMutex();
  final Map<String, CollectionIndex> _indexes = <String, CollectionIndex>{};

  /// Tables whose index rebuild is currently in flight (so concurrent
  /// `collection()` calls coalesce onto one rebuild per table).
  final Set<String> _rebuildingIndexes = <String>{};
  late final SyncHookApi _sync = _SyncHookImpl(this);
  late final ConflictApi _conflicts = _ConflictApiImpl(this);
  late final AttachmentApi _attachments = _AttachmentApiImpl(this);
  late final SchemaApi _schema = _SchemaApiImpl(this);
  late final DiagnosticsApi _diagnostics = _DiagnosticsApiImpl(this);
  late final MaintenanceApi _maintenance = _MaintenanceApiImpl(this);
  bool _closed = false;
  bool _closing = false;
  Future<void>? _closeFuture;

  @override
  bool get isReadOnly => _readOnly;

  void _assertWritable() {
    _assertOpen();
    if (_readOnly) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Database is read-only; write operations are not allowed',
      );
    }
  }

  @override
  SyncHookApi get sync => _sync;

  @override
  ConflictApi get conflicts => _conflicts;

  @override
  AttachmentApi get attachments => _attachments;

  @override
  SchemaApi get schema => _schema;

  @override
  DiagnosticsApi get diagnostics => _diagnostics;

  @override
  MaintenanceApi get maintenance => _maintenance;

  void _assertOpen() {
    if (_closed || _closing) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Database is closed or closing',
      );
    }
  }

  RawEngine get engine => _engine;

  static const _codec = DefaultWireCodec();

  Object? _decode(List<int> bytes) => _codec.decode(bytes);

  Object? _decodedId(String table, ByteKey key) {
    try {
      return _codec.decode(key.bytes);
    } catch (_) {
      return key.bytes;
    }
  }

  RelationshipManager? _relationships;

  /// The relationship manager bound to this database (Phase 6). FK lookups are
  /// wired to the collection indexes so children/parents queries use an index
  /// when the foreign-key field is indexed (WS3).
  RelationshipManager get relationships => _relationships ??=
      RelationshipManager(_engine, indexLookup: (table) => _indexes[table]);

  /// Opens a database. When [useInMemory] is true (default for tests) a fresh
  /// in-memory backend is used; otherwise a file-backed placeholder is
  /// expected (native phase). Enforces the same-path single-open contract.
  static Future<DatabaseImpl> open(
    String path, {
    DatabaseConfig config = const DatabaseConfig(),
    bool useInMemory = true,
  }) async {
    final key = _registryKey(path);
    if (_openDatabases.containsKey(key) || !_openingDatabases.add(key)) {
      throw GeckoError(
        GeckoErrorType.databaseAlreadyOpen,
        'Database at "$path" is already open or opening in this process',
        details: <String, Object?>{'path': path},
      );
    }
    RawBackend? backend;
    DatabaseImpl? db;
    try {
      // Resolve the physical encryption key BEFORE the file is touched. A
      // missing key must fail with a typed error and never silently create a
      // plaintext database (Workstream 4 requirement 5).
      final physicalKey =
          config.physicalEncryptionKey ??
          await _resolvePhysicalKey(config.keyProvider, path);
      if (useInMemory) {
        if (physicalKey != null) {
          throw GeckoError(
            GeckoErrorType.cryptoBackend,
            'Physical encryption requires the native file backend; '
            'in-memory databases cannot be encrypted at rest',
          );
        }
        backend = InMemoryBackend(isReadOnly: config.readOnly);
      } else {
        backend = await NativeRawBackend.open(
          path,
          readOnly: config.readOnly,
          nativeLibraryPath: config.nativeLibraryPath,
          physicalKey: physicalKey,
          physicalKeyGeneration: config.physicalKeyGeneration,
        );
      }
      if (config.encryptionKey != null) {
        final crypto = config.cryptoBackendName == 'aes256Gcm'
            ? Aes256GcmCryptoBackend(config.encryptionKey!)
            : CryptoBackend.resolve(config.cryptoBackendName);
        backend = EncryptedRawBackend(backend, crypto: crypto);
      }
      db = DatabaseImpl._(
        path,
        RawEngine(
          backend,
          inFlightBatchLimit: config.inFlightBatchLimit,
          lruCapacity: config.lruCapacity,
          lruMaxWeight: config.lruMaxWeight,
          slowQueryThresholdMicros: config.slowQueryThresholdMicros,
        ),
        config.clock,
        config.changeLogMaxEntries,
        config.maxKnownSchemaVersion,
        config.readOnly,
        config.compactionSnapshotDrainTimeout,
      );
      _openDatabases[key] = db;
      // Detect an interrupted compaction from a previous session (durable
      // marker left as `compacting`) and surface it as `recovering`.
      await (db._maintenance as _MaintenanceApiImpl)._init();
      // Open-time compatibility gate: a stamped schema newer than this build
      // understands must never be silently read.
      if (config.maxKnownSchemaVersion > 0) {
        final stamped = await db.schema.readVersion();
        if (stamped > config.maxKnownSchemaVersion) {
          throw GeckoError(
            GeckoErrorType.upgradeRequired,
            'Database schema version $stamped is newer than this build supports '
            '(max $config.maxKnownSchemaVersion)',
            details: <String, Object?>{
              'schemaVersion': stamped,
              'maxKnown': config.maxKnownSchemaVersion,
            },
          );
        }
      }
      return db;
    } catch (error) {
      _openDatabases.remove(key);
      await db?.close();
      if (db == null && backend != null) await backend.close();
      if (error is GeckoError) rethrow;
      throw GeckoError(
        GeckoErrorType.invalidOperation,
        'Database could not be initialized: $error',
        details: <String, Object?>{'path': path},
      );
    } finally {
      _openingDatabases.remove(key);
    }
  }

  /// Whether a database is currently open at [path] (for lifecycle tests).
  static bool isOpenAt(String path) =>
      _openDatabases.containsKey(_registryKey(path));

  /// Resolves the 32-byte physical encryption key from [provider] before the
  /// file is opened. A provider that returns null (or throws) fails with a
  /// typed `keyUnavailable`/`cryptoBackend` error so no file is ever created
  /// without the key the caller expected (Workstream 4 requirement 5).
  static Future<List<int>?> _resolvePhysicalKey(
    KeyProvider? provider,
    String path,
  ) async {
    if (provider == null) return null;
    final List<int>? key;
    try {
      key = await provider.obtain();
    } catch (error) {
      throw GeckoError(
        GeckoErrorType.keyUnavailable,
        'Physical key provider "${provider.name}" failed for $path: $error',
        details: <String, Object?>{'path': path, 'provider': provider.name},
      );
    }
    if (key == null) {
      throw GeckoError(
        GeckoErrorType.keyUnavailable,
        'No physical encryption key available from provider '
        '"${provider.name}" for $path',
        details: <String, Object?>{'path': path, 'provider': provider.name},
      );
    }
    validatePhysicalKey(key);
    return key;
  }

  @override
  Collection<T> collection<T>(
    String name, {
    required Object? Function(T) toRow,
    required T Function(Object? row) fromRow,
    Object? Function(T)? id,
    RowSchema? schema,
    List<String>? indexFields,
    Iterable<String>? prefixFields,
  }) {
    _assertOpen();
    ensureUserTableName(name);
    schema?.validateDefinition();
    final index = indexFields == null && prefixFields == null
        ? null
        : _indexes.putIfAbsent(
            name,
            () => CollectionIndex(
              fields: indexFields ?? const [],
              prefixFields: prefixFields ?? const [],
            ),
          );
    if (index != null) {
      unawaited(_rebuildIndex(name, index));
    }
    return _CollectionImpl<T>(
      this,
      name,
      toRow,
      fromRow,
      id,
      schema: schema,
      index: index,
    );
  }

  /// (Re)builds [index] from the current table contents at collection-open and
  /// verifies the durable `__gecko_index` table against the primary-derived
  /// entries, repairing any drift atomically (one backend batch). An index can
  /// therefore never be silently ahead of or behind its primary table.
  Future<void> _rebuildIndex(String name, CollectionIndex index) async {
    if (!_rebuildingIndexes.add(name)) {
      // Another rebuild is in flight for this table; wait for it.
      await index.ready;
      return;
    }
    try {
      final scan = await _engine.rawScanAll(name);
      index.secondary.clearForRebuild();
      final expectedKeys = <ByteKey>{};
      for (final entry in scan) {
        final rowValue = _decode(entry.value ?? const []);
        if (rowValue is Map) {
          final recordId = _decodedId(name, entry.key);
          final row = Map<Object?, Object?>.from(rowValue);
          index.onPut(recordId, null, row);
          for (final field in <String>[
            ...index.secondary.fields,
            ...index.secondary.prefixFields,
          ]) {
            if (row.containsKey(field)) {
              expectedKeys.add(
                _durableIndexKey(name, field, row[field], recordId),
              );
            }
          }
        }
      }

      // Verify the durable index table: gather the keys belonging to this
      // table and compare with the primary-derived set.
      final snap = await _engine.backend.snapshot();
      List<RawEntry> durableEntries;
      try {
        durableEntries = await snap.scanAll(geckoIndexTable);
      } finally {
        await snap.dispose();
      }
      final durableKeys = <ByteKey>{
        for (final entry in durableEntries)
          if (_decodeDurableIndexKey(entry.key.bytes).$1 == name) entry.key,
      };
      if (!_sameByteKeySet(expectedKeys, durableKeys)) {
        // Atomic repair: remove this table's stale keys and insert the
        // correct entries in one backend batch (single write transaction).
        final repairOps = <RawOp>[
          for (final key in durableKeys) RawDelete(geckoIndexTable, key),
          for (final key in expectedKeys)
            RawPut(
              geckoIndexTable,
              key,
              _defaultCodec.encode(_decodeDurableIndexKey(key.bytes).$4),
            ),
        ];
        if (repairOps.isNotEmpty) {
          await _engine.backend.applyBatch(repairOps);
        }
      }
      index.markReady();
    } finally {
      _rebuildingIndexes.remove(name);
    }
  }

  static bool _sameByteKeySet(Set<ByteKey> a, Set<ByteKey> b) {
    if (a.length != b.length) return false;
    for (final key in a) {
      if (!b.contains(key)) return false;
    }
    return true;
  }

  final Map<String, int> _autoIdCounters = <String, int>{};

  /// Ids are monotonic per table (a `String` like `"<table>#<n>"`), which
  /// keeps them stable, ordering-friendly, and unique across concurrent
  /// inserts because every insert goes through this single counter.
  Object? _nextAutoId(String table) {
    final next = (_autoIdCounters[table] ?? 0) + 1;
    _autoIdCounters[table] = next;
    return '$table#$next';
  }

  @override
  Future<void> writeTxn(WriteCallback body) async {
    _assertWritable();
    final snapshot = await _engine.backend.snapshot();
    final txn = _TxnImpl(this, snapshot);
    try {
      await body(txn);
      if (!txn.isFinished) await txn.commit();
    } catch (_) {
      await txn.rollback();
      rethrow;
    } finally {
      await snapshot.dispose();
    }
  }

  @override
  Future<BulkWriteResult> bulkWrite(List<BulkMutation> mutations) async {
    _assertWritable();
    if (mutations.isEmpty) {
      return const BulkWriteResult(sequence: 0, mutationCount: 0);
    }
    final codec = const DefaultWireCodec();
    // A bulk write is still a local mutation: it must be change-tracked
    // (change log + sync state) and maintain secondary indexes, all inside
    // the SAME atomic redb transaction as the primary rows, with the
    // in-memory index applied only after the durable commit.
    final pendingIndexMutations = <_TxnMutation>[];
    final lsn = await _engine.commitBatch(
      (lsn, snapshot) async {
        final ops = <RawOp>[];
        for (var ordinal = 0; ordinal < mutations.length; ordinal++) {
          final mutation = mutations[ordinal];
          final keyBytes = codec.encode(mutation.key);
          final index = _indexes[mutation.table];
          // Read the prior row so change records + index maintenance can drop
          // old state on updates (never left stale).
          final previousRaw = await snapshot.read(
            mutation.table,
            ByteKey(keyBytes),
          );
          final previous = previousRaw == null ? null : codec.decode(previousRaw);
          final txnMutation = _TxnMutation(
            table: mutation.table,
            key: ByteKey(keyBytes),
            recordId: mutation.key,
            kind: mutation.kind,
            value: mutation.kind == ChangeKind.put ? mutation.value : null,
            previousVersion: previous,
            origin: ChangeOrigin.user,
          );
          if (index != null) {
            ops.addAll(_durableIndexOps(txnMutation, index));
            pendingIndexMutations.add(txnMutation);
          }
          if (mutation.kind == ChangeKind.put) {
            ops.add(
              RawPut(mutation.table, ByteKey(keyBytes), codec.encode(mutation.value)),
            );
          } else {
            ops.add(RawDelete(mutation.table, ByteKey(keyBytes)));
          }
          // Change tracking in the same batch (Phase 7 contract).
          final record = ChangeRecord(
            localMutationId: lsn,
            recordId: mutation.key,
            timestamp: _clock(),
            collection: mutation.table,
            kind: mutation.kind,
            value: mutation.kind == ChangeKind.put ? mutation.value : null,
            previousVersion: previous,
            origin: ChangeOrigin.user,
            dirty: true,
            syncState: const SyncState(phase: SyncPhase.pending),
          );
          ops.add(
            RawPut(
              geckoChangeLogTable,
              ByteKey(codec.encode([lsn, ordinal])),
              codec.encode(_recordToMap(record)),
            ),
          );
          ops.add(
            RawPut(
              geckoSyncStateTable,
              _refKey(mutation.table, mutation.key),
              codec.encode(_recordToMap(record)),
            ),
          );
        }
        if (_changeLogMaxEntries > 0) {
          final logEntries = await snapshot.scanAll(geckoChangeLogTable);
          final excess =
              logEntries.length + mutations.length - _changeLogMaxEntries;
          if (excess > 0) {
            var removed = 0;
            var highestPrunedLsn = 0;
            for (final entry in logEntries) {
              if (removed >= excess) break;
              final prior = _recordFromMap(
                codec.decode(entry.value ?? const []),
              );
              if (!prior.dirty) {
                ops.add(RawDelete(geckoChangeLogTable, entry.key));
                removed++;
                if (prior.localMutationId > highestPrunedLsn) {
                  highestPrunedLsn = prior.localMutationId;
                }
              }
            }
            if (highestPrunedLsn > 0) {
              final oldWatermarkRaw = await snapshot.read(
                geckoSyncMetaTable,
                ByteKey(codec.encode(geckoWatermarkKey)),
              );
              final oldWatermark = oldWatermarkRaw == null
                  ? 0
                  : (codec.decode(oldWatermarkRaw) as int? ?? 0);
              ops.add(
                RawPut(
                  geckoSyncMetaTable,
                  ByteKey(codec.encode(geckoWatermarkKey)),
                  codec.encode(math.max(oldWatermark, highestPrunedLsn)),
                ),
              );
            }
          }
        }
        return ops;
      },
      buildChanges: (_) => [
        for (final mutation in mutations)
          Change(table: mutation.table, key: mutation.key, kind: mutation.kind),
      ],
    );
    // Only after the durable commit do we reflect the batch in the in-memory
    // secondary index, so a failed commit can never leave the index ahead of
    // (or behind) its primary table.
    for (final m in pendingIndexMutations) {
      final index = _indexes[m.table];
      if (index == null) continue;
      if (m.kind == ChangeKind.delete) {
        index.onDelete(m.recordId, m.previousVersion);
      } else {
        index.onPut(m.recordId, m.previousVersion, m.value);
      }
    }
    return BulkWriteResult(sequence: lsn, mutationCount: mutations.length);
  }

  @override
  Stream<ChangeSet> watchAll() {
    _assertOpen();
    return _engine.changes.stream;
  }

  /// Raw access for engine-level callers (Phase 3+ build on this).
  Future<List<int>?> rawGet(String table, ByteKey key) {
    _assertOpen();
    return _engine.rawGet(table, key);
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    final existing = _closeFuture;
    if (existing != null) return existing;
    final future = _closeInternal();
    _closeFuture = future;
    return future;
  }

  Future<void> _closeInternal() async {
    _closing = true;
    final key = _registryKey(path);
    try {
      await _engine.dispose();
    } finally {
      _closed = true;
      _closing = false;
      _openDatabases.remove(key);
    }
  }

  /// Retrieve a live instance by path (for lifecycle close-verification).
  static bool get hasLiveOpen => _openDatabases.isNotEmpty;
}

/// A typed collection bound to a [`DatabaseImpl`].
class _CollectionImpl<T> implements Collection<T> {
  _CollectionImpl(
    this._db,
    this.name,
    this._toRow,
    this._fromRow,
    this._id, {
    this.schema,
    this.index,
    this.transaction,
  });

  final DatabaseImpl _db;
  final _TxnImpl? transaction;
  final CollectionIndex? index;
  @override
  final String name;
  final Object? Function(T) _toRow;
  final T Function(Object?) _fromRow;
  final Object? Function(T)? _id;

  /// Optional row schema for validation, defaults, and patch semantics.
  final RowSchema? schema;

  static const _codec = DefaultWireCodec();

  ByteKey _keyFor(Object? id) => ByteKey(_codec.encode(id));

  /// The id extractor, or a generated monotonic id when no extractor exists.
  Object? _extractId(T model) {
    final id = _id;
    if (id != null) return id(model);
    return _db._nextAutoId(name);
  }

  @override
  Object get database => _db;

  @override
  Future<T?> get(Object? id) async {
    if (transaction == null) _db._assertOpen();
    final raw = transaction == null
        ? await _db.rawGet(name, _keyFor(id))
        : await transaction!.readRaw(name, _keyFor(id));
    if (raw == null) return null;
    final row = _codec.decode(raw);
    return _fromRow(row);
  }

  @override
  Future<Object?> put(T model) async {
    if (transaction == null) _db._assertOpen();
    if (transaction == null) {
      Object? result;
      await _db.writeTxn((txn) async {
        result = await txn
            .collection<T>(
              name,
              toRow: _toRow,
              fromRow: _fromRow,
              id: _id,
              schema: schema,
            )
            .put(model);
      });
      return result;
    }
    final id = _extractId(model);
    Object? row = _toRow(model);
    final s = schema;
    if (s != null) {
      s.validate(row);
      row = applyDefaults(row, s);
    }
    final key = _keyFor(id);
    final previous = await transaction!.readRaw(name, key);
    if (previous != null && row is Map) {
      final oldRow = _codec.decode(previous);
      if (oldRow is Map) {
        row = Map<Object?, Object?>.from(oldRow)
          ..addAll(Map<Object?, Object?>.from(row));
      }
    }
    await transaction!.stagePut(
      name,
      key,
      _codec.encode(row),
      recordId: id,
      value: row,
      previousVersion: previous == null ? null : _codec.decode(previous),
    );
    return id;
  }

  @override
  Future<void> delete(Object? id) async {
    if (transaction == null) _db._assertOpen();
    if (transaction == null) {
      await _db.writeTxn((txn) async {
        await txn
            .collection<T>(
              name,
              toRow: _toRow,
              fromRow: _fromRow,
              id: _id,
              schema: schema,
            )
            .delete(id);
      });
      return;
    }
    final key = _keyFor(id);
    final previous = await transaction!.readRaw(name, key);
    await transaction!.stageDelete(
      name,
      key,
      recordId: id,
      previousVersion: previous == null ? null : _codec.decode(previous),
    );
  }

  @override
  Future<void> patch(Object? id, Map<String, Object?> fields) async {
    if (transaction == null) _db._assertOpen();
    if (transaction == null) {
      await _db.writeTxn((txn) async {
        await txn
            .collection<T>(
              name,
              toRow: _toRow,
              fromRow: _fromRow,
              id: _id,
              schema: schema,
            )
            .patch(id, fields);
      });
      return;
    }
    final key = _keyFor(id);
    final existingRaw = await transaction!.readRaw(name, key);
    if (existingRaw == null) {
      throw GeckoError(
        GeckoErrorType.keyNotFound,
        'Cannot patch missing record "$id" in "$name"',
      );
    }
    final result = applyPatch(_codec.decode(existingRaw), [
      for (final entry in fields.entries)
        FieldPatch.set(entry.key, entry.value),
    ], schema: schema);
    Object? newRow = result.row;
    final s = schema;
    if (s != null) {
      s.validate(newRow);
      newRow = applyDefaults(newRow, s);
    }
    await transaction!.stagePut(
      name,
      key,
      _codec.encode(newRow),
      recordId: id,
      value: newRow,
      previousVersion: _codec.decode(existingRaw),
      changedFields: result.changedFields,
    );
  }

  @override
  Future<List<T>> getAll() async {
    _db._assertOpen();
    final scan = transaction == null
        ? await _db.engine.rawScanAll(name)
        : await transaction!.scanAll(name);
    return scan
        .map((e) => _fromRow(_codec.decode(e.value ?? const [])))
        .toList();
  }

  @override
  Stream<T?> watch(Object? id) {
    _db._assertOpen();
    late StreamController<T?> controller;
    late StreamSubscription<ChangeSet> sub;
    controller = StreamController<T?>(
      onListen: () {
        // Emit the current value immediately (StreamBuilder-friendly).
        get(id).then(controller.add);
        sub = _db.engine.changes.stream.listen((ChangeSet change) {
          final relevant = change.changes.any(
            (entry) => entry.table == name && entry.key == id,
          );
          if (relevant) get(id).then(controller.add);
        });
      },
      onCancel: () async {
        await sub.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Stream<CollectionDiff<T>> watchAllDiff() {
    _db._assertOpen();
    late StreamController<CollectionDiff<T>> controller;
    late StreamSubscription<ChangeSet> sub;
    var previous = <Object?, T>{};
    controller = StreamController<CollectionDiff<T>>(
      onListen: () async {
        final initial = await getAll();
        previous = _keyed(initial);
        controller.add(
          CollectionDiff<T>(
            added: initial,
            updated: const [],
            removed: const [],
            snapshot: initial,
          ),
        );
        sub = _db.engine.changes.stream.listen((change) async {
          if (!change.changes.any((entry) => entry.table == name)) return;
          final nextList = await getAll();
          final next = _keyed(nextList);
          final added = <T>[];
          final updated = <T>[];
          final removed = <T>[];
          for (final entry in next.entries) {
            final old = previous[entry.key];
            if (old == null) {
              added.add(entry.value);
            } else if (!_sameMapped(old, entry.value)) {
              updated.add(entry.value);
            }
          }
          for (final entry in previous.entries) {
            if (!next.containsKey(entry.key)) removed.add(entry.value);
          }
          previous = next;
          if (added.isNotEmpty || updated.isNotEmpty || removed.isNotEmpty) {
            controller.add(
              CollectionDiff<T>(
                added: added,
                updated: updated,
                removed: removed,
                snapshot: nextList,
              ),
            );
          }
        });
      },
      onCancel: () async => sub.cancel(),
    );
    return controller.stream;
  }

  Map<Object?, T> _keyed(List<T> values) {
    return {for (final value in values) (_id?.call(value) ?? value): value};
  }

  bool _sameMapped(T a, T b) {
    final left = _toRow(a);
    final right = _toRow(b);
    return left.toString() == right.toString();
  }

  @override
  Stream<List<T>> watchAll() {
    _db._assertOpen();
    late StreamController<List<T>> controller;
    late StreamSubscription<ChangeSet> sub;
    controller = StreamController<List<T>>(
      onListen: () {
        // Emit the current full list immediately.
        getAll().then(controller.add);
        sub = _db.engine.changes.stream.listen((ChangeSet change) {
          if (change.changes.any((entry) => entry.table == name)) {
            getAll().then(controller.add);
          }
        });
      },
      onCancel: () async {
        await sub.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Query<T> where([Map<String, Object?>? predicates]) {
    _db._assertOpen();
    return QueryImpl<T>(
      _db.engine,
      name,
      toRow: _toRow,
      fromRow: _fromRow,
      initialEq: predicates,
      secondary: index,
    );
  }
}

/// A staged transaction. Reads consult the immutable opening snapshot first,
/// then overlay the transaction's own writes; no backend write occurs until
/// [commit] assembles one data+metadata batch.
class _TxnImpl implements Transaction {
  _TxnImpl(this._db, this._snapshot);

  final DatabaseImpl _db;
  final RawSnapshot _snapshot;
  final List<RawOp> _ops = <RawOp>[];
  final List<_TxnMutation> _mutations = <_TxnMutation>[];
  final Map<_TxnKey, _TxnValue> _overlay = <_TxnKey, _TxnValue>{};
  bool _finished = false;
  bool _committed = false;

  bool get isFinished => _finished;

  @override
  bool get isReadOnly => _db.isReadOnly;

  @override
  Collection<T> collection<T>(
    String name, {
    required Object? Function(T) toRow,
    required T Function(Object? row) fromRow,
    Object? Function(T)? id,
    RowSchema? schema,
    List<String>? indexFields,
    Iterable<String>? prefixFields,
  }) {
    _checkActive();
    ensureUserTableName(name);
    schema?.validateDefinition();
    final index = indexFields == null && prefixFields == null
        ? _db._indexes[name]
        : _db._indexes.putIfAbsent(
            name,
            () => CollectionIndex(
              fields: indexFields ?? const [],
              prefixFields: prefixFields ?? const [],
            ),
          );
    return _CollectionImpl<T>(
      _db,
      name,
      toRow,
      fromRow,
      id,
      schema: schema,
      index: index,
      transaction: this,
    );
  }

  @override
  Future<T?> get<T>(
    String collection,
    Object? id, {
    required Object? Function(T) toRow,
    required T Function(Object? row) fromRow,
  }) async {
    return this
        .collection<T>(collection, toRow: toRow, fromRow: fromRow)
        .get(id);
  }

  Future<List<int>?> readRaw(String table, ByteKey key) async {
    _checkActive();
    final staged = _overlay[_TxnKey(table, key)];
    if (staged != null) return staged.value;
    return _snapshot.read(table, key);
  }

  Future<List<RawEntry>> scanAll(String table) async {
    _checkActive();
    final entries = <ByteKey, List<int>?>{
      for (final entry in await _snapshot.scanAll(table))
        entry.key: entry.value,
    };
    for (final entry in _overlay.entries) {
      if (entry.key.table != table) continue;
      if (entry.value.value == null) {
        entries.remove(entry.key.key);
      } else {
        entries[entry.key.key] = entry.value.value;
      }
    }
    final keys = entries.keys.toList()..sort();
    return [for (final key in keys) RawEntry(key, entries[key])];
  }

  Future<void> stagePut(
    String table,
    ByteKey key,
    List<int> encodedValue, {
    required Object? recordId,
    required Object? value,
    Object? previousVersion,
    List<String>? changedFields,
    ChangeOrigin origin = ChangeOrigin.user,
    String? idempotencyKey,
    Object? remoteVersion,
  }) async {
    _checkActive();
    _ops.add(RawPut(table, key, encodedValue));
    _overlay[_TxnKey(table, key)] = _TxnValue(encodedValue);
    _mutations.add(
      _TxnMutation(
        table: table,
        key: key,
        recordId: recordId,
        kind: ChangeKind.put,
        value: value,
        previousVersion: previousVersion,
        changedFields: changedFields,
        origin: origin,
        idempotencyKey: idempotencyKey,
        remoteVersion: remoteVersion,
      ),
    );
  }

  Future<void> stageDelete(
    String table,
    ByteKey key, {
    required Object? recordId,
    Object? previousVersion,
    ChangeOrigin origin = ChangeOrigin.user,
    String? idempotencyKey,
    Object? remoteVersion,
  }) async {
    _checkActive();
    _ops.add(RawDelete(table, key));
    _overlay[_TxnKey(table, key)] = const _TxnValue(null);
    _mutations.add(
      _TxnMutation(
        table: table,
        key: key,
        recordId: recordId,
        kind: ChangeKind.delete,
        previousVersion: previousVersion,
        origin: origin,
        idempotencyKey: idempotencyKey,
        remoteVersion: remoteVersion,
      ),
    );
  }

  @override
  Future<void> commit() async {
    if (_committed) return;
    if (_finished) return;
    _finished = true;
    if (_ops.isEmpty) return;
    await _db.engine.commitBatch(
      (lsn, snapshot) async {
        final ops = <RawOp>[..._ops];
        for (var ordinal = 0; ordinal < _mutations.length; ordinal++) {
          final mutation = _mutations[ordinal];
          final record = ChangeRecord(
            localMutationId: lsn,
            recordId: mutation.recordId,
            timestamp: _db._clock(),
            collection: mutation.table,
            kind: mutation.kind,
            value: mutation.value,
            previousVersion: mutation.previousVersion,
            changedFields: mutation.changedFields,
            origin: mutation.origin,
            dirty: mutation.origin != ChangeOrigin.remoteSync,
            syncState: SyncState(
              phase: mutation.origin == ChangeOrigin.remoteSync
                  ? SyncPhase.clean
                  : SyncPhase.pending,
            ),
            idempotencyKey: mutation.idempotencyKey,
            remoteVersion: mutation.remoteVersion,
          );
          ops.add(
            RawPut(
              geckoChangeLogTable,
              ByteKey(_codec.encode([lsn, ordinal])),
              _codec.encode(_recordToMap(record)),
            ),
          );
          ops.add(
            RawPut(
              geckoSyncStateTable,
              _refKey(mutation.table, mutation.recordId),
              _codec.encode(_recordToMap(record)),
            ),
          );
          // Durable secondary index: maintained in the exact same redb write
          // transaction as the primary record (WS3).
          final index = _db._indexes[mutation.table];
          if (index != null) {
            ops.addAll(_durableIndexOps(mutation, index));
          }
        }
        if (_db._changeLogMaxEntries > 0) {
          final logEntries = await snapshot.scanAll(geckoChangeLogTable);
          final excess =
              logEntries.length + _mutations.length - _db._changeLogMaxEntries;
          if (excess > 0) {
            var removed = 0;
            var highestPrunedLsn = 0;
            for (final entry in logEntries) {
              if (removed >= excess) break;
              final prior = _recordFromMap(
                _codec.decode(entry.value ?? const []),
              );
              if (!prior.dirty) {
                ops.add(RawDelete(geckoChangeLogTable, entry.key));
                removed++;
                if (prior.localMutationId > highestPrunedLsn) {
                  highestPrunedLsn = prior.localMutationId;
                }
              }
            }
            if (highestPrunedLsn > 0) {
              final oldWatermarkRaw = await snapshot.read(
                geckoSyncMetaTable,
                ByteKey(_codec.encode(geckoWatermarkKey)),
              );
              final oldWatermark = oldWatermarkRaw == null
                  ? 0
                  : (_codec.decode(oldWatermarkRaw) as int? ?? 0);
              ops.add(
                RawPut(
                  geckoSyncMetaTable,
                  ByteKey(_codec.encode(geckoWatermarkKey)),
                  _codec.encode(math.max(oldWatermark, highestPrunedLsn)),
                ),
              );
            }
          }
        }
        return ops;
      },
      buildChanges: (lsn) {
        return [
          for (final mutation in _mutations)
            Change(
              table: mutation.table,
              key: _codec.decode(mutation.key.bytes),
              kind: mutation.kind,
            ),
        ];
      },
    );
    // Only after the backend batch commits durably do we reflect it in the
    // in-memory secondary index, so a failed commit can never leave the index
    // ahead of (or behind) its primary table.
    for (final mutation in _mutations) {
      _applyIndexMutation(mutation);
    }
    _committed = true;
  }

  @override
  Future<void> rollback() async {
    if (_committed) return;
    _finished = true;
    _ops.clear();
    _mutations.clear();
    _overlay.clear();
  }

  void _checkActive() {
    if (_db.isReadOnly) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Database is read-only; transaction writes are not allowed',
      );
    }
    if (_finished) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Transaction is already finished',
      );
    }
  }

  void _applyIndexMutation(_TxnMutation mutation) {
    final index = _db._indexes[mutation.table];
    if (index == null) return;
    if (mutation.kind == ChangeKind.delete) {
      index.onDelete(mutation.recordId, mutation.previousVersion);
    } else {
      index.onPut(mutation.recordId, mutation.previousVersion, mutation.value);
    }
  }

  static const _codec = DefaultWireCodec();
}

class _TxnMutation {
  const _TxnMutation({
    required this.table,
    required this.key,
    required this.recordId,
    required this.kind,
    this.value,
    this.previousVersion,
    this.changedFields,
    required this.origin,
    this.idempotencyKey,
    this.remoteVersion,
  });

  final String table;
  final ByteKey key;
  final Object? recordId;
  final ChangeKind kind;
  final Object? value;
  final Object? previousVersion;
  final List<String>? changedFields;
  final ChangeOrigin origin;
  final String? idempotencyKey;
  final Object? remoteVersion;
}

class _TxnKey {
  const _TxnKey(this.table, this.key);
  final String table;
  final ByteKey key;

  @override
  bool operator ==(Object other) =>
      other is _TxnKey && other.table == table && other.key == key;

  @override
  int get hashCode => Object.hash(table, key);
}

class _TxnValue {
  const _TxnValue(this.value);
  final List<int>? value;
}

/// Sentinel distinguishing "field absent from the row" from a present `null`.
const Object _indexFieldAbsent = _AbsentFieldSentinel();

class _AbsentFieldSentinel {
  const _AbsentFieldSentinel();
}

/// The durable index key for (table, field, value, recordId). Composite keys
/// are codec-encoded lists, so byte-order groups by table → field → value →
/// recordId, which makes per-table and per-field range scans possible at the
/// storage layer.
ByteKey _durableIndexKey(
  String table,
  String field,
  Object? value,
  Object? recordId,
) => ByteKey(_defaultCodec.encode([table, field, value, recordId]));

/// Decodes a durable index key back into (table, field, value, recordId).
(Object?, Object?, Object?, Object?) _decodeDurableIndexKey(List<int> bytes) {
  final decoded = _defaultCodec.decode(bytes);
  if (decoded is List && decoded.length == 4) {
    return (decoded[0], decoded[1], decoded[2], decoded[3]);
  }
  return (null, null, null, null);
}

const DefaultWireCodec _defaultCodec = DefaultWireCodec();

/// Builds the durable index maintenance ops for [mutation] against [index].
///
/// Old entries (from `previousVersion`) are removed and new entries (from
/// `value`) are inserted, so the durable `__gecko_index` table is updated in
/// the exact same redb write transaction as the primary record — index/data
/// atomicity by construction.
List<RawOp> _durableIndexOps(_TxnMutation mutation, CollectionIndex index) {
  final fields = <String>[
    ...index.secondary.fields,
    ...index.secondary.prefixFields,
  ];
  if (fields.isEmpty) return const [];
  final ops = <RawOp>[];
  final oldRow = mutation.previousVersion is Map
      ? Map<Object?, Object?>.from(mutation.previousVersion as Map)
      : <Object?, Object?>{};
  final newRow = mutation.value is Map
      ? Map<Object?, Object?>.from(mutation.value as Map)
      : <Object?, Object?>{};
  for (final field in fields) {
    final oldValue = oldRow.containsKey(field)
        ? oldRow[field]
        : _indexFieldAbsent;
    final newValue = newRow.containsKey(field)
        ? newRow[field]
        : _indexFieldAbsent;
    if (identical(oldValue, newValue) || oldValue == newValue) continue;
    if (!identical(oldValue, _indexFieldAbsent)) {
      ops.add(
        RawDelete(
          geckoIndexTable,
          _durableIndexKey(mutation.table, field, oldValue, mutation.recordId),
        ),
      );
    }
    if (!identical(newValue, _indexFieldAbsent)) {
      ops.add(
        RawPut(
          geckoIndexTable,
          _durableIndexKey(mutation.table, field, newValue, mutation.recordId),
          _defaultCodec.encode(mutation.recordId),
        ),
      );
    }
  }
  return ops;
}

Map<String, Object?> _recordToMap(ChangeRecord record) => <String, Object?>{
  'localMutationId': record.localMutationId,
  'recordId': record.recordId,
  'timestamp': record.timestamp,
  'collection': record.collection,
  'kind': record.kind?.name,
  'value': record.value,
  'remoteVersion': record.remoteVersion,
  'dirty': record.dirty,
  'previousVersion': record.previousVersion,
  'changedFields': record.changedFields,
  'origin': record.origin.name,
  'syncPhase': record.syncState?.phase.name,
  'lastSyncAttempt': record.lastSyncAttempt,
  'retryCount': record.retryCount,
  'lastSyncError': record.lastSyncError,
  'idempotencyKey': record.idempotencyKey,
};

ChangeRecord _recordFromMap(Object? value) {
  final map = Map<Object?, Object?>.from(value as Map);
  final kindName = map['kind'] as String?;
  final originName = map['origin'] as String? ?? ChangeOrigin.user.name;
  final phaseName = map['syncPhase'] as String?;
  return ChangeRecord(
    localMutationId: map['localMutationId'] as int,
    recordId: map['recordId'],
    timestamp: map['timestamp'] as DateTime,
    collection: map['collection'] as String?,
    kind: kindName == null ? null : ChangeKind.values.byName(kindName),
    value: map['value'],
    remoteVersion: map['remoteVersion'],
    dirty: map['dirty'] as bool? ?? true,
    previousVersion: map['previousVersion'],
    changedFields: (map['changedFields'] as List?)?.cast<String>(),
    origin: ChangeOrigin.values.byName(originName),
    syncState: phaseName == null
        ? null
        : SyncState(
            phase: SyncPhase.values.byName(phaseName),
            lastSyncAttempt: map['lastSyncAttempt'] as DateTime?,
            retryCount: map['retryCount'] as int? ?? 0,
            lastSyncError: map['lastSyncError'] as String?,
            idempotencyKey: map['idempotencyKey'] as String?,
          ),
    lastSyncAttempt: map['lastSyncAttempt'] as DateTime?,
    retryCount: map['retryCount'] as int? ?? 0,
    lastSyncError: map['lastSyncError'] as String?,
    idempotencyKey: map['idempotencyKey'] as String?,
  );
}

ByteKey _refKey(String collection, Object? id) =>
    ByteKey(const DefaultWireCodec().encode([collection, id]));

Map<String, Object?> _versionToMap(ConflictVersion version) =>
    <String, Object?>{
      'value': version.value,
      'deleted': version.deleted,
      'sequence': version.sequence,
      'version': version.version,
    };

ConflictVersion _versionFromMap(Object? value) {
  final map = Map<Object?, Object?>.from(value as Map);
  return ConflictVersion(
    value: map['value'],
    deleted: map['deleted'] as bool? ?? false,
    sequence: map['sequence'] as int?,
    version: map['version'],
  );
}

Map<String, Object?> _resolutionToMap(Resolution resolution) =>
    <String, Object?>{'kind': resolution.kind.name, 'value': resolution.value};

Resolution _resolutionFromMap(Object? value) {
  final map = Map<Object?, Object?>.from(value as Map);
  final kind = ResolutionKind.values.byName(map['kind'] as String);
  return switch (kind) {
    ResolutionKind.useLocal => const Resolution.useLocal(),
    ResolutionKind.useRemote => const Resolution.useRemote(),
    ResolutionKind.mergedValue => Resolution.mergedValue(map['value']),
    ResolutionKind.delete => const Resolution.delete(),
    ResolutionKind.manualReview => const Resolution.manualReview(),
  };
}

Map<String, Object?> _conflictToMap(PreservedConflict conflict) =>
    <String, Object?>{
      'conflictId': conflict.conflictId,
      'collection': conflict.record.collection,
      'recordId': conflict.record.id,
      'local': _versionToMap(conflict.local),
      'remote': _versionToMap(conflict.remote),
      'base': conflict.base == null ? null : _versionToMap(conflict.base!),
      'resolution': conflict.resolution == null
          ? null
          : _resolutionToMap(conflict.resolution!),
      'resolutionTimestamp': conflict.resolutionTimestamp,
      'resolutionSource': conflict.resolutionSource,
    };

PreservedConflict _conflictFromMap(Object? value) {
  final map = Map<Object?, Object?>.from(value as Map);
  return PreservedConflict(
    conflictId: map['conflictId'] as String,
    record: RecordRef(map['collection'] as String, map['recordId']),
    local: _versionFromMap(map['local']),
    remote: _versionFromMap(map['remote']),
    base: map['base'] == null ? null : _versionFromMap(map['base']),
    resolution: map['resolution'] == null
        ? null
        : _resolutionFromMap(map['resolution']),
    resolutionTimestamp: map['resolutionTimestamp'] as DateTime?,
    resolutionSource: map['resolutionSource'] as String?,
  );
}

class _SyncHookImpl implements SyncHookApi {
  _SyncHookImpl(this._db);

  final DatabaseImpl _db;
  static const _codec = DefaultWireCodec();

  @override
  Future<List<PendingChange>> readLocallyChanged() async {
    _db._assertOpen();
    final entries = await _db.engine.rawScanAll(geckoSyncStateTable);
    final latest = <String, ChangeRecord>{};
    for (final entry in entries) {
      final record = _recordFromMap(_codec.decode(entry.value ?? const []));
      if (record.collection == null) continue;
      latest['${record.collection}:${record.recordId}'] = record;
    }
    return [
      for (final record in latest.values)
        if (record.dirty && record.origin != ChangeOrigin.remoteSync)
          PendingChange(recordId: record.recordId, change: record),
    ]..sort(
      (a, b) => a.change.localMutationId.compareTo(b.change.localMutationId),
    );
  }

  @override
  Future<void> markSynchronizing(List<Object?> ids) async {
    await _transition(ids, (record) {
      final now = _db._clock();
      return ChangeRecord(
        localMutationId: record.localMutationId,
        recordId: record.recordId,
        timestamp: record.timestamp,
        collection: record.collection,
        kind: record.kind,
        value: record.value,
        remoteVersion: record.remoteVersion,
        dirty: true,
        previousVersion: record.previousVersion,
        changedFields: record.changedFields,
        origin: record.origin,
        syncState: SyncState(
          phase: SyncPhase.synchronizing,
          lastSyncAttempt: now,
          retryCount: record.retryCount,
          lastSyncError: null,
          idempotencyKey: record.idempotencyKey,
        ),
        lastSyncAttempt: now,
        retryCount: record.retryCount,
        idempotencyKey: record.idempotencyKey,
      );
    });
  }

  @override
  Future<void> markSynced(List<Object?> ids) async {
    await _transition(ids, (record) {
      final now = _db._clock();
      return ChangeRecord(
        localMutationId: record.localMutationId,
        recordId: record.recordId,
        timestamp: record.timestamp,
        collection: record.collection,
        kind: record.kind,
        value: record.value,
        remoteVersion: record.remoteVersion,
        dirty: false,
        previousVersion: record.previousVersion,
        changedFields: record.changedFields,
        origin: record.origin,
        syncState: SyncState(
          phase: SyncPhase.synced,
          lastSyncAttempt: now,
          retryCount: record.retryCount,
          idempotencyKey: record.idempotencyKey,
        ),
        lastSyncAttempt: now,
        retryCount: record.retryCount,
        idempotencyKey: record.idempotencyKey,
      );
    }, updateLog: true);
  }

  @override
  Future<void> markFailed(List<Object?> ids, String error) async {
    await _transition(ids, (record) {
      final now = _db._clock();
      return ChangeRecord(
        localMutationId: record.localMutationId,
        recordId: record.recordId,
        timestamp: record.timestamp,
        collection: record.collection,
        kind: record.kind,
        value: record.value,
        remoteVersion: record.remoteVersion,
        dirty: true,
        previousVersion: record.previousVersion,
        changedFields: record.changedFields,
        origin: record.origin,
        syncState: SyncState(
          phase: SyncPhase.failed,
          lastSyncAttempt: now,
          retryCount: record.retryCount + 1,
          lastSyncError: error,
          idempotencyKey: record.idempotencyKey,
        ),
        lastSyncAttempt: now,
        retryCount: record.retryCount + 1,
        lastSyncError: error,
        idempotencyKey: record.idempotencyKey,
      );
    });
  }

  Future<void> _transition(
    List<Object?> ids,
    ChangeRecord Function(ChangeRecord) update, {
    bool updateLog = false,
  }) async {
    await _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final stateEntries = await snapshot.scanAll(geckoSyncStateTable);
        final selected = <ChangeRecord>[];
        for (final entry in stateEntries) {
          final record = _recordFromMap(_codec.decode(entry.value ?? const []));
          if (record.collection == null) continue;
          if (ids.any((id) => _matches(id, record))) selected.add(record);
        }
        if (selected.isEmpty) return;
        // One pass over the change log, indexed by
        // (collection, recordId, localMutationId), so a bulk transition
        // (e.g. markSynced of thousands of ids) is O(log + ids), never
        // O(ids × log).
        final logByKey = <String, List<(ByteKey, ChangeRecord)>>{};
        if (updateLog) {
          for (final entry in await snapshot.scanAll(geckoChangeLogTable)) {
            final record =
                _recordFromMap(_codec.decode(entry.value ?? const []));
            if (record.collection == null) continue;
            final key =
                '${record.collection}|${record.recordId}|${record.localMutationId}';
            (logByKey[key] ??= []).add((entry.key, record));
          }
        }
        await _db.engine.commitBatch((lsn, _) async {
          final ops = <RawOp>[];
          for (final record in selected) {
            final next = update(record);
            ops.add(
              RawPut(
                geckoSyncStateTable,
                _refKey(record.collection!, record.recordId),
                _codec.encode(_recordToMap(next)),
              ),
            );
            if (updateLog) {
              final key =
                  '${record.collection}|${record.recordId}|${record.localMutationId}';
              for (final (logKey, _) in logByKey[key] ?? const <(ByteKey, ChangeRecord)>[]) {
                ops.add(
                  RawPut(
                    geckoChangeLogTable,
                    logKey,
                    _codec.encode(_recordToMap(next)),
                  ),
                );
              }
            }
          }
          return ops;
        });
      } finally {
        await snapshot.dispose();
      }
    });
  }

  @override
  Future<List<Object?>> applyRemoteTransactional(
    List<ChangeRecord> records,
  ) async {
    _db._assertOpen();
    final affected = <Object?>[];
    await _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final accepted = <ChangeRecord>[];
        final seenInBatch = <String>{};
        for (final record in records) {
          final key = record.idempotencyKey;
          if (key == null ||
              seenInBatch.add(key) &&
                  await snapshot.read(
                        geckoSyncDedupeTable,
                        ByteKey(_codec.encode(key)),
                      ) ==
                      null) {
            accepted.add(record);
          }
        }
        for (final record in accepted) {
          final key = record.idempotencyKey;
          if (key == null ||
              await snapshot.read(
                    geckoSyncDedupeTable,
                    ByteKey(_codec.encode(key)),
                  ) ==
                  null) {
            affected.add(record.recordId);
          }
        }
        if (accepted.isEmpty) return;
        await _db.engine.commitBatch(
          (lsn, _) async {
            final ops = <RawOp>[];
            for (var ordinal = 0; ordinal < accepted.length; ordinal++) {
              final record = accepted[ordinal];
              final collection = record.collection;
              final kind = record.kind ?? ChangeKind.put;
              if (collection == null) {
                throw ArgumentError(
                  'Remote ChangeRecord.collection is required',
                );
              }
              final key = ByteKey(_codec.encode(record.recordId));
              if (kind == ChangeKind.delete) {
                ops.add(RawDelete(collection, key));
              } else {
                ops.add(RawPut(collection, key, _codec.encode(record.value)));
              }
              final committed = ChangeRecord(
                localMutationId: lsn,
                recordId: record.recordId,
                timestamp: _db._clock(),
                collection: collection,
                kind: kind,
                value: record.value,
                remoteVersion: record.remoteVersion,
                dirty: false,
                previousVersion: record.previousVersion,
                changedFields: record.changedFields,
                origin: ChangeOrigin.remoteSync,
                syncState: const SyncState(phase: SyncPhase.clean),
                idempotencyKey: record.idempotencyKey,
              );
              ops.add(
                RawPut(
                  geckoChangeLogTable,
                  ByteKey(_codec.encode([lsn, ordinal])),
                  _codec.encode(_recordToMap(committed)),
                ),
              );
              ops.add(
                RawPut(
                  geckoSyncStateTable,
                  _refKey(collection, record.recordId),
                  _codec.encode(_recordToMap(committed)),
                ),
              );
              if (record.idempotencyKey != null) {
                ops.add(
                  RawPut(
                    geckoSyncDedupeTable,
                    ByteKey(_codec.encode(record.idempotencyKey)),
                    _codec.encode(lsn),
                  ),
                );
              }
            }
            return ops;
          },
          buildChanges: (lsn) => [
            for (final record in accepted)
              Change(
                table: record.collection!,
                key: record.recordId,
                kind: record.kind ?? ChangeKind.put,
              ),
          ],
        );
      } finally {
        await snapshot.dispose();
      }
    });
    return affected;
  }

  @override
  Future<void> applyRemoteDeletion(List<Object?> ids) async {
    final refs = <RecordRef>[];
    if (ids.any((id) => id is RecordRef)) {
      refs.addAll(ids.whereType<RecordRef>());
    } else {
      final entries = await _db.engine.rawScanAll(geckoSyncStateTable);
      for (final entry in entries) {
        final record = _recordFromMap(_codec.decode(entry.value ?? const []));
        if (record.collection != null && ids.contains(record.recordId)) {
          refs.add(RecordRef(record.collection!, record.recordId));
        }
      }
    }
    await applyRemoteTransactional([
      for (final ref in refs)
        ChangeRecord(
          localMutationId: 0,
          recordId: ref.id,
          timestamp: _db._clock(),
          collection: ref.collection,
          kind: ChangeKind.delete,
          origin: ChangeOrigin.remoteSync,
        ),
    ]);
  }

  @override
  Future<Object?> readRemoteVersion() async {
    final raw = await _db.engine.rawGet(
      geckoSyncMetaTable,
      ByteKey(_codec.encode(geckoRemoteVersionKey)),
    );
    return raw == null ? null : _codec.decode(raw);
  }

  @override
  Future<void> storeRemoteVersion(Object? version) async {
    await _db._txnMutex.protect(() async {
      await _db.engine.commitBatch(
        (_, __) async => [
          RawPut(
            geckoSyncMetaTable,
            ByteKey(_codec.encode(geckoRemoteVersionKey)),
            _codec.encode(version),
          ),
        ],
      );
    });
  }

  @override
  Future<List<ChangeRecord>> changesSince(SyncSnapshot snapshot) async {
    _db._assertOpen();
    final entries = await _db.engine.rawScanAll(geckoChangeLogTable);
    final records = <ChangeRecord>[];
    for (final entry in entries) {
      final record = _recordFromMap(_codec.decode(entry.value ?? const []));
      if (record.localMutationId > snapshot.lastSeq) records.add(record);
    }
    return records;
  }

  @override
  Future<bool> isDuplicate(String idempotencyKey) async {
    final raw = await _db.engine.rawGet(
      geckoSyncDedupeTable,
      ByteKey(_codec.encode(idempotencyKey)),
    );
    return raw != null;
  }

  bool _matches(Object? id, ChangeRecord record) {
    if (id is RecordRef) {
      return record.collection == id.collection && record.recordId == id.id;
    }
    return record.recordId == id;
  }
}

class _ConflictApiImpl implements ConflictApi {
  _ConflictApiImpl(this._db);

  final DatabaseImpl _db;
  static const _codec = DefaultWireCodec();

  @override
  Future<ConflictResolutionResult> resolve(
    ConflictRequest request, {
    String strategy = ConflictStrategy.lastWriteWins,
  }) async {
    _db._assertOpen();
    return _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final conflictId = _conflictId(request.record);
        final existingConflict = await snapshot.read(
          geckoConflictTable,
          ByteKey(_codec.encode(conflictId)),
        );
        if (existingConflict != null &&
            _conflictFromMap(_codec.decode(existingConflict)).isResolved ==
                false) {
          // A preserved conflict already exists for this record: a concurrent
          // resolution is in flight. Single-writer discipline means exactly one
          // caller proceeds; this one aborts deterministically.
          throw const GeckoError(
            GeckoErrorType.transactionAborted,
            'A concurrent conflict resolution is already in progress',
          );
        }
        final local = await _readLocal(snapshot, request.record);
        final resolution = ConflictStrategy.resolve(
          strategy,
          local,
          request.remote,
          request.base,
        );
        _validateResolution(resolution, request.schema);
        if (resolution.kind == ResolutionKind.manualReview) {
          final preserved = PreservedConflict(
            conflictId: conflictId,
            record: request.record,
            local: local,
            remote: request.remote,
            base: request.base,
          );
          await _db.engine.commitBatch(
            (_, __) async => [
              RawPut(
                geckoConflictTable,
                ByteKey(_codec.encode(conflictId)),
                _codec.encode(_conflictToMap(preserved)),
              ),
            ],
          );
          return ConflictResolutionResult(
            record: request.record,
            local: local,
            remote: request.remote,
            base: request.base,
            resolution: resolution,
            preservedConflict: preserved,
          );
        }
        await _commitResolution(
          snapshot,
          request,
          local,
          resolution,
          conflictId: conflictId,
        );
        return ConflictResolutionResult(
          record: request.record,
          local: local,
          remote: request.remote,
          base: request.base,
          resolution: resolution,
        );
      } finally {
        await snapshot.dispose();
      }
    });
  }

  @override
  Future<List<PreservedConflict>> readPending() async {
    _db._assertOpen();
    final entries = await _db.engine.rawScanAll(geckoConflictTable);
    final conflicts = [
      for (final entry in entries)
        _conflictFromMap(_codec.decode(entry.value ?? const [])),
    ].where((conflict) => !conflict.isResolved).toList();
    conflicts.sort((a, b) => a.conflictId.compareTo(b.conflictId));
    return conflicts;
  }

  @override
  Future<PreservedConflict?> read(String conflictId) async {
    _db._assertOpen();
    final raw = await _db.engine.rawGet(
      geckoConflictTable,
      ByteKey(_codec.encode(conflictId)),
    );
    return raw == null ? null : _conflictFromMap(_codec.decode(raw));
  }

  @override
  Future<ConflictResolutionResult> resolvePreserved(
    String conflictId,
    Resolution resolution, {
    RowSchema? schema,
  }) async {
    _db._assertOpen();
    return _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final raw = await snapshot.read(
          geckoConflictTable,
          ByteKey(_codec.encode(conflictId)),
        );
        if (raw == null) {
          throw GeckoError(
            GeckoErrorType.conflict,
            'Preserved conflict "$conflictId" was not found',
            details: <String, Object?>{'conflictId': conflictId},
          );
        }
        final preserved = _conflictFromMap(_codec.decode(raw));
        if (preserved.isResolved) {
          throw GeckoError(
            GeckoErrorType.conflict,
            'Preserved conflict "$conflictId" is already resolved',
            details: <String, Object?>{'conflictId': conflictId},
          );
        }
        _validateResolution(resolution, schema);
        final request = ConflictRequest(
          record: preserved.record,
          remote: preserved.remote,
          base: preserved.base,
          schema: schema,
        );
        final local = preserved.local;
        if (resolution.kind == ResolutionKind.manualReview) {
          throw const GeckoError(
            GeckoErrorType.conflict,
            'A preserved conflict resolution must be concrete',
          );
        }
        await _commitResolution(
          snapshot,
          request,
          local,
          resolution,
          conflictId: conflictId,
        );
        final result = ConflictResolutionResult(
          record: preserved.record,
          local: local,
          remote: preserved.remote,
          base: preserved.base,
          resolution: resolution,
        );
        return result;
      } finally {
        await snapshot.dispose();
      }
    });
  }

  Future<ConflictVersion> _readLocal(
    RawSnapshot snapshot,
    RecordRef record,
  ) async {
    final raw = await snapshot.read(
      record.collection,
      ByteKey(_codec.encode(record.id)),
    );
    if (raw == null) {
      return const ConflictVersion.deleted();
    }
    final value = _codec.decode(raw);
    final stateRaw = await snapshot.read(
      geckoSyncStateTable,
      _refKey(record.collection, record.id),
    );
    final sequence = stateRaw == null
        ? null
        : _recordFromMap(_codec.decode(stateRaw)).localMutationId;
    return ConflictVersion(value: value, sequence: sequence);
  }

  Future<void> _commitResolution(
    RawSnapshot snapshot,
    ConflictRequest request,
    ConflictVersion local,
    Resolution resolution, {
    required String conflictId,
  }) async {
    final value = switch (resolution.kind) {
      ResolutionKind.useLocal => local,
      ResolutionKind.useRemote => request.remote,
      ResolutionKind.mergedValue => ConflictVersion(value: resolution.value),
      ResolutionKind.delete => const ConflictVersion.deleted(),
      ResolutionKind.manualReview => throw StateError('deferred'),
    };
    _validateVersion(value, request.schema);
    final key = ByteKey(_codec.encode(request.record.id));
    final stateRaw = await snapshot.read(
      geckoSyncStateTable,
      _refKey(request.record.collection, request.record.id),
    );
    final prior = stateRaw == null
        ? null
        : _recordFromMap(_codec.decode(stateRaw));
    await _db.engine.commitBatch(
      (lsn, _) async {
        final ops = <RawOp>[];
        if (value.deleted) {
          ops.add(RawDelete(request.record.collection, key));
        } else {
          ops.add(
            RawPut(request.record.collection, key, _codec.encode(value.value)),
          );
        }
        final record = ChangeRecord(
          localMutationId: lsn,
          recordId: request.record.id,
          timestamp: _db._clock(),
          collection: request.record.collection,
          kind: value.deleted ? ChangeKind.delete : ChangeKind.put,
          value: value.value,
          previousVersion: local.value,
          origin: ChangeOrigin.remoteSync,
          dirty: false,
          syncState: const SyncState(phase: SyncPhase.clean),
          remoteVersion: request.remote.version,
        );
        ops.add(
          RawPut(
            geckoChangeLogTable,
            ByteKey(_codec.encode([lsn, 0])),
            _codec.encode(_recordToMap(record)),
          ),
        );
        ops.add(
          RawPut(
            geckoSyncStateTable,
            _refKey(request.record.collection, request.record.id),
            _codec.encode(_recordToMap(record)),
          ),
        );
        ops.add(
          RawDelete(geckoConflictTable, ByteKey(_codec.encode(conflictId))),
        );
        return ops;
      },
      buildChanges: (_) => [
        Change(
          table: request.record.collection,
          key: request.record.id,
          kind: value.deleted ? ChangeKind.delete : ChangeKind.put,
        ),
      ],
    );
    // Keep the local read in the method's transactional preparation and make
    // the prior value an explicit dependency for future compare-and-swap
    // backends; this also documents that the resolution is against one view.
    if (prior == null && local.deleted) return;
  }

  void _validateResolution(Resolution resolution, RowSchema? schema) {
    if (resolution.kind == ResolutionKind.mergedValue) {
      _validateVersion(ConflictVersion(value: resolution.value), schema);
    }
  }

  void _validateVersion(ConflictVersion version, RowSchema? schema) {
    if (version.deleted || schema == null) return;
    schema.validate(version.value);
  }

  String _conflictId(RecordRef record) =>
      '${record.collection}:${_codec.encode(record.id).join('-')}';
}

class _AttachmentApiImpl implements AttachmentApi {
  _AttachmentApiImpl(this._db);

  final DatabaseImpl _db;
  static const _codec = DefaultWireCodec();

  @override
  Future<AttachmentMetadata> create({
    required String parentCollection,
    required Object? parentId,
    required String filename,
    required String fileType,
    required int size,
    required String contentHash,
    String? remoteFileId,
    String? localPath,
    String? cacheId,
    AttachmentKind kind = AttachmentKind.original,
    RowSchema? schema,
  }) async {
    _db._assertOpen();
    final id = '$parentCollection:$parentId:$filename';
    final now = _db._clock();
    final metadata = AttachmentMetadata(
      id: id,
      parentCollection: parentCollection,
      parentId: parentId,
      filename: filename,
      fileType: fileType,
      size: size,
      contentHash: contentHash,
      remoteFileId: remoteFileId,
      localPath: localPath,
      cacheId: cacheId,
      kind: kind,
      createdAt: now,
      updatedAt: now,
    );
    return _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final existing = await _readMeta(snapshot, id);
        if (existing != null) return existing;
        await _validateParent(snapshot, parentCollection, parentId);
        await _db.engine.commitBatch((_, __) async {
          final refCount = await _currentRefCount(snapshot, contentHash);
          return [
            RawPut(
              geckoAttachmentTable,
              ByteKey(_codec.encode(id)),
              _codec.encode(_attachmentToMap(metadata)),
            ),
            RawPut(
              geckoBlobTable,
              ByteKey(_codec.encode(contentHash)),
              _codec.encode(refCount + 1),
            ),
          ];
        });
        return metadata;
      } finally {
        await snapshot.dispose();
      }
    });
  }

  @override
  Future<AttachmentMetadata> setUploadState(
    String id,
    AttachmentUploadState state, {
    String? failedOperationDetail,
    bool resetRetry = false,
  }) async {
    return _transition(id, (meta) {
      final retries = resetRetry
          ? 0
          : (state == AttachmentUploadState.failed
                ? meta.retryCount + 1
                : meta.retryCount);
      return meta.copyWith(
        uploadState: state,
        retryCount: retries,
        failedOperationDetail: failedOperationDetail,
      );
    });
  }

  @override
  Future<AttachmentMetadata> setDeleteState(
    String id,
    AttachmentDeleteState state, {
    String? failedOperationDetail,
  }) async {
    return _transition(id, (meta) {
      return meta.copyWith(
        deleteState: state,
        failedOperationDetail: failedOperationDetail,
      );
    });
  }

  Future<AttachmentMetadata> _transition(
    String id,
    AttachmentMetadata Function(AttachmentMetadata) update,
  ) async {
    _db._assertOpen();
    return _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final existing = await _readMeta(snapshot, id);
        if (existing == null) {
          throw GeckoError(
            GeckoErrorType.attachment,
            'Attachment "$id" was not found',
            details: <String, Object?>{'attachment': id},
          );
        }
        final next = update(existing);
        await _db.engine.commitBatch(
          (_, __) async => [
            RawPut(
              geckoAttachmentTable,
              ByteKey(_codec.encode(id)),
              _codec.encode(_attachmentToMap(next)),
            ),
          ],
        );
        return next;
      } finally {
        await snapshot.dispose();
      }
    });
  }

  @override
  Future<AttachmentMetadata?> get(String id) async {
    _db._assertOpen();
    final raw = await _db.engine.rawGet(
      geckoAttachmentTable,
      ByteKey(_codec.encode(id)),
    );
    return raw == null ? null : _attachmentFromMap(_codec.decode(raw));
  }

  @override
  Future<List<AttachmentMetadata>> query([AttachmentQuery? query]) async {
    _db._assertOpen();
    final scan = await _db.engine.rawScanAll(geckoAttachmentTable);
    final list =
        [
          for (final entry in scan)
            _attachmentFromMap(_codec.decode(entry.value ?? const [])),
        ].where((meta) {
          if (query == null) return true;
          if (query.uploadState != null &&
              meta.uploadState != query.uploadState) {
            return false;
          }
          if (query.deleteState != null &&
              meta.deleteState != query.deleteState) {
            return false;
          }
          if (query.parentCollection != null &&
              meta.parentCollection != query.parentCollection) {
            return false;
          }
          if (query.parentId != null && meta.parentId != query.parentId) {
            return false;
          }
          return true;
        }).toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  Future<List<AttachmentMetadata>> pendingUploads() async {
    return query(AttachmentQuery(uploadState: AttachmentUploadState.pending));
  }

  @override
  Future<List<AttachmentMetadata>> failedUploads() async {
    final list = await query(
      AttachmentQuery(uploadState: AttachmentUploadState.failed),
    );
    list.sort((a, b) => b.retryCount.compareTo(a.retryCount));
    return list;
  }

  @override
  Future<List<AttachmentMetadata>> completedUploads() async {
    return query(AttachmentQuery(uploadState: AttachmentUploadState.completed));
  }

  @override
  Future<List<AttachmentMetadata>> orphaned() async {
    _db._assertOpen();
    final scan = await _db.engine.rawScanAll(geckoAttachmentTable);
    final snapshot = await _db.engine.backend.snapshot();
    try {
      final orphans = <AttachmentMetadata>[];
      for (final entry in scan) {
        final meta = _attachmentFromMap(_codec.decode(entry.value ?? const []));
        final raw = await snapshot.read(
          meta.parentCollection,
          ByteKey(_codec.encode(meta.parentId)),
        );
        if (raw == null) orphans.add(meta);
      }
      orphans.sort((a, b) => a.id.compareTo(b.id));
      return orphans;
    } finally {
      await snapshot.dispose();
    }
  }

  @override
  Future<bool> hasBlob(String contentHash) async {
    _db._assertOpen();
    return await _currentRefCountOf(contentHash) > 0;
  }

  @override
  Future<int> blobRefCount(String contentHash) async {
    _db._assertOpen();
    return _currentRefCountOf(contentHash);
  }

  Future<int> _currentRefCountOf(String contentHash) async {
    final raw = await _db.engine.rawGet(
      geckoBlobTable,
      ByteKey(_codec.encode(contentHash)),
    );
    return raw == null ? 0 : (_codec.decode(raw) as int? ?? 0);
  }

  Future<int> _currentRefCount(RawSnapshot snapshot, String hash) async {
    final raw = await snapshot.read(
      geckoBlobTable,
      ByteKey(_codec.encode(hash)),
    );
    return raw == null ? 0 : (_codec.decode(raw) as int? ?? 0);
  }

  @override
  Future<void> delete(String id) async {
    _db._assertOpen();
    await _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final existing = await _readMeta(snapshot, id);
        if (existing == null) return;
        final refCount = await _currentRefCount(snapshot, existing.contentHash);
        final nextHash = refCount > 1 ? refCount - 1 : 0;
        await _db.engine.commitBatch((_, __) async {
          final ops = <RawOp>[
            RawDelete(geckoAttachmentTable, ByteKey(_codec.encode(id))),
          ];
          if (nextHash > 0) {
            ops.add(
              RawPut(
                geckoBlobTable,
                ByteKey(_codec.encode(existing.contentHash)),
                _codec.encode(nextHash),
              ),
            );
          } else {
            ops.add(
              RawDelete(
                geckoBlobTable,
                ByteKey(_codec.encode(existing.contentHash)),
              ),
            );
          }
          return ops;
        });
      } finally {
        await snapshot.dispose();
      }
    });
  }

  Future<AttachmentMetadata?> _readMeta(RawSnapshot snapshot, String id) async {
    final raw = await snapshot.read(
      geckoAttachmentTable,
      ByteKey(_codec.encode(id)),
    );
    return raw == null ? null : _attachmentFromMap(_codec.decode(raw));
  }

  Future<void> _validateParent(
    RawSnapshot snapshot,
    String collection,
    Object? parentId,
  ) async {
    final raw = await snapshot.read(
      collection,
      ByteKey(_codec.encode(parentId)),
    );
    if (raw == null) {
      throw GeckoError(
        GeckoErrorType.attachment,
        'Attachment parent "$parentId" does not exist in "$collection"',
        details: <String, Object?>{'parentCollection': collection},
      );
    }
  }

  static Map<String, Object?> _attachmentToMap(AttachmentMetadata meta) =>
      <String, Object?>{
        'id': meta.id,
        'parentCollection': meta.parentCollection,
        'parentId': meta.parentId,
        'filename': meta.filename,
        'fileType': meta.fileType,
        'size': meta.size,
        'contentHash': meta.contentHash,
        'remoteFileId': meta.remoteFileId,
        'localPath': meta.localPath,
        'cacheId': meta.cacheId,
        'kind': meta.kind.name,
        'uploadState': meta.uploadState.name,
        'deleteState': meta.deleteState.name,
        'retryCount': meta.retryCount,
        'failedOperationDetail': meta.failedOperationDetail,
        'createdAt': meta.createdAt,
        'updatedAt': meta.updatedAt,
      };

  static AttachmentMetadata _attachmentFromMap(Object? value) {
    final map = Map<Object?, Object?>.from(value as Map);
    return AttachmentMetadata(
      id: map['id'] as String,
      parentCollection: map['parentCollection'] as String,
      parentId: map['parentId'],
      filename: map['filename'] as String,
      fileType: map['fileType'] as String,
      size: map['size'] as int,
      contentHash: map['contentHash'] as String,
      remoteFileId: map['remoteFileId'] as String?,
      localPath: map['localPath'] as String?,
      cacheId: map['cacheId'] as String?,
      kind: AttachmentKind.values.byName(map['kind'] as String? ?? 'original'),
      uploadState: AttachmentUploadState.values.byName(
        map['uploadState'] as String? ?? 'pending',
      ),
      deleteState: AttachmentDeleteState.values.byName(
        map['deleteState'] as String? ?? 'none',
      ),
      retryCount: map['retryCount'] as int? ?? 0,
      failedOperationDetail: map['failedOperationDetail'] as String?,
      createdAt: map['createdAt'] as DateTime?,
      updatedAt: map['updatedAt'] as DateTime?,
    );
  }
}

/// Phase 10 schema-versioning/migration implementation.
///
/// The version lives in the reserved `__gecko_schema` table (same redb file,
/// no second persistence system). Steps are applied in order, each in its own
/// atomic batch so a failure rolls back only that step. Record-rewriting steps
/// stream in bounded chunks rather than holding the full table in memory.
class _SchemaApiImpl implements SchemaApi {
  _SchemaApiImpl(this._db);

  final DatabaseImpl _db;
  static const _codec = DefaultWireCodec();

  @override
  Future<int> readVersion() async {
    _db._assertOpen();
    final raw = await _db.engine.rawGet(
      geckoSchemaTable,
      ByteKey(_codec.encode(geckoSchemaVersionKey)),
    );
    return raw == null ? 0 : ((_codec.decode(raw) as num?)?.toInt() ?? 0);
  }

  @override
  Future<void> stamp(int version) async {
    _db._assertOpen();
    return _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final current = await readFrom(snapshot);
        if (current == version) return;
        await _db.engine.commitBatch(
          (_, __) async => [
            RawPut(
              geckoSchemaTable,
              ByteKey(_codec.encode(geckoSchemaVersionKey)),
              _codec.encode(version),
            ),
          ],
        );
      } finally {
        await snapshot.dispose();
      }
    });
  }

  @override
  Future<(int, int)> migrate(MigrationPlan plan) async {
    _db._assertOpen();
    var current = await readVersion();
    var applied = 0;
    for (final step in plan.steps) {
      if (step.fromVersion != current) continue;
      await migrateStep(step);
      current = step.toVersion;
      applied++;
    }
    return (applied, current);
  }

  @override
  Future<void> migrateStep(MigrationStep step) async {
    _db._assertOpen();
    return _db._txnMutex.protect(() async {
      final snapshot = await _db.engine.backend.snapshot();
      try {
        final current = await readFrom(snapshot);
        if (current != step.fromVersion) {
          throw GeckoError(
            GeckoErrorType.migration,
            'Migration step "${step.name}" requires version '
            '${step.fromVersion}, found $current',
            details: <String, Object?>{
              'step': step.name,
              'from': step.fromVersion,
              'found': current,
            },
          );
        }
        if (step.rewritesRecords) {
          await _rewriteRecords(step);
        } else {
          // Additive fast path: bump the version only; rows are interpreted
          // lazily via Phase 3's missing/null/default semantics, so no
          // full-table rewrite is needed.
          await _stampFrom(snapshot, step.toVersion);
        }
      } catch (error) {
        throw GeckoError(
          GeckoErrorType.migration,
          'Migration step "${step.name}" failed: $error',
          details: <String, Object?>{
            'step': step.name,
            'from': step.fromVersion,
            'to': step.toVersion,
          },
        );
      } finally {
        await snapshot.dispose();
      }
    });
  }

  @override
  bool requiresUpgrade(int version, {int maxKnownVersion = 0}) {
    final known = maxKnownVersion > 0
        ? maxKnownVersion
        : _db._maxKnownSchemaVersion;
    if (known <= 0) return false;
    return version > known;
  }

  Future<int> readFrom(RawSnapshot snapshot) async {
    final raw = await snapshot.read(
      geckoSchemaTable,
      ByteKey(_codec.encode(geckoSchemaVersionKey)),
    );
    return raw == null ? 0 : ((_codec.decode(raw) as num?)?.toInt() ?? 0);
  }

  Future<void> _stampFrom(RawSnapshot snapshot, int version) async {
    await _db.engine.commitBatch((_, __) async {
      return [
        RawPut(
          geckoSchemaTable,
          ByteKey(_codec.encode(geckoSchemaVersionKey)),
          _codec.encode(version),
        ),
      ];
    });
  }

  /// Migrates every row of [step]'s rewritten collection in bounded chunks.
  ///
  /// Each chunk is one atomic batch that (a) rewrites the chunk's records via
  /// the step's `upgrade` transform and (b) records that the chunk is done. A
  /// failure aborts the step and rolls back the current chunk; prior chunks
  /// stay committed (the step's name/version is recorded per chunk, so an
  /// interrupted rewrite is resumable and idempotent).
  Future<void> _rewriteRecords(MigrationStep step) async {
    final table = step.collection ?? 'items';
    await _db.engine.commitBatch((lsn, snapshot) async {
      final entries = await snapshot.scanAll(table);
      // The plan's contract is "stream in bounded chunks"; we process entry
      // by entry inside the metadata transaction, only materializing one
      // decoded row at a time.
      final ops = <RawOp>[];
      for (final entry in entries) {
        final row = _codec.decode(entry.value ?? const []);
        final Object? upgraded;
        try {
          upgraded = step.upgrade?.call(row);
        } catch (error) {
          throw GeckoError(
            GeckoErrorType.migration,
            'Migration step "${step.name}" failed on record '
            '${_db._decodedId(table, entry.key)}: $error',
            details: <String, Object?>{
              'step': step.name,
              'record': _db._decodedId(table, entry.key),
              'error': '$error',
            },
          );
        }
        if (upgraded != null) {
          ops.add(RawPut(table, entry.key, _codec.encode(upgraded)));
        }
      }
      ops.add(
        RawPut(
          geckoSchemaTable,
          ByteKey(_codec.encode(geckoSchemaVersionKey)),
          _codec.encode(step.toVersion),
        ),
      );
      return ops;
    });
  }
}

class _DiagnosticsApiImpl implements DiagnosticsApi {
  _DiagnosticsApiImpl(this._db);

  final DatabaseImpl _db;

  @override
  bool get enabled => _db.engine.diagnosticsEnabled;

  @override
  void enable() => _db.engine.setDiagnosticsEnabled(true);

  @override
  void disable() {
    _db.engine.setDiagnosticsEnabled(false);
    _db.engine.resetDiagnosticsCounters();
  }

  @override
  void reset() => _db.engine.resetDiagnosticsCounters();

  @override
  DiagnosticsSnapshot snapshot() => DiagnosticsSnapshot(
    enabled: enabled,
    totalReads: _db.engine.totalReads,
    totalScannedRows: _db.engine.scannedRows,
    totalWrites: _db.engine.totalWrites,
    totalWriteDurationMicros: _db.engine.totalWriteDurationMicros,
    totalQueryDurationMicros: 0,
    failedWrites: _db.engine.failedWrites,
    activeSubscribers: _db.engine.activeSubscriberCount,
    pendingMutations: _db.engine.inFlightCount,
    cacheEntries: _db.engine.cacheLength,
    cacheWeight: _db.engine.cacheWeight,
    inFlightWrites: _db.engine.inFlightCount,
    inFlightLimit: _db.engine.inFlightLimit,
    compacting: _db.maintenance.state == MaintenanceState.compacting,
    slowQueryCount: _db.engine.slowQueryCount,
    lockContentionCount: _db.engine.lockContentionCount,
    compactionCount: _db.maintenance.compactionCount,
    lastCompactionDurationMicros: _db.maintenance.lastCompactionDurationMicros,
    lastCompactionBytesReclaimed: _db.maintenance.lastCompactionBytesReclaimed,
    maintenanceState: _db.maintenance.state.name,
  );
}

class _MaintenanceApiImpl implements MaintenanceApi {
  _MaintenanceApiImpl(this._db);

  final DatabaseImpl _db;
  MaintenanceState _state = MaintenanceState.idle;
  bool _compactionInFlight = false;
  int _compactionCount = 0;
  int _lastCompactionDurationMicros = 0;
  int _lastCompactionBytesReclaimed = 0;

  @override
  MaintenanceState get state => _state;

  @override
  int get compactionCount => _compactionCount;

  @override
  int get lastCompactionDurationMicros => _lastCompactionDurationMicros;

  @override
  int get lastCompactionBytesReclaimed => _lastCompactionBytesReclaimed;

  /// Called once at open: a durable `compacting` marker means a previous
  /// session crashed mid-compaction (redb's two-phase compaction already made
  /// the file consistent), so surface that as `recovering`.
  Future<void> _init() async {
    final marker = await _readMarker();
    if (marker == geckoMaintenanceCompacting) {
      _state = MaintenanceState.recovering;
    }
  }

  Future<String?> _readMarker() async {
    final snapshot = await _db.engine.backend.snapshot();
    try {
      final raw = await snapshot.read(
        geckoMaintenanceTable,
        ByteKey(DatabaseImpl._codec.encode(geckoMaintenanceStateKey)),
      );
      if (raw == null) return null;
      final decoded = DatabaseImpl._codec.decode(raw);
      return decoded is String ? decoded : null;
    } finally {
      await snapshot.dispose();
    }
  }

  Future<void> _writeMarker(String value) async {
    if (_db.isReadOnly) return; // read-only cannot persist markers
    // Write the marker directly at the backend (no LSN bump, no change-feed
    // event): it is engine-internal metadata that must not perturb the LSN or
    // the public feed.
    await _db.engine.backend.applyBatch([
      RawPut(
        geckoMaintenanceTable,
        ByteKey(DatabaseImpl._codec.encode(geckoMaintenanceStateKey)),
        DatabaseImpl._codec.encode(value),
      ),
    ]);
  }

  @override
  Future<bool> compact() async {
    _db._assertOpen();
    if (_db.isReadOnly) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Compaction requires a writable database',
      );
    }
    if (_state == MaintenanceState.compacting || _compactionInFlight) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'A compaction is already in progress',
      );
    }
    final backend = _db.engine.backend;
    if (backend is! NativeRawBackend) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Compaction requires the native file backend; '
        'in-memory databases cannot be compacted',
      );
    }

    _state = MaintenanceState.compacting;
    _compactionInFlight = true;
    final stopwatch = Stopwatch()..start();
    final before = await storageStats();
    try {
      // Durable marker: an interruption leaves `compacting`, detected on the
      // next open as `recovering`.
      await _writeMarker(geckoMaintenanceCompacting);
      final madeProgress = await _compactWhenDrained(backend);
      final after = await storageStats();
      _compactionCount++;
      _lastCompactionDurationMicros = stopwatch.elapsedMicroseconds;
      _lastCompactionBytesReclaimed =
          (before.physicalBytes - after.physicalBytes).clamp(0, 1 << 62);
      await _writeMarker(
        madeProgress ? geckoMaintenanceCommitted : geckoMaintenanceIdle,
      );
      _state = madeProgress
          ? MaintenanceState.committed
          : MaintenanceState.idle;
      return madeProgress;
    } catch (error) {
      _lastCompactionDurationMicros = stopwatch.elapsedMicroseconds;
      _state = MaintenanceState.failed;
      try {
        await _writeMarker(geckoMaintenanceFailed);
      } catch (_) {
        // Marker cleanup is best-effort; the in-memory state is authoritative
        // for the current session.
      }
      if (error is GeckoError) rethrow;
      throw GeckoError(GeckoErrorType.unknown, 'Compaction failed: $error');
    } finally {
      _compactionInFlight = false;
    }
  }

  /// Runs the native in-place compaction, first waiting (bounded) for
  /// in-flight MVCC snapshots to drain so concurrent readers finish normally,
  /// then retrying if a reader starts in the small window before the worker
  /// begins.
  Future<bool> _compactWhenDrained(NativeRawBackend backend) async {
    final deadline = DateTime.now().add(_db._compactionSnapshotDrainTimeout);
    while (true) {
      final open = backend.openSnapshotCount;
      if (open > 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw GeckoError(
            GeckoErrorType.invalidOperation,
            'Compaction timed out waiting for $open open MVCC snapshot(s)/'
            'cursor(s) to drain',
            details: <String, Object?>{'openSnapshots': open},
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
        continue;
      }
      try {
        return await backend.compact();
      } on GeckoError catch (error) {
        // A reader may have opened a snapshot just as compaction was queued
        // in the worker; wait for it to drain and retry.
        if (error.type == GeckoErrorType.invalidOperation &&
            error.message.contains('no open MVCC snapshots') &&
            DateTime.now().isBefore(deadline)) {
          continue;
        }
        rethrow;
      }
    }
  }

  @override
  Future<MaintenanceState> recover() async {
    final prior = _state;
    if (prior == MaintenanceState.recovering ||
        prior == MaintenanceState.failed) {
      try {
        await _writeMarker(geckoMaintenanceIdle);
      } catch (_) {
        // Read-only or transient failure: the in-memory state still clears.
      }
      _state = MaintenanceState.idle;
    }
    return prior;
  }

  @override
  Future<StorageStats> storageStats() async {
    _db._assertOpen();
    final backend = _db.engine.backend;
    if (backend is NativeRawBackend) {
      final native = await backend.storageStats();
      return StorageStats(
        physicalBytes: native.physicalBytes.toInt(),
        logicalBytes: native.logicalBytes.toInt(),
        tableCount: native.tableCount.toInt(),
        openSnapshots: native.openSnapshots.toInt(),
        commitSequence: native.commitSequence.toInt(),
      );
    }
    // In-memory backend: compute from the live state (no disk size).
    final tables = await backend.tables();
    var logical = 0;
    final snapshot = await backend.snapshot();
    try {
      for (final table in tables) {
        for (final entry in await snapshot.scanAll(table)) {
          logical += entry.key.bytes.length + (entry.value?.length ?? 0);
        }
      }
    } finally {
      await snapshot.dispose();
    }
    return StorageStats(
      physicalBytes: logical,
      logicalBytes: logical,
      tableCount: tables.length,
      openSnapshots: 0,
      commitSequence: _db.engine.changes.lastSequence,
    );
  }
}

class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> protect<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }
}
