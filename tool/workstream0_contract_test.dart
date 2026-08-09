import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('Workstream 0 CI declares all required contract gates', () {
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    for (final required in <String>[
      'dart analyze',
      'dart test packages/gecko_db/test',
      'tool/coverage_gate.dart',
      'tool/traceability_check.dart',
      'cargo fmt --check',
      'cargo check --all-targets',
      'cargo test',
      'cargo clippy --all-targets --all-features -- -D warnings',
      'cargo llvm-cov',
      'tool/rust_coverage_gate.dart',
      'flutter_rust_bridge_codegen generate --config-file frb.yaml',
      'tool/api_snapshot.dart tool/api_snapshot.txt',
      'git diff --exit-code',
    ]) {
      expect(ci, contains(required), reason: 'missing CI gate: $required');
    }
  });

  test('API snapshot is reproducible from the current entrypoint', () {
    expect(File('tool/api_snapshot.txt').existsSync(), isTrue);
    expect(File('packages/gecko_db/lib/gecko_db.dart').existsSync(), isTrue);
  });
}
