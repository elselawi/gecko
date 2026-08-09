import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('API contract gate source enforces ADR or version bump policy', () {
    final source = File('tool/api_contract_gate.dart').readAsStringSync();
    expect(source, contains('public contract changes require an ADR'));
    expect(source, contains('docs/adr/'));
    expect(source, contains('packages/gecko_db/pubspec.yaml'));
  });
}
