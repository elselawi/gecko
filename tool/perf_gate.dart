#!/usr/bin/env dart
// Performance regression gate for gecko_db (Workstream 8).
//
// Runs the local benchmark harness in --json mode and compares every
// (backend, workload) against the pinned baseline in benchmark/baseline.json.
// Fails if any workload regressed beyond the tolerance (a ratio of ms/op,
// so "slower" = higher ms/op).
//
// Usage (from the repo root):
//   dart run tool/perf_gate.dart                  # both backends, 30% tolerance
//   dart run tool/perf_gate.dart --native         # native file only
//   dart run tool/perf_gate.dart --mem            # in-memory only
//   dart run tool/perf_gate.dart --tolerance=0.50 # relax the noise budget
//   dart run tool/perf_gate.dart --update         # refresh baseline.json
//
// Notes:
//   * Requires the release native artifact (cd rust && cargo build --release).
//   * Bench numbers are hardware/JIT dependent; the gate is a rough
//     regression check, not a precision instrument. CI uses a generous
//     tolerance; --update is for intentional, reviewed performance changes.
//   * A workload missing from the baseline is always a failure (the baseline
//     must cover every workload the harness emits).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final String baselinePath = 'benchmark${Platform.pathSeparator}baseline.json';
const double defaultTolerance = 0.30;

/// One measured (backend, workload, ms/op) row.
class PerfRow {
  PerfRow(this.backend, this.workload, this.msPerOp);
  final String backend;
  final String workload;
  final double msPerOp;
}

Future<void> main(List<String> args) async {
  final update = args.contains('--update');
  final runNative = !args.contains('--mem');
  final runMemory = !args.contains('--native');
  var tolerance = defaultTolerance;
  for (final a in args) {
    if (a.startsWith('--tolerance=')) {
      tolerance = double.parse(a.substring('--tolerance='.length));
    }
  }

  final root = Directory.current.path;
  final baselineFile = File(p.join(root, baselinePath));

  // 1. Run the harness in JSON mode.
  final benchArgs = ['run', 'benchmark/bench.dart', '--json'];
  if (runNative && !runMemory) benchArgs.add('--native');
  if (runMemory && !runNative) benchArgs.add('--mem');
  final proc = await Process.start(Platform.resolvedExecutable, benchArgs);
  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  proc.stdout.transform(utf8.decoder).listen(stdoutBuf.write);
  proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);
  final code = await proc.exitCode;
  if (code != 0) {
    stderr.writeln('PERF GATE: benchmark harness failed (exit $code).');
    stderr.writeln(stderrBuf.toString());
    exit(1);
  }

  final Map<String, Object?> doc;
  try {
    doc = jsonDecode(stdoutBuf.toString()) as Map<String, Object?>;
  } catch (e) {
    stderr.writeln('PERF GATE: could not parse benchmark JSON output: $e');
    stderr.writeln(stdoutBuf.toString());
    exit(1);
  }
  final results = parseResults(stdoutBuf.toString());

  // 2. Update mode: merge into (or create) the baseline and stop. Running
  // with one backend (`--native`/`--mem`) updates only that backend's rows
  // while keeping the other's, so the pinned file always covers everything.
  if (update) {
    final merged = <String, double>{};
    if (baselineFile.existsSync()) {
      final existing =
          jsonDecode(baselineFile.readAsStringSync()) as Map<String, Object?>;
      for (final r in (existing['results'] as List)) {
        merged['${(r as Map)['backend']}|${r['workload']}'] =
            (r['msPerOp'] as num).toDouble();
      }
    }
    for (final r in results) {
      merged['${r.backend}|${r.workload}'] = r.msPerOp;
    }
    final out = {
      'benchmark': doc['benchmark'],
      'platform': doc['platform'],
      'dart': doc['dart'],
      'generatedAt': doc['generatedAt'],
      'tolerance': tolerance,
      'results': [
        for (final entry in merged.entries)
          {
            'backend': entry.key.substring(0, entry.key.indexOf('|')),
            'workload': entry.key.substring(entry.key.indexOf('|') + 1),
            'msPerOp': entry.value,
          },
      ],
    };
    baselineFile.parent.createSync(recursive: true);
    baselineFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(out)}\n',
    );
    stdout.writeln('PERF GATE: baseline updated at $baselinePath '
        '(${merged.length} workloads).');
    return;
  }

  // 3. Compare against the pinned baseline.
  if (!baselineFile.existsSync()) {
    stderr.writeln(
      'PERF GATE FAILED: no baseline at $baselinePath. '
      'Run `dart run tool/perf_gate.dart --update` after reviewing the '
      'numbers.',
    );
    exit(1);
  }
  final baseline =
      jsonDecode(baselineFile.readAsStringSync()) as Map<String, Object?>;
  final baseRows = <String, double>{
    for (final r in (baseline['results'] as List))
      '${(r as Map)['backend']}|${r['workload']}': (r['msPerOp'] as num).toDouble(),
  };

  final (failed, report) = compare(results, baseRows, tolerance);
  stdout.writeln(report);
  if (failed) {
    stderr.writeln(
      'PERF GATE FAILED. Review the deltas; if the change is intentional, '
      'refresh the baseline with `dart run tool/perf_gate.dart --update`.',
    );
    exit(1);
  }
  stdout.writeln('PERF GATE PASSED.');
}

/// Parses the harness's `--json` output into rows.
///
/// Exposed (and tested) separately so the gate's parsing logic is verified
/// without running the benchmark.
List<PerfRow> parseResults(String jsonText) {
  final doc = jsonDecode(jsonText) as Map<String, Object?>;
  return [
    for (final r in (doc['results'] as List))
      PerfRow(
        (r as Map)['backend'] as String,
        r['workload'] as String,
        (r['msPerOp'] as num).toDouble(),
      ),
  ];
}

/// Compares [results] against a pinned [baseline] (keyed
/// `backend|workload` → ms/op) with the given regression [tolerance].
///
/// Returns `(failed, humanReport)`. A workload absent from the baseline is a
/// failure; a baseline workload the harness no longer produces is also a
/// failure. Slower = higher ms/op; regressions beyond the tolerance fail.
(bool, String) compare(
  List<PerfRow> results,
  Map<String, double> baseRows,
  double tolerance,
) {
  var failed = false;
  final report = StringBuffer();
  report.writeln('PERF GATE — comparing (tolerance '
      '${(tolerance * 100).toStringAsFixed(0)}%):');
  report.writeln(
    '${'workload'.padRight(28)} ${'baseline ms'.padLeft(12)} '
    '${'now ms'.padLeft(12)} ${'delta'.padLeft(10)}  verdict',
  );
  report.writeln('-' * 78);
  for (final r in results) {
    final key = '${r.backend}|${r.workload}';
    final base = baseRows[key];
    if (base == null) {
      report.writeln(
        '${key.padRight(28)} ${''.padLeft(12)} '
        '${r.msPerOp.toStringAsFixed(3).padLeft(12)} '
        '${'NEW'.padLeft(10)}  FAIL (not in baseline)',
      );
      failed = true;
      continue;
    }
    final delta = (r.msPerOp - base) / base;
    final regressed = delta > tolerance;
    report.writeln(
      '${(key).padRight(28)} ${base.toStringAsFixed(3).padLeft(12)} '
      '${r.msPerOp.toStringAsFixed(3).padLeft(12)} '
      '${(delta * 100).toStringAsFixed(1).padLeft(9)}% '
      '${regressed ? 'FAIL' : 'ok'}',
    );
    if (regressed) failed = true;
  }
  // Every baseline workload of a backend that WAS measured must still exist
  // (a workload disappearing from the harness is a signal). Baselines of
  // backends not measured in this run (e.g. `--native` only) are skipped.
  final producedBackends = results.map((r) => r.backend).toSet();
  for (final key in baseRows.keys) {
    final backend = key.substring(0, key.indexOf('|'));
    if (!producedBackends.contains(backend)) continue;
    if (!results.any((r) => '${r.backend}|${r.workload}' == key)) {
      report.writeln('$key no longer produced by the harness — check.');
      failed = true;
    }
  }
  return (failed, report.toString());
}
