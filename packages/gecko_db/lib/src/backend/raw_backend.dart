/// The raw byte-level backend interface (core).
///
/// This is the seam the Rust `redb` worker (native) implements; a single
/// parametrized test suite guards the backend contract. All metadata lives in
/// reserved `__gecko_*` tables in the same store as the data.
library;

import 'byte_key.dart';
import '../errors/errors.dart';

/// A single operation applied atomically within a batch.
sealed class RawOp {
  const RawOp();
}

/// Insert or overwrite [key] → [value] in [table].
class RawPut extends RawOp {
  const RawPut(this.table, this.key, this.value);
  final String table;
  final ByteKey key;
  final List<int> value;
}

/// Delete the record at [key] in [table] (a no-op if absent).
class RawDelete extends RawOp {
  const RawDelete(this.table, this.key);
  final String table;
  final ByteKey key;
}

/// Delete every key in [[start], [end]] (inclusive bounds below).
class RawDeleteRange extends RawOp {
  const RawDeleteRange(this.table, this.start, this.end);
  final String table;
  final ByteKey start;
  final ByteKey end;
}

/// Delete every key in [table].
class RawClear extends RawOp {
  const RawClear(this.table);
  final String table;
}

typedef RawBatch = List<RawOp>;

/// A point range scan (key + optional value), exposed as an ordered snapshot.
class RawEntry {
  const RawEntry(this.key, this.value);
  final ByteKey key;

  /// The raw value bytes, or null when the entry has no payload.
  final List<int>? value;
}

/// child rows sharing one foreign-key value (parent id), grouped in the
/// Rust worker. The worker classifies candidates by FK so Dart only decodes
/// the rows that already belong to the requested parents.
class GroupedChildren {
  const GroupedChildren({required this.parentId, required this.entries});

  /// The encoded FK value (the parent id bytes).
  final ByteKey parentId;

  /// Child rows in row-key order whose FK equals [parentId].
  final List<RawEntry> entries;
}

/// A snapshot handle for consistent reads.
///
/// Readers capture a snapshot (MVCC), observe a single consistent view, and
/// retry implicitly on write contention at the commit boundary. A snapshot is
/// only valid within the backend that created it.
abstract class RawSnapshot {
  /// Reads the value at [key] in [table], or null if absent.
  Future<List<int>?> read(String table, ByteKey key);

  /// batched point-read — reads [keys] in [table], returning `(key,
  /// value)` pairs for keys that exist in input order. Absent keys are
  /// omitted. Backends with a native batch primitive (the Rust worker)
  /// implement this as one boundary crossing; in-memory backends loop over
  /// [read].
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys);

  /// Scans keys in [[start], [end]] (inclusive both ends), in ascending
  /// byte-wise order. Returns key/value pairs.
  Future<List<RawEntry>> scan(
    String table, {
    ByteKey? start,
    ByteKey? end,
    bool startInclusive = true,
    bool endInclusive = true,
  });

  /// All keys in [table] in ascending order.
  Future<List<RawEntry>> scanAll(String table);

  /// Releases any backend-held resources (e.g. a native MVCC read
  /// transaction). Safe to call multiple times; a no-op on backends that hold
  /// no resources (in-memory). Callers that hold a snapshot across work (the
  /// engine, transactions) dispose it deterministically; backends also drop
  /// their open snapshots on [RawBackend.close].
  Future<void> dispose() async {}
}

/// Optional capability implemented by native backends that forward durable
/// index declarations to Rust.
abstract class DurableIndexRegistrar {
  void registerDurableIndex(String table, List<String> fields);
}

/// one per-registration delta produced by a committed batch.
/// All lists are ordered: [added], [updated], [removed] follow the batch's
/// change order; [snapshot] is the full current result set in result order
/// (byte-key order for unsorted registrations, comparator order for sorted).
class RegistryDelta {
  const RegistryDelta({
    required this.id,
    required this.added,
    required this.updated,
    required this.removed,
    required this.snapshot,
    required this.unchanged,
  });

  /// The registration id this delta belongs to.
  final int id;

  /// Rows that joined the result set this batch (key, value).
  final List<RawEntry> added;

  /// Rows whose value changed but that stayed in the result set.
  final List<RawEntry> updated;

  /// Rows that left the result set (key + previous value bytes).
  final List<RawEntry> removed;

  /// The full current result set in result order.
  final List<RawEntry> snapshot;

  /// True when nothing observable changed (idempotent writes); the
  /// `watchAllDiff` stream suppresses no-op emissions.
  final bool unchanged;
}

/// the outcome of one committed batch at the raw layer — the
/// affected (table, key) pairs plus one [RegistryDelta] per touched live
/// registration.
class ApplyBatchResult {
  const ApplyBatchResult({required this.affected, required this.deltas});
  final Set<(String, ByteKey)> affected;
  final List<RegistryDelta> deltas;
}

/// the kind of live result a registration maintains (mirrors
/// `rust::registry::LiveQueryKind`).
enum LiveQueryKind {
  /// `collection.watchAll()` — full set, emits every relevant batch.
  watchAll(0),

  /// `collection.watchAllDiff()` — full set + per-batch diff; suppresses
  /// emissions when nothing observable changed.
  watchAllDiff(1),

  /// `query.where(...).watch()` — filtered (optionally sorted) set.
  query(2);

  const LiveQueryKind(this.value);
  final int value;
}

/// a registered live query — its id plus the initial result
/// set in result order.
class LiveQueryRegistration {
  const LiveQueryRegistration({required this.id, required this.initial});
  final int id;
  final List<RawEntry> initial;
}

/// The raw write/read engine contract. Exactly one writer may run at a time;
/// reads use snapshots for MVCC isolation.
abstract class RawBackend {
  /// Whether this backend was opened without write capability.
  bool get isReadOnly;

  /// Applies [ops] atomically: either all take effect or none do (single
  /// write transaction). Returns the affected (table, key) pairs plus any
  /// reactive-registry deltas produced by the batch.
  Future<ApplyBatchResult> applyBatch(RawBatch ops);

  /// registers a live query with the worker's reactive
  /// registry and materializes its initial result set. [kind] is 0 = watchAll,
  /// 1 = watchAllDiff, 2 = query. [predicateBytes]/[sortBytes] are the encoded
  /// predicate/sort payloads (empty predicate matches everything).
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
  });

  /// removes a live-query registration (idempotent).
  Future<void> unregisterLiveQuery(int id);

  /// Number of active live-query registrations (diagnostics).
  Future<int> liveQueryCount();

  /// aggregates the pending local changes from the sync-state table
  /// (dirty, non-remote, ordered by localMutationId). The scan/filter/sort
  /// executes in Rust; Dart decodes the returned (key, record) pairs.
  Future<List<RawEntry>> pendingChanges();

  /// Captures a consistent snapshot for reading.
  Future<RawSnapshot> snapshot();

  /// batched point-read without an explicit snapshot handle. Reads all
  /// [keys] in [table] under ONE consistent read transaction, returning
  /// `(key, value)` pairs for keys that exist in input order; absent keys are
  /// omitted. On the native backend this is a single boundary crossing (one
  /// Rust read transaction), so the incremental watch path can apply a change
  /// batch at one FRB hop instead of create-snapshot + read + drop-snapshot.
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys);

  /// Whether a table exists (used to distinguish missing-table reads).
  Future<bool> tableExists(String table);

  /// Lists all tables (including reserved `__gecko_*` metadata tables).
  Future<List<String>> tables();

  /// The engine's monotonic commit counter (LSN), for ordering / debugging.
  Future<int> lastCommitSeq();

  /// Releases native/file resources. In-memory backends may no-op.
  Future<void> close();
}

/// Maps a missing-key read to a typed `keyNotFound` error — the public
/// contract, never an opaque throw.
GeckoError keyNotFoundError(String table, ByteKey key) => GeckoError(
  GeckoErrorType.keyNotFound,
  'No value for key $key in table "$table"',
  details: <String, Object?>{'table': table},
);
