// architecture profiler 
//
// Measures the worker-isolate boundary and compares plaintext native storage
// with the Rust physical-encryption path. The boundary numbers are also
// available from benchmark/boundary.dart; this harness supports 
// performance qualification.
//
// Run from the repository root:
//   dart run benchmark/architecture.dart
//
// Numbers are indicative and depend on hardware/JIT state. Not consumed by
// tool/perf_gate.dart.
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

const _key = <int>[
  0x10,
  0x21,
  0x32,
  0x43,
  0x54,
  0x65,
  0x76,
  0x87,
  0x98,
  0xA9,
  0xBA,
  0xCB,
  0xDC,
  0xED,
  0xFE,
  0x0F,
  0x10,
  0x21,
  0x32,
  0x43,
  0x54,
  0x65,
  0x76,
  0x87,
  0x98,
  0xA9,
  0xBA,
  0xCB,
  0xDC,
  0xED,
  0xFE,
  0x0F,
];

Future<void> main() async {
  final root = Directory.current.path;
  final nativePath =
      '$root${Platform.pathSeparator}rust'
      '${Platform.pathSeparator}target${Platform.pathSeparator}release'
      '${Platform.pathSeparator}gecko_db_rust.dll';
  const rows = 10000;

  Future<(int, int)> measure(DatabaseImpl db, {required bool encrypted}) async {
    final col = db.collection<Map<String, Object?>>(
      'items',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
      indexFields: ['group'],
    );
    for (var i = 0; i < rows; i += 1000) {
      await db.bulkWrite([
        for (var j = i; j < (i + 1000).clamp(0, rows); j++)
          BulkMutation.put(
            table: 'items',
            key: 'r$j',
            value: {'id': 'r$j', 'group': 'g${j % 10}', 'payload': j},
          ),
      ]);
    }
    final q = col.where({'group': 'g3'});
    await q.findAll();
    const runs = 10;
    final times = <int>[];
    for (var i = 0; i < runs; i++) {
      final sw = Stopwatch()..start();
      final result = await q.findAll();
      sw.stop();
      if (result.length != rows ~/ 10) {
        throw StateError('unexpected result count for encrypted=$encrypted');
      }
      times.add(sw.elapsedMicroseconds);
    }
    times.sort();
    stdout.writeln(
      '${encrypted ? 'native physical-encrypted' : 'native plain'} indexed equality: '
      'best=${times.first}us median=${times[times.length ~/ 2]}us plan=${q.lastPlan}',
    );
    return (times.first, times[times.length ~/ 2]);
  }

  final plainDir = await Directory.systemTemp.createTemp('arch-plain-');
  final encryptedDir = await Directory.systemTemp.createTemp('arch-encrypted-');
  try {
    final plain = await DatabaseImpl.open(
      '${plainDir.path}${Platform.pathSeparator}db.redb',
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );
    await measure(plain, encrypted: false);
    await plain.close();

    final encrypted = await DatabaseImpl.open(
      '${encryptedDir.path}${Platform.pathSeparator}db.redb',
      config: DatabaseConfig(
        nativeLibraryPath: nativePath,
        encryptionKey: _key,
      ),
    );
    await measure(encrypted, encrypted: true);
    await encrypted.close();
  } finally {
    try {
      await plainDir.delete(recursive: true);
    } catch (_) {}
    try {
      await encryptedDir.delete(recursive: true);
    } catch (_) {}
  }
}
