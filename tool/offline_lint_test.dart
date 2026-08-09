import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('offline lint source documents the network and clock rules', () {
    final source = File('tool/offline_lint.dart').readAsStringSync();
    expect(source, contains('_networkPattern'));
    expect(source, contains('_clockPattern'));
    expect(source, contains('OFFLINE LINT PASSED'));
  });

  test('repo test sources contain no network or real-clock usage', () async {
    final proc = await Process.run(
      Platform.resolvedExecutable,
      ['run', 'tool/offline_lint.dart'],
    );
    expect(proc.exitCode, 0,
        reason: 'offline lint must pass on the tree:\n${proc.stdout}');
    expect((proc.stdout as String), contains('OFFLINE LINT PASSED'));
  });
}
