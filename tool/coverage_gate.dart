#!/usr/bin/env dart
// Coverage gate for gecko_db packages.
//
// Measures line + branch coverage from `dart test --coverage=coverage` output
// via package:coverage's format_coverage, then fails the build if either
// metric drops below the configured threshold.
//
// Usage:
//   dart test --coverage=coverage
//   dart run tool/coverage_gate.dart [--threshold=95]
//
// Per Design Principle 5, the gate covers BOTH Dart packages and the Rust
// crate (enforced separately by cargo llvm-cov / grcov + lcov). This tool is
// the Dart side.

import 'dart:io';

import 'package:path/path.dart' as p;

const double defaultThreshold = 95.0;

Future<void> main(List<String> args) async {
  final parsed = _parseArgs(args);
  final threshold = parsed.threshold;
  final root = Directory.current;

  final List<File> lcovFiles = _resolveLcovFiles(parsed.lcovPaths, root.path);

  if (lcovFiles.isEmpty) {
    stderr.writeln('COVERAGE GATE FAILED: no .lcov files under coverage/.');
    exit(1);
  }

  final (line, branch, merged) = _computeCoverage(lcovFiles);

  stdout.writeln('Coverage results:');
  stdout.writeln('  line coverage:   $line%');
  stdout.writeln('  branch coverage: $branch%');
  stdout.writeln('  threshold:       $threshold%');
  stdout.writeln(
    '  merged from:     ${lcovFiles.length} lcov file(s) '
    '(${_fmtBytes(merged.linesFound)} lines)',
  );

  var failed = false;
  if (line < threshold) {
    stderr.writeln('  Line coverage $line% < $threshold%  [FAIL]');
    failed = true;
  }
  if (branch < threshold) {
    stderr.writeln('  Branch coverage $branch% < $threshold%  [FAIL]');
    failed = true;
  }

  if (failed) {
    stderr.writeln('COVERAGE GATE FAILED.');
    exit(1);
  }
  stdout.writeln('COVERAGE GATE PASSED.');
}

(double line, double branch, _Totals totals) _computeCoverage(
  List<File> lcovFiles,
) {
  var linesHit = 0;
  var linesFound = 0;
  var branchesHit = 0;
  var branchesFound = 0;

  for (final f in lcovFiles) {
    if (!f.existsSync()) {
      stderr.writeln('COVERAGE GATE: skipping missing file ${f.path}');
      continue;
    }
    final lines = f.readAsLinesSync();
    var record = false;
    for (final line in lines) {
      if (line.startsWith('SF:')) {
        record = true;
      } else if (line.startsWith('end_of_record')) {
        record = false;
      } else if (record) {
        if (line.startsWith('LF:')) {
          linesFound += int.parse(line.substring(3));
        } else if (line.startsWith('LH:')) {
          linesHit += int.parse(line.substring(3));
        } else if (line.startsWith('BRF:')) {
          branchesFound += int.parse(line.substring(4));
        } else if (line.startsWith('BRH:')) {
          branchesHit += int.parse(line.substring(4));
        }
      }
    }
  }

  final linePct = linesFound == 0
      ? 100.0
      : (linesHit / linesFound * 100).roundToDouble();
  final branchPct = branchesFound == 0
      ? 100.0
      : (branchesHit / branchesFound * 100).roundToDouble();
  return (
    linePct,
    branchPct,
    _Totals(
      linesFound: linesFound,
      linesHit: linesHit,
      branchesFound: branchesFound,
      branchesHit: branchesHit,
    ),
  );
}

String _fmtBytes(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

class _Totals {
  const _Totals({
    required this.linesFound,
    required this.linesHit,
    required this.branchesFound,
    required this.branchesHit,
  });
  final int linesFound;
  final int linesHit;
  final int branchesFound;
  final int branchesHit;
}

/// Resolves the set of lcov input files.
///
/// [explicitPaths] (when non-empty) are honored verbatim — each must exist and
/// is taken as-is, regardless of extension, so a real `lcov.info` produced by
/// `package:coverage`'s `format_coverage` is accepted.
///
/// With no explicit paths, every lcov-named file (`*.lcov` or `lcov.info`)
/// under `<root>/coverage/` is collected (merged, not averaged).
List<File> _resolveLcovFiles(List<String> explicitPaths, String rootPath) {
  if (explicitPaths.isNotEmpty) {
    final files = <File>[];
    for (final raw in explicitPaths) {
      final f = File(raw);
      if (!f.existsSync()) {
        stderr.writeln('COVERAGE GATE: skipping missing path "$raw"');
        continue;
      }
      if (f.statSync().type == FileSystemEntityType.file) {
        files.add(f);
      }
    }
    if (files.isEmpty) {
      stderr.writeln(
        'COVERAGE GATE FAILED: none of the given lcov paths exist.',
      );
      exit(1);
    }
    return files;
  }

  final coverageDir = p.join(rootPath, 'coverage');
  if (!Directory(coverageDir).existsSync()) {
    stderr.writeln('COVERAGE GATE FAILED: no coverage/ directory found.');
    stderr.writeln('Run `dart test --coverage=coverage` first.');
    exit(1);
  }
  final files = Directory(
    coverageDir,
  ).listSync(recursive: true).whereType<File>().where(_isLcovName).toList();
  if (files.isEmpty) {
    stderr.writeln('COVERAGE GATE FAILED: no lcov files under coverage/.');
    exit(1);
  }
  return files;
}

/// True for `*.lcov` or `lcov.info` filenames (the two common outputs of
/// coverage tooling).
bool _isLcovName(File f) {
  final name = p.basename(f.path).toLowerCase();
  return name.endsWith('.lcov') || name == 'lcov.info';
}

class _Args {
  const _Args({required this.threshold, required this.lcovPaths});
  final double threshold;
  final List<String> lcovPaths;
}

_Args _parseArgs(List<String> args) {
  var threshold = defaultThreshold;
  final paths = <String>[];
  for (final arg in args) {
    if (arg.startsWith('--threshold=')) {
      threshold = double.parse(arg.substring('--threshold='.length));
    } else if (!arg.startsWith('-')) {
      paths.add(arg);
    }
  }
  return _Args(threshold: threshold, lcovPaths: paths);
}
