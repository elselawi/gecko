// query-path profiler.
//
// Seeds a native (redb) database at 1k and 100k rows and runs, for each size:
//   - an UNINDEXED full-scan equality query (every row decoded & predicated)
//   - an INDEXED equality query (covered by the durable in-memory index)
//
// Both run with slow-query timing armed (slowQueryThresholdMicros: 1) so the
// per-stage QueryStageTimings breakdown is captured. Output is the stage
// split (µs, % of total) so the roadmap can see exactly where the
// ~110 µs/row full-scan cost and the per-query cost come from.
//
// Run from the repo root:
//   dart run benchmark/query_profile.dart
//
// The native backend needs the release artifact:
//   cd rust && cargo build --release
//
// Numbers are indicative and depend on hardware/JIT state. Not consumed by
// tool/perf_gate.dart.
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

const List<int> _sizes = [1000, 100000];

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

Future<void> main(List<String> args) async {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);
  if (!File(nativePath).existsSync()) {
    stderr.writeln('Native artifact not found at $nativePath');
    stderr.writeln('Build it first: cd rust && cargo build --release');
    exitCode = 2;
    return;
  }

  stdout.writeln('=== gecko_db query-path profiler () ===');
  stdout.writeln(
    'platform: ${Platform.operatingSystem} | '
    'dart ${Platform.version.split(' ').first}',
  );
  stdout.writeln();

  for (final size in _sizes) {
    await _profileSize(size, nativePath);
    stdout.writeln();
  }
}

Future<void> _profileSize(int size, String nativePath) async {
  final dir = await Directory.systemTemp.createTemp('gecko-qprof-');
  final dbPath = '${dir.path}${Platform.pathSeparator}qprof.redb';
  try {
    final db = await DatabaseImpl.open(
      dbPath,
      config: DatabaseConfig(
        nativeLibraryPath: nativePath,
        changeLogMaxEntries: 0,
        slowQueryThresholdMicros: 1,
      ),
    );
    final col = db.collection<_Row>(
      'items',
      toRow: _toRow,
      fromRow: _fromRow,
      id: _id,
      indexFields: const ['group'],
    );

    // Seed [size] rows via bulkWrite (the production bulk path; individually
    // would be far slower than the profile itself). Distributed across 100
    // groups so the indexed eq query is ~1% selective.
    stdout.writeln('--- $size rows: seeding (bulkWrite, 100 groups) ---');
    final seedWatch = Stopwatch()..start();
    const chunk = 2000;
    for (var start = 0; start < size; start += chunk) {
      final end = (start + chunk > size) ? size : start + chunk;
      await db.bulkWrite([
        for (var i = start; i < end; i++)
          BulkMutation.put(
            table: 'items',
            key: 'r$i',
            value: {'id': 'r$i', 'num': i, 'group': 'g${i % 100}'},
          ),
      ]);
    }
    seedWatch.stop();
    stdout.writeln(
      '  seeded $size rows in ${(seedWatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} s '
      '(${(seedWatch.elapsedMicroseconds / size).toStringAsFixed(1)} µs/row)',
    );

    // Reset counters so the probe records are about the query, not the seed.
    db.engine.resetDiagnosticsCounters();
    db.engine.setDiagnosticsEnabled(true);

    stdout.writeln('  unindexed full-scan: where({num: <middle>}) ...');
    final scanTarget = size ~/ 2;
    final scanWatch = Stopwatch()..start();
    final scanResult = await col.where({'num': scanTarget}).findAll();
    scanWatch.stop();
    final scanRec = db.engine.recentSlowQueries.last;
    stdout.writeln(
      '    matched ${scanResult.length} row(s) in '
      '${(scanWatch.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms',
    );
    _printStages(scanRec, scanRec.timings!, size);

    stdout.writeln('  indexed equality: where({group: g0}) ...');
    final idxWatch = Stopwatch()..start();
    final idxResult = await col.where({'group': 'g0'}).findAll();
    idxWatch.stop();
    final idxRec = db.engine.recentSlowQueries.last;
    stdout.writeln(
      '    matched ${idxResult.length} row(s) in '
      '${(idxWatch.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms '
      '(plan: ${idxRec.indexed ? 'secondaryIndex' : 'fullScan'})',
    );
    _printStages(idxRec, idxRec.timings!, size);

    await db.close();
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

void _printStages(SlowQueryRecord rec, QueryStageTimings t, int size) {
  final total = rec.durationMicros == 0 ? 1 : rec.durationMicros;
  String pct(int v) => '${((v / total) * 100).toStringAsFixed(1)}%'.padLeft(6);
  String us(int v) {
    if (v >= 1000) {
      return '${(v / 1000).toStringAsFixed(2)} ms'.padLeft(10);
    }
    return '$v µs'.padLeft(10);
  }

  stdout.writeln('    stage                stage-µs    total%   per-row-µs');
  stdout.writeln('    ${'-' * 56}');
  void line(String label, int v) {
    final perRow = size == 0 ? 0.0 : v / t.rowsScanned;
    stdout.writeln(
      '    ${label.padRight(16)} ${us(v)} ${pct(v)} '
      '${perRow.toStringAsFixed(3).padLeft(10)}',
    );
  }

  line('plan', t.plan);
  line('indexLookup', t.indexLookup);
  line('backendRead', t.backendRead);
  line('decode', t.decode);
  line('mapCopy', t.mapCopy);
  line('predicate', t.predicate);
  line('sort', t.sort);
  line('model', t.model);
  stdout.writeln('    ${'-' * 56}');
  line('Σ stages', t.total);
  stdout.writeln(
    '    ${'query total'.padRight(16)} ${us(rec.durationMicros)} '
    '${pct(rec.durationMicros)}',
  );
  stdout.writeln(
    '    rows scanned=${t.rowsScanned} matched=${t.rowsMatched} '
    'selectivity=${((t.rowsMatched / (t.rowsScanned == 0 ? 1 : t.rowsScanned)) * 100).toStringAsFixed(2)}%',
  );
}
