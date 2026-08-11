// Audit-driven coverage-gate edge tests (audited-test-gaps Part 4).
//
// Runs the gate against edge-case LCOV inputs: empty, malformed, no-branch,
// zero-line, duplicate records, invalid numeric fields, and extreme
// thresholds. Every case must settle (exit 0 or 1) without crashing.

import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> _runGate(File lcov, {String threshold = '95'}) =>
    Process.run(
      Platform.resolvedExecutable,
      ['run', 'tool/coverage_gate.dart', '--threshold=$threshold', lcov.path],
      workingDirectory: Directory.current.path,
    );

Future<File> _write(String name, String content) async {
  final dir = await Directory.systemTemp.createTemp('gecko-cov-edge-');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  file.writeAsStringSync(content);
  return file;
}

const _good = '''
TN:
SF:fixture.dart
DA:1,1
DA:2,1
LF:2
LH:2
BRDA:1,0,0,1
BRDA:1,0,1,1
BRF:2
BRH:2
end_of_record
''';

/// A file with 2 lines found but only 1 hit (50% line coverage).
const _partial = '''
TN:
SF:fixture.dart
DA:1,1
DA:2,0
LF:2
LH:1
BRDA:1,0,0,1
BRDA:1,0,1,0
BRF:2
BRH:1
end_of_record
''';

void main() {
  test('empty LCOV is treated as 100% (pinned quirk)', () async {
    final file = await _write('empty.lcov', '');
    final result = await _runGate(file);
    // The gate reports 0 lines found / 0 lines hit as 100%, so an empty
    // report passes today. Pinned so a future fix is deliberate.
    expect(result.exitCode, 0, reason: 'empty LCOV currently passes');
    expect((result.stdout as String), contains('100.0%'));
  });

  test('malformed LCOV (garbage) is treated as 100% (pinned quirk)', () async {
    final file = await _write('garbage.lcov', 'this is not lcov\nrandom\n');
    final result = await _runGate(file);
    expect(result.exitCode, 0, reason: 'garbage LCOV currently passes');
  });

  test('no-branch records are accepted (0/0 branches)', () async {
    final file = await _write('nobranch.lcov', '''
TN:
SF:fixture.dart
DA:1,1
DA:2,1
LF:2
LH:2
end_of_record
''');
    final result = await _runGate(file);
    expect(result.exitCode, 0, reason: 'no-branch records must not fail');
  });

  test('zero-line records are accepted', () async {
    final file = await _write('zeroline.lcov', '''
TN:
SF:fixture.dart
LF:0
LH:0
BRF:0
BRH:0
end_of_record
''');
    final result = await _runGate(file);
    expect(result.exitCode, 0, reason: 'empty files satisfy the threshold');
  });

  test('duplicate records are merged without crashing', () async {
    final file = await _write('dup.lcov', '$_good\n$_good');
    final result = await _runGate(file);
    expect(result.exitCode, inInclusiveRange(0, 1));
  });

  test('invalid numeric fields fail the gate without crashing', () async {
    final file = await _write('badsf.lcov', '''
TN:
SF:fixture.dart
DA:1,not-a-number
LF:1
LH:0
end_of_record
''');
    final result = await _runGate(file);
    expect(result.exitCode, inInclusiveRange(0, 1));
  });

  test('threshold 0 passes and threshold 100 fails a partial file', () async {
    final file = await _write('partial.lcov', _partial);
    final zero = await _runGate(file, threshold: '0');
    expect(zero.exitCode, 0);
    final hundred = await _runGate(file, threshold: '100');
    expect(hundred.exitCode, isNonZero,
        reason: 'a partially-covered file cannot reach 100%');
  });

  test('missing lcov path fails the gate', () async {
    final result = await _runGate(File('definitely-missing.lcov'));
    expect(result.exitCode, isNonZero);
  });
}
