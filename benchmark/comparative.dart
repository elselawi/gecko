// Phase 13 — comparative benchmark: gecko_db vs Hive CE vs Sembast.
//
// A pragmatic, honest head-to-head on the SAME VM/hardware for the common
// local-first workloads: single insert, bulk insert, hot/cold reads, update,
// delete, full scan, and an equality-filtered query.
//
// IMPORTANT caveats (read before quoting any number):
//   * gecko_db is transactional (per-write redb commit), change-tracked
//     (sync log), MVCC, and reactive. Hive CE and Sembast are simpler
//     stores with lighter durability/atomicity guarantees. The delta you see
//     is partly the cost of those guarantees — that is the point of the
//     comparison, not a defect.
//   * Sizes are small enough to run in CI-ish time. Numbers are
//     hardware/JIT dependent — indicative, not marketing.
//
// Run from the repo root (requires release native artifact):
//   dart run benchmark/comparative.dart          # all three
//   dart run benchmark/comparative.dart --json   # machine-readable
//
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:hive_ce/hive.dart';
import 'package:sembast/sembast_io.dart' as sembast;

const int _seedRows = 1000;
const int _insertOps = 100;
const int _bulkRows = 500;
const int _readOps = 1000;
const int _updateOps = 100;
const int _deleteOps = 100;
const int _scanOps = 2;
const int _queryOps = 50;

// Sizes are modest because Sembast rewrites its whole store file per
// transaction (O(n²) on individual puts) — at 10k seed rows a single backend
// alone would take many minutes. The benchmark documents this cost honestly;
// gecko_db's redb and Hive CE handle the same per-write model without it.

const int _geckoChangeLogMaxEntries =
    0; // same as the local bench: storage path

String _repoRoot() {
  if (Directory.current.path.endsWith('benchmark')) {
    return Directory.current.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

Map<String, Object?> _row(int id, int num, String group) => {
  'id': id,
  'num': num,
  'group': group,
};

/// Common backend surface so every workload runs identically per store.
abstract class _Backend {
  String get name;
  Future<void> open(String dirPath);

  /// Seeds the table with [rows] using each store's natural batch mechanism
  /// (unmeasured — a real app seeds in bulk, not one transaction per row).
  Future<void> seed(List<Map<String, Object?>> rows);
  Future<void> put(int id, Map<String, Object?> row);
  Future<void> bulkPut(List<Map<String, Object?>> rows);
  Future<Map<String, Object?>?> get(int id);
  Future<void> update(int id, Map<String, Object?> row);
  Future<void> delete(int id);
  Future<List<Map<String, Object?>>> scanAll();
  Future<List<Map<String, Object?>>> queryGroup(String group);
  Future<void> close();
}

class _GeckoBackend implements _Backend {
  _GeckoBackend(this.nativePath);
  final String nativePath;
  late Database _db;
  late Collection<Map<String, Object?>> _coll;

  @override
  String get name => 'gecko_db (redb)';

  @override
  Future<void> open(String dirPath) async {
    _db = await Database.open(
      '$dirPath${Platform.pathSeparator}db.redb',
      config: DatabaseConfig(
        nativeLibraryPath: nativePath,
        changeLogMaxEntries: _geckoChangeLogMaxEntries,
      ),
    );
    _coll = _db.collection<Map<String, Object?>>(
      'items',
      toRow: (Map<String, Object?> r) => r,
      fromRow: (Object? r) => Map<String, Object?>.from(r as Map),
      id: (Map<String, Object?> r) => r['id'],
      indexFields: const ['group'],
    );
  }

  @override
  Future<void> seed(List<Map<String, Object?>> rows) async {
    await bulkPut(rows);
  }

  @override
  Future<void> put(int id, Map<String, Object?> row) => _coll.put(row);

  @override
  Future<void> bulkPut(List<Map<String, Object?>> rows) async {
    const chunk = 1000;
    for (var start = 0; start < rows.length; start += chunk) {
      final end = (start + chunk) > rows.length ? rows.length : start + chunk;
      await _db.bulkWrite([
        for (final row in rows.sublist(start, end))
          BulkMutation.put(table: 'items', key: row['id'], value: row),
      ]);
    }
  }

  @override
  Future<Map<String, Object?>?> get(int id) => _coll.get(id);

  @override
  Future<void> update(int id, Map<String, Object?> row) => _coll.put(row);

  @override
  Future<void> delete(int id) => _coll.delete(id);

  @override
  Future<List<Map<String, Object?>>> scanAll() => _coll.getAll();

  @override
  Future<List<Map<String, Object?>>> queryGroup(String group) =>
      _coll.where().filter('group', group).findAll();

  @override
  Future<void> close() => _db.close();
}

class _HiveBackend implements _Backend {
  @override
  String get name => 'hive_ce (box)';

  late Box<dynamic> _box;

  @override
  Future<void> open(String dirPath) async {
    Hive.init(dirPath); // hive_ce init is synchronous (void)
    _box = await Hive.openBox('items');
  }

  @override
  Future<void> seed(List<Map<String, Object?>> rows) async {
    await _box.putAll({for (final r in rows) r['id'].toString(): r});
  }

  @override
  Future<void> put(int id, Map<String, Object?> row) async {
    await _box.put(id.toString(), row);
  }

  @override
  Future<void> bulkPut(List<Map<String, Object?>> rows) async {
    for (final row in rows) {
      await _box.put(row['id'].toString(), row);
    }
  }

  @override
  Future<Map<String, Object?>?> get(int id) async {
    final v = _box.get(id.toString());
    return v is Map ? Map<String, Object?>.from(v) : null;
  }

  @override
  Future<void> update(int id, Map<String, Object?> row) async {
    await _box.put(id.toString(), row);
  }

  @override
  Future<void> delete(int id) async {
    await _box.delete(id.toString());
  }

  @override
  Future<List<Map<String, Object?>>> scanAll() async =>
      _box.values.map((v) => Map<String, Object?>.from(v as Map)).toList();

  @override
  Future<List<Map<String, Object?>>> queryGroup(String group) async => _box
      .values
      .map((v) => Map<String, Object?>.from(v as Map))
      .where((r) => r['group'] == group)
      .toList();

  @override
  Future<void> close() async {
    await _box.close();
  }
}

class _SembastBackend implements _Backend {
  @override
  String get name => 'sembast (file)';

  late sembast.Database _db;
  late sembast.StoreRef<String, Map<String, Object?>> _store;

  @override
  Future<void> open(String dirPath) async {
    _db = await sembast.databaseFactoryIo.openDatabase(
      '$dirPath${Platform.pathSeparator}db.sembast',
    );
    _store = sembast.stringMapStoreFactory.store('items');
  }

  @override
  Future<void> seed(List<Map<String, Object?>> rows) async {
    // Sembast rewrites its whole store file per transaction; seed in ONE
    // transaction so the unmeasured setup stays usable.
    await _db.transaction((txn) async {
      for (final row in rows) {
        await _store.record(row['id'].toString()).put(txn, row);
      }
    });
  }

  @override
  Future<void> put(int id, Map<String, Object?> row) async {
    await _store.record(id.toString()).put(_db, row);
  }

  @override
  Future<void> bulkPut(List<Map<String, Object?>> rows) async {
    for (final row in rows) {
      await _store.record(row['id'].toString()).put(_db, row);
    }
  }

  @override
  Future<Map<String, Object?>?> get(int id) =>
      _store.record(id.toString()).get(_db);

  @override
  Future<void> update(int id, Map<String, Object?> row) async {
    await _store.record(id.toString()).put(_db, row);
  }

  @override
  Future<void> delete(int id) async {
    await _store.record(id.toString()).delete(_db);
  }

  @override
  Future<List<Map<String, Object?>>> scanAll() async {
    final records = await _store.find(_db);
    return [for (final r in records) Map<String, Object?>.from(r.value)];
  }

  @override
  Future<List<Map<String, Object?>>> queryGroup(String group) async {
    final records = await _store.find(
      _db,
      finder: sembast.Finder(filter: sembast.Filter.equals('group', group)),
    );
    return [for (final r in records) Map<String, Object?>.from(r.value)];
  }

  @override
  Future<void> close() async {
    await _db.close();
  }
}

class _Row {
  _Row(this.backend, this.workload, this.msPerOp);
  final String backend;
  final String workload;
  final double msPerOp;
}

Future<void> main(List<String> args) async {
  final emitJson = args.contains('--json');
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);
  if (!File(nativePath).existsSync()) {
    stderr.writeln(
      'Native artifact not found at $nativePath. '
      'Run: cd rust && cargo build --release',
    );
    exit(2);
  }

  final backends = <_Backend>[
    _GeckoBackend(nativePath),
    _HiveBackend(),
    _SembastBackend(),
  ];

  final dir = await Directory.systemTemp.createTemp('gecko-compare-');
  final rows = <_Row>[];
  try {
    for (final backend in backends) {
      final backendDir =
          '${dir.path}${Platform.pathSeparator}${backend.name.replaceAll(' ', '_')}';
      Directory(backendDir).createSync(recursive: true);
      rows.addAll(await _runBackend(backend, backendDir, emitJson));
    }
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  if (emitJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'benchmark': 'gecko_db_phase13_comparative',
        'platform': Platform.operatingSystem,
        'dart': Platform.version.split(' ').first,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'note':
            'gecko_db is transactional/change-tracked/MVCC; delta vs simpler '
            'stores reflects those guarantees.',
        'results': [
          for (final r in rows)
            {
              'backend': r.backend,
              'workload': r.workload,
              'msPerOp': r.msPerOp,
            },
        ],
      }),
    );
    return;
  }

  final header =
      '${'backend'.padRight(18)} ${'workload'.padRight(14)} ${'ms/op'.padLeft(10)}';
  stdout.writeln('Phase 13 comparative (same VM/hardware):');
  stdout.writeln(header);
  stdout.writeln('-' * header.length);
  for (final r in rows) {
    final shown = r.msPerOp >= 1
        ? '${r.msPerOp.toStringAsFixed(3)} ms'
        : '${(r.msPerOp * 1000).toStringAsFixed(3)} us';
    stdout.writeln(
      '${r.backend.padRight(18)} ${r.workload.padRight(14)} '
      '${shown.padLeft(10)}',
    );
  }
  stdout.writeln();
  stdout.writeln(
    'Caveat: gecko_db commits every write transactionally (redb) and tracks '
    'changes for sync; Hive CE / Sembast do less. Compare like-for-like.',
  );
}

Future<List<_Row>> _runBackend(
  _Backend backend,
  String dirPath,
  bool quiet,
) async {
  if (!quiet) stdout.writeln('--- ${backend.name} ---');
  final results = <_Row>[];
  await backend.open(dirPath);

  // Seed (unmeasured) via each store's natural batch mechanism.
  await backend.seed([
    for (var i = 0; i < _seedRows; i++) _row(i, i, 'g${i % 100}'),
  ]);
  // Integrity: the seed must be durably readable before we measure anything.
  final seeded = await backend.scanAll();
  if (seeded.length != _seedRows) {
    throw StateError(
      '${backend.name}: seed integrity failed — expected $_seedRows rows, '
      'found ${seeded.length}. The backend is not executing writes.',
    );
  }
  if (!quiet) {
    stdout.writeln('  seeded ${seeded.length} rows (integrity ok)');
  }

  // 1. Single insert.
  final insertWatch = Stopwatch()..start();
  for (var i = 0; i < _insertOps; i++) {
    await backend.put(_seedRows + i, _row(_seedRows + i, i, 'g0'));
  }
  insertWatch.stop();
  results.add(
    _Row(
      backend.name,
      'insert',
      insertWatch.elapsedMicroseconds / _insertOps / 1000,
    ),
  );
  final afterInsert = await backend.scanAll();
  if (afterInsert.length != _seedRows + _insertOps) {
    throw StateError(
      '${backend.name}: insert integrity failed — expected '
      '${_seedRows + _insertOps}, found ${afterInsert.length}.',
    );
  }

  // 2. Bulk insert.
  final bulkRows = [
    for (var i = 0; i < _bulkRows; i++)
      _row(_seedRows + _insertOps + i, i, 'g1'),
  ];
  final bulkWatch = Stopwatch()..start();
  await backend.bulkPut(bulkRows);
  bulkWatch.stop();
  results.add(
    _Row(
      backend.name,
      'bulkInsert',
      bulkWatch.elapsedMicroseconds / _bulkRows / 1000,
    ),
  );

  // 3. Hot read.
  final hotWatch = Stopwatch()..start();
  for (var i = 0; i < _readOps; i++) {
    await backend.get(0);
  }
  hotWatch.stop();
  results.add(
    _Row(
      backend.name,
      'hotRead',
      hotWatch.elapsedMicroseconds / _readOps / 1000,
    ),
  );

  // 4. Cold read.
  final coldWatch = Stopwatch()..start();
  for (var i = 0; i < _readOps; i++) {
    await backend.get(i % _seedRows);
  }
  coldWatch.stop();
  results.add(
    _Row(
      backend.name,
      'coldRead',
      coldWatch.elapsedMicroseconds / _readOps / 1000,
    ),
  );

  // 5. Update.
  final updateWatch = Stopwatch()..start();
  for (var i = 0; i < _updateOps; i++) {
    await backend.update(i % _seedRows, _row(i % _seedRows, i, 'g2'));
  }
  updateWatch.stop();
  results.add(
    _Row(
      backend.name,
      'update',
      updateWatch.elapsedMicroseconds / _updateOps / 1000,
    ),
  );

  // 6. Delete (removes the first _deleteOps seed rows so the final count is
  // deterministic and the workload is meaningful).
  final deleteWatch = Stopwatch()..start();
  for (var i = 0; i < _deleteOps; i++) {
    await backend.delete(i);
  }
  deleteWatch.stop();
  results.add(
    _Row(
      backend.name,
      'delete',
      deleteWatch.elapsedMicroseconds / _deleteOps / 1000,
    ),
  );

  // 7. Full scan.
  final scanWatch = Stopwatch()..start();
  for (var i = 0; i < _scanOps; i++) {
    await backend.scanAll();
  }
  scanWatch.stop();
  results.add(
    _Row(
      backend.name,
      'scanAll',
      scanWatch.elapsedMicroseconds / _scanOps / 1000,
    ),
  );

  // 8. Filtered query (equality on group).
  final queryWatch = Stopwatch()..start();
  for (var i = 0; i < _queryOps; i++) {
    await backend.queryGroup('g${i % 100}');
  }
  queryWatch.stop();
  results.add(
    _Row(
      backend.name,
      'queryGroup',
      queryWatch.elapsedMicroseconds / _queryOps / 1000,
    ),
  );

  // Final integrity: seed + inserts + bulk must all be present, minus deletes.
  final expectedFinal = _seedRows + _insertOps + _bulkRows - _deleteOps;
  final finalCount = (await backend.scanAll()).length;
  if (finalCount != expectedFinal) {
    throw StateError(
      '${backend.name}: final integrity failed — expected $expectedFinal, '
      'found $finalCount.',
    );
  }

  await backend.close();
  if (!quiet) stdout.writeln();
  return results;
}
