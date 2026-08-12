// / comparative benchmark: gecko_db vs Hive CE vs Sembast vs
// SQLite vs Isar (isar_community) vs Drift.
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
//   * SQLite and Drift (a typed layer over SQLite) resolve the native
//     `sqlite3` library through Dart native assets (`package:sqlite3` 3.x) —
//     no external dll is required on any platform.
//   * Isar runs through the actively-maintained `isar_community` fork (the
//     original `isar` generator rejects the current Dart SDK). Isar and Drift
//     schemas are code-generated (`dart run build_runner build --force-jit`);
//     the generated files are committed so the benchmark runs with no build
//     step.
//
// Run from the benchmark package (requires release native artifact):
//   cd benchmark && dart run comparative.dart          # all six
//   cd benchmark && dart run comparative.dart --json   # machine-readable
//
// The benchmark is its own package on purpose: sqlite3 3.x runs Dart
// native-assets build hooks that would otherwise pollute the monorepo root's
// `dart run` stdout (breaking the process tests that read exact markers).
//
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:gecko_db/gecko_db.dart';
import 'package:hive_ce/hive.dart';
import 'package:isar_community/isar.dart' as isar;
import 'package:sembast/sembast_io.dart' as sembast;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'drift_database.dart';
import 'isar_schema.dart';

const int _seedRows = 1000;
const int _insertOps = 100;
const int _bulkRows = 500;
const int _readOps = 1000;
const int _updateOps = 100;
const int _deleteOps = 100;
const int _scanOps = 2;
const int _queryOps = 50;

/// Unmeasured read-path JIT warm-up before the hot/cold read timing. Every
/// backend runs in a fresh process, so the first reads JIT-compile the get()
/// path; timing a cold read path inflates the hot/cold read means. Warm the
/// hit path on the hot key and the native miss path on existing keys outside
/// the cold-read set (see `_runBackend`).
const int _warmupReads = 5000;

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

/// SQLite backend raw SQL via `package:sqlite3`, WAL journal, an index
/// on `group`, prepared statements, and batched writes in one transaction.
class _SqliteBackend implements _Backend {
  @override
  String get name => 'sqlite3 (file)';

  late sqlite3.Database _db;
  late sqlite3.PreparedStatement _put;
  late sqlite3.PreparedStatement _get;
  late sqlite3.PreparedStatement _delete;
  late sqlite3.PreparedStatement _scan;
  late sqlite3.PreparedStatement _query;

  @override
  Future<void> open(String dirPath) async {
    // sqlite3 3.x resolves the native library through Dart native assets; no
    // external dll is needed on any platform.
    _db = sqlite3.sqlite3.open('$dirPath${Platform.pathSeparator}db.sqlite');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute(
      'CREATE TABLE IF NOT EXISTS items ('
      'id INTEGER PRIMARY KEY, num INTEGER NOT NULL, "group" TEXT NOT NULL)',
    );
    _db.execute('CREATE INDEX IF NOT EXISTS idx_items_group ON items("group")');
    _put = _db.prepare(
      'INSERT INTO items(id, num, "group") VALUES (?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET num = excluded.num, '
      '"group" = excluded."group"',
    );
    _get = _db.prepare('SELECT num, "group" FROM items WHERE id = ?');
    _delete = _db.prepare('DELETE FROM items WHERE id = ?');
    _scan = _db.prepare('SELECT id, num, "group" FROM items ORDER BY id');
    _query = _db.prepare(
      'SELECT id, num, "group" FROM items WHERE "group" = ?',
    );
  }

  Future<void> _tx(List<Map<String, Object?>> rows) async {
    _db.execute('BEGIN');
    try {
      for (final r in rows) {
        _put.execute([r['id'], r['num'], r['group']]);
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> seed(List<Map<String, Object?>> rows) => _tx(rows);

  @override
  Future<void> put(int id, Map<String, Object?> row) async {
    _put.execute([id, row['num'], row['group']]);
  }

  @override
  Future<void> bulkPut(List<Map<String, Object?>> rows) => _tx(rows);

  @override
  Future<Map<String, Object?>?> get(int id) async {
    final rows = _get.select([id]).toList();
    if (rows.isEmpty) return null;
    final r = rows.first;
    return <String, Object?>{'id': id, 'num': r['num'], 'group': r['group']};
  }

  @override
  Future<void> update(int id, Map<String, Object?> row) async {
    _put.execute([id, row['num'], row['group']]);
  }

  @override
  Future<void> delete(int id) async {
    _delete.execute([id]);
  }

  @override
  Future<List<Map<String, Object?>>> scanAll() async => [
    for (final r in _scan.select([]))
      <String, Object?>{'id': r['id'], 'num': r['num'], 'group': r['group']},
  ];

  @override
  Future<List<Map<String, Object?>>> queryGroup(String group) async => [
    for (final r in _query.select([group]))
      <String, Object?>{'id': r['id'], 'num': r['num'], 'group': r['group']},
  ];

  @override
  Future<void> close() async {
    _put.close();
    _get.close();
    _delete.close();
    _scan.close();
    _query.close();
    _db.close();
  }
}

/// Isar backend `isar_community`, indexed on `group`.
///
/// Isar ids must be non-zero, so the benchmark's external id (which starts at
/// 0) is offset by +1 when stored and mapped back when read.
class _IsarBackend implements _Backend {
  @override
  String get name => 'isar_community (file)';

  late isar.Isar _isar;
  late isar.IsarCollection<Item> _coll;

  Item _toItem(int id, Map<String, Object?> row) => Item()
    ..id = id + 1
    ..num = row['num'] as int
    ..group = row['group'] as String;

  Map<String, Object?> _toRow(Item item) => <String, Object?>{
    'id': item.id - 1,
    'num': item.num,
    'group': item.group,
  };

  @override
  Future<void> open(String dirPath) async {
    // Pure-Dart (non-Flutter) use: download the platform's Isar Core binary
    // on first run and cache it next to the script (see isar_community docs
    // for `initializeIsarCore`). Subsequent runs reuse the cached binary.
    await isar.Isar.initializeIsarCore(download: true);
    _isar = await isar.Isar.open(
      [ItemSchema],
      directory: dirPath,
      name: 'items',
    );
    _coll = _isar.items;
  }

  @override
  Future<void> seed(List<Map<String, Object?>> rows) =>
      _isar.writeTxn(() async {
        await _coll.putAll([for (final r in rows) _toItem(r['id'] as int, r)]);
      });

  @override
  Future<void> put(int id, Map<String, Object?> row) =>
      _isar.writeTxn(() => _coll.put(_toItem(id, row)));

  @override
  Future<void> bulkPut(List<Map<String, Object?>> rows) =>
      _isar.writeTxn(() async {
        await _coll.putAll([for (final r in rows) _toItem(r['id'] as int, r)]);
      });

  @override
  Future<Map<String, Object?>?> get(int id) async {
    final item = await _coll.get(id + 1);
    return item == null ? null : _toRow(item);
  }

  @override
  Future<void> update(int id, Map<String, Object?> row) =>
      _isar.writeTxn(() => _coll.put(_toItem(id, row)));

  @override
  Future<void> delete(int id) => _isar.writeTxn(() => _coll.delete(id + 1));

  @override
  Future<List<Map<String, Object?>>> scanAll() async => [
    for (final item in await _coll.where().findAll()) _toRow(item),
  ];

  @override
  Future<List<Map<String, Object?>>> queryGroup(String group) async => [
    for (final item in await _coll.where().groupEqualTo(group).findAll())
      _toRow(item),
  ];

  @override
  Future<void> close() => _isar.close();
}

/// Drift backend a typed layer over SQLite using the same native
/// `sqlite3` library as the plain-SQLite backend.
class _DriftBackend implements _Backend {
  @override
  String get name => 'drift (sqlite)';

  late AppDatabase _db;

  ItemsCompanion _companion(int id, Map<String, Object?> row) =>
      ItemsCompanion.insert(
        id: drift.Value(id),
        num: row['num'] as int,
        group: row['group'] as String,
      );

  Map<String, Object?> _toRow(ItemRow r) => <String, Object?>{
    'id': r.id,
    'num': r.num,
    'group': r.group,
  };

  @override
  Future<void> open(String dirPath) async {
    _db = AppDatabase.openFile('$dirPath${Platform.pathSeparator}db.sqlite');
  }

  @override
  Future<void> seed(List<Map<String, Object?>> rows) async {
    await _db.transaction(() async {
      for (final r in rows) {
        await _db.into(_db.items).insert(_companion(r['id'] as int, r));
      }
    });
  }

  @override
  Future<void> put(int id, Map<String, Object?> row) =>
      _db.into(_db.items).insertOnConflictUpdate(_companion(id, row));

  @override
  Future<void> bulkPut(List<Map<String, Object?>> rows) async {
    await _db.transaction(() async {
      for (final r in rows) {
        await _db.into(_db.items).insert(_companion(r['id'] as int, r));
      }
    });
  }

  @override
  Future<Map<String, Object?>?> get(int id) async {
    final row = await (_db.select(
      _db.items,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toRow(row);
  }

  @override
  Future<void> update(int id, Map<String, Object?> row) =>
      _db.into(_db.items).insertOnConflictUpdate(_companion(id, row));

  @override
  Future<void> delete(int id) async {
    await (_db.delete(_db.items)..where((t) => t.id.equals(id))).go();
  }

  @override
  Future<List<Map<String, Object?>>> scanAll() async {
    final rows = await (_db.select(
      _db.items,
    )..orderBy([(t) => drift.OrderingTerm.asc(t.id)])).get();
    return [for (final r in rows) _toRow(r)];
  }

  @override
  Future<List<Map<String, Object?>>> queryGroup(String group) async {
    final rows = await (_db.select(
      _db.items,
    )..where((t) => t.group.equals(group))).get();
    return [for (final r in rows) _toRow(r)];
  }

  @override
  Future<void> close() => _db.close();
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

  // SQLite/Drift resolve the native `sqlite3` library through Dart native
  // assets (package:sqlite3 3.x) — no external dll is required.

  final backends = <_Backend>[
    _GeckoBackend(nativePath),
    _HiveBackend(),
    _SembastBackend(),
    _SqliteBackend(),
    _IsarBackend(),
    _DriftBackend(),
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
        'benchmark': 'gecko_db_comparative',
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
  stdout.writeln('comparative (same VM/hardware):');
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
    'changes for sync; Hive CE / Sembast / Isar do less, and SQLite / Drift '
    'skip change tracking and MVCC snapshotting. Compare like-for-like.',
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

  // Read-path JIT warm-up (unmeasured). Warm the hit path on the hot key so
  // hotRead measures steady-state cache hits, and warm the native miss path
  // on existing keys OUTSIDE the cold-read set (0..seedRows) so coldRead
  // still measures genuine cache misses on a JIT-warm path.
  for (var i = 0; i < _warmupReads; i++) {
    await backend.get(0);
  }
  for (var i = 0; i < _warmupReads; i++) {
    await backend.get(_seedRows + (i % (_insertOps + _bulkRows)));
  }

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
