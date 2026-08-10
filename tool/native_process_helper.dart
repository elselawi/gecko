// Helper entrypoint for Workstream 1 process-level tests.
//
// This script runs as a *separate OS process* and is spawned by
// `phase2_process_crash_test.dart` / `phase2_cross_process_lock_test.dart`
// through `Process.start(Platform.resolvedExecutable, ['run', ...])`. It is
// deliberately trivial so a test can kill it with `ProcessSignal.sigkill`
// (TerminateProcess on Windows) to exercise real crash-recovery paths in the
// redb-backed native worker.
//
// Modes:
//   write <dbPath> <nativeLib> <batches> <batchSize> [sleepBetweenMs]
//     Opens the database, then commits `batches` raw batches of `batchSize`
//     puts each to table `items`. After each committed batch it prints a
//     single line `committed <n>` on stdout and flushes, so the parent can
//     observe progress and kill the process at a precise point.
//   hold <dbPath> <nativeLib>
//     Opens the database and keeps the file lock held until the process is
//     killed. Prints `ready` (and flushes) once the database is open.
//
// Everything besides the progress markers goes to stderr so stdout stays a
// clean, parseable control channel for the parent test.
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

Future<void> main(List<String> args) async {
  try {
    await _run(args);
  } catch (error, stack) {
    stderr.writeln('HELPER-FATAL: $error');
    stderr.writeln(stack);
    exitCode = 70;
  }
}

Future<void> _run(List<String> args) async {
  if (args.length < 3) {
    throw ArgumentError(
      'usage: native_process_helper <write|hold> <dbPath> '
      '<nativeLib> [batches] [batchSize] [sleepBetweenMs]',
    );
  }
  final mode = args[0];
  final dbPath = args[1];
  final nativeLib = args[2];
  final config = DatabaseConfig(nativeLibraryPath: nativeLib);
  final db = await DatabaseImpl.open(
    dbPath,
    config: config,
  );
  try {
    switch (mode) {
      case 'write':
        final batches = int.parse(args[3]);
        final batchSize = int.parse(args[4]);
        final sleepBetweenMs = args.length > 5 ? int.parse(args[5]) : 0;
        await _writeBatches(db, batches, batchSize, sleepBetweenMs);
        break;
      case 'typed':
        // Same as `write`, but through the typed collection API so every
        // committed batch is a single redb write transaction that contains
        // the user row, its change-log record, its sync-state record, and the
        // LSN metadata together.
        final batches = int.parse(args[3]);
        final batchSize = int.parse(args[4]);
        final sleepBetweenMs = args.length > 5 ? int.parse(args[5]) : 0;
        await _writeTypedBatches(db, batches, batchSize, sleepBetweenMs);
        break;
      case 'hold':
        stdout.writeln('ready');
        await stdout.flush();
        // Keep the process (and therefore the redb file lock) alive until the
        // parent kills us. Dart timers are enough; nothing else is scheduled.
        await Future<void>.delayed(const Duration(days: 1));
        break;
      case 'compact':
        // Writes `batches` x `batchSize` rows of 4KiB values (so compaction is
        // slow enough to be reliably killed mid-flight), then starts an
        // in-place compaction. Prints `ready` after the writes and
        // `compacting` immediately before `maintenance.compact()` so the
        // parent can kill the OS process during the compaction window.
        final batches = int.parse(args[3]);
        final batchSize = int.parse(args[4]);
        await _writeFatBatches(db, batches, batchSize);
        stdout.writeln('ready');
        await stdout.flush();
        stdout.writeln('compacting');
        await stdout.flush();
        await db.maintenance.compact();
        stdout.writeln('compact-done');
        await stdout.flush();
        await Future<void>.delayed(const Duration(days: 1));
        break;
      default:
        throw ArgumentError('unknown mode: $mode');
    }
  } finally {
    await db.close();
  }
}

/// Writes [batches] x [batchSize] rows of ~4KiB values to table `items`.
Future<void> _writeFatBatches(
  DatabaseImpl db,
  int batches,
  int batchSize,
) async {
  const codec = DefaultWireCodec();
  final fat = codec.encode(<String, Object>{'payload': 'x' * 4000});
  for (var batch = 0; batch < batches; batch++) {
    final ops = <RawOp>[];
    for (var i = 0; i < batchSize; i++) {
      final key = codec.encode('k${batch}_$i');
      ops.add(RawPut('items', ByteKey(key), fat));
    }
    await db.engine.backend.applyBatch(ops);
    stdout.writeln('committed $batch');
    await stdout.flush();
  }
}

Future<void> _writeTypedBatches(
  DatabaseImpl db,
  int batches,
  int batchSize,
  int sleepBetweenMs,
) async {
  final items = db.collection<Map<String, Object?>>(
    'items',
    toRow: (m) => m,
    fromRow: (m) => Map<String, Object?>.from(m as Map),
    id: (m) => m['id'],
  );
  for (var batch = 0; batch < batches; batch++) {
    for (var i = 0; i < batchSize; i++) {
      await items.put({'id': 'k${batch}_$i', 'batch': batch, 'index': i});
    }
    stdout.writeln('committed $batch');
    await stdout.flush();
    if (sleepBetweenMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: sleepBetweenMs));
    }
  }
}

Future<void> _writeBatches(
  DatabaseImpl db,
  int batches,
  int batchSize,
  int sleepBetweenMs,
) async {
  const codec = DefaultWireCodec();
  for (var batch = 0; batch < batches; batch++) {
    final ops = <RawOp>[];
    for (var i = 0; i < batchSize; i++) {
      final key = codec.encode('k${batch}_$i');
      final value = codec.encode(<String, Object>{'batch': batch, 'index': i});
      ops.add(RawPut('items', ByteKey(key), value));
    }
    // One redb write transaction per batch: redb commits are atomic, so a
    // process kill can never leave a partial batch visible after reopen.
    await db.engine.backend.applyBatch(ops);
    stdout.writeln('committed $batch');
    await stdout.flush();
    if (sleepBetweenMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: sleepBetweenMs));
    }
  }
}
