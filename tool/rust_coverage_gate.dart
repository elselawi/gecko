#!/usr/bin/env dart
// Rust LCOV coverage gate for gecko_db_rust.
//
// Usage:
//   dart run tool/rust_coverage_gate.dart rust/coverage.lcov
//   dart run tool/rust_coverage_gate.dart --threshold=95 rust/coverage.lcov

import 'dart:io';

const double defaultThreshold = 95.0;

void main(List<String> args) {
  var threshold = defaultThreshold;
  String? path;
  for (final arg in args) {
    if (arg.startsWith('--threshold=')) {
      threshold = double.parse(arg.substring('--threshold='.length));
    } else if (!arg.startsWith('-')) {
      path = arg;
    }
  }

  if (path == null) {
    stderr.writeln(
      'Usage: dart run tool/rust_coverage_gate.dart [--threshold=95] <lcov>',
    );
    exitCode = 2;
    return;
  }

  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('RUST COVERAGE GATE FAILED: missing LCOV file ${file.path}');
    exitCode = 1;
    return;
  }

  var linesFound = 0;
  var linesHit = 0;
  var branchesFound = 0;
  var branchesHit = 0;
  var inRecord = false;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      inRecord = true;
    } else if (line == 'end_of_record') {
      inRecord = false;
    } else if (inRecord) {
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

  final lineCoverage = linesFound == 0 ? 100.0 : linesHit / linesFound * 100;
  final branchCoverage = branchesFound == 0
      ? 100.0
      : branchesHit / branchesFound * 100;
  stdout.writeln('Rust coverage results:');
  stdout.writeln('  line coverage:   ${lineCoverage.toStringAsFixed(2)}%');
  stdout.writeln('  branch coverage: ${branchCoverage.toStringAsFixed(2)}%');
  stdout.writeln('  threshold:       ${threshold.toStringAsFixed(2)}%');

  if (lineCoverage < threshold || branchCoverage < threshold) {
    stderr.writeln('RUST COVERAGE GATE FAILED.');
    exitCode = 1;
  } else {
    stdout.writeln('RUST COVERAGE GATE PASSED.');
  }
}
