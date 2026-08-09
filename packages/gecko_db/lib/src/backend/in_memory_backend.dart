/// In-memory byte-level backend used for tests and non-persistent databases.
///
/// Implements the exact [`RawBackend`] interface as the (future) Rust `redb`
/// worker so that a single parametrized test suite can guard both. Per the
/// plan this is "the backbone of every later phase's test suite."
///
/// Semantics:
/// * One writer: [`applyBatch`] runs atomically — every op in a batch is
///   applied against the current committed state and published in one step, so
///   a reader can never observe a partial batch.
/// * MVCC reads: [`snapshot`] captures an immutable copy of the committed state
///   at that moment; subsequent writes don't affect it.
/// * Keys are byte-wise sorted within each table.
library;

import 'dart:collection';

import '../errors/errors.dart';
import 'byte_key.dart';
import 'raw_backend.dart';

/// A single table's key→value map, keyed by canonical bytes.
class _Table {
  _Table() : rows = SplayTreeMap<ByteKey, List<int>>();
  final SplayTreeMap<ByteKey, List<int>> rows;

  _Table copy() {
    final t = _Table();
    rows.forEach((k, v) => t.rows[k] = List<int>.from(v));
    return t;
  }
}

/// An immutable point-in-time snapshot of the whole database.
class _State {
  _State() : tables = <String, _Table>{};
  final Map<String, _Table> tables;

  _Table tableFor(String name) => tables.putIfAbsent(name, _Table.new);

  bool hasTable(String name) => tables.containsKey(name);

  _State copy() {
    final s = _State();
    tables.forEach((name, t) => s.tables[name] = t.copy());
    return s;
  }
}

/// In-memory [`RawBackend`] implementation.
class InMemoryBackend implements RawBackend {
  /// Creates an empty in-memory backend.
  InMemoryBackend({this.isReadOnly = false}) : _state = _State();

  @override
  final bool isReadOnly;

  _State _state;
  int _commitSeq = 0;

  @override
  Future<Set<(String, ByteKey)>> applyBatch(RawBatch ops) async {
    if (isReadOnly) {
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'The in-memory backend is read-only',
      );
    }
    // Build a copy first; publish only if the whole batch succeeds.
    final next = _state.copy();
    final affected = <(String, ByteKey)>{};
    for (final op in ops) {
      switch (op) {
        case RawPut(:final table, :final key, :final value):
          next.tableFor(table).rows[key] = List<int>.from(value);
          affected.add((table, key));
        case RawDelete(:final table, :final key):
          next.tableFor(table).rows.remove(key);
          affected.add((table, key));
        case RawDeleteRange(:final table, :final start, :final end):
          final doomed = next
              .tableFor(table)
              .rows
              .keys
              .where((k) => k.compareTo(start) >= 0 && k.compareTo(end) <= 0)
              .toList();
          for (final k in doomed) {
            next.tableFor(table).rows.remove(k);
            affected.add((table, k));
          }
        case RawClear(:final table):
          next.tableFor(table).rows.clear();
          affected.add((table, ByteKey(const [])));
      }
    }
    // Publish atomically: swap the immutable state, bump the commit counter.
    _state = next;
    _commitSeq++;
    return affected;
  }

  @override
  Future<RawSnapshot> snapshot() async => _MemSnapshot(_state);

  @override
  Future<bool> tableExists(String table) async => _state.hasTable(table);

  @override
  Future<List<String>> tables() async => _state.tables.keys.toList();

  @override
  Future<int> lastCommitSeq() async => _commitSeq;

  @override
  Future<void> close() async {}

  /// Direct mutation for tests that need to seed state (kept internal).
  void seedForTest(String table, List<int> key, List<int> value) {
    _state.tableFor(table).rows[ByteKey(key)] = List<int>.from(value);
  }

  /// Reads without a snapshot (for diagnostics).
  Future<List<int>?> debugRead(String table, ByteKey key) async =>
      _state.tables[table]?.rows[key];
}

class _MemSnapshot implements RawSnapshot {
  _MemSnapshot(this._state);
  final _State _state;

  @override
  Future<List<int>?> read(String table, ByteKey key) async {
    final t = _state.tables[table];
    if (t == null) return null;
    final v = t.rows[key];
    return v == null ? null : List<int>.from(v);
  }

  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) async {
    final out = <RawEntry>[];
    for (final key in keys) {
      final value = await read(table, key);
      if (value == null) continue;
      out.add(RawEntry(key, value));
    }
    return out;
  }

  @override
  Future<List<RawEntry>> scan(
    String table, {
    ByteKey? start,
    ByteKey? end,
    bool startInclusive = true,
    bool endInclusive = true,
  }) async {
    final t = _state.tables[table];
    if (t == null) return const [];
    final out = <RawEntry>[];
    for (final entry in t.rows.entries) {
      final k = entry.key;
      if (start != null) {
        final c = k.compareTo(start);
        if (c < 0 || (c == 0 && !startInclusive)) continue;
      }
      if (end != null) {
        final c = k.compareTo(end);
        if (c > 0 || (c == 0 && !endInclusive)) continue;
      }
      out.add(RawEntry(k, List<int>.from(entry.value)));
    }
    return out;
  }

  @override
  Future<List<RawEntry>> scanAll(String table) async =>
      scan(table, start: null, end: null);

  @override
  Future<void> dispose() async {
    // Immutable Dart state: nothing to release.
  }
}
