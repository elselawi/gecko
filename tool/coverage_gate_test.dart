import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('coverage gate source documents the threshold and lcov formats', () {
    final source = File('tool/coverage_gate.dart').readAsStringSync();
    expect(source, contains('defaultThreshold = 95.0'));
    expect(source, contains("name == 'lcov.info'"));
    expect(source, contains('BRF:'));
    expect(source, contains('BRH:'));
  });
}
