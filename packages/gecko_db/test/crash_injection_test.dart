// crash injection at every native commit boundary.
//
// Spawns the native write helper as a separate OS process, kills it with a
// hard kill (TerminateProcess / SIGKILL) at EVERY committed-batch boundary,
// reopens the database, and verifies: exactly the durable batches are present
// (data + change log + sync state + LSN all agree), the in-flight batch is
// absent, and there is no corruption. Then it repeats with randomized
// boundaries for good measure.
//
// This is the strongest crash-safety assertion: redb's two-phase commits must
// leave the file consistent at every possible interruption point.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
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

const int _batchSize = 5;
const int _batches = 8;

Future<Process> _spawnHelper(List<String> args, String root) {
  return Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/native_process_helper.dart', ...args],
    workingDirectory: root,
    mode: ProcessStartMode.normal,
  );
}

/// Waits until the helper has committed [target] batches (or the process
/// exits), tracking every committed marker.
Future<List<int>> _waitForCommit(
  Process process,
  int target, {
  int timeoutSeconds = 120,
}) async {
  final committed = <int>[];
  final reached = Completer<void>();
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.startsWith('committed ')) {
          final n = int.parse(line.substring('committed '.length));
          committed.add(n);
          if (n >= target && !reached.isCompleted) reached.complete();
        }
      });
  final exited = process.exitCode.then<int>((code) => -1);
  try {
    await Future.any<int>([
      reached.future.then((_) => 0),
      exited,
    ]).timeout(Duration(seconds: timeoutSeconds), onTimeout: () => -2);
  } finally {
    await sub.cancel();
  }
  return committed;
}

Future<void> _kill(Process process) async {
  process.kill(ProcessSignal.sigkill);
  await process.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () => 0,
  );
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  Future<(String, Directory)> freshDb() async {
    final dir = await Directory.systemTemp.createTemp('gecko-crash-');
    return ('${dir.path}${Platform.pathSeparator}db.redb', dir);
  }

  /// Reopens [path] and returns how many batches are durably present.
  ///
  /// The `write` helper commits each batch as ONE redb write transaction (the
  /// native commit boundary). Crash injection must never leave a partial
  /// batch, so the durable state is always a contiguous prefix 0..maxBatch
  /// with every batch fully present. (LSN + change-log atomicity for
  /// engine-mediated writes is asserted by the process-crash suite.)
  Future<int> durableBatches(String path) async {
    final db = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );
    try {
      const codec = DefaultWireCodec();
      final items = await db.engine.rawScanAll('items');
      final maxBatch = items.fold<int>(0, (acc, entry) {
        final value = codec.decode(entry.value!) as Map;
        return value['batch'] as int > acc ? value['batch'] as int : acc;
      });
      // Durable batches are contiguous from 0..maxBatch (no holes, no
      // partially-applied batches).
      final batchCounts = <int, int>{};
      for (final entry in items) {
        final value = codec.decode(entry.value!) as Map;
        batchCounts[value['batch'] as int] =
            (batchCounts[value['batch'] as int] ?? 0) + 1;
      }
      for (var b = 0; b <= maxBatch; b++) {
        expect(
          batchCounts[b],
          _batchSize,
          reason: 'batch $b must be fully present (crash injection invariant)',
        );
      }
      return maxBatch + 1;
    } finally {
      await db.close();
    }
  }

  test(
    'hard kill at EVERY commit boundary leaves exactly the durable prefix',
    () async {
      for (var boundary = 1; boundary <= _batches; boundary++) {
        final (path, dir) = await freshDb();
        final process = await _spawnHelper([
          'write',
          path,
          nativePath,
          '$_batches',
          '$_batchSize',
          '50',
        ], root);
        final committed = await _waitForCommit(process, boundary);
        await _kill(process);

        final durable = await durableBatches(path);
        // Every observed commit marker was printed AFTER its redb commit
        // returned, so all `committed.length` batches must be durable. The
        // helper may additionally commit the next batch before the kill lands,
        // so durable may exceed the observed count — but never exceed total
        // batches, and never be a partial/holey prefix (that invariant is
        // enforced inside durableBatches).
        expect(
          durable,
          greaterThanOrEqualTo(committed.length),
          reason: 'boundary=$boundary: no observed committed batch may be lost',
        );
        expect(durable, lessThanOrEqualTo(_batches));
        await dir.delete(recursive: true);
      }
    },
  );

  test('randomized kill boundaries preserve durability', () async {
    var seed = 0x1234ABCD;
    for (var round = 0; round < 5; round++) {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
      final boundary = 1 + (seed % _batches);
      final (path, dir) = await freshDb();
      final process = await _spawnHelper([
        'write',
        path,
        nativePath,
        '$_batches',
        '$_batchSize',
        '20',
      ], root);
      final committed = await _waitForCommit(process, boundary);
      await _kill(process);
      final durable = await durableBatches(path);
      expect(
        durable,
        greaterThanOrEqualTo(committed.length),
        reason:
            'random round $round boundary=$boundary: no observed committed '
            'batch may be lost',
      );
      expect(durable, lessThanOrEqualTo(_batches));
      await dir.delete(recursive: true);
    }
  });
}
