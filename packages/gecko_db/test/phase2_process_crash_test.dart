import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart'
    show
        geckoChangeLogTable,
        geckoLsnKey,
        geckoSyncMetaTable,
        geckoSyncStateTable;
import 'package:test/test.dart';

/// Path of the monorepo root (parent of `packages/gecko_db` when tests run
/// from the package directory, or the current directory from the root).
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

/// Spawns the helper as a separate OS process running from the repo root so
/// that `package:gecko_db` resolves through the root package config.
Future<Process> _spawnHelper(List<String> args, String root) {
  return Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/native_process_helper.dart', ...args],
    workingDirectory: root,
    mode: ProcessStartMode.normal,
  );
}

/// Reads `committed <n>` markers from the helper's stdout, completing when
/// [stopAfter] has been committed, and tracking every observed marker.
StreamSubscription<String> _trackCommitted(
  Process process,
  int stopAfter,
  Completer<void> done,
  List<int> committed,
) {
  return process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line.startsWith('committed ')) {
          final n = int.parse(line.substring('committed '.length));
          committed.add(n);
          if (n == stopAfter && !done.isCompleted) done.complete();
        }
      });
}

/// Reads `ready` from the helper's stdout (hold mode).
Future<void> _waitForReady(Process process) async {
  final ready = Completer<void>();
  final sub = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == 'ready' && !ready.isCompleted) ready.complete();
      });
  try {
    await ready.future.timeout(const Duration(seconds: 60));
  } finally {
    await sub.cancel();
  }
}

Future<Map<String, Map<String, Object>>> _readItems(DatabaseImpl db) async {
  const codec = DefaultWireCodec();
  final entries = await db.engine.rawScanAll('items');
  return {
    for (final entry in entries)
      codec.decode(entry.key.bytes) as String:
          (codec.decode(entry.value!) as Map).cast<String, Object>(),
  };
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  Future<(String, Directory)> freshDb() async {
    final dir = await Directory.systemTemp.createTemp('gecko-proc-');
    final path = '${dir.path}${Platform.pathSeparator}database.redb';
    return (path, dir);
  }

  Future<DatabaseImpl> reopen(String path, {bool readOnly = false}) =>
      DatabaseImpl.open(
        path,
        useInMemory: false,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          readOnly: readOnly,
        ),
      );

  group('process-level crash recovery', () {
    test(
      'committed batches survive a hard kill; the in-flight batch is absent',
      () async {
        final (path, dir) = await freshDb();
        final committed = <int>[];
        final reached = Completer<void>();
        final process = await _spawnHelper([
          'write',
          path,
          nativePath,
          '6',
          '2000',
          '500',
        ], root);
        final sub = _trackCommitted(process, 3, reached, committed);
        try {
          await reached.future.timeout(const Duration(seconds: 90));
          // The helper sleeps 500ms between batches, so the kill lands while
          // it is idle: batches 0..3 are durably committed, batch 4 never
          // started.
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 30));
          await sub.cancel();

          final db = await reopen(path);
          try {
            final items = await _readItems(db);
            for (var b = 0; b <= 3; b++) {
              for (var i = 0; i < 2000; i++) {
                final value = items['k${b}_$i'];
                expect(
                  value,
                  isNotNull,
                  reason: 'committed batch $b key $i must survive a kill',
                );
                expect(value!['batch'], b);
                expect(value['index'], i);
              }
            }
            for (var b = 4; b < 6; b++) {
              for (var i = 0; i < 2000; i++) {
                expect(
                  items.containsKey('k${b}_$i'),
                  isFalse,
                  reason: 'batch $b was never committed before the kill',
                );
              }
            }
          } finally {
            await db.close();
          }
        } finally {
          await sub.cancel();
          await dir.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'no partial batch is visible after a kill during an in-flight batch',
      () async {
        final (path, dir) = await freshDb();
        final committed = <int>[];
        final reached = Completer<void>();
        // Large batch: the kill is delivered while batch 4 is mid-commit.
        final process = await _spawnHelper([
          'write',
          path,
          nativePath,
          '6',
          '50000',
          '0',
        ], root);
        final sub = _trackCommitted(process, 3, reached, committed);
        try {
          await reached.future.timeout(const Duration(seconds: 90));
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 30));
          await sub.cancel();

          final db = await reopen(path);
          try {
            final items = await _readItems(db);
            // All durably committed batches are fully present.
            for (var b = 0; b <= 3; b++) {
              final present = [
                for (var i = 0; i < 50000; i++)
                  if (items.containsKey('k${b}_$i')) i,
              ];
              expect(
                present.length,
                50000,
                reason: 'committed batch $b must be fully present',
              );
            }
            // The batch in flight when we killed is atomic: all or nothing.
            final inFlight = [
              for (var i = 0; i < 50000; i++)
                if (items.containsKey('k4_$i')) i,
            ];
            expect(
              inFlight.isEmpty || inFlight.length == 50000,
              isTrue,
              reason:
                  'redb must never expose a partially committed batch '
                  '(found ${inFlight.length}/50000 keys of batch 4)',
            );
            // Later batches were never reached.
            for (var b = 5; b < 6; b++) {
              for (var i = 0; i < 50000; i++) {
                expect(
                  items.containsKey('k${b}_$i'),
                  isFalse,
                  reason: 'batch $b must be absent',
                );
              }
            }
          } finally {
            await db.close();
          }
        } finally {
          await sub.cancel();
          await dir.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'user data, change log, sync state, and LSN commit atomically together',
      () async {
        // The typed collection path writes user row + change-log record +
        // sync-state record + LSN in a single redb write transaction. A hard
        // process kill must never leave metadata for a partial batch behind.
        final (path, dir) = await freshDb();
        final committed = <int>[];
        final reached = Completer<void>();
        final process = await _spawnHelper([
          'typed',
          path,
          nativePath,
          '6',
          '200',
          '500',
        ], root);
        final sub = _trackCommitted(process, 3, reached, committed);
        try {
          await reached.future.timeout(const Duration(seconds: 90));
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 30));
          await sub.cancel();

          final db = await reopen(path);
          try {
            const codec = DefaultWireCodec();
            final items = await _readItems(db);
            for (var b = 0; b <= 3; b++) {
              for (var i = 0; i < 200; i++) {
                expect(
                  items.containsKey('k${b}_$i'),
                  isTrue,
                  reason: 'committed typed batch $b key $i must survive a kill',
                );
              }
            }
            for (var b = 4; b < 6; b++) {
              for (var i = 0; i < 200; i++) {
                expect(
                  items.containsKey('k${b}_$i'),
                  isFalse,
                  reason: 'batch $b was never committed before the kill',
                );
              }
            }

            // Change log mirrors the committed rows exactly: one entry per
            // committed row, never an entry for a row the kill rolled back.
            final changeLogIds = <String>{};
            for (final entry in await db.engine.rawScanAll(
              geckoChangeLogTable,
            )) {
              final record = (codec.decode(entry.value!) as Map)
                  .cast<String, Object?>();
              changeLogIds.add(record['recordId']! as String);
            }
            expect(
              changeLogIds.length,
              4 * 200,
              reason:
                  'exactly one change-log record per committed row; the '
                  'partial batch must not leave orphaned change-log entries',
            );

            // Sync-state table mirrors the committed rows exactly as well.
            final syncStateIds = <String>{};
            for (final entry in await db.engine.rawScanAll(
              geckoSyncStateTable,
            )) {
              final record = (codec.decode(entry.value!) as Map)
                  .cast<String, Object?>();
              syncStateIds.add(record['recordId']! as String);
            }
            expect(syncStateIds.length, 4 * 200, reason: 'same for sync state');

            // LSN continuity: exactly one LSN per committed row; the partial
            // batch must not have consumed an LSN.
            final lsnRaw = await db.engine.rawGet(
              geckoSyncMetaTable,
              ByteKey(codec.encode(geckoLsnKey)),
            );
            expect(lsnRaw, isNotNull);
            expect(
              codec.decode(lsnRaw!) as int,
              4 * 200,
              reason:
                  'the persisted LSN must equal the committed-row count and '
                  'survive the kill',
            );
          } finally {
            await db.close();
          }
        } finally {
          await sub.cancel();
          await dir.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });

  group('cross-process database lock', () {
    test(
      'a second process opening a held database gets a typed lock error',
      () async {
        final (path, dir) = await freshDb();
        // First, create the database file from this process so the helper and
        // the asserting open see an existing store.
        final seed = await reopen(path);
        await seed.close();

        // Helper process opens the database and holds the redb file lock.
        final holder = await _spawnHelper(['hold', path, nativePath], root);
        var holderKilled = false;
        try {
          await _waitForReady(holder);

          // A second open in THIS process must fail with the typed
          // cross-process lock error (not a silent second writer).
          await expectLater(
            reopen(path),
            throwsA(
              isA<GeckoError>().having(
                (e) => e.type,
                'type',
                GeckoErrorType.databaseLocked,
              ),
            ),
          );

          // The lock is released when the holder dies; reopen then succeeds.
          holder.kill(ProcessSignal.sigkill);
          await holder.exitCode.timeout(const Duration(seconds: 30));

          final db = await reopen(path);
          await db.close();
          holderKilled = true;
        } finally {
          if (!holderKilled) {
            // Ensure the holder process is always cleaned up, even when an
            // assertion above fails before the explicit kill.
            holder.kill(ProcessSignal.sigkill);
            try {
              await holder.exitCode.timeout(const Duration(seconds: 10));
            } catch (_) {}
          }
          await dir.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
