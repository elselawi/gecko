#!/usr/bin/env dart
// Performance regression gate for gecko_db
//
// Runs the local benchmark harness in --json mode and compares every
// (backend, workload) against the pinned baseline in benchmark/baseline.json.
// Fails if any workload regressed beyond the tolerance on the mean (ms/op)
// or, when both the run and the baseline pin it, on p95 (p95MsPerOp).
//
// Usage (from the repo root):
//   dart run tool/perf_gate.dart                    # native file, 30% tolerance
//   dart run tool/perf_gate.dart --native           # accepted (only backend)
//   dart run tool/perf_gate.dart --indexed          # also gate indexed workloads
//   dart run tool/perf_gate.dart --rows=100000      # gate a non-default scale
//   dart run tool/perf_gate.dart --shape=wide       # non-default row shape
//   dart run tool/perf_gate.dart --tolerance=0.50   # relax the noise budget
//   dart run tool/perf_gate.dart --update           # refresh baseline.json
//
// Notes:
//   * Requires the release native artifact (cd rust && cargo build --release).
//   * Bench numbers are hardware/JIT dependent; the gate is a rough
//     regression check, not a precision instrument. The release checklist
//     runs the strict gate locally; --update is for intentional, reviewed
//     performance changes.
//   * The in-memory backend is no longer produced by the harness; `--mem`
//     fails loudly instead of silently running a different configuration.
//   * The baseline is schema-versioned and records the dataset configuration
//     (row count, shape, batch, selectivity, indexed rows) the numbers were
//     produced with. A run whose configuration differs from the baseline
//     fails rather than comparing apples to oranges; regenerate with --update
//     only for an intentional, reviewed scale/config change.
//   * A workload missing from the baseline is always a failure (the baseline
//     must cover every workload the harness emits).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final String baselinePath = 'benchmark${Platform.pathSeparator}baseline.json';
const double defaultTolerance = 0.30;

/// JSON schema version shared with benchmark/bench.dart. The gate refuses to
/// compare run output or a baseline with a different version.
const int schemaVersion = 2;

/// Keys of the dataset config that must match between a run and its baseline
/// for the comparison to be meaningful.
const List<String> datasetConfigKeys = [
  'seedRows',
  'shape',
  'batch',
  'distinctGroups',
  'indexed',
  'indexedRows',
  'changeLogMaxEntries',
];

/// Baseline mean (ms/op) at or above which p95 is a gated regression metric.
/// Below this, p95 is reported but advisory: microsecond-scale p95 is
/// dominated by scheduler/JIT noise (documented across the m4/m5 perf notes),
/// so gating it produces false failures.
const double p95GateMinMeanMs = 0.05;

/// One measured (backend, workload, ms/op) row. p95 is advisory (only
/// compared when the baseline pins it too).
class PerfRow {
  PerfRow(this.backend, this.workload, this.msPerOp, {this.p95MsPerOp});
  final String backend;
  final String workload;
  final double msPerOp;
  final double? p95MsPerOp;
}

/// A baseline row: pinned mean and (optionally) pinned p95.
class BaselineRow {
  BaselineRow(this.msPerOp, this.p95MsPerOp);
  final double msPerOp;
  final double? p95MsPerOp;
}

/// Parsed harness `--json` output.
class BenchDoc {
  BenchDoc(
    this.benchmark,
    this.platform,
    this.dart,
    this.generatedAt,
    this.schemaVersion,
    this.metadata,
    this.results,
  );

  final String benchmark;
  final String platform;
  final String dart;
  final String generatedAt;
  final int schemaVersion;
  final Map<String, Object?> metadata;
  final List<PerfRow> results;

  Map<String, Object?> get dataset =>
      (metadata['dataset'] as Map<String, Object?>?) ?? const {};
}

/// Parsed baseline file.
class BaselineFile {
  BaselineFile(this.schemaVersion, this.metadata, this.rows);
  final int? schemaVersion;
  final Map<String, Object?> metadata;
  final Map<String, BaselineRow> rows;

  Map<String, Object?> get dataset =>
      (metadata['dataset'] as Map<String, Object?>?) ?? const {};
}

/// Parses the harness's `--json` output into rows.
///
/// Exposed (and tested) separately so the gate's parsing logic is verified
/// without running the benchmark.
List<PerfRow> parseResults(String jsonText) =>
    _parseResults(jsonDecode(jsonText) as Map<String, Object?>);

List<PerfRow> _parseResults(Map<String, Object?> doc) => [
  for (final r in (doc['results'] as List))
    PerfRow(
      (r as Map)['backend'] as String,
      r['workload'] as String,
      (r['msPerOp'] as num).toDouble(),
      p95MsPerOp: (r['p95MsPerOp'] as num?)?.toDouble(),
    ),
];

/// Parses the full harness output document (schema version, metadata, rows).
BenchDoc parseBenchDoc(String jsonText) {
  final doc = jsonDecode(jsonText) as Map<String, Object?>;
  return BenchDoc(
    doc['benchmark'] as String? ?? 'unknown',
    doc['platform'] as String? ?? 'unknown',
    doc['dart'] as String? ?? 'unknown',
    doc['generatedAt'] as String? ?? '',
    (doc['schemaVersion'] as num?)?.toInt() ?? 1,
    (doc['metadata'] as Map<String, Object?>?) ?? const {},
    _parseResults(doc),
  );
}

/// Parses a baseline file into rows, preserving the schema version and the
/// dataset config it was generated with.
BaselineFile parseBaseline(String jsonText) {
  final doc = jsonDecode(jsonText) as Map<String, Object?>;
  return BaselineFile(
    (doc['schemaVersion'] as num?)?.toInt(),
    (doc['metadata'] as Map<String, Object?>?) ?? const {},
    {
      for (final r in (doc['results'] as List))
        '${(r as Map)['backend']}|${r['workload']}': BaselineRow(
          (r['msPerOp'] as num).toDouble(),
          (r['p95MsPerOp'] as num?)?.toDouble(),
        ),
    },
  );
}

/// Returns a human-readable error if [baseline] cannot be compared against,
/// or null when it is usable.
String? baselineUsable(BaselineFile baseline) {
  if (baseline.schemaVersion == null) {
    return 'baseline is unversioned; regenerate it with --update '
        '(current schema $schemaVersion).';
  }
  if (baseline.schemaVersion != schemaVersion) {
    return 'baseline schema ${baseline.schemaVersion} != harness schema '
        '$schemaVersion; regenerate it with --update.';
  }
  return null;
}

/// Returns a human-readable error when the run's dataset configuration
/// differs from the baseline's, or null when they match (or the baseline
/// carries no dataset config).
String? datasetMismatch(BenchDoc run, BaselineFile baseline) {
  for (final k in datasetConfigKeys) {
    if (!baseline.dataset.containsKey(k)) continue;
    if (run.dataset[k] != baseline.dataset[k]) {
      return 'dataset config mismatch on `$k`: baseline=${baseline.dataset[k]} '
          'run=${run.dataset[k]}. Run the gate with the same configuration '
          'as the baseline (or regenerate the baseline with --update only '
          'for an intentional, reviewed scale/config change).';
    }
  }
  return null;
}

Future<void> main(List<String> args) async {
  final update = args.contains('--update');
  var tolerance = defaultTolerance;
  // Pass-through flags forwarded to the harness so the gate can run (and
  // gate) a specific scale/indexed configuration.
  final passthrough = <String>[];
  for (final a in args) {
    if (a == '--mem') {
      stderr.writeln(
        'PERF GATE: the in-memory backend is no longer produced by the '
        'harness; --mem is unsupported. The gate benchmarks the native file '
        'backend only.',
      );
      exit(2);
    }
    if (a.startsWith('--tolerance=')) {
      tolerance = double.parse(a.substring('--tolerance='.length));
    } else if (a == '--native' || a == '--update') {
      // --native: only backend, accepted for compatibility.
      // --update: handled below.
    } else if (a == '--indexed' ||
        a.startsWith('--rows=') ||
        a.startsWith('--shape=') ||
        a.startsWith('--batch=') ||
        a.startsWith('--groups=') ||
        a.startsWith('--indexedRows=')) {
      passthrough.add(a);
    } else if (a.startsWith('--tolerance')) {
      // Malformed tolerance values fail in the parse below.
      tolerance = double.parse(a.substring('--tolerance='.length));
    } else {
      stderr.writeln('PERF GATE: unknown flag `$a`.');
      exit(2);
    }
  }

  final root = Directory.current.path;
  final baselineFile = File(p.join(root, baselinePath));

  // 1. Run the harness in JSON mode.
  final benchArgs = ['run', 'benchmark/bench.dart', '--json', ...passthrough];
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

  final BenchDoc doc;
  try {
    doc = parseBenchDoc(stdoutBuf.toString());
  } catch (e) {
    stderr.writeln('PERF GATE: could not parse benchmark JSON output: $e');
    stderr.writeln(stdoutBuf.toString());
    exit(1);
  }
  if (doc.schemaVersion != schemaVersion) {
    stderr.writeln(
      'PERF GATE FAILED: harness output schema ${doc.schemaVersion} != '
      'expected $schemaVersion. Regenerate the baseline with --update after '
      'reviewing the harness change.',
    );
    exit(1);
  }

  // 2. Update mode: write a schema-versioned baseline carrying the run's
  //    dataset config and p95, and stop. The baseline is a full snapshot of
  //    this run (single backend), so stale rows cannot linger.
  if (update) {
    final out = {
      'benchmark': doc.benchmark,
      'schemaVersion': schemaVersion,
      'platform': doc.platform,
      'dart': doc.dart,
      'generatedAt': doc.generatedAt,
      'tolerance': tolerance,
      'metadata': doc.metadata,
      'results': [
        for (final r in doc.results)
          {
            'backend': r.backend,
            'workload': r.workload,
            'msPerOp': r.msPerOp,
            'p95MsPerOp': r.p95MsPerOp,
          },
      ],
    };
    baselineFile.parent.createSync(recursive: true);
    baselineFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(out)}\n',
    );
    stdout.writeln(
      'PERF GATE: baseline updated at $baselinePath '
      '(${doc.results.length} workloads, schema $schemaVersion).',
    );
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
  final BaselineFile baseline;
  try {
    baseline = parseBaseline(baselineFile.readAsStringSync());
  } catch (e) {
    stderr.writeln('PERF GATE FAILED: could not parse baseline: $e');
    exit(1);
  }
  final baselineProblem = baselineUsable(baseline);
  if (baselineProblem != null) {
    stderr.writeln('PERF GATE FAILED: $baselineProblem');
    exit(1);
  }
  final configProblem = datasetMismatch(doc, baseline);
  if (configProblem != null) {
    stderr.writeln('PERF GATE FAILED: $configProblem');
    exit(1);
  }

  final (failed, report) = compare(doc.results, baseline.rows, tolerance);
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

/// Compares [results] against a pinned [baseline] (keyed
/// `backend|workload` → [BaselineRow]) with the given regression [tolerance].
///
/// Returns `(failed, humanReport)`. A workload absent from the baseline is a
/// failure; a baseline workload the harness no longer produces is also a
/// failure. Slower = higher ms/op; regressions on the mean (or on p95 when
/// both the run and the baseline pin it) beyond the tolerance fail.
(bool, String) compare(
  List<PerfRow> results,
  Map<String, BaselineRow> baseRows,
  double tolerance,
) {
  var failed = false;
  final report = StringBuffer();
  report.writeln(
    'PERF GATE — comparing (tolerance '
    '${(tolerance * 100).toStringAsFixed(0)}%):',
  );
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
    var rowFailed = false;
    final delta = (r.msPerOp - base.msPerOp) / base.msPerOp;
    if (delta > tolerance) rowFailed = true;
    var p95Note = '';
    if (base.p95MsPerOp != null && r.p95MsPerOp != null) {
      final p95Delta = (r.p95MsPerOp! - base.p95MsPerOp!) / base.p95MsPerOp!;
      p95Note = ' | p95 ${(p95Delta * 100).toStringAsFixed(1)}%';
      final gateP95 = base.msPerOp >= p95GateMinMeanMs;
      if (!gateP95) p95Note += ' (advisory)';
      if (gateP95 && p95Delta > tolerance) rowFailed = true;
    }
    report.writeln(
      '${(key).padRight(28)} ${base.msPerOp.toStringAsFixed(3).padLeft(12)} '
      '${r.msPerOp.toStringAsFixed(3).padLeft(12)} '
      '${(delta * 100).toStringAsFixed(1).padLeft(9)}%'
      '$p95Note  ${rowFailed ? 'FAIL' : 'ok'}',
    );
    if (rowFailed) failed = true;
  }
  // Every baseline workload of a backend that WAS measured must still exist
  // (a workload disappearing from the harness is a signal).
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
