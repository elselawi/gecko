// boundary micro-benchmark.
//
// Measures the per-layer latency of the gecko_db read path on the native
// (redb) backend, in strict order from cheapest to most expensive:
//
//   1. dartCall        — a plain Dart `async` function returning a value.
//                        Establishes the floor: event-loop + Future overhead.
//   2. isolateRoundTrip — caller isolate → SendPort → worker isolate →
//                        SendPort → caller, via `NativeWorkerClient`'s request/
//                        response protocol (operation: `commitSequence`, which
//                        does trivial Rust work — returning a counter — so the
//                        measurement isolates the isolate/port round trip).
//   3. frbCall         — a direct `NativeWorker` FRB call from the *calling*
//                        isolate (no worker isolate), via
//                        `compatibilityHandshake` — measures FRB marshalling +
//                        Rust string construction, no redb.
//   4. rustNoop        — `NativeWorker.commitSequence()` called directly (no
//                        worker isolate): a Rust function that reads an atomic
//                        counter and returns a BigInt. The cheapest "real" Rust
//                        work — the floor below any storage op.
//   5. redbGetMiss     — `worker.get_(table, key)` on an absent key: a redb
//                        point get with no payload, measuring the B-tree lookup
//                        + empty-result path.
//   6. redbGetHit      — `worker.get_(table, key)` on a present ~40-byte
//                        value: the real point-read storage cost.
//   7. rawGetCold      — the full `RawEngine.rawGet` (LRU miss → open MVCC
//                        snapshot → redb read → cache populate), on a key not
//                        in the LRU. This is the end-to-end Tier-3 read cost
//                        the query path pays per candidate row when cold.
//   8. rawGetHot       — `RawEngine.rawGet` on an LRU-resident key: the
//                        cache-hit path; only LRU + map copy, no backend.
//
// Run from the repo root:
//   dart run benchmark/boundary.dart            # table
//   dart run benchmark/boundary.dart --json     # machine-readable JSON
//
// The native backend needs the release artifact:
//   cd rust && cargo build --release
//
// Numbers are indicative and depend on hardware/JIT state — this is a
// breakdown for the roadmap, not a publishable marketing claim.
// `tool/perf_gate.dart` does NOT consume this harness (it is a breakdown, not
// a regression gate); `benchmark/bench.dart` remains the regression gate.
library;

import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/native/external_library_loader.dart'
    show resolveExternalLibrary;

const int _warmup = 200;
const int _ops = 2000;
const String _table = 'items';
const String _presentKey = 'present';
final List<int> _presentKeyBytes = const DefaultWireCodec().encode(_presentKey);
final List<int> _absentKeyBytes = const DefaultWireCodec().encode('absent');
final List<int> _valueBytes = const DefaultWireCodec().encode({
  'id': _presentKey,
  'num': 1,
  'group': 'g0',
});

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

class _Boundary {
  _Boundary(this.stage, this.microsPerOp);
  final String stage;
  final double microsPerOp;
  double get msPerOp => microsPerOp / 1000;
  double get opsPerSec => (1e6 / microsPerOp).roundToDouble();
}

Future<void> main(List<String> args) async {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);
  final emitJson = args.contains('--json');
  if (!File(nativePath).existsSync()) {
    stderr.writeln('Native artifact not found at $nativePath');
    stderr.writeln('Build it first: cd rust && cargo build --release');
    exitCode = 2;
    return;
  }

  final dir = await Directory.systemTemp.createTemp('gecko-boundary-');
  final dbPath = '${dir.path}${Platform.pathSeparator}boundary.redb';
  try {
    final results = await _run(dbPath, nativePath, emitJson);
    if (emitJson) {
      _printJson(results);
    } else {
      _printTable(results);
    }
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  }
}

Future<List<_Boundary>> _run(
  String dbPath,
  String nativePath,
  bool quiet,
) async {
  if (!quiet) {
    stdout.writeln('=== gecko_db boundary micro-benchmark () ===');
    stdout.writeln(
      'platform: ${Platform.operatingSystem} | '
      'dart ${Platform.version.split(' ').first}',
    );
    stdout.writeln(
      'warmup: $_warmup | ops: $_ops | table: $_table '
      '(1 present ~${_valueBytes.length}B value, 1 absent key)',
    );
    stdout.writeln();
  }

  // 1) Seed a present key into a fresh file, then CLOSE it so the file can
  //    be copied without contending for redb's OS file lock (Windows locks
  //    an open file against concurrent copy). The seeded copy feeds the
  //    direct FRB-only worker; the original is reopened RW below for the
  //    RawEngine.rawGet and worker-isolate round-trip probes.
  final seedDb = await DatabaseImpl.open(
    dbPath,
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      changeLogMaxEntries: 0,
    ),
  );
  await seedDb
      .collection<_Row>(_table, toRow: _rToRow, fromRow: _rFromRow, id: _rId)
      .put(_Row(_presentKey, 1, 'g0'));
  await seedDb.close();

  // 2) Copy the closed, seeded file for the read-only direct FRB worker.
  //    Taken while the file is closed so it never contends for redb's OS
  //    file lock (Windows locks an open file against concurrent copy).
  await RustLib.init(
    externalLibrary: await resolveExternalLibrary(
      nativeLibraryPath: nativePath,
    ),
  );
  final directPath = '$dbPath.ro.redb';
  await File(dbPath).copy(directPath);
  NativeWorker? directWorker;
  try {
    directWorker = await NativeWorker.open(path: directPath, readOnly: true);
  } catch (e) {
    if (!quiet) {
      stdout.writeln(
        '  (note: direct FRB worker open failed: $e; '
        'frbCall/rustNoop/redbGet layers will be skipped)',
      );
    }
  }

  // 3) Reopen the original RW for the worker-isolate (full Stack) path.
  final db = await DatabaseImpl.open(
    dbPath,
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      changeLogMaxEntries: 0,
    ),
  );
  final engine = db.engine;
  // The underlying native backend exposes the worker-isolate round-trip
  // probe (a trivial-Rust operation that isolates the isolate/port cost).
  final nativeBackend = engine.backend as NativeRawBackend;

  final results = <_Boundary>[];

  // 1. Plain Dart async call (the floor).
  Future<int> dartCall() async => 42;
  results.add(
    await _measure('dartCall', (_) async {
      await dartCall();
    }),
  );

  // 2. Isolate round trip (caller → worker isolate → caller), minimal Rust.
  results.add(
    await _measure('isolateRoundTrip', (_) async {
      await nativeBackend.commitSequenceProbe();
    }),
  );

  // 3. FRB call (direct, no isolate): handshake builds a Rust String.
  if (directWorker != null) {
    results.add(
      await _measure('frbCall', (_) async {
        await directWorker!.compatibilityHandshake();
      }),
    );
    // 4. Rust no-op (direct): reads an atomic counter, returns BigInt.
    results.add(
      await _measure('rustNoop', (_) async {
        await directWorker!.commitSequence();
      }),
    );
    // 5. redb point get on an absent key.
    results.add(
      await _measure('redbGetMiss', (_) async {
        await directWorker!.get_(table: _table, key: _absentKeyBytes);
      }),
    );
    // 6. redb point get on a present key.
    results.add(
      await _measure('redbGetHit', (_) async {
        await directWorker!.get_(table: _table, key: _presentKeyBytes);
      }),
    );
  }

  // 7. Full RawEngine.rawGet, cold (LRU flushed) — end-to-end Tier-3 read.
  //    Each iteration uses a distinct key so the LRU never hits.
  // Warm the present key once so rawGetHot measures a real hit.
  await engine.rawGet(_table, ByteKey(_presentKeyBytes));
  // For cold: cycle through N absent keys (each misses the LRU once the LRU
  // is smaller than N; we use far more distinct keys than the default LRU
  // capacity of 1024).
  results.add(
    await _measure('rawGetCold', (i) async {
      final k = ByteKey(const DefaultWireCodec().encode('cold$i'));
      await engine.rawGet(_table, k);
    }),
  );
  // 8. Full RawEngine.rawGet, hot (same LRU-resident key).
  results.add(
    await _measure('rawGetHot', (_) async {
      await engine.rawGet(_table, ByteKey(_presentKeyBytes));
    }),
  );

  await db.close();
  try {
    await directWorker?.close();
  } catch (_) {}
  return results;
}

class _Row {
  _Row(this.id, this.num, this.group);
  final String id;
  final int num;
  final String group;
}

Object? _rToRow(_Row r) => {'id': r.id, 'num': r.num, 'group': r.group};
_Row _rFromRow(Object? row) => _Row(
  (row as Map)['id'] as String,
  row['num'] as int,
  row['group'] as String,
);
Object? _rId(_Row r) => r.id;

Future<_Boundary> _measure(
  String stage,
  Future<void> Function(int i) fn, {
  int ops = _ops,
}) async {
  for (var i = 0; i < _warmup; i++) {
    await fn(i % 97);
  }
  final watch = Stopwatch()..start();
  for (var i = 0; i < ops; i++) {
    await fn(i);
  }
  watch.stop();
  return _Boundary(stage, watch.elapsedMicroseconds / ops);
}

String _fmtTime(double microsPerOp) => microsPerOp >= 1000
    ? '${(microsPerOp / 1000).toStringAsFixed(3)} ms'
    : '${microsPerOp.toStringAsFixed(3)} us';

void _printTable(List<_Boundary> rows) {
  final header =
      '${'stage'.padRight(18)} ${'per-op'.padLeft(12)} ${'ops/s'.padLeft(12)}';
  stdout.writeln(header);
  stdout.writeln('-' * header.length);
  for (final row in rows) {
    stdout.writeln(
      '${row.stage.padRight(18)} '
      '${_fmtTime(row.microsPerOp).padLeft(12)} '
      '${row.opsPerSec.toStringAsFixed(0).padLeft(12)}',
    );
  }
}

/// Machine-readable JSON (advisory; not consumed by tool/perf_gate.dart).
void _printJson(List<_Boundary> rows) {
  final doc = {
    'benchmark': 'gecko_db_boundary',
    'platform': Platform.operatingSystem,
    'dart': Platform.version.split(' ').first,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'results': [
      for (final r in rows)
        {
          'stage': r.stage,
          'microsPerOp': r.microsPerOp,
          'msPerOp': r.msPerOp,
          'opsPerSec': r.opsPerSec,
        },
    ],
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(doc));
}
