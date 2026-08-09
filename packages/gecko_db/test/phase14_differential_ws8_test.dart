// Workstream 8 — randomized native/in-memory differential replay.
//
// Replays the identical seeded pseudo-random operation script against the
// in-memory engine and the native file-backed engine (redb via the worker
// isolate) using the shared differential harness, and asserts byte-equal
// snapshots, identical results/errors, identical LSNs, and identical change
// feeds after every step. A seed sweep catches backend-vs-backend semantic
// drift before it reaches 100k-record scale.
//
// The seed set is fixed so a regression reproduces; set `GECKO_LONG_TEST=1`
// (nightly) to sweep more seeds and more steps per seed.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/differential.dart';

/// Deterministic xorshift64 PRNG (identical behavior on every platform).
class SeededRandom {
  SeededRandom(this._state);
  int _state;

  int nextInt(int bound) {
    var x = _state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    _state = x;
    return (x * 0x2545F4914F6CDD1D) & 0x7FFFFFFFFFFFFFFF % bound;
  }
}

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

bool get _longMode => Platform.environment['GECKO_LONG_TEST'] == '1';
const int _shortSeeds = 3;
const int _shortSteps = 80;
const int _longSeeds = 12;
const int _longSteps = 400;
int get _seeds => _longMode ? _longSeeds : _shortSeeds;
int get _steps => _longMode ? _longSteps : _shortSteps;

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  for (var seed = 1; seed <= _seeds; seed++) {
    test('differential replay seed=$seed ($_steps steps)', () async {
      final tempDir = await Directory.systemTemp.createTemp('gecko-diff-');
      final nativeDbPath = '${tempDir.path}${Platform.pathSeparator}db.redb';
      final memoryEngine = RawEngine(InMemoryBackend());
      final nativeEngine = RawEngine(
        await NativeRawBackend.open(
          nativeDbPath,
          nativeLibraryPath: nativePath,
        ),
      );
      try {
        final steps = _generate(SeededRandom(seed * 0x85EBCA6B), _steps);
        final outcome = await runDifferential(
          memoryEngine,
          nativeEngine,
          steps,
        );
        expect(
          outcome.passed,
          isTrue,
          reason: 'seed=$seed diverged:\n${outcome.mismatches.join('\n')}',
        );
      } finally {
        await memoryEngine.dispose();
        await nativeEngine.dispose();
        await tempDir.delete(recursive: true);
      }
    });
  }
}

const List<String> _tables = ['t0', 't1', 't2', 't3'];

/// Generates [_steps] deterministic differential steps covering puts (all
/// modes), deletes, clears, gets, range scans, full scans, direct backend
/// batches, and MVCC snapshot reads.
List<DiffStep> _generate(SeededRandom random, int steps) {
  final existing = <String, List<int>>{for (final t in _tables) t: <int>[]};
  final stepsOut = <DiffStep>[];
  for (var i = 0; i < steps; i++) {
    final table = _tables[random.nextInt(_tables.length)];
    final roll = random.nextInt(16);
    if (roll < 5 || existing[table]!.isEmpty) {
      // Puts (mostly upsert; occasionally insertOnly/updateOnly).
      final key = random.nextInt(120);
      final value = List<int>.generate(
        1 + random.nextInt(16),
        (j) => random.nextInt(256),
      );
      final modeRoll = random.nextInt(10);
      final mode = modeRoll < 8
          ? RawWriteMode.upsert
          : modeRoll == 8
          ? RawWriteMode.insertOnly
          : RawWriteMode.updateOnly;
      stepsOut.add(DiffPut(table, [key], value, mode: mode));
      if (!existing[table]!.contains(key)) existing[table]!.add(key);
    } else if (roll < 7) {
      final key = existing[table]![random.nextInt(existing[table]!.length)];
      stepsOut.add(DiffDelete(table, [key]));
      existing[table]!.remove(key);
    } else if (roll < 8) {
      stepsOut.add(DiffClear(table));
      existing[table]!.clear();
    } else if (roll < 10) {
      stepsOut.add(DiffGet(table, [random.nextInt(120)]));
    } else if (roll < 12) {
      final start = random.nextInt(120);
      final end = start + random.nextInt(40);
      stepsOut.add(DiffRangeScan(table, start: [start], end: [end]));
    } else if (roll < 13) {
      stepsOut.add(DiffScanAll(table));
    } else if (roll < 15) {
      // Direct backend batch across one or two tables.
      final ops = <RawOp>[];
      final n = 1 + random.nextInt(4);
      for (var j = 0; j < n; j++) {
        final t = _tables[random.nextInt(_tables.length)];
        final key = random.nextInt(120);
        if (random.nextBoolean()) {
          ops.add(RawPut(t, ByteKey([key]), <int>[key, j]));
        } else {
          ops.add(RawDelete(t, ByteKey([key])));
        }
      }
      stepsOut.add(DiffBackendBatch(ops));
    } else {
      // MVCC snapshot-then-write differential.
      final readTable = _tables[random.nextInt(_tables.length)];
      final keys = <List<int>>[
        for (var j = 0; j < 3; j++) <int>[random.nextInt(120)],
      ];
      stepsOut.add(
        DiffMvccRead(
          ops: [
            RawPut(table, ByteKey([random.nextInt(120)]), <int>[1, 2, 3]),
          ],
          readTable: readTable,
          readKeys: keys,
        ),
      );
    }
  }
  return stepsOut;
}

extension on SeededRandom {
  bool nextBoolean() => nextInt(2) == 0;
}
