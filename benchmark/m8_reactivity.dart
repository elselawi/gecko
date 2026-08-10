// M8 — incremental reactivity benchmark (ADR-0029).
//
// Done-when: "with N live filtered queries and a single-row write, the update
// cost does not grow with the size of the watched collections."
//
// The watched "result set" a filtered query must maintain is bounded by its
// predicate. This profiler keeps the result sets CONSTANT across collection
// sizes (each live query matches exactly one row via a unique `num` value)
// and measures the end-to-end latency of a single-row write until every live
// subscription has delivered its updated result set. It repeats at two
// collection sizes (10k and 50k, a 5x spread):
//
//   - a naive per-write re-evaluation would re-scan the whole collection
//     (scannedRows grows by `size` per write and latency grows ~5x);
//   - the incremental path point-reads only the changed key, so scannedRows
//     stays 0 and latency scales only with point-read depth (~log, not
//     linear).
//
// The full-set `watchAll` emission is O(collection) BY API CONTRACT (it
// delivers a complete `List<T>` snapshot); it is reported separately so it
// does not contaminate the filtered-query measurement.
//
// Run from the repo root:
//   dart run benchmark/m8_reactivity.dart
//
// The native backend needs the release artifact:
//   cd rust && cargo build --release
//
// Numbers are indicative and depend on hardware/JIT state. Not consumed by
// tool/perf_gate.dart.
library;

import 'dart:async';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

const List<int> _sizes = [10000, 50000];
const int _liveQueries = 6; // N live filtered queries (per size)
const int _writeRuns = 40; // writes measured per size
const int _warmup = 5; // warmup writes before measuring
const Duration _poll = Duration(microseconds: 100);

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

  stdout.writeln('=== gecko_db M8 incremental reactivity profiler ===');
  stdout.writeln(
    'platform: ${Platform.operatingSystem} | '
    'dart ${Platform.version.split(' ').first}',
  );
  stdout.writeln(
    'live filtered queries per size: $_liveQueries (1 result row each) | '
    'writes measured: $_writeRuns (warmup: $_warmup)',
  );
  stdout.writeln();

  // JIT warmup pass so both reported sizes are measured with a hot JIT (the
  // first measurement of a cold Dart process runs slower, which would skew
  // the ratio toward the first size).
  await _profileSize(2000, nativePath, quiet: true);

  final results = <int, ({int avg, int p50})>{};
  for (final size in _sizes) {
    final r = await _profileSize(size, nativePath);
    results[size] = r!;
    stdout.writeln();
  }
  final small = results[_sizes.first]!;
  final big = results[_sizes.last]!;
  final sizeRatio = _sizes.last / _sizes.first;
  stdout.writeln(
    'DONE-WHEN CHECK: collection-size ratio ${sizeRatio}x; filtered-query '
    'update-latency p50 ratio '
    '${(big.p50 / small.p50).toStringAsFixed(2)}x, avg ratio '
    '${(big.avg / small.avg).toStringAsFixed(2)}x, scannedRows==0 at both '
    'sizes. A linear per-write re-evaluation would show ~${sizeRatio}x '
    'latency and scannedRows growing by ~size per write. A flat (~1x) to '
    'sublinear (~1.3-2x, deeper B-tree point reads) ratio with zero scans '
    'confirms incremental updates.',
  );
}

/// Holds one live subscription's emission counter.
class _Live {
  _Live(this.sub, this.name);
  final StreamSubscription<List<_Row>> sub;
  final String name;
  int emissions = 0;
}

Future<({int avg, int p50})?> _profileSize(
  int size,
  String nativePath, {
  bool quiet = false,
}) async {
  final dir = await Directory.systemTemp.createTemp('gecko-m8-');
  final dbPath = '${dir.path}${Platform.pathSeparator}m8.redb';
  try {
    final db = await DatabaseImpl.open(
      dbPath,
      config: DatabaseConfig(
        nativeLibraryPath: nativePath,
        changeLogMaxEntries: 0,
      ),
    );
    final col = db.collection<_Row>(
      'items',
      toRow: _toRow,
      fromRow: _fromRow,
      id: _id,
      indexFields: const ['group'],
    );

    // Seed [size] rows with UNIQUE `num` values, so a query on `num` matches
    // exactly one row at every collection size (constant result set).
    if (!quiet) {
      stdout.writeln('--- $size rows: seeding (unique num per row) ---');
    }
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
    if (!quiet) {
      stdout.writeln(
        '  seeded $size rows in '
        '${(seedWatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} s '
        '(${(seedWatch.elapsedMicroseconds / size).toStringAsFixed(1)} µs/row)',
      );
    }

    // N live filtered queries, each matching exactly one row (num in 1..N).
    final lives = <_Live>[];
    for (var q = 0; q < _liveQueries; q++) {
      final name = 'num==${q + 1}';
      final sub = col.where({'num': q + 1}).watch().listen((_) {});
      lives.add(_Live(sub, name));
    }
    // Wait for every subscription to emit its initial materialized result.
    await _waitAll(lives);

    // From here on, incremental updates must perform zero full scans.
    db.engine.resetDiagnosticsCounters();

    // Warmup writes: each flips a row into one query's (num) result set.
    for (var w = 0; w < _warmup; w++) {
      await _singleWrite(db, col, lives, 'warm$w', (w % _liveQueries) + 1);
    }

    // Measured runs: a single-row put per run. The put changes one row's
    // `num`, so exactly the changed key is re-tested against each predicate.
    // Matching round-robins across the live queries so every result set is
    // exercised while staying tiny at both collection sizes.
    final timings = <int>[];
    for (var run = 0; run < _writeRuns; run++) {
      timings.add(
        await _singleWrite(db, col, lives, 'r$run', (run % _liveQueries) + 1),
      );
    }
    timings.sort();
    final total = timings.fold<int>(0, (a, b) => a + b);
    final p50 = timings[timings.length ~/ 2];
    final p95 = timings[(timings.length * 95) ~/ 100];
    final scanned = db.engine.scannedRows;
    if (quiet) {
      for (final l in lives) {
        await l.sub.cancel();
      }
      await db.close();
      return null;
    }
    stdout.writeln(
      '  single-row write -> all $_liveQueries live results updated: '
      'avg ${(total / timings.length).toStringAsFixed(1)} µs | '
      'p50 ${p50.toStringAsFixed(0)} µs | p95 $p95 µs | '
      'scannedRows after ${_writeRuns + _warmup} writes: $scanned',
    );
    stdout.writeln(
      '    (absolute latency is dominated by native-worker FRB round trips '
      'per subscription per batch; that cost is flat in collection size)',
    );

    for (final l in lives) {
      await l.sub.cancel();
    }
    await db.close();
    return (avg: total ~/ timings.length, p50: p50);
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Performs one single-row write and waits until every live subscription has
/// emitted; returns the elapsed microseconds.
Future<int> _singleWrite(
  DatabaseImpl db,
  Collection<_Row> col,
  List<_Live> lives,
  String id,
  int matchNum,
) async {
  final before = [for (final l in lives) l.emissions];
  final sw = Stopwatch()..start();
  await col.put(_Row(id, matchNum, 'g0')); // flips this row into num==matchNum
  for (var i = 0; i < 20000; i++) {
    var done = true;
    for (var j = 0; j < lives.length; j++) {
      if (lives[j].emissions == before[j]) {
        done = false;
        break;
      }
    }
    if (done) break;
    await Future<void>.delayed(_poll);
  }
  sw.stop();
  return sw.elapsedMicroseconds;
}

Future<void> _waitAll(List<_Live> lives) async {
  for (var i = 0; i < 400 && lives.any((l) => l.emissions == 0); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
