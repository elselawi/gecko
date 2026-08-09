// Phase 13 / WS8 — perf gate instrumentation test.
//
// Verifies the gate's parsing and comparison logic WITHOUT running the
// benchmark (which needs the release native artifact and is slow): a JSON
// payload parses, a happy-path run passes, a deliberate regression fails, a
// workload missing from the baseline fails, and a baseline workload the
// harness no longer produces fails.
import 'dart:io';

import 'package:test/test.dart';

import 'package:path/path.dart' as p;

import 'perf_gate.dart';

String _jsonDoc(List<Map<String, Object?>> results) {
  final sb = StringBuffer()
    ..writeln('{')
    ..writeln('  "benchmark": "gecko_db_local_stopgap",')
    ..writeln('  "platform": "test",')
    ..writeln('  "dart": "3.10.8",')
    ..writeln('  "generatedAt": "2026-01-01T00:00:00Z",')
    ..writeln('  "results": [');
  for (var i = 0; i < results.length; i++) {
    final r = results[i];
    sb.writeln(
      '    {"backend": "${r['backend']}", "workload": "${r['workload']}", '
      '"msPerOp": ${r['msPerOp']}}${i < results.length - 1 ? ',' : ''}',
    );
  }
  sb.writeln('  ]');
  sb.writeln('}');
  return sb.toString();
}

void main() {
  test('--json output parses into rows', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
        {'backend': 'native file', 'workload': 'hotRead', 'msPerOp': 0.001},
      ]),
    );
    expect(rows, hasLength(2));
    expect(rows[0].backend, 'native file');
    expect(rows[0].workload, 'insert');
    expect(rows[0].msPerOp, 0.05);
  });

  test('happy-path run at or under baseline passes', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.06},
      ]),
    );
    final baseline = <String, double>{'native file|insert': 0.05};
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isFalse, reason: report);
    expect(report, isNot(contains('FAIL')));
  });

  test('deliberate regression beyond tolerance fails', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.5},
      ]),
    );
    final baseline = <String, double>{'native file|insert': 0.05};
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isTrue, reason: report);
    expect(report, contains('FAIL'));
  });

  test('workload absent from baseline fails; baseline workload missing from '
      'harness fails', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'brandNew', 'msPerOp': 0.01},
      ]),
    );
    final baseline = <String, double>{'native file|removedWorkload': 0.02};
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isTrue, reason: report);
    expect(report, contains('not in baseline'));
    expect(report, contains('no longer produced'));
  });

  test('gate source documents the regression rules', () {
    final source = p.join('tool', 'perf_gate.dart');
    final text = File(source).readAsStringSync();
    expect(text, contains('--update'));
    expect(text, contains('--tolerance'));
    expect(text, contains('PERF GATE PASSED'));
  });
}
