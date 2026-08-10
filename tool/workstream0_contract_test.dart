import 'dart:io';

import 'package:test/test.dart';

import 'release_checklist.dart';

void main() {
  test('Workstream 0 declares all required contract gates', () {
    // M12: the repo uses release-only CI (build/verify/upload of platform
    // artifacts on manual trigger) and does NOT run gates remotely. The
    // required gates are enforced by the single-command local release
    // checklist (`dart run tool/release_checklist.dart`).
    final steps = buildSteps();
    final commands = steps.map((s) => s.command.join(' ')).join('\n');
    for (final required in <String>[
      'dart analyze',
      'dart test packages/gecko_db/test',
      'tool/coverage_gate.dart',
      'tool/traceability_check.dart',
      'cargo check --all-targets',
      'cargo test',
      'cargo clippy --all-targets --all-features -- -D warnings',
      'tool/api_snapshot.dart tool/api_snapshot.txt',
      'git diff --exit-code -- tool/api_snapshot.txt',
      'tool/build_artifacts.dart check-bindings',
    ]) {
      expect(commands, contains(required), reason: 'missing gate: $required');
    }
  });

  test('API snapshot is reproducible from the current entrypoint', () {
    expect(File('tool/api_snapshot.txt').existsSync(), isTrue);
    expect(File('packages/gecko_db/lib/gecko_db.dart').existsSync(), isTrue);
  });
}
