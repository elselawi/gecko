// support: backend differential harness.
//
// Replays the same deterministic operation script against two `RawEngine`s
// (typically an in-memory backend and the native file-backed backend) and
// compares, after every step:
//
//   * the full committed snapshot of every table, byte-for-byte,
//   * the returned result (deep equality) and the typed error category,
//   * the engine-assigned LSN (`changes.lastSequence`),
//   * the change-feed batches (order, keys, kinds, sequence numbers).
//
// This is the shared guard against in-memory/native/web semantic drift the
// plan's calls for. The harness itself contains no behavior
// behind a backend-specific branch: any divergence is reported as a mismatch.
library;

import 'package:gecko_db/gecko_db.dart';

/// A single deterministic step of a differential scenario.
sealed class DiffStep {
  const DiffStep();

  /// Human-readable label used in mismatch messages.
  String get label;

  /// Executes against [engine]. May throw a `GeckoError`; the runner maps the
  /// typed category for comparison.
  Future<Object?> run(RawEngine engine);
}

/// Engine-level `rawPut` (upsert / insertOnly / updateOnly).
class DiffPut extends DiffStep {
  const DiffPut(
    this.table,
    this.key,
    this.value, {
    this.mode = RawWriteMode.upsert,
  });

  final String table;
  final List<int> key;
  final List<int> value;
  final RawWriteMode mode;

  @override
  String get label => 'put(${mode.name}) $table ${_hex(key)} = ${_hex(value)}';

  @override
  Future<Object?> run(RawEngine engine) =>
      engine.rawPut(table, ByteKey(key), value, mode: mode);
}

/// Engine-level `rawDelete`.
class DiffDelete extends DiffStep {
  const DiffDelete(this.table, this.key);
  final String table;
  final List<int> key;

  @override
  String get label => 'delete $table ${_hex(key)}';

  @override
  Future<Object?> run(RawEngine engine) =>
      engine.rawDelete(table, ByteKey(key));
}

/// Engine-level `rawClear`.
class DiffClear extends DiffStep {
  const DiffClear(this.table);
  final String table;

  @override
  String get label => 'clear $table';

  @override
  Future<Object?> run(RawEngine engine) => engine.rawClear(table);
}

/// Engine-level `rawGet`.
class DiffGet extends DiffStep {
  const DiffGet(this.table, this.key);
  final String table;
  final List<int> key;

  @override
  String get label => 'get $table ${_hex(key)}';

  @override
  Future<Object?> run(RawEngine engine) => engine.rawGet(table, ByteKey(key));
}

/// Engine-level `rawRangeScan`.
class DiffRangeScan extends DiffStep {
  const DiffRangeScan(this.table, {this.start, this.end});
  final String table;
  final List<int>? start;
  final List<int>? end;

  @override
  String get label =>
      'rangeScan $table [${start == null ? '..' : _hex(start!)} .. '
      '${end == null ? '..' : _hex(end!)}]';

  @override
  Future<Object?> run(RawEngine engine) async {
    final entries = await engine.rawRangeScan(
      table,
      start: start == null ? null : ByteKey(start!),
      end: end == null ? null : ByteKey(end!),
    );
    return [
      for (final e in entries) <Object?>[_hex(e.key.bytes), e.value],
    ];
  }
}

/// Engine-level `rawScanAll`.
class DiffScanAll extends DiffStep {
  const DiffScanAll(this.table);
  final String table;

  @override
  String get label => 'scanAll $table';

  @override
  Future<Object?> run(RawEngine engine) async {
    final entries = await engine.rawScanAll(table);
    return [
      for (final e in entries) <Object?>[_hex(e.key.bytes), e.value],
    ];
  }
}

/// A direct backend batch (one atomic write transaction), exercising
/// multi-op and multi-table atomic batches below the engine.
class DiffBackendBatch extends DiffStep {
  const DiffBackendBatch(this.ops);
  final List<RawOp> ops;

  @override
  String get label =>
      'backendBatch(${ops.length} ops: ${ops.map((o) => o.runtimeType).join(',')})';

  @override
  Future<Object?> run(RawEngine engine) async {
    final result = await engine.backend.applyBatch(ops);
    return [
      for (final (table, key) in result.affected)
        <Object?>[table, _hex(key.bytes)],
    ];
  }
}

/// MVCC isolation differential: captures a snapshot, applies a write through
/// the backend, then reads the same keys from the old snapshot and a fresh
/// snapshot. Both engines must see the same pre-write state from the old
/// snapshot and the same post-write state from the fresh one.
class DiffMvccRead extends DiffStep {
  const DiffMvccRead({
    required this.ops,
    required this.readTable,
    required this.readKeys,
  });

  final List<RawOp> ops;
  final String readTable;
  final List<List<int>> readKeys;

  @override
  String get label => 'mvcc snapshot-then-write(${ops.length} ops)';

  @override
  Future<Object?> run(RawEngine engine) async {
    final snapshot = await engine.backend.snapshot();
    final before = <String, Object?>{
      for (final key in readKeys)
        _hex(key): await snapshot.read(readTable, ByteKey(key)),
    };
    await engine.backend.applyBatch(ops);
    final afterOldSnapshot = <String, Object?>{
      for (final key in readKeys)
        _hex(key): await snapshot.read(readTable, ByteKey(key)),
    };
    final fresh = await engine.backend.snapshot();
    final afterFreshSnapshot = <String, Object?>{
      for (final key in readKeys)
        _hex(key): await fresh.read(readTable, ByteKey(key)),
    };
    return <String, Object?>{
      'before': before,
      'afterOldSnapshot': afterOldSnapshot,
      'afterFreshSnapshot': afterFreshSnapshot,
    };
  }
}

/// The outcome of replaying a scenario: empty [mismatches] means the two
/// engines behaved identically on every step, snapshot, and feed.
class DifferentialOutcome {
  DifferentialOutcome(this.mismatches);
  final List<String> mismatches;
  bool get passed => mismatches.isEmpty;
}

/// Replays [steps] against both engines, comparing results, error categories,
/// snapshots, LSNs, and change feeds after every step.
Future<DifferentialOutcome> runDifferential(
  RawEngine engineA,
  RawEngine engineB,
  List<DiffStep> steps,
) async {
  final mismatches = <String>[];
  final feedA = _FeedCapture();
  final feedB = _FeedCapture();
  feedA.attach(engineA.changes);
  feedB.attach(engineB.changes);

  for (final step in steps) {
    final resultA = await _attempt(step, engineA);
    final resultB = await _attempt(step, engineB);
    if (!_sameResult(resultA, resultB)) {
      mismatches.add(
        'step "${step.label}": A=${_describe(resultA)} '
        'B=${_describe(resultB)}',
      );
    }
    final snapA = await _dump(engineA);
    final snapB = await _dump(engineB);
    if (canonical(snapA) != canonical(snapB)) {
      mismatches.add('step "${step.label}": committed snapshots differ');
    }
    if (engineA.changes.lastSequence != engineB.changes.lastSequence) {
      mismatches.add(
        'step "${step.label}": LSN differs '
        '(A=${engineA.changes.lastSequence}, '
        'B=${engineB.changes.lastSequence})',
      );
    }
  }

  if (canonical(feedA.batches) != canonical(feedB.batches)) {
    mismatches.add(
      'change feeds differ:\nA: ${feedA.batches}\nB: ${feedB.batches}',
    );
  }
  return DifferentialOutcome(mismatches);
}

typedef _Attempt = ({Object? value, GeckoError? error});

Future<_Attempt> _attempt(DiffStep step, RawEngine engine) async {
  try {
    return (value: await step.run(engine), error: null);
  } on GeckoError catch (error) {
    return (value: null, error: error);
  }
}

bool _sameResult(_Attempt a, _Attempt b) {
  final bothOk = a.error == null && b.error == null;
  if (bothOk) return canonical(a.value) == canonical(b.value);
  final bothError = a.error != null && b.error != null;
  if (bothError) return a.error!.type == b.error!.type;
  return false;
}

String _describe(_Attempt attempt) => attempt.error != null
    ? 'GeckoError(${attempt.error!.type.name})'
    : canonical(attempt.value);

/// Dumps every table (user + reserved) as table → sorted {keyHex → value}.
Future<Map<String, Map<String, Object?>>> _dump(RawEngine engine) async {
  final tables = await engine.backend.tables()
    ..sort();
  final result = <String, Map<String, Object?>>{};
  for (final table in tables) {
    final snapshot = await engine.backend.snapshot();
    final entries = await snapshot.scanAll(table);
    result[table] = {
      for (final entry in entries) _hex(entry.key.bytes): entry.value,
    };
  }
  return result;
}

/// Canonical deep string for cross-engine comparison.
///
/// Keys and values are canonicalized together so a map's *values* participate
/// in the comparison (looking up with the canonicalized key string would drop
/// them). Sorting the full `key=value` pair string still groups by key first.
String canonical(Object? value) {
  if (value == null) return 'null';
  if (value is String) return 'str:$value';
  if (value is bool) return 'bool:$value';
  if (value is int) return 'int:$value';
  if (value is double) return 'double:$value';
  if (value is ByteKey) return 'bytes:${_hex(value.bytes)}';
  if (value is List) {
    return 'list[${value.map(canonical).join(',')}]';
  }
  if (value is Map) {
    final pairs =
        value.entries
            .map((e) => '${canonical(e.key)}=${canonical(e.value)}')
            .toList()
          ..sort();
    return 'map{${pairs.join(',')}}';
  }
  return 'other:$value';
}

class _FeedCapture {
  final List<String> batches = [];

  void attach(ChangeBus bus) {
    bus.stream.listen((set) {
      final changes = [
        for (final c in set.changes)
          '${c.table}/${c.key}:${c.kind.name}:${c.sequence}',
      ];
      batches.add('seq=${set.sequence}[${changes.join(',')}]');
    });
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
