// gecko_db local benchmark harness (stopgap; not the Phase 13 comparative
// suite). Measures real, per-operation numbers for the native file backend:
// single-insert throughput, bulk insert, hot/cold point reads, range scans,
// filtered queries, watch latency, and transaction commit.
//
// Run from the repo root:
//   dart run benchmark/bench.dart            # native file backend
//   dart run benchmark/bench.dart --json     # machine-readable JSON on stdout
//
// The native backend needs the release artifact built:
//   cd rust && cargo build --release
//
// Output is a table of ms/op and ops/s (or JSON with --json); numbers are
// indicative and depend on hardware/JIT state — this is a regression
// rough-check, not a publishable marketing claim. tool/perf_gate.dart
// consumes the --json output to gate regressions against benchmark/baseline.json.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

const int _seedRows = 1000;
const int _insertOps = 500;
const int _bulkPerCall = 500;
const int _bulkCalls = 2;
const int _readOps = 5000;
const int _scanOps = 30;
const int _queryOps = 30;
const int _watchOps = 100;
const int _txnOps = 200;

/// The benchmark measures the storage path, so the change-log pruning scan
/// (O(n) per commit once the log is full, and it never prunes dirty records)
/// is disabled. With default config (1000) the per-write scan dominates and
/// would swamp the numbers.
const int _changeLogMaxEntries = 0;

class _Row {
  _Row(this.id, this.num, this.group);
  final String id;
  final int num;
  final String group;
}

Object? _toRow(_Row r) => {'id': r.id, 'num': r.num, 'group': r.group};
_Row _fromRow(Object? row) => _Row(
  (row as Map)['id'] as String,
  row['num'] as int,
  row['group'] as String,
);
Object? _id(_Row r) => r.id;

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

class _Result {
  _Result(this.backend, this.workload, this.msPerOp, this.opsPerSec);
  final String backend;
  final String workload;
  final double msPerOp;
  final double opsPerSec;
}

final List<Directory> _tempDirs = <Directory>[];

Future<void> main(List<String> args) async {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);
  final emitJson = args.contains('--json');
  if (!emitJson) {
    stdout.writeln('=== gecko_db benchmark (local stopgap harness) ===');
    stdout.writeln(
      'platform: ${Platform.operatingSystem} | '
      'dart ${Platform.version.split(' ').first}',
    );
    stdout.writeln(
      'seed rows: $_seedRows | workloads: '
      'insert=$_insertOps bulk=${_bulkCalls * _bulkPerCall} '
      'read=$_readOps scan=$_scanOps query=$_queryOps '
      'watch=$_watchOps txn=$_txnOps',
    );
    stdout.writeln('change-log pruning: disabled (measures the storage path)');
    stdout.writeln();
  }

  final results = <_Result>[];
  // Native (production path).
  results.addAll(
    await _benchmark('native file', () => _openNative(nativePath), emitJson),
  );

  for (final dir in _tempDirs) {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  if (emitJson) {
    _printJson(results);
    return;
  }

  stdout.writeln();
  _printTable(results);
  stdout.writeln();
  stdout.writeln(
    'NOTE: rough local numbers only. Real comparative benchmarks vs Hive/'
    'Isar/Drift/SQLite/Sembast are the Phase 13 suite.',
  );
}

Future<DatabaseImpl> _openNative(String nativePath) async {
  final dir = await Directory.systemTemp.createTemp('gecko-bench-');
  final db = await DatabaseImpl.open(
    '${dir.path}${Platform.pathSeparator}db.redb',
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      changeLogMaxEntries: _changeLogMaxEntries,
    ),
  );
  _tempDirs.add(dir);
  return db;
}

Future<List<_Result>> _benchmark(
  String label,
  Future<DatabaseImpl> Function() open,
  bool quiet,
) async {
  if (!quiet) stdout.writeln('--- $label ---');
  final db = await open();
  final col = db.collection<_Row>(
    'items',
    toRow: _toRow,
    fromRow: _fromRow,
    id: _id,
  );

  // JIT warmup.
  for (var i = 0; i < 200; i++) {
    await col.put(_Row('warm$i', i, 'w'));
  }
  for (var i = 0; i < 200; i++) {
    await col.get('warm$i');
  }

  final results = <_Result>[];

  // Seed the main table (excluded from the measured insert workload).
  final seedWatch = Stopwatch()..start();
  for (var i = 0; i < _seedRows; i++) {
    await col.put(_Row('r$i', i, 'g${i % 100}'));
  }
  seedWatch.stop();
  if (!quiet) {
    stdout.writeln(
      '  seed $_seedRows rows in '
      '${_fmtTime(seedWatch.elapsedMicroseconds / _seedRows)}/op',
    );
  }

  // 1. Single-record insert throughput.
  results.add(
    await _measure(label, 'insert', _insertOps, (i) async {
      await col.put(_Row('n$i', i, 'g0'));
    }),
  );

  // 2. Bulk insert (batched via bulkWrite).
  final bulk = await _measure(label, 'bulkInsert', _bulkCalls, (c) async {
    await db.bulkWrite([
      for (var j = 0; j < _bulkPerCall; j++)
        BulkMutation.put(
          table: 'items',
          key: 'b${c}_$j',
          value: {'id': 'b${c}_$j', 'num': j, 'group': 'g0'},
        ),
    ]);
  });
  results.add(
    _Result(
      label,
      'bulkInsert',
      bulk.msPerOp / _bulkPerCall,
      bulk.opsPerSec * _bulkPerCall,
    ),
  );

  // 3. Hot point read (LRU cache hit on the same key).
  await col.get('r0');
  results.add(
    await _measure(label, 'hotRead', _readOps, (_) async {
      await col.get('r0');
    }),
  );

  // 4. Cold point read (cycling through distinct keys).
  results.add(
    await _measure(label, 'coldRead', _readOps, (i) async {
      await col.get('r${i % _seedRows}');
    }),
  );

  // 5. Range scan (half-table window).
  results.add(
    await _measure(label, 'rangeScan', _scanOps, (i) async {
      final window = _seedRows ~/ 2;
      final lo = (i * 7) % (_seedRows - window + 1);
      await col.where().range('num', min: lo, max: lo + window).findAll();
    }),
  );

  // 6. Filtered query (equality on a 1%-selectivity column).
  results.add(
    await _measure(label, 'filteredQuery', _queryOps, (i) async {
      await col.where({'group': 'g${i % 100}'}).findAll();
    }),
  );

  // 7. Watch latency (time from put until the change event is delivered).
  var received = 0;
  final sub = db.watchAll().listen((_) => received++);
  results.add(
    await _measure(label, 'watch', _watchOps, (i) async {
      final before = received;
      await col.put(_Row('w2_$i', i, 'w2'));
      var waited = 0;
      while (received == before && waited < 10000) {
        await Future<void>.delayed(Duration.zero);
        waited++;
      }
      if (received == before) {
        throw StateError('watch event was not delivered');
      }
    }),
  );
  await sub.cancel();

  // 8. Transaction commit (one put per writeTxn).
  results.add(
    await _measure(label, 'txnCommit', _txnOps, (i) async {
      await db.writeTxn((t) async {
        await t
            .collection<_Row>(
              'items',
              toRow: _toRow,
              fromRow: _fromRow,
              id: _id,
            )
            .put(_Row('t$i', i, 'g0'));
      });
    }),
  );

  await db.close();
  if (!quiet) stdout.writeln();
  return results;
}

Future<_Result> _measure(
  String backend,
  String workload,
  int ops,
  Future<void> Function(int i) fn,
) async {
  // Warm up the workload a little before timing.
  for (var i = 0; i < 50; i++) {
    await fn(i % 97);
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < ops; i++) {
    await fn(i);
  }
  watch.stop();
  final microsPerOp = watch.elapsedMicroseconds / ops;
  return _Result(
    backend,
    workload,
    microsPerOp / 1000,
    (1e6 / microsPerOp).roundToDouble(),
  );
}

String _fmtTime(double microsPerOp) => microsPerOp >= 1000
    ? '${(microsPerOp / 1000).toStringAsFixed(3)} ms'
    : '${microsPerOp.toStringAsFixed(3)} us';

void _printTable(List<_Result> rows) {
  final header =
      '${'backend'.padRight(12)} ${'workload'.padRight(16)} '
      '${'ms/op'.padLeft(10)} ${'ops/s'.padLeft(12)}';
  stdout.writeln(header);
  stdout.writeln('-' * header.length);
  for (final row in rows) {
    stdout.writeln(
      '${row.backend.padRight(12)} ${row.workload.padRight(16)} '
      '${_fmtTime(row.msPerOp * 1000).padLeft(10)} '
      '${row.opsPerSec.toStringAsFixed(0).padLeft(12)}',
    );
  }
}

/// Machine-readable JSON (consumed by tool/perf_gate.dart).
void _printJson(List<_Result> rows) {
  final doc = {
    'benchmark': 'gecko_db_local_stopgap',
    'platform': Platform.operatingSystem,
    'dart': Platform.version.split(' ').first,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'results': [
      for (final r in rows)
        {
          'backend': r.backend,
          'workload': r.workload,
          'msPerOp': r.msPerOp,
          'opsPerSec': r.opsPerSec,
        },
    ],
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(doc));
}
