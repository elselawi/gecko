// the local release checklist is the single source of the required
// quality gates (release-only CI does NOT run gates — it only builds, verifies,
// and uploads platform artifacts on manual trigger).
import 'dart:io';

import 'package:test/test.dart';

import 'release_checklist.dart';

void main() {
  test('the release checklist declares all required gates', () {
    final steps = buildSteps();
    expect(steps, isNotEmpty);
    final commands = steps.map((s) => s.command.join(' ')).join('\n');
    for (final required in <String>[
      'dart analyze',
      'dart test packages/gecko_db/test',
      'tool/coverage_gate.dart',
      'tool/traceability_check.dart',
      'tool/offline_lint.dart',
      'tool/security_review.dart',
      'tool/api_snapshot.dart tool/api_snapshot.txt',
      'git diff --exit-code -- tool/api_snapshot.txt',
      'tool/api_contract_gate.dart',
      'tool/build_artifacts.dart check-bindings',
      'cargo check --all-targets',
      'cargo test',
      'cargo clippy --all-targets --all-features -- -D warnings',
    ]) {
      expect(commands, contains(required), reason: 'missing gate: $required');
    }
  });

  test('the checklist enumerates every tool test explicitly', () {
    final files = toolTestFiles();
    expect(files, isNotEmpty);
    for (final f in files) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
  });

  test('optional blocks are added only when their flag is set', () {
    expect(buildSteps().where((s) => s.label.contains('long suite')), isEmpty);
    expect(
      buildSteps(long: true).where((s) => s.label.contains('long suite')),
      hasLength(1),
    );
    expect(buildSteps().where((s) => s.label.contains('Perf gate')), isEmpty);
    expect(
      buildSteps(perf: true).where((s) => s.label.contains('Perf gate')),
      hasLength(1),
    );
    expect(buildSteps(coverage: false).where((s) => s.label.contains('Coverage')),
        isEmpty);
  });

  test('required steps have unique, descriptive labels', () {
    final steps = buildSteps(coverage: false);
    final labels = steps.map((s) => s.label).toSet();
    expect(labels.length, steps.length);
  });
}
