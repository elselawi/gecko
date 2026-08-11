import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('API contract gate source enforces the version bump policy', () {
    final source = File('tool/api_contract_gate.dart').readAsStringSync();
    expect(source, contains('require a '));
    expect(source, contains('version bump'));
    expect(source, contains('packages/gecko_db/pubspec.yaml'));
    expect(source, isNot(contains('docs/adr/')));
    expect(source, isNot(contains('ADR')));
  });
}
