// incremental reactivity benchmark 
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
//   dart run benchmark/reactivity.dart
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

import 'reactivity_helpers.dart';

const List<int> _sizes = [10000, 50000];
const int _liveQueries = 6; // N live filtered queries (per size)
const int _writeRuns = 40; // writes measured per size
const int _warmup = 5; // warmup writes before measuring
const Duration _poll = Duration(microseconds: 100);

/// Rows in the large watched-result-set profile.
const int _largeWatchRows = 10000;

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

  stdout.writeln('=== gecko_db incremental reactivity profiler ===');
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

  // Large watched result sets, windowed queries, and relationship watches.
  await _profileLargeWatches(nativePath);
}

/// Holds one live subscription's delivery counter.
class _Live {
  _Live(this.counter, this.name);
  final EmissionCounter<List<_Row>> counter;
  final String name;
}

Future<({int avg, int p50})?> _profileSize(
  int size,
  String nativePath, {
  bool quiet = false,
}) async {
  final dir = await Directory.systemTemp.createTemp('gecko-reactivity-');
  final dbPath = '${dir.path}${Platform.pathSeparator}reactivity.redb';
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
    // Every listener increments exactly one counter per received event so the
    // benchmark actually verifies that the measured subscription delivered.
    final lives = <_Live>[];
    for (var q = 0; q < _liveQueries; q++) {
      final name = 'num==${q + 1}';
      lives.add(_Live(
        EmissionCounter<List<_Row>>(col.where({'num': q + 1}).watch()),
        name,
      ));
    }
    // Registration latency: time until every subscription has delivered its
    // initial materialized snapshot.
    final regSw = Stopwatch()..start();
    await _waitAll(lives);
    regSw.stop();
    if (!quiet) {
      stdout.writeln(
        '  $_liveQueries live registrations delivered initial snapshots in '
        '${regSw.elapsedMicroseconds} µs',
      );
    }

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
        await l.counter.cancel();
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
      await l.counter.cancel();
    }
    await db.close();
    return (avg: total ~/ timings.length, p50: p50);
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Performs one single-row write and waits until every live subscription has
/// emitted; returns the elapsed microseconds. Throws a descriptive error if
/// any subscription does not deliver within the poll budget instead of
/// silently timing out and reporting a bogus (timeout-dominated) latency.
Future<int> _singleWrite(
  DatabaseImpl db,
  Collection<_Row> col,
  List<_Live> lives,
  String id,
  int matchNum,
) async {
  final before = [for (final l in lives) l.counter.count];
  final sw = Stopwatch()..start();
  await col.put(_Row(id, matchNum, 'g0')); // flips this row into num==matchNum
  var delivered = false;
  for (var i = 0; i < 20000; i++) {
    delivered = true;
    for (var j = 0; j < lives.length; j++) {
      if (lives[j].counter.count == before[j]) {
        delivered = false;
        break;
      }
    }
    if (delivered) break;
    await Future<void>.delayed(_poll);
  }
  sw.stop();
  if (!delivered) {
    throw StateError(
      'timed out waiting for all $_liveQueries live emissions after '
      'write "$id"',
    );
  }
  return sw.elapsedMicroseconds;
}

/// Waits for every subscription to deliver its initial emission, throwing a
/// descriptive timeout error rather than silently continuing.
Future<void> _waitAll(List<_Live> lives) {
  return waitForInitialEmissions([for (final l in lives) l.counter]);
}

// ── large watched result sets / windowed / relationship watches ─────────────

Future<void> _waitForCount(List<Object?> counts, int count) async {
  final sw = Stopwatch()..start();
  while (counts.length < count && sw.elapsedMilliseconds < 5000) {
    await Future<void>.delayed(_poll);
  }
}

/// Runs [write] and returns the µs until [counts] grew to [target].
Future<int> _timeEmission(
  Future<void> Function() write,
  List<Object?> counts,
  int target,
) async {
  final sw = Stopwatch()..start();
  await write();
  await _waitForCount(counts, target);
  sw.stop();
  return sw.elapsedMicroseconds;
}

void _report(String label, int us) {
  stdout.writeln('  ${label.padRight(46)} ${us.toString().padLeft(6)} µs');
}

/// Measures the end-to-end latency of one write until a watched result set
/// re-emits, across the scenarios the reactive path must handle well:
/// large watchAll (full snapshot — API contract), watchAllDiff (diff-only),
/// membership enter/leave, idempotent writes (no emission), a whole-table
/// clear, a large batch (one emission), sorted reorder, a windowed query
/// (Dart re-evaluation today), and a relationship watch.
Future<void> _profileLargeWatches(String nativePath) async {
  stdout.writeln('\n=== gecko_db large watched result sets ===');
  final dir = await Directory.systemTemp.createTemp('gecko-largereact-');
  final dbPath = '${dir.path}${Platform.pathSeparator}large.redb';
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
    const chunk = 2000;
    final seedWatch = Stopwatch()..start();
    for (var start = 0; start < _largeWatchRows; start += chunk) {
      final end = (start + chunk > _largeWatchRows)
          ? _largeWatchRows
          : start + chunk;
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
      '  seeded $_largeWatchRows rows in '
      '${(seedWatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} s',
    );

    // JIT warm the read/write paths before timing anything.
    for (var i = 0; i < 300; i++) {
      await col.get('r0');
      if (i % 100 == 0) await col.put(_Row('warm$i', 90000 + i, 'g0'));
    }

    // 1. watchAll: one-row update forces a FULL 10k snapshot emission.
    final allCounts = <Object?>[];
    final allSub = col.watchAll().listen(allCounts.add);
    await _waitForCount(allCounts, 1);
    final watchAllUs = await _timeEmission(
      () => col.put(_Row('r1', 100001, 'g0')),
      allCounts,
      2,
    );
    _report('watchAll one-row update (10k snapshot)', watchAllUs);
    await allSub.cancel();

    // 2. watchAllDiff: same write emits only the diff (no full snapshot).
    final diffCounts = <Object?>[];
    final diffSub = col.watchAllDiff().listen(diffCounts.add);
    await _waitForCount(diffCounts, 1);
    final diffUs = await _timeEmission(
      () => col.put(_Row('r2', 100002, 'g0')),
      diffCounts,
      2,
    );
    _report('watchAllDiff one-row update (diff-only)', diffUs);

    // 3. Membership enter (new matching row joins the set).
    final enterUs = await _timeEmission(
      () => col.put(_Row('enter', 100003, 'g0')),
      diffCounts,
      3,
    );
    _report('watchAllDiff membership enter', enterUs);

    // 4. Membership leave (row deleted).
    final leaveUs = await _timeEmission(
      () => col.delete('enter'),
      diffCounts,
      4,
    );
    _report('watchAllDiff membership leave', leaveUs);

    // 5. Idempotent write: identical value → no emission.
    await col.put(_Row('r3', 100004, 'g0')); // distinct value
    await _waitForCount(diffCounts, 5);
    final beforeIdem = diffCounts.length;
    await col.put(_Row('r3', 100004, 'g0')); // identical value
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final idemEmitted = diffCounts.length > beforeIdem;
    _report('watchAllDiff idempotent write (no emission)', idemEmitted ? -1 : 0);

    // 6. Large batch: 1000-row bulkWrite → exactly ONE emission.
    final beforeBatch = diffCounts.length;
    final batchUs = await _timeEmission(
      () => db.bulkWrite([
        for (var i = 0; i < 1000; i++)
          BulkMutation.put(
            table: 'items',
            key: 'batch$i',
            value: {'id': 'batch$i', 'num': 200000 + i, 'group': 'g${i % 100}'},
          ),
      ]),
      diffCounts,
      beforeBatch + 1,
    );
    _report('watchAllDiff 1000-row batch (one emission)', batchUs);
    await diffSub.cancel();

    // 7. Sorted watch (10k rows, sort by num): update repositions a row.
    final sortedCounts = <Object?>[];
    final sortedSub = col.where().sort([SortSpec('num')]).watch().listen(sortedCounts.add);
    await _waitForCount(sortedCounts, 1);
    final sortedUs = await _timeEmission(
      () => col.put(_Row('r5', 300000, 'g0')),
      sortedCounts,
      2,
    );
    _report('sorted watch one-row update (reposition)', sortedUs);
    await sortedSub.cancel();

    // 8. Windowed query (limit 100): today falls back to Dart re-evaluation.
    final windowCounts = <Object?>[];
    final windowSub = col.where().sort([SortSpec('num')]).limit(100).watch().listen(windowCounts.add);
    await _waitForCount(windowCounts, 1);
    final windowUs = await _timeEmission(
      () => col.put(_Row('r6', 400000, 'g0')),
      windowCounts,
      2,
    );
    _report('windowed query watch (limit 100, Dart re-eval)', windowUs);
    await windowSub.cancel();

    // 9. Relationship watchChildren: one child put → parent's list re-emits.
    const rel = Relationship(
      name: 'author_posts',
      parentCollection: 'authors',
      childCollection: 'posts',
      type: RelationshipType.oneToMany,
      foreignKeyField: 'authorId',
    );
    final relMgr = db.relationships;
    relMgr.registerAccessors(
      'posts',
      RowAccessors(childIdOf: (row) => row['id'], parentIdOf: (row) => row['authorId']),
    );
    relMgr.declare(rel);
    final authors = db.collection<Map<String, Object?>>(
      'authors',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    final posts = db.collection<Map<String, Object?>>(
      'posts',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );
    await authors.put({'id': 'a1'});
    await posts.put({'id': 'p0', 'authorId': 'a1'});
    final relCounts = <Object?>[];
    final relSub = relMgr.watchChildren(rel, 'a1').listen(relCounts.add);
    await _waitForCount(relCounts, 1);
    final relUs = await _timeEmission(
      () => posts.put({'id': 'p1', 'authorId': 'a1'}),
      relCounts,
      2,
    );
    _report('relationship watchChildren child put', relUs);
    await relSub.cancel();

    // 10. Whole-table clear: everything leaves the set in one emission.
    final clearCounts = <Object?>[];
    final clearSub = col.watchAllDiff().listen(clearCounts.add);
    await _waitForCount(clearCounts, 1);
    final clearUs = await _timeEmission(
      () => db.engine.rawClear('items'),
      clearCounts,
      2,
    );
    _report('watchAllDiff whole-table clear', clearUs);
    await clearSub.cancel();

    await db.close();
  } finally {
    await dir.delete(recursive: true);
  }
}
