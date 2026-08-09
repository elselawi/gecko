/// The raw byte-level backend interface (Phase 2 core).
///
/// This is the seam both the in-memory backend (`InMemoryBackend`, for tests)
/// and the Rust `redb` worker (native) implement identically, so a single
/// parametrized test suite can guard every backend against divergence. Per
/// §0.5 contract 5, all metadata lives in reserved `__gecko_*` tables in the
/// same store as the data.
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

/// A snapshot handle for consistent reads.
///
/// Readers capture a snapshot (MVCC), observe a single consistent view, and
/// retry implicitly on write contention at the commit boundary. A snapshot is
/// only valid within the backend that created it.
abstract class RawSnapshot {
  /// Reads the value at [key] in [table], or null if absent.
  Future<List<int>?> read(String table, ByteKey key);

  /// M3: batched point-read — reads [keys] in [table], returning `(key,
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

/// The raw write/read engine contract. Exactly one writer may run at a time;
/// reads use snapshots for MVCC isolation.
abstract class RawBackend {
  /// Whether this backend was opened without write capability.
  bool get isReadOnly;

  /// Applies [ops] atomically: either all take effect or none do (single
  /// write transaction). Returns the set of affected (table, key) pairs.
  Future<Set<(String, ByteKey)>> applyBatch(RawBatch ops);

  /// Captures a consistent snapshot for reading.
  Future<RawSnapshot> snapshot();

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
