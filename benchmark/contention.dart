// Worker queue-contention benchmark (terry-perf Item 19).
//
// Measures how a long-running background job (full-table scan, index repair,
// or compaction) in the single worker isolate affects latency-sensitive
// point gets and writes. The worker processes commands serially, so a long
// scan delays later short reads; this harness quantifies that with:
//
//   * per-request latency of the latency-sensitive workload (mean/p50/p95/
//     p99/max),
//   * client-observed in-flight request depth high-water (a proxy for the
//     worker queue),
//   * the write-gate lock-contention counter delta,
//   * correctness: row counts stay exact while background work runs, and
//     closing the database while a scan is in flight completes cleanly.
//
// Run from the repo root (benchmark is a standalone package; always cd into
// it first so the native-assets build hooks never pollute the root's stdout):
//
//   cd benchmark && dart run contention.dart --background=scan
//   cd benchmark && dart run contention.dart --background=compact --json
//   cd benchmark && dart run contention.dart --help
//
// The native backend needs the release artifact built:
//   cd rust && cargo build --release

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gecko_db/gecko_db.dart';

const int _defaultRows = 20000;
const int _defaultRequests = 400;
const int _defaultConcurrency = 8;
const int _seedBatch = 500;

/// Fixed 32-byte AES-256 key for the encrypted profile.
const List<int> _benchmarkEncryptionKey = [
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
];

class _Options {
  _Options({
    required this.rows,
    required this.requests,
    required this.concurrency,
    required this.background,
    required this.json,
    required this.encrypted,
  });

  final int rows;
  final int requests;
  final int concurrency;
  final String background;
  final bool json;
  final bool encrypted;
}

const String _usage = '''
Usage: dart run benchmark/contention.dart [flags]

  --rows=N           seeded rows (default $_defaultRows)
  --requests=N       latency-sensitive requests per phase (default $_defaultRequests)
  --concurrency=N    concurrent latency-sensitive requests in flight (default $_defaultConcurrency)
  --background=KIND  background long job: none|scan|repair|compact (default scan)
  --encrypted        run over physically encrypted storage
  --json             machine-readable JSON output
  --help             this help
''';

_Options _parseArgs(List<String> args) {
  var rows = _defaultRows;
  var requests = _defaultRequests;
  var concurrency = _defaultConcurrency;
  var background = 'scan';
  var json = false;
  var encrypted = false;
  for (final arg in args) {
    if (arg == '--help') {
      stdout.writeln(_usage);
      exit(0);
    } else if (arg == '--json') {
      json = true;
    } else if (arg == '--encrypted') {
      encrypted = true;
    } else if (arg.startsWith('--rows=')) {
      rows = int.parse(arg.substring('--rows='.length));
    } else if (arg.startsWith('--requests=')) {
      requests = int.parse(arg.substring('--requests='.length));
    } else if (arg.startsWith('--concurrency=')) {
      concurrency = int.parse(arg.substring('--concurrency='.length));
    } else if (arg.startsWith('--background=')) {
      background = arg.substring('--background='.length);
    } else {
      stderr.writeln('unknown flag: $arg\n$_usage');
      exit(2);
    }
  }
  if (!{'none', 'scan', 'repair', 'compact'}.contains(background)) {
    stderr.writeln('--background must be none|scan|repair|compact\n$_usage');
    exit(2);
  }
  return _Options(
    rows: rows,
    requests: requests,
    concurrency: concurrency,
    background: background,
    json: json,
    encrypted: encrypted,
  );
}

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

/// One measured request's duration in microseconds plus whether it was a
/// write (writes also contend on the write gate).
class _Sample {
  _Sample(this.durationMicros, this.isWrite);
  final int durationMicros;
  final bool isWrite;
}

class _LatencyStats {
  _LatencyStats(this.samples);
  final List<_Sample> samples;

  double _pct(num p) {
    if (samples.isEmpty) return 0;
    final sorted = [...samples]
      ..sort((a, b) => a.durationMicros.compareTo(b.durationMicros));
    final index = ((sorted.length - 1) * p).round();
    return sorted[index].durationMicros / 1000;
  }

  double get meanMs => samples.isEmpty
      ? 0
      : (samples.fold<int>(0, (s, e) => s + e.durationMicros) / samples.length) /
          1000;
  double get p50Ms => _pct(0.50);
  double get p95Ms => _pct(0.95);
  double get p99Ms => _pct(0.99);
  double get maxMs => samples.isEmpty
      ? 0
      : samples.map((e) => e.durationMicros).reduce(max) / 1000;
}

class _Phase {
  _Phase(this.label, this.latency, this.depthHighWater, this.lockContention);
  final String label;
  final _LatencyStats latency;
  final int depthHighWater;
  final int lockContention;

  Map<String, Object?> toJson() => {
    'label': label,
    'meanMs': _round3(latency.meanMs),
    'p50Ms': _round3(latency.p50Ms),
    'p95Ms': _round3(latency.p95Ms),
    'p99Ms': _round3(latency.p99Ms),
    'maxMs': _round3(latency.maxMs),
    'depthHighWater': depthHighWater,
    'writeGateContention': lockContention,
  };
}

double _round3(double v) => (v * 1000).roundToDouble() / 1000;

final DefaultWireCodec _codec = DefaultWireCodec();

Map<String, Object?> _row(int num) => {
  'id': 'r$num',
  'num': num,
  'group': 'g${num % 100}',
  'payload': 'value-$num',
};

Future<void> main(List<String> args) async {
  final opts = _parseArgs(args);
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);
  final dir = await Directory.systemTemp.createTemp('gecko-contention-');
  final path = '${dir.path}${Platform.pathSeparator}db.redb';

  final db = await DatabaseImpl.open(
    path,
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      encryptionKey: opts.encrypted ? _benchmarkEncryptionKey : null,
    ),
  );
  final engine = db.engine;
  final c = db.collection<Map<String, Object?>>(
    'items',
    toRow: (value) => value,
    fromRow: (row) => Map<String, Object?>.from(row as Map),
    id: (value) => value['id'],
  );

  // Seed.
  for (var start = 0; start < opts.rows; start += _seedBatch) {
    final end = (start + _seedBatch) < opts.rows ? start + _seedBatch : opts.rows;
    await db.bulkWrite([
      for (var i = start; i < end; i++)
        BulkMutation.put(table: 'items', key: 'r$i', value: _row(i)),
    ]);
  }
  final expected = (await c.getAll()).length;

  // Register a durable index so the `repair` background job has work to do.
  final indexed = db.collection<Map<String, Object?>>(
    'items',
    toRow: (value) => value,
    fromRow: (row) => Map<String, Object?>.from(row as Map),
    id: (value) => value['id'],
    indexFields: const ['num'],
  );
  await indexed.where({'num': 0}).findAll(); // triggers the one-time repair

  final phases = <_Phase>[];

  // Baseline: no background job.
  final baseContention0 = engine.lockContentionCount;
  final base = await _runLatencyWorkload(engine, opts);
  phases.add(
    _Phase(
      'baseline (no background)',
      base.latency,
      base.depthHighWater,
      engine.lockContentionCount - baseContention0,
    ),
  );

  // Contention phase: long job concurrent with the latency-sensitive load.
  final job = _startBackgroundJob(db, engine, opts.background);
  final contContention0 = engine.lockContentionCount;
  final contended = await _runLatencyWorkload(engine, opts);
  await job.cancel();
  phases.add(
    _Phase(
      'background=${opts.background}',
      contended.latency,
      contended.depthHighWater,
      engine.lockContentionCount - contContention0,
    ),
  );

  // Correctness: background work never corrupts the row set.
  final afterCount = (await c.getAll()).length;
  final spot = await c.get('r${opts.rows ~/ 2}');
  final correct =
      afterCount == expected && spot != null && spot['num'] == opts.rows ~/ 2;

  // Correctness under close: closing while a scan is in flight completes
  // cleanly and the file reopens with the exact row set.
  final closeWhileBusy = await _verifyCloseWhileBusy(db, opts, path);

  if (opts.json) {
    final doc = <String, Object?>{
      'harness': 'contention',
      'dataset': {
        'rows': opts.rows,
        'requests': opts.requests,
        'concurrency': opts.concurrency,
        'background': opts.background,
        'encrypted': opts.encrypted,
      },
      'correct': correct,
      'closeWhileBusy': closeWhileBusy,
      'phases': [for (final p in phases) p.toJson()],
    };
    stdout.writeln(jsonEncode(doc));
  } else {
    stdout.writeln('rows=$expected requests=${opts.requests} '
        'concurrency=${opts.concurrency} background=${opts.background}');
    for (final p in phases) {
      stdout.writeln(
        '${p.label.padRight(26)} mean=${p.latency.meanMs.toStringAsFixed(3)}ms '
        'p50=${p.latency.p50Ms.toStringAsFixed(3)}ms '
        'p95=${p.latency.p95Ms.toStringAsFixed(3)}ms '
        'p99=${p.latency.p99Ms.toStringAsFixed(3)}ms '
        'max=${p.latency.maxMs.toStringAsFixed(3)}ms '
        'depthHW=${p.depthHighWater} writeContention=${p.lockContention}',
      );
    }
    stdout.writeln('correctness: ${correct ? 'ok' : 'FAILED'}');
    stdout.writeln('closeWhileBusy: ${closeWhileBusy ? 'ok' : 'FAILED'}');
  }

  try {
    await dir.delete(recursive: true);
  } catch (_) {}
  if (!correct || !closeWhileBusy) exit(1);
}

class _LatencyOutcome {
  _LatencyOutcome(this.latency, this.depthHighWater);
  final _LatencyStats latency;
  final int depthHighWater;
}

/// Runs [opts.requests] latency-sensitive point reads/writes at
/// [opts.concurrency], tracking per-request latency and the in-flight depth
/// high-water (a client-side proxy for the worker queue depth).
Future<_LatencyOutcome> _runLatencyWorkload(RawEngine engine, _Options opts) async {
  final samples = <_Sample>[];
  var inFlight = 0;
  var depthHighWater = 0;
  final completer = Completer<void>();
  var issued = 0;
  var done = false;
  final rng = Random();

  Future<void> worker() async {
    while (!done) {
      inFlight++;
      if (inFlight > depthHighWater) depthHighWater = inFlight;
      final isWrite = rng.nextInt(5) == 0; // 20% writes, 80% reads
      final id = rng.nextInt(opts.rows);
      final key = ByteKey(_codec.encode('r$id'));
      final sw = Stopwatch()..start();
      try {
        if (isWrite) {
          await engine.rawPut('items', key, _codec.encode(_row(id)));
        } else {
          await engine.rawGet('items', key);
        }
      } catch (_) {
        // Best-effort: a late op may race a close during closeWhileBusy.
      } finally {
        sw.stop();
        inFlight--;
        samples.add(_Sample(sw.elapsedMicroseconds, isWrite));
        issued++;
        if (issued >= opts.requests) done = true;
      }
    }
    if (!completer.isCompleted) completer.complete();
  }

  final workers = [for (var i = 0; i < opts.concurrency; i++) worker()];
  await completer.future;
  await Future.wait(workers);
  return _LatencyOutcome(_LatencyStats(samples), depthHighWater);
}

class _BackgroundJob {
  _BackgroundJob(this._cancel);
  final Future<void> Function() _cancel;
  Future<void> cancel() => _cancel();
}

/// Starts a cancellable background long-running job on the single worker.
_BackgroundJob _startBackgroundJob(DatabaseImpl db, RawEngine engine, String kind) {
  final stop = Completer<void>();
  final job = () async {
    while (!stop.isCompleted) {
      try {
        switch (kind) {
          case 'scan':
            // The primary contention source: a long full-table scan holds the
            // worker while later short reads queue behind it.
            await engine.rawRangeScan('items');
          case 'repair':
            if (engine.backend case final NativeRawBackend backend) {
              await backend.repairIndex(table: 'items', fields: const ['num']);
            }
          case 'compact':
            await db.maintenance.compact();
          default:
            break;
        }
      } catch (_) {
        // Background work is best-effort; a failure must not kill the load.
      }
    }
  }();
  return _BackgroundJob(() async {
    stop.complete();
    await job;
  });
}

/// Closes [db] while a full-table scan is in flight and proves the close
/// completes cleanly (no hang) and the file reopens with the exact row set.
Future<bool> _verifyCloseWhileBusy(DatabaseImpl db, _Options opts, String path) async {
  final scan = db.engine.rawRangeScan('items'); // issued, not awaited
  final closed = db.close();
  final results = await Future.wait<Object?>([
    scan.then<Object?>((_) => 'scan-ok').catchError((Object _) => 'scan-aborted'),
    closed.then<Object?>((_) => 'close-ok'),
  ]);
  if (results[1] != 'close-ok') return false;
  try {
    final reopened = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(nativeLibraryPath: _nativeLibraryPath(_repoRoot())),
    );
    final count = (await reopened
            .collection<Map<String, Object?>>(
              'items',
              toRow: (value) => value,
              fromRow: (row) => Map<String, Object?>.from(row as Map),
              id: (value) => value['id'],
            )
            .getAll())
        .length;
    await reopened.close();
    return count == opts.rows;
  } catch (_) {
    return false;
  }
}
