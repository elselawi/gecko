import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('security review source implements the hard rules', () {
    final source = File('tool/security_review.dart').readAsStringSync();
    expect(source, contains('secret-literal'));
    expect(source, contains('key-in-log'));
    expect(source, contains('_secretLiteral'));
    expect(source, contains('_keyInLog'));
  });

  test('repo has no hard secret-literal or key-logging findings', () async {
    final proc = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/security_review.dart',
    ]);
    final out = (proc.stdout as String).toLowerCase();
    expect(
      proc.exitCode,
      0,
      reason: 'security review must pass on the tree:\n${proc.stdout}',
    );
    expect(out, contains('security review passed'));
  });
}
