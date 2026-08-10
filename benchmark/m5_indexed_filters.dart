// M5 indexed-filter profiler (ADR-0020).
//
// Measures covered range, prefix, and multi-equality queries against the
// native predicate-push baseline. Range and prefix candidate bounds are broad
// field spans; Rust performs the final semantic predicate recheck.
//
// Run from the repository root:
//   dart run benchmark/m5_indexed_filters.dart
//
// Numbers are indicative and depend on hardware/JIT state. Not consumed by
// tool/perf_gate.dart.
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('m5-perf-');
  final root = Directory.current.path;
  final nativePath =
      '$root${Platform.pathSeparator}rust'
      '${Platform.pathSeparator}target${Platform.pathSeparator}release'
      '${Platform.pathSeparator}gecko_db_rust.dll';
  final db = await DatabaseImpl.open(
    '${dir.path}${Platform.pathSeparator}db.redb',
    useInMemory: false,
    config: DatabaseConfig(nativeLibraryPath: nativePath),
  );
  final col = db.collection<Map<String, Object?>>(
    't',
    toRow: (m) => m,
    fromRow: (m) => Map<String, Object?>.from(m as Map),
    id: (m) => m['id'],
    indexFields: ['age', 'group'],
    prefixFields: ['name'],
  );
  const n = 100000;
  for (var i = 0; i < n; i += 5000) {
    await db.bulkWrite([
      for (var j = i; j < (i + 5000).clamp(0, n); j++)
        BulkMutation.put(
          table: 't',
          key: 'r$j',
          value: {
            'id': 'r$j',
            'age': j % 1000,
            'group': 'g${j % 100}',
            'name': 'name-${j % 20}-$j',
          },
        ),
    ]);
  }

  Future<(int, int)> measure(Query<Map<String, Object?>> query) async {
    await query.findAll();
    const runs = 10;
    final times = <int>[];
    for (var i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      await query.findAll();
      sw.stop();
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    return (times.first, times[times.length ~/ 2]);
  }

  final range = await measure(col.where().range('age', min: 120, max: 129));
  stdout.writeln('indexed range: best=${range.$1}us median=${range.$2}us');
  final prefix = await measure(col.where().prefix('name', 'name-1-'));
  stdout.writeln('indexed prefix: best=${prefix.$1}us median=${prefix.$2}us');
  final multi = await measure(col.where({'group': 'g3', 'age': 203}));
  stdout.writeln('indexed multi-eq: best=${multi.$1}us median=${multi.$2}us');

  final nativeScan = await measure(col.where().filter('unindexed', true));
  stdout.writeln(
    'unindexed predicate scan: best=${nativeScan.$1}us median=${nativeScan.$2}us',
  );

  await db.close();
  try {
    await dir.delete(recursive: true);
  } catch (_) {}
}
