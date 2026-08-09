import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Dart and Rust coverage gates reject under-covered LCOV', () async {
    final root = await Directory.systemTemp.createTemp('gecko-coverage-gate-');
    final underCovered = File('${root.path}${Platform.pathSeparator}under.lcov')
      ..writeAsStringSync(_lcov(linesHit: 1, branchesHit: 1));
    final covered = File('${root.path}${Platform.pathSeparator}covered.lcov')
      ..writeAsStringSync(_lcov(linesHit: 2, branchesHit: 2));

    try {
      final dartUnder = await _runGate('tool/coverage_gate.dart', underCovered);
      final dartCovered = await _runGate('tool/coverage_gate.dart', covered);
      final rustUnder = await _runGate(
        'tool/rust_coverage_gate.dart',
        underCovered,
      );
      final rustCovered = await _runGate(
        'tool/rust_coverage_gate.dart',
        covered,
      );

      expect(dartUnder.exitCode, isNonZero);
      expect(dartCovered.exitCode, 0);
      expect(rustUnder.exitCode, isNonZero);
      expect(rustCovered.exitCode, 0);
    } finally {
      await root.delete(recursive: true);
    }
  });
}

Future<ProcessResult> _runGate(String script, File lcov) => Process.run(
  Platform.resolvedExecutable,
  ['run', script, '--threshold=95', lcov.path],
  workingDirectory: Directory.current.path,
);

String _lcov({required int linesHit, required int branchesHit}) =>
    '''
TN:
SF:fixture.rs
DA:1,1
DA:2,${linesHit == 2 ? 1 : 0}
LF:2
LH:$linesHit
BRDA:1,0,0,${branchesHit == 2 ? 1 : 0}
BRDA:1,0,1,${branchesHit == 2 ? 1 : 0}
BRF:2
BRH:$branchesHit
end_of_record
''';
