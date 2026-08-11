// gecko_db local benchmark harness (stopgap; not the comparative
// suite). Measures real, per-operation numbers for the native file backend:
// single-insert throughput, bulk insert, hot/cold point reads, range scans,
// filtered queries, watch latency, transaction commit, and (with --indexed)
// indexed equality/range/prefix workloads.
//
// Run from the repo root:
//   dart run benchmark/bench.dart                          # native file backend
//   dart run benchmark/bench.dart --json                   # machine-readable JSON
//   dart run benchmark/bench.dart --rows=100000            # scale matrix row count
//   dart run benchmark/bench.dart --shape=wide             # narrow|wide|nested|blob
//   dart run benchmark/bench.dart --batch=1000             # bulkWrite batch size
//   dart run benchmark/bench.dart --groups=10              # eq selectivity 1/N
//   dart run benchmark/bench.dart --indexed                # + indexed workloads
//   dart run benchmark/bench.dart --indexed --indexedRows=100000
//   dart run benchmark/bench.dart --counters               # + worker work counters
//   dart run benchmark/bench.dart --help
//
// The native backend needs the release artifact built:
//   cd rust && cargo build --release
//
// Output is a table of p50/p95/mean ms/op and ops/s (or JSON with --json).
// The JSON carries a schema version, full environment/artifact metadata
// (commit, dirty state, OS/CPU/Dart/Rust versions, native library path +
// SHA-256, dataset shape), and per-workload distributions (p50/p95/p99/
// min/max/stddev) so numbers can be reproduced and attributed. Numbers are
// indicative and depend on hardware/JIT state — this is a regression
// rough-check, not a publishable marketing claim. tool/perf_gate.dart
// consumes the --json output to gate regressions against benchmark/baseline.json.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:gecko_db/gecko_db.dart';

/// JSON schema version of the harness output. Bump when the output shape
/// changes; tool/perf_gate.dart refuses to compare across versions.
const int schemaVersion = 2;

const int _seedRows = 1000;
const int _insertOps = 500;
const int _bulkPerCall = 500;
const int _bulkCalls = 2;
const int _readOps = 5000;
const int _scanOps = 30;
const int _queryOps = 30;
const int _watchOps = 100;
const int _txnOps = 200;
const int _indexedOps = 10;
const int _indexedRows = 100000;
const int _defaultGroups = 100;

/// The benchmark measures the storage path, so the change-log pruning scan
/// (O(n) per commit once the log is full, and it never prunes dirty records)
/// is disabled. With default config (1000) the per-write scan dominates and
/// would swamp the numbers.
const int _changeLogMaxEntries = 0;

const Set<String> _shapes = {'narrow', 'wide', 'nested', 'blob'};

/// Command-line configuration; also serialized into the JSON `dataset`
/// metadata so a run's scale/shape/selectivity is fully attributed.
class _Options {
  _Options({
    required this.json,
    required this.rows,
    required this.shape,
    required this.batch,
    required this.groups,
    required this.indexed,
    required this.indexedRows,
    required this.counters,
  });

  final bool json;
  final int rows;
  final String shape;
  final int batch;
  final int groups;
  final bool indexed;
  final int indexedRows;
  final bool counters;

  Map<String, Object?> toDataset() => {
    'seedRows': rows,
    'shape': shape,
    'batch': batch,
    'distinctGroups': groups,
    'indexed': indexed,
    'indexedRows': indexed ? indexedRows : 0,
    'changeLogMaxEntries': _changeLogMaxEntries,
  };
}

/// Outcome of one benchmark run: measured rows plus, with `--counters`, the
/// worker's physical-work counters accumulated over the measured workloads.
class _BenchOutcome {
  _BenchOutcome(this.results, this.workCounters);
  final List<_Result> results;
  final WorkCounters? workCounters;
}

class _Row {
  _Row(this.id, this.num, this.group);
  final String id;
  final int num;
  final String group;
}

/// Builds the encoded row map for the requested [shape]. The base fields
/// (id/num/group) are always present; wide/nested/blob add payload fields so
/// encode/decode/map-copy cost is exercised without changing the model.
Map<String, Object?> _makeRow(String shape, String id, int num, String group) {
  switch (shape) {
    case 'wide':
      return {
        'id': id,
        'num': num,
        'group': group,
        for (var i = 0; i < 20; i++) 'f$i': 'field-value-$i-$num',
      };
    case 'nested':
      return {
        'id': id,
        'num': num,
        'group': group,
        'nested': {
          'a': num,
          'b': {
            'c': 'deep-$num',
            'd': [num, num + 1],
          },
        },
        'list': [num, num + 1, num + 2],
      };
    case 'blob':
      return {'id': id, 'num': num, 'group': group, 'blob': 'x' * 1024};
    default:
      return {'id': id, 'num': num, 'group': group};
  }
}

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

/// Per-op latency distribution, in milliseconds.
class _Dist {
  const _Dist({
    required this.meanMs,
    required this.p50Ms,
    required this.p95Ms,
    required this.p99Ms,
    required this.minMs,
    required this.maxMs,
    required this.stddevMs,
    required this.samples,
  });

  factory _Dist.fromMicros(List<int> micros) {
    final sorted = [...micros]..sort();
    final n = sorted.length;
    double percentile(double q) {
      if (n == 0) return 0;
      if (n == 1) return sorted[0].toDouble();
      return sorted[(q * (n - 1)).round()].toDouble();
    }

    final mean = micros.isEmpty ? 0.0 : micros.reduce((a, b) => a + b) / n;
    var variance = 0.0;
    for (final m in micros) {
      variance += (m - mean) * (m - mean);
    }
    final stddev = n <= 1
        ? 0.0
        : (variance / (n - 1)).clamp(0.0, double.infinity).toDouble();

    double asMs(double us) => us / 1000;
    return _Dist(
      meanMs: asMs(mean),
      p50Ms: asMs(percentile(0.50)),
      p95Ms: asMs(percentile(0.95)),
      p99Ms: asMs(percentile(0.99)),
      minMs: asMs(sorted.isEmpty ? 0 : sorted.first.toDouble()),
      maxMs: asMs(sorted.isEmpty ? 0 : sorted.last.toDouble()),
      stddevMs: asMs(stddev),
      samples: n,
    );
  }

  /// A copy with every latency field divided by [divisor] (used to report
  /// bulkWrite per-row numbers from per-call samples).
  _Dist scaled(double divisor) => _Dist(
    meanMs: meanMs / divisor,
    p50Ms: p50Ms / divisor,
    p95Ms: p95Ms / divisor,
    p99Ms: p99Ms / divisor,
    minMs: minMs / divisor,
    maxMs: maxMs / divisor,
    stddevMs: stddevMs / divisor,
    samples: samples,
  );

  final double meanMs;
  final double p50Ms;
  final double p95Ms;
  final double p99Ms;
  final double minMs;
  final double maxMs;
  final double stddevMs;
  final int samples;
}

class _Result {
  _Result(
    this.backend,
    this.workload,
    this.dist, {
    this.rssStartKb,
    this.rssEndKb,
  });

  final String backend;
  final String workload;
  final _Dist dist;
  final int? rssStartKb;
  final int? rssEndKb;

  double get msPerOp => dist.meanMs;
  double get opsPerSec =>
      dist.meanMs == 0 ? 0 : (1000 / dist.meanMs).roundToDouble();
}

class _Measurement {
  _Measurement(this.dist, this.rssStartKb, this.rssEndKb);
  final _Dist dist;
  final int? rssStartKb;
  final int? rssEndKb;
}

/// Environment + artifact metadata recorded with every run so numbers can be
/// reproduced and attributed.
class _Metadata {
  _Metadata({
    required this.commit,
    required this.dirty,
    required this.rustCrateVersion,
    required this.nativePath,
    required this.nativeSha256,
  });

  final String? commit;
  final bool dirty;
  final String rustCrateVersion;
  final String nativePath;
  final String nativeSha256;
}

final List<Directory> _tempDirs = <Directory>[];

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);
  if (!File(nativePath).existsSync()) {
    stderr.writeln('Native artifact not found at $nativePath');
    stderr.writeln('Build it first: cd rust && cargo build --release');
    exitCode = 2;
    return;
  }
  final metadata = await _collectMetadata(root, nativePath);
  if (!opts.json) {
    stdout.writeln('=== gecko_db benchmark — native file backend ===');
    stdout.writeln();
    _printEnvironment(opts, metadata);
    stdout.writeln();
    _printDataset(opts);
    stdout.writeln();
  }

  final wall = Stopwatch()..start();
  final outcome = await _benchmark(
    'native file',
    () => _openNative(nativePath),
    opts,
  );
  wall.stop();

  for (final dir in _tempDirs) {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  if (opts.json) {
    _printJson(
      outcome.results,
      opts,
      metadata,
      outcome.workCounters,
      wall.elapsedMilliseconds,
    );
    return;
  }

  stdout.writeln();
  _printResultsTable(outcome.results);
  if (outcome.workCounters != null) {
    stdout.writeln();
    _printCounters(outcome.workCounters!);
  }
  stdout.writeln();
  _printTotals(outcome.results, wall.elapsedMilliseconds);
  stdout.writeln();
  stdout.writeln(
    'NOTE: rough local numbers only. Real comparative benchmarks vs Hive/'
    'Isar/Drift/SQLite/Sembast are the suite.',
  );
}

/// Parses CLI flags; fails loudly on unknown flags and on `--mem`, which is
/// no longer produced by this harness.
_Options _parseArgs(List<String> args) {
  var json = false;
  var indexed = false;
  var counters = false;
  var rows = _seedRows;
  var batch = _bulkPerCall;
  var groups = _defaultGroups;
  var indexedRows = _indexedRows;
  var shape = 'narrow';

  final usage =
      '''
Usage: dart run benchmark/bench.dart [options]
  --json               machine-readable JSON on stdout
  --native             accepted no-op (native file is the only backend)
  --rows=N             seed rows for the base collection (default $_seedRows)
  --shape=SHAPE        row shape: narrow|wide|nested|blob (default narrow)
  --batch=N            bulkWrite batch size (default $_bulkPerCall)
  --groups=N           distinct values of the query column; eq selectivity
                       is 1/N (default $_defaultGroups)
  --indexed            also seed an indexed collection and run indexed
                       equality/range/prefix workloads
  --indexedRows=N      rows in the indexed collection (default $_indexedRows)
  --counters           enable the worker's physical-work counters for the
                       measured workloads and emit them in the JSON output
  --help               this help
''';

  for (final a in args) {
    if (a == '--json') {
      json = true;
    } else if (a == '--native') {
      // Only backend; accepted for compatibility with tool/perf_gate.dart.
    } else if (a == '--mem') {
      stderr.writeln(
        'ERROR: the in-memory backend is no longer produced by this '
        'harness; only the native file backend is benchmarked.',
      );
      exit(2);
    } else if (a == '--help') {
      stdout.writeln(usage);
      exit(0);
    } else if (a.startsWith('--rows=')) {
      rows = _flagInt(a, '--rows=');
    } else if (a.startsWith('--shape=')) {
      shape = a.substring('--shape='.length);
    } else if (a.startsWith('--batch=')) {
      batch = _flagInt(a, '--batch=');
    } else if (a.startsWith('--groups=')) {
      groups = _flagInt(a, '--groups=');
    } else if (a == '--indexed') {
      indexed = true;
    } else if (a == '--counters') {
      counters = true;
    } else if (a.startsWith('--indexedRows=')) {
      indexedRows = _flagInt(a, '--indexedRows=');
    } else {
      stderr.writeln('ERROR: unknown flag `$a`.\n$usage');
      exit(2);
    }
  }
  if (!_shapes.contains(shape)) {
    stderr.writeln('ERROR: unknown --shape `$shape` (expected $_shapes).');
    exit(2);
  }
  if (rows < 1 || batch < 1 || groups < 1 || indexedRows < 1) {
    stderr.writeln(
      'ERROR: --rows / --batch / --groups / --indexedRows must be >= 1.',
    );
    exit(2);
  }
  return _Options(
    json: json,
    rows: rows,
    shape: shape,
    batch: batch,
    groups: groups,
    indexed: indexed,
    indexedRows: indexedRows,
    counters: counters,
  );
}

int _flagInt(String arg, String prefix) {
  final v = int.tryParse(arg.substring(prefix.length));
  if (v == null) {
    stderr.writeln('ERROR: expected an integer for `$prefix<N>`, got `$arg`.');
    exit(2);
  }
  return v;
}

/// Collects the environment/artifact metadata attached to every JSON run:
/// git commit + dirty state, Rust crate version, and native library SHA-256.
Future<_Metadata> _collectMetadata(String root, String nativePath) async {
  String? commit;
  var dirty = false;
  try {
    final rev = await Process.run('git', [
      'rev-parse',
      '--short',
      'HEAD',
    ], workingDirectory: root);
    if (rev.exitCode == 0) commit = (rev.stdout as String).trim();
    final status = await Process.run('git', [
      'status',
      '--porcelain',
    ], workingDirectory: root);
    if (status.exitCode == 0) {
      dirty = (status.stdout as String).trim().isNotEmpty;
    }
  } catch (_) {
    // Not a git checkout (or git unavailable); metadata stays absent.
  }
  var sha256 = '';
  try {
    final bytes = await File(nativePath).readAsBytes();
    sha256 = crypto.sha256.convert(bytes).toString();
  } catch (_) {}
  return _Metadata(
    commit: commit,
    dirty: dirty,
    rustCrateVersion: _readRustCrateVersion(root),
    nativePath: nativePath,
    nativeSha256: sha256,
  );
}

String _readRustCrateVersion(String root) {
  try {
    final cargo = File(
      '$root${Platform.pathSeparator}rust${Platform.pathSeparator}Cargo.toml',
    ).readAsStringSync();
    final m = RegExp(
      r'^version\s*=\s*"([^"]+)"',
      multiLine: true,
    ).firstMatch(cargo);
    if (m != null) return m.group(1)!;
  } catch (_) {}
  return 'unknown';
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

Future<_BenchOutcome> _benchmark(
  String label,
  Future<DatabaseImpl> Function() open,
  _Options opts,
) async {
  final quiet = opts.json;
  final db = await open();
  final col = db.collection<_Row>(
    'items',
    toRow: (r) => _makeRow(opts.shape, r.id, r.num, r.group),
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
  await _seedTable(db, 'items', opts.rows, opts.shape, opts.batch, opts.groups);
  seedWatch.stop();
  if (!quiet) {
    stdout.writeln(
      '  seed ${opts.rows} rows in '
      '${_fmtTime(seedWatch.elapsedMicroseconds / opts.rows)}/op',
    );
  }

  // Physical-work counters start after seeding, so they attribute only the
  // measured workloads (plus the indexed-collection seed when --indexed).
  if (opts.counters) {
    await (db.engine.backend as NativeRawBackend).enableCounters();
  }

  // 1. Single-record insert throughput.
  results.add(
    await _runWorkload(label, 'insert', _insertOps, (i) async {
      await col.put(_Row('n$i', i, 'g0'));
    }),
  );

  // 2. Bulk insert (batched via bulkWrite), reported per row.
  results.add(
    await _runWorkload(label, 'bulkInsert', _bulkCalls, (c) async {
      await db.bulkWrite([
        for (var j = 0; j < opts.batch; j++)
          BulkMutation.put(
            table: 'items',
            key: 'b${c}_$j',
            value: _makeRow(opts.shape, 'b${c}_$j', j, 'g0'),
          ),
      ]);
    }, scale: opts.batch.toDouble()),
  );

  // 3. Hot point read (LRU cache hit on the same key).
  await col.get('r0');
  results.add(
    await _runWorkload(label, 'hotRead', _readOps, (_) async {
      await col.get('r0');
    }),
  );

  // 4. Cold point read (cycling through distinct keys).
  results.add(
    await _runWorkload(label, 'coldRead', _readOps, (i) async {
      await col.get('r${i % opts.rows}');
    }),
  );

  // 5. Range scan (half-table window). The base collection is UNINDEXED, so
  //    this exercises the full scan + predicate pushdown path, not an index
  //    range; the indexed range workload (--indexed) measures the indexed
  //    path. Named `rangeScanUnindexed` so the two are never conflated.
  results.add(
    await _runWorkload(label, 'rangeScanUnindexed', _scanOps, (i) async {
      final window = opts.rows ~/ 2;
      final lo = (i * 7) % (opts.rows - window + 1);
      await col.where().range('num', min: lo, max: lo + window).findAll();
    }),
  );

  // 6. Filtered query (equality on a 1/N-selectivity column).
  results.add(
    await _runWorkload(label, 'filteredQuery', _queryOps, (i) async {
      await col.where({'group': 'g${i % opts.groups}'}).findAll();
    }),
  );

  // 7. Watch latency (time from put until the change event is delivered).
  var received = 0;
  final sub = db.watchAll().listen((_) => received++);
  results.add(
    await _runWorkload(label, 'watch', _watchOps, (i) async {
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
    await _runWorkload(label, 'txnCommit', _txnOps, (i) async {
      await db.writeTxn((t) async {
        await t
            .collection<_Row>(
              'items',
              toRow: (r) => _makeRow(opts.shape, r.id, r.num, r.group),
              fromRow: _fromRow,
              id: _id,
            )
            .put(_Row('t$i', i, 'g0'));
      });
    }),
  );

  // 9. Indexed equality/range/prefix workloads (opt-in via --indexed) so
  //    index selectivity is measured instead of only the unindexed paths.
  if (opts.indexed) {
    results.addAll(await _benchmarkIndexed(db, label, opts));
  }

  WorkCounters? counters;
  if (opts.counters) {
    counters = await (db.engine.backend as NativeRawBackend).takeCounters();
  }
  await db.close();
  if (!quiet) stdout.writeln();
  return _BenchOutcome(results, counters);
}

/// Seeds [count] rows into [table] via `bulkWrite` in [batch]-sized chunks
/// (single-row puts at 100k+ scale would take minutes). Seeding is excluded
/// from every measured workload.
Future<void> _seedTable(
  DatabaseImpl db,
  String table,
  int count,
  String shape,
  int batch,
  int groups,
) async {
  for (var start = 0; start < count; start += batch) {
    final end = (start + batch) < count ? start + batch : count;
    await db.bulkWrite([
      for (var j = start; j < end; j++)
        BulkMutation.put(
          table: table,
          key: 'r$j',
          value: _makeRow(shape, 'r$j', j, 'g${j % groups}'),
        ),
    ]);
  }
}

/// Indexed-collection workloads: equality (1/N selectivity), a narrow range
/// (1% of rows), and a prefix (10% of rows), all served by the durable index
/// at [opts.indexedRows] rows.
Future<List<_Result>> _benchmarkIndexed(
  DatabaseImpl db,
  String label,
  _Options opts,
) async {
  final quiet = opts.json;
  final col = db.collection<Map<String, Object?>>(
    'items_indexed',
    toRow: (m) => m,
    fromRow: (m) => Map<String, Object?>.from(m as Map),
    id: (m) => m['id'],
    indexFields: ['num', 'group'],
    prefixFields: ['nick'],
  );
  if (!quiet) {
    stdout.writeln('  seeding indexed collection (${opts.indexedRows} rows)');
  }
  final seedWatch = Stopwatch()..start();
  for (var start = 0; start < opts.indexedRows; start += opts.batch) {
    final end = (start + opts.batch) < opts.indexedRows
        ? start + opts.batch
        : opts.indexedRows;
    await db.bulkWrite([
      for (var j = start; j < end; j++)
        BulkMutation.put(
          table: 'items_indexed',
          key: 'r$j',
          value: {
            'id': 'r$j',
            'num': j % 1000,
            'group': 'g${j % opts.groups}',
            'nick': 'n-${j % 10}-$j',
          },
        ),
    ]);
  }
  seedWatch.stop();
  if (!quiet) {
    stdout.writeln(
      '  seeded in '
      '${_fmtTime(seedWatch.elapsedMicroseconds / opts.indexedRows)}/row',
    );
  }

  final results = <_Result>[];

  // Indexed equality: 1/N selectivity via the durable index.
  results.add(
    await _runWorkload(label, 'indexedEq', _indexedOps, (i) async {
      await col.where({'group': 'g${i % opts.groups}'}).findAll();
    }),
  );

  // Indexed range: 1% of rows (10 of 1000 distinct `num` values).
  results.add(
    await _runWorkload(label, 'indexedRange', _indexedOps, (i) async {
      final lo = (i * 10) % 990;
      await col.where().range('num', min: lo, max: lo + 9).findAll();
    }),
  );

  // Indexed prefix: 10% of rows (one of ten `nick` prefixes).
  results.add(
    await _runWorkload(label, 'indexedPrefix', _indexedOps, (i) async {
      await col.where().prefix('nick', 'n-${i % 10}-').findAll();
    }),
  );

  return results;
}

Future<_Result> _runWorkload(
  String backend,
  String workload,
  int ops,
  Future<void> Function(int i) fn, {
  double scale = 1,
}) async {
  final m = await _measure(fn, ops);
  final dist = scale == 1 ? m.dist : m.dist.scaled(scale);
  return _Result(
    backend,
    workload,
    dist,
    rssStartKb: m.rssStartKb,
    rssEndKb: m.rssEndKb,
  );
}

Future<_Measurement> _measure(
  Future<void> Function(int i) fn,
  int ops, {
  int warmup = 50,
}) async {
  // Warm up the workload a little before timing (JIT steady state).
  for (var i = 0; i < warmup; i++) {
    await fn(i % 97);
  }
  final micros = <int>[];
  int? rssStart;
  int? rssEnd;
  try {
    rssStart = ProcessInfo.currentRss;
  } catch (_) {}
  for (var i = 0; i < ops; i++) {
    final sw = Stopwatch()..start();
    await fn(i);
    sw.stop();
    micros.add(sw.elapsedMicroseconds);
  }
  try {
    rssEnd = ProcessInfo.currentRss;
  } catch (_) {}
  return _Measurement(
    _Dist.fromMicros(micros),
    rssStart == null ? null : (rssStart / 1024).round(),
    rssEnd == null ? null : (rssEnd / 1024).round(),
  );
}

String _fmtTime(double microsPerOp) {
  if (microsPerOp >= 1000) {
    return '${(microsPerOp / 1000).toStringAsFixed(3).padLeft(8)} ms';
  }
  return '${microsPerOp.toStringAsFixed(2).padLeft(8)} us';
}

/// Prints one aligned `key  value` line in a sectioned report.
void _kv(String key, String value) {
  stdout.writeln('  ${key.padRight(24)} $value');
}

void _printEnvironment(_Options opts, _Metadata metadata) {
  stdout.writeln('environment');
  _kv('platform', Platform.operatingSystem);
  _kv('os', Platform.operatingSystemVersion);
  _kv('dart', Platform.version.split(' ').first);
  _kv('cpus', '${Platform.numberOfProcessors}');
  _kv(
    'commit',
    metadata.commit == null
        ? 'unknown'
        : '${metadata.commit}${metadata.dirty ? ' (dirty)' : ''}',
  );
  _kv('rust crate', metadata.rustCrateVersion);
  final sha = metadata.nativeSha256.isEmpty
      ? 'unknown'
      : '${metadata.nativeSha256.substring(0, 8)}…';
  _kv('native library', '${metadata.nativePath} (sha256 $sha)');
}

void _printDataset(_Options opts) {
  stdout.writeln('dataset');
  _kv('seed rows', '${opts.rows}');
  _kv('shape', opts.shape);
  _kv('batch', '${opts.batch}');
  _kv(
    'distinct groups',
    '${opts.groups} (eq selectivity ${(100 / opts.groups).toStringAsFixed(1)}%)',
  );
  _kv('indexed', opts.indexed ? 'yes (${opts.indexedRows} rows)' : 'no');
  _kv('change-log', 'disabled (storage path only)');
}

/// Human-readable results table as a Markdown pipe table: p50/p95/p99/mean
/// latencies (µs or ms) and throughput, one row per workload. Pipe tables
/// keep their structure when copied/pasted into docs, chat, or spreadsheet
/// tools (and render as real tables in any Markdown viewer).
void _printResultsTable(List<_Result> rows) {
  stdout.writeln('workloads (per-op p50 / p95 / p99 / mean latency, ops/s)');
  _markdownTable(
    ['workload', 'p50', 'p95', 'p99', 'mean', 'ops/s'],
    [
      for (final row in rows)
        [
          row.workload,
          _fmtTime(row.dist.p50Ms * 1000),
          _fmtTime(row.dist.p95Ms * 1000),
          _fmtTime(row.dist.p99Ms * 1000),
          _fmtTime(row.msPerOp * 1000),
          row.opsPerSec.toStringAsFixed(0),
        ],
    ],
    rightAlign: [false, true, true, true, true, true],
  );
}

/// Prints a Markdown-style pipe table. Columns marked in [rightAlign] are
/// right-aligned in both the terminal and the rendered Markdown (`---:`).
void _markdownTable(
  List<String> headers,
  List<List<String>> rows, {
  List<bool>? rightAlign,
}) {
  final align = List<bool>.filled(headers.length, false);
  final requested = rightAlign ?? const <bool>[];
  for (var i = 0; i < requested.length && i < headers.length; i++) {
    align[i] = requested[i];
  }
  final widths = List<int>.generate(headers.length, (i) => headers[i].length);
  for (final row in rows) {
    for (var i = 0; i < headers.length && i < row.length; i++) {
      if (row[i].length > widths[i]) widths[i] = row[i].length;
    }
  }

  String cell(int i, String value) => align[i]
      ? ' ${value.padLeft(widths[i])} '
      : ' ${value.padRight(widths[i])} ';

  final headerLine = StringBuffer('|');
  for (var i = 0; i < headers.length; i++) {
    headerLine
      ..write(cell(i, headers[i]))
      ..write('|');
  }
  stdout.writeln(headerLine);

  final separator = StringBuffer('|');
  for (var i = 0; i < headers.length; i++) {
    separator.write(
      align[i]
          ? ' ${'-' * (widths[i] < 2 ? 2 : widths[i] - 1)}: '
          : ' ${'-' * widths[i]} ',
    );
    separator.write('|');
  }
  stdout.writeln(separator);

  for (final row in rows) {
    final buffer = StringBuffer('|');
    for (var i = 0; i < headers.length; i++) {
      buffer
        ..write(cell(i, row[i]))
        ..write('|');
    }
    stdout.writeln(buffer);
  }
}

void _printTotals(List<_Result> rows, int elapsedMs) {
  stdout.writeln('totals');
  _kv('workloads', '${rows.length}');
  _kv('ops measured', '${_totalSamples(rows)}');
  _kv('wall time', _fmtSeconds(elapsedMs));
  final peakRss = _peakRssKb(rows);
  if (peakRss > 0) _kv('peak RSS', '$peakRss KB');
}

int _totalSamples(List<_Result> rows) =>
    rows.fold<int>(0, (sum, row) => sum + row.dist.samples);

int _peakRssKb(List<_Result> rows) => rows.fold<int>(0, (peak, row) {
  var rowPeak = peak;
  if (row.rssStartKb != null && row.rssStartKb! > rowPeak) {
    rowPeak = row.rssStartKb!;
  }
  if (row.rssEndKb != null && row.rssEndKb! > rowPeak) {
    rowPeak = row.rssEndKb!;
  }
  return rowPeak;
});

String _fmtSeconds(int ms) {
  if (ms < 1000) return '$ms ms';
  final seconds = ms / 1000;
  if (seconds < 60) return '${seconds.toStringAsFixed(1)} s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return '$minutes min ${rest.toStringAsFixed(0)} s';
}

/// Machine-readable JSON (consumed by tool/perf_gate.dart). Carries the
/// schema version, environment/artifact metadata, the dataset configuration,
/// per-workload latency distributions, and (with `--counters`) the worker's
/// physical-work counters for the measured workloads.
void _printJson(
  List<_Result> rows,
  _Options opts,
  _Metadata metadata,
  WorkCounters? counters,
  int elapsedMs,
) {
  final doc = {
    'benchmark': 'gecko_db_local_stopgap',
    'schemaVersion': schemaVersion,
    'platform': Platform.operatingSystem,
    'dart': Platform.version.split(' ').first,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'metadata': {
      'commit': metadata.commit,
      'dirty': metadata.dirty,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpus': Platform.numberOfProcessors,
      'rustCrateVersion': metadata.rustCrateVersion,
      'nativeLibrary': {
        'path': metadata.nativePath,
        'sha256': metadata.nativeSha256,
      },
      'dataset': opts.toDataset(),
      'durability': 'redb default (Immediate fsync)',
      'freshFile': true,
      'countersEnabled': opts.counters,
      'cacheWarmth':
          'hotRead: r0 LRU-resident; coldRead: cycling r0..r${opts.rows - 1}',
    },
    'summary': {
      'backend': 'native file',
      'workloads': rows.length,
      'totalSamples': _totalSamples(rows),
      'elapsedMs': elapsedMs,
      'peakRssKb': _peakRssKb(rows),
      'countersEnabled': opts.counters,
    },
    if (counters != null) 'workCounters': _countersJson(counters),
    'results': [
      for (final r in rows)
        {
          'backend': r.backend,
          'workload': r.workload,
          'msPerOp': r.msPerOp,
          'opsPerSec': r.opsPerSec,
          'p50MsPerOp': r.dist.p50Ms,
          'p95MsPerOp': r.dist.p95Ms,
          'p99MsPerOp': r.dist.p99Ms,
          'minMsPerOp': r.dist.minMs,
          'maxMsPerOp': r.dist.maxMs,
          'stddevMsPerOp': r.dist.stddevMs,
          'samples': r.dist.samples,
          'rssStartKb': r.rssStartKb,
          'rssEndKb': r.rssEndKb,
        },
    ],
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(doc));
}

Map<String, Object?> _countersJson(WorkCounters c) => {
  'batchesApplied': c.batchesApplied.toInt(),
  'rowsWritten': c.rowsWritten.toInt(),
  'tableOpens': c.tableOpens.toInt(),
  'previousValueReads': c.previousValueReads.toInt(),
  'indexMaintenanceOps': c.indexMaintenanceOps.toInt(),
  'changeLogScanned': c.changeLogScanned.toInt(),
  'changeLogPruned': c.changeLogPruned.toInt(),
  'primaryRowsVisited': c.primaryRowsVisited.toInt(),
  'indexEntriesVisited': c.indexEntriesVisited.toInt(),
  'candidateKeysAllocated': c.candidateKeysAllocated.toInt(),
  'primaryRowsFetched': c.primaryRowsFetched.toInt(),
  'predicateEvaluations': c.predicateEvaluations.toInt(),
  'rowsReturned': c.rowsReturned.toInt(),
  'bytesReturned': c.bytesReturned.toInt(),
  'snapshotsCreated': c.snapshotsCreated.toInt(),
  'registryRowsAdded': c.registryRowsAdded.toInt(),
  'registryRowsUpdated': c.registryRowsUpdated.toInt(),
  'registryRowsRemoved': c.registryRowsRemoved.toInt(),
  'registryRowsCloned': c.registryRowsCloned.toInt(),
  'registrySnapshotBytes': c.registrySnapshotBytes.toInt(),
};

/// Human-readable summary of the worker's physical-work counters (table mode),
/// one aligned pair per counter.
void _printCounters(WorkCounters c) {
  stdout.writeln('worker physical-work counters (measured workloads)');
  _kv('batches applied', '${c.batchesApplied}');
  _kv('rows written', '${c.rowsWritten}');
  _kv('table opens', '${c.tableOpens}');
  _kv('previous-value reads', '${c.previousValueReads}');
  _kv('index maintenance ops', '${c.indexMaintenanceOps}');
  _kv('change-log scanned', '${c.changeLogScanned}');
  _kv('change-log pruned', '${c.changeLogPruned}');
  _kv('primary rows visited', '${c.primaryRowsVisited}');
  _kv('predicate evaluations', '${c.predicateEvaluations}');
  _kv('index entries visited', '${c.indexEntriesVisited}');
  _kv('candidate keys allocated', '${c.candidateKeysAllocated}');
  _kv('primary rows fetched', '${c.primaryRowsFetched}');
  _kv('rows returned', '${c.rowsReturned}');
  _kv('bytes returned', '${c.bytesReturned}');
  _kv('snapshots created', '${c.snapshotsCreated}');
  _kv('registry rows added', '${c.registryRowsAdded}');
  _kv('registry rows updated', '${c.registryRowsUpdated}');
  _kv('registry rows removed', '${c.registryRowsRemoved}');
  _kv('registry rows cloned', '${c.registryRowsCloned}');
  _kv('registry snapshot bytes', '${c.registrySnapshotBytes}');
}
