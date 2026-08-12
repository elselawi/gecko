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
import 'package:gecko_db/src/backend/raw_backend.dart'
    show RawBatchPlan, RawChangeTemplate;
import 'package:gecko_db/src/wire/wire_codec.dart' show DefaultWireCodec;

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

/// Application-level positive LRU capacity for point reads. The cache-mode
/// workloads (lruHitRead / lruMissRead) are only meaningful relative to this
/// number: a miss test needs a working set strictly larger than it.
const int _defaultLruCapacity = 1024;

/// Change-log retention for the `--retention` profile. The default (0) keeps
/// the storage-only numbers unchanged; `--retention=1000` measures the
/// default retention path (prune scans once the log is full) and
/// `--retention=1000 --allDirty` measures the all-dirty bounded-inspection
/// profile (prune finds nothing clean and must not re-scan on every write).
const int _defaultRetention = 0;

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
    required this.encrypted,
    required this.lruCapacity,
    required this.retention,
    required this.allDirty,
    required this.coldRead,
    required this.pages,
  });

  final bool json;
  final int rows;
  final String shape;
  final int batch;
  final int groups;
  final bool indexed;
  final int indexedRows;
  final bool counters;
  final bool encrypted;
  final int lruCapacity;
  final int retention;
  final bool allDirty;
  final bool coldRead;
  final List<int> pages;

  /// The effective positive-LRU capacity actually used for the run: when the
  /// working set (seed rows) is not strictly larger than the configured
  /// capacity, the capacity is lowered so `lruMissRead` is a genuine miss
  /// test (the acceptance rule for the cache-mode separation). Recorded in
  /// the dataset so the number is attributed.
  int get effectiveLruCapacity {
    final configured = lruCapacity;
    if (rows > configured) return configured;
    return rows > 1 ? rows - 1 : 1;
  }

  Map<String, Object?> toDataset() => {
    'seedRows': rows,
    'shape': shape,
    'batch': batch,
    'distinctGroups': groups,
    'indexed': indexed,
    'indexedRows': indexed ? indexedRows : 0,
    'encrypted': encrypted,
    'changeLogMaxEntries': retention,
    'allDirtyHistory': allDirty,
    'lruCapacity': effectiveLruCapacity,
    'pageSizes': pages,
  };
}

/// Outcome of one benchmark run: measured rows plus, with `--counters`, the
/// worker's physical-work counters accumulated over the measured workloads.
class _BenchOutcome {
  _BenchOutcome(this.results, this.workCounters, this.dbPath);
  final List<_Result> results;
  final WorkCounters? workCounters;
  final String dbPath;
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
  // Hidden child mode for storageColdRead: an isolated process that opens a
  // pre-seeded database and times one full read pass. The parent spawns this
  // with --coldChild=<path> and folds the child's distribution in.
  final coldChildIndex = args.indexOf(
    args.firstWhere((a) => a.startsWith('--coldChild='), orElse: () => ''),
  );
  if (coldChildIndex >= 0) {
    final path = args[coldChildIndex].substring('--coldChild='.length);
    // Strip the child-mode flag before parsing the rest.
    await _runColdChild(
      path,
      _parseArgs([
        for (final a in args)
          if (!a.startsWith('--coldChild=')) a,
      ]),
    );
    return;
  }

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
    opts.encrypted ? 'native file (encrypted)' : 'native file',
    nativePath,
    () => _openNative(nativePath, opts),
    opts,
  );
  wall.stop();

  // storageColdRead: an isolated child process reopens the SAME file (the
  // parent already closed it) with a fresh heap and times one full read pass.
  // The OS page cache may still be warm on this host — the strategy is
  // documented, not claimed portable. Run it before the temp dirs are removed.
  if (opts.coldRead) {
    final cold = await _runStorageColdRead(opts, outcome.dbPath);
    if (cold != null) outcome.results.add(cold);
  }

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

/// The isolated `storageColdRead` child: reopens [path] with an empty heap
/// and application cache and times one full pass over every seeded row (each
/// key read once, so the fresh LRU cannot help). Emits a one-workload JSON
/// document on stdout for the parent to fold in.
Future<void> _runColdChild(String path, _Options opts) async {
  final nativePath = _nativeLibraryPath(_repoRoot());
  final db = await _reopenNative(nativePath, path, opts);
  try {
    final col = db.collection<_Row>(
      'items',
      toRow: (r) => _makeRow(opts.shape, r.id, r.num, r.group),
      fromRow: _fromRow,
      id: _id,
    );
    final m = await _measure(
      (i) => col.get('r${i % opts.rows}'),
      opts.rows,
      warmup: 0,
    );
    stdout.writeln(
      const JsonEncoder().convert({
        'workload': 'storageColdRead',
        'msPerOp': m.dist.meanMs,
        'p50MsPerOp': m.dist.p50Ms,
        'p95MsPerOp': m.dist.p95Ms,
        'p99MsPerOp': m.dist.p99Ms,
        'minMsPerOp': m.dist.minMs,
        'maxMsPerOp': m.dist.maxMs,
        'stddevMsPerOp': m.dist.stddevMs,
        'samples': m.dist.samples,
      }),
    );
  } finally {
    await db.close();
  }
}

/// Spawns the `storageColdRead` child and returns its measured distribution,
/// or null if the child failed. Cold-start semantics are host-dependent (the
/// OS page cache may still be warm); the isolated process guarantees a fresh
/// Dart heap and an empty application LRU.
Future<_Result?> _runStorageColdRead(_Options opts, String path) async {
  final root = _repoRoot();
  final args = [
    'run',
    'benchmark/bench.dart',
    '--coldChild=$path',
    '--rows=${opts.rows}',
    '--shape=${opts.shape}',
    '--lruCapacity=${opts.lruCapacity}',
    '--retention=${opts.retention}',
    if (opts.encrypted) '--encrypted',
  ];
  final proc = await Process.start(Platform.resolvedExecutable, args,
      workingDirectory: root);
  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  proc.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
  proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);
  final code = await proc.exitCode;
  if (code != 0) {
    stderr.writeln('storageColdRead child failed (exit $code): '
        '${stderrBuf.toString().trim()}');
    return null;
  }
  try {
    final doc = jsonDecode(stdoutBuf.toString()) as Map<String, Object?>;
    return _Result(
      opts.encrypted ? 'native file (encrypted)' : 'native file',
      'storageColdRead',
      _Dist.fromMicros([
        for (var i = 0; i < (doc['samples'] as num).toInt(); i++)
          ((doc['msPerOp'] as num) * 1000).round(),
      ]),
    );
  } catch (e) {
    stderr.writeln('storageColdRead child output unparsable: $e');
    return null;
  }
}

/// Parses CLI flags; fails loudly on unknown flags and on `--mem`, which is
/// no longer produced by this harness.
_Options _parseArgs(List<String> args) {
  var json = false;
  var indexed = false;
  var counters = false;
  var encrypted = false;
  var allDirty = false;
  var coldRead = false;
  var rows = _seedRows;
  var batch = _bulkPerCall;
  var groups = _defaultGroups;
  var indexedRows = _indexedRows;
  var shape = 'narrow';
  var lruCapacity = _defaultLruCapacity;
  var retention = _defaultRetention;
  var pages = const <int>[50, 200];

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
  --encrypted          run the same workloads over a physically encrypted
                       database (separate baseline; never merged with
                       plaintext numbers)
  --lruCapacity=N      positive LRU capacity for point reads
                       (default $_defaultLruCapacity); the lruMissRead
                       working set is always strictly larger than the
                       effective capacity
  --retention=N        change-log retention (default $_defaultRetention);
                       >0 measures the retention/prune path instead of the
                       storage-only path
  --allDirty           (with --retention) seed an all-dirty change history so
                       prune has no clean entries to remove (bounded-
                       inspection profile)
  --coldRead           measure storageColdRead in an isolated child process
                       (documented host-dependent cold-start strategy)
  --pages=50,200       page sizes for the pagination workload
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
    } else if (a == '--encrypted') {
      encrypted = true;
    } else if (a == '--allDirty') {
      allDirty = true;
    } else if (a == '--coldRead') {
      coldRead = true;
    } else if (a.startsWith('--lruCapacity=')) {
      lruCapacity = _flagInt(a, '--lruCapacity=');
    } else if (a.startsWith('--retention=')) {
      retention = _flagInt(a, '--retention=');
    } else if (a.startsWith('--pages=')) {
      pages = [
        for (final p in a.substring('--pages='.length).split(','))
          int.parse(p),
      ];
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
  if (lruCapacity < 1) {
    stderr.writeln('ERROR: --lruCapacity must be >= 1.');
    exit(2);
  }
  if (retention < 0) {
    stderr.writeln('ERROR: --retention must be >= 0.');
    exit(2);
  }
  if (allDirty && retention == 0) {
    stderr.writeln('ERROR: --allDirty requires --retention > 0.');
    exit(2);
  }
  if (pages.isEmpty || pages.any((p) => p < 1)) {
    stderr.writeln('ERROR: --pages must be a comma list of sizes >= 1.');
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
    encrypted: encrypted,
    lruCapacity: lruCapacity,
    retention: retention,
    allDirty: allDirty,
    coldRead: coldRead,
    pages: pages,
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

/// A freshly opened benchmark database plus its file path (the path lets the
/// harness reopen the same file for the pageCacheRead / storageColdRead
/// cache-mode workloads).
class _OpenHandle {
  _OpenHandle(this.db, this.path);
  final DatabaseImpl db;
  final String path;
}

Future<_OpenHandle> _openNative(String nativePath, _Options opts) async {
  final dir = await Directory.systemTemp.createTemp('gecko-bench-');
  final path = '${dir.path}${Platform.pathSeparator}db.redb';
  final db = await DatabaseImpl.open(
    path,
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      changeLogMaxEntries: opts.retention,
      // Application-level LRU sized so the cache-mode workloads are
      // unambiguous: the lruMissRead working set is strictly larger than the
      // effective capacity recorded in the dataset.
      lruCapacity: opts.effectiveLruCapacity,
      // Physical encryption (AES-256-GCM per page): established as a SEPARATE
      // baseline, never merged into the plaintext numbers. Fixed 32-byte key
      // so every encrypted run is comparable.
      encryptionKey: opts.encrypted ? _benchmarkEncryptionKey : null,
    ),
  );
  _tempDirs.add(dir);
  return _OpenHandle(db, path);
}

/// Reopens an existing benchmark database at [path] (used by pageCacheRead,
/// which must leave the OS page cache warm while starting with an empty
/// application LRU).
Future<DatabaseImpl> _reopenNative(
  String nativePath,
  String path,
  _Options opts,
) async {
  return DatabaseImpl.open(
    path,
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      changeLogMaxEntries: opts.retention,
      lruCapacity: opts.effectiveLruCapacity,
      encryptionKey: opts.encrypted ? _benchmarkEncryptionKey : null,
    ),
  );
}

/// Seeds [count] DIRTY change-log + sync-state records (never clean, so
/// retention can prune nothing) using prepared change templates. This is the
/// all-dirty history profile: subsequent writes must prove prune stays
/// bounded instead of re-scanning unprunable history on every commit.
Future<void> _seedDirtyHistory(
  DatabaseImpl db,
  int count,
  int batch,
  String shape,
  int groups,
) async {
  final codec = DefaultWireCodec();
  for (var start = 0; start < count; start += batch) {
    final end = (start + batch) < count ? start + batch : count;
    final ops = <RawOp>[];
    final templates = <RawChangeTemplate>[];
    for (var j = start; j < end; j++) {
      final id = 'd$j';
      final row = _makeRow(shape, id, j, 'g${j % groups}');
      ops.add(
        RawPut('items', ByteKey(codec.encode(id)), codec.encode(row)),
      );
      templates.add(
        RawChangeTemplate(
          operationIndex: j - start,
          ordinal: j,
          syncStateKey: ByteKey(codec.encode('items:$id')),
          recordTemplate: codec.encode({
            'localMutationId': j,
            'recordId': id,
            'timestamp': DateTime.fromMillisecondsSinceEpoch(1),
            'collection': 'items',
            'kind': 'put',
            'value': row,
            'previousVersion': null,
            'origin': 'user',
            'dirty': true,
            'syncPhase': 'pending',
          }),
        ),
      );
    }
    await db.engine.applyPreparedPlan(
      RawBatchPlan(ops: ops, changeTemplates: templates),
    );
  }
}

/// Fixed 32-byte AES-256 key for the encrypted benchmark baseline.
const List<int> _benchmarkEncryptionKey = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
];

Future<_BenchOutcome> _benchmark(
  String label,
  String nativePath,
  Future<_OpenHandle> Function() open,
  _Options opts,
) async {
  final quiet = opts.json;
  final handle = await open();
  final db = handle.db;
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
  if (opts.allDirty) {
    // All-dirty history profile: retention has no clean entry to remove, so
    // every later write must prove the prune scan stays bounded.
    await _seedDirtyHistory(
      db,
      opts.rows,
      opts.batch,
      opts.shape,
      opts.groups,
    );
  }
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

  // 3. Cache-mode point reads — three distinct workloads that are NEVER
  //    compared as if they were the same thing:
  //    - lruHitRead: one resident key, always an application-LRU hit.
  //    - lruMissRead: the full working set (strictly larger than the
  //      effective LRU capacity), so every read is a genuine storage miss.
  //    - pageCacheRead: a FRESH open of the same file (empty application
  //      cache) with the OS page cache still warm, one pass over all rows.
  //    storageColdRead is opt-in (--coldRead) and runs in an isolated child
  //    process (see _runStorageColdRead).
  await col.get('r0');
  results.add(
    await _runWorkload(label, 'lruHitRead', _readOps, (_) async {
      await col.get('r0');
    }),
  );
  results.add(
    await _runWorkload(label, 'lruMissRead', _readOps, (i) async {
      await col.get('r${i % opts.rows}');
    }),
  );

  // 4. Range scan (half-table window). The base collection is UNINDEXED, so
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

  // 5. Filtered query (equality on a 1/N-selectivity column).
  results.add(
    await _runWorkload(label, 'filteredQuery', _queryOps, (i) async {
      await col.where({'group': 'g${i % opts.groups}'}).findAll();
    }),
  );

  // 6. Pagination / first-result latency: the first page of a page-sized
  //    query. First-page latency and bytes must scale with the page size,
  //    not the full result size, for supported plans.
  for (final pageSize in opts.pages) {
    results.add(
      await _runWorkload(label, 'findPage$pageSize', _queryOps, (i) async {
        await col.where().findPage(pageSize: pageSize);
      }),
    );
  }

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

  // 9. Sync history profile (with --retention): mark-synced transitions over
  //    a large change log. The transition must be selective (no full-history
  //    Dart scan) and the write must stay bounded even when the history is
  //    all dirty.
  if (opts.retention > 0) {
    final history = col.where({'group': 'g0'}).findAll();
    final rows = await history;
    if (rows.isNotEmpty) {
      final ids = [for (var i = 0; i < rows.length && i < 500; i++) rows[i].id];
      results.add(
        await _runWorkload(label, 'markSynced', 20, (c) async {
          final slice = ids
              .sublist((c * 25) % ids.length, ((c * 25) % ids.length) + 25)
              .toList();
          await db.sync.markSynced(slice);
        }),
      );
    }
  }

  // 10. Indexed equality/range/prefix workloads (opt-in via --indexed) so
  //     index selectivity is measured instead of only the unindexed paths.
  if (opts.indexed) {
    results.addAll(await _benchmarkIndexed(db, label, opts));
  }

  WorkCounters? counters;
  if (opts.counters) {
    counters = await (db.engine.backend as NativeRawBackend).takeCounters();
  }
  await db.close();

  // 11. pageCacheRead + openToFirstIndexedQuery: a FRESH open of the same
  //     file (empty application cache, warm OS page cache) timed as a single
  //     read pass, plus — with --indexed — the open-to-first-indexed-query
  //     latency on that fresh handle. The main handle must be closed first —
  //     the engine refuses two opens of one path in a process. Neither is
  //     comparable to lruHitRead/lruMissRead: distinct cache modes.
  results.addAll(await _runReopenedWorkloads(nativePath, handle.path, opts, label));

  if (!quiet) stdout.writeln();
  return _BenchOutcome(results, counters, handle.path);
}

/// Reopens [path] with an empty application cache (the OS page cache stays
/// warm from the prior session) and measures two fresh-handle workloads:
/// `pageCacheRead` (one pass over every seeded row, each key read once so
/// the fresh LRU cannot help) and, with `--indexed`, `openToFirstIndexedQuery`
/// (latency from collection declaration to the first indexed-query result,
/// which includes any index repair on the fresh open).
Future<List<_Result>> _runReopenedWorkloads(
  String nativePath,
  String path,
  _Options opts,
  String label,
) async {
  final reopened = await _reopenNative(nativePath, path, opts);
  final results = <_Result>[];
  try {
    final col = reopened.collection<_Row>(
      'items',
      toRow: (r) => _makeRow(opts.shape, r.id, r.num, r.group),
      fromRow: _fromRow,
      id: _id,
    );
    final m = await _measure(
      (i) => col.get('r${i % opts.rows}'),
      opts.rows,
      warmup: 0,
    );
    results.add(
      _Result(
        label,
        'pageCacheRead',
        m.dist,
        rssStartKb: m.rssStartKb,
        rssEndKb: m.rssEndKb,
      ),
    );

    if (opts.indexed) {
      // Declare the indexed collection on the fresh handle and time the first
      // query (the declaration triggers repair on a fresh open when the
      // manifest is absent — the open-to-first-indexed-query profile).
      final idx = reopened.collection<Map<String, Object?>>(
        'items_indexed',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
        indexFields: ['num', 'group'],
        prefixFields: ['nick'],
      );
      final sw = Stopwatch()..start();
      await idx.where({'group': 'g0'}).findAll();
      sw.stop();
      results.add(
        _Result(
          label,
          'openToFirstIndexedQuery',
          _Dist.fromMicros([sw.elapsedMicroseconds]),
        ),
      );
    }
  } finally {
    await reopened.close();
  }
  return results;
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
  _kv('LRU capacity', '${opts.effectiveLruCapacity} (miss working set larger)');
  _kv(
    'change-log',
    opts.retention > 0
        ? 'max ${opts.retention}${opts.allDirty ? ', all-dirty history' : ''}'
        : 'disabled (storage path only)',
  );
  _kv('page sizes', opts.pages.join(', '));
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
          'lruHitRead: r0 LRU-resident; lruMissRead: cycling r0..r${opts.rows - 1} '
          'with effective LRU capacity ${opts.effectiveLruCapacity} (working set > '
          'capacity); pageCacheRead: fresh open, warm OS page cache, one pass; '
          'storageColdRead: isolated child process, fresh heap, one pass '
          '(host-dependent cold start)${opts.coldRead ? '' : ' (not run)'}',
      'retention': opts.retention > 0
          ? 'changeLogMaxEntries=${opts.retention}'
              '${opts.allDirty ? ', all-dirty history' : ', clean history'}'
          : 'disabled (storage path only)',
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
