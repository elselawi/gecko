// sort/limit profiler 
//
// Seeds a native (redb) database at 100k rows with an index on `nick` and
// measures, for each scenario:
//   - INDEXED ORDER BY nick LIMIT 20  (index-covered sort, streamed in order)
//   - top-K ORDER BY age LIMIT 20     (non-indexed sort, Rust top-K heap)
//   - early LIMIT 20                  (plain early-stop scan)
//
// Run from the repo root:
//   dart run benchmark/sort_limit.dart
//
// The native backend needs the release artifact:
//   cd rust && cargo build --release
//
// Numbers are indicative and depend on hardware/JIT state. Not consumed by
// tool/perf_gate.dart.
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('sortlimit-perf-');
  final root = Directory.current.path;
  final nativePath =
      '$root${Platform.pathSeparator}rust'
      '${Platform.pathSeparator}target${Platform.pathSeparator}release'
      '${Platform.pathSeparator}gecko_db_rust.dll';
  final db = await DatabaseImpl.open(
    '${dir.path}${Platform.pathSeparator}db.redb',
    config: DatabaseConfig(nativeLibraryPath: nativePath),
  );
  final col = db.collection<Map<String, Object?>>(
    't',
    toRow: (m) => m,
    fromRow: (m) => Map<String, Object?>.from(m as Map),
    id: (m) => m['id'],
    indexFields: ['nick'],
  );
  const n = 100000;
  final seed = Stopwatch()..start();
  for (var i = 0; i < n; i += 5000) {
    await db.bulkWrite([
      for (var j = i; j < (i + 5000).clamp(0, n); j++)
        BulkMutation.put(
          table: 't',
          key: 'r$j',
          value: {'id': 'r$j', 'nick': 'g${j % 1000}', 'age': j},
        ),
    ]);
  }
  seed.stop();
  stdout.writeln('seeded $n rows in ${seed.elapsedMilliseconds}ms');

  // Warm up.
  await col.where().sort([const SortSpec('nick')]).limit(20).findAll();

  Future<List<int>> measure(Query<Map<String, Object?>> q) async {
    const runs = 20;
    final times = <int>[];
    for (var i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      await q.findAll();
      sw.stop();
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    return [times.first, times[times.length ~/ 2]];
  }

  final idx = await measure(
    col.where().sort([const SortSpec('nick')]).limit(20),
  );
  stdout.writeln(
    'indexed ORDER BY nick LIMIT 20 on $n rows: best=${idx[0]}us median=${idx[1]}us',
  );

  final topk = await measure(
    col.where().sort([const SortSpec('age')]).limit(20),
  );
  stdout.writeln(
    'top-K ORDER BY age LIMIT 20 on $n rows: best=${topk[0]}us median=${topk[1]}us',
  );

  final early = await measure(col.where().limit(20));
  stdout.writeln(
    'early LIMIT 20 on $n rows: best=${early[0]}us median=${early[1]}us',
  );

  await db.close();
  try {
    await dir.delete(recursive: true);
  } catch (_) {}
}
