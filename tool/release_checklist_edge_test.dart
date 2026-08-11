// Audit-driven release-checklist edge tests (audited-test-gaps Part 4).
//
// Pins step ordering, optional-flag combinations, working-directory and
// environment propagation on individual steps, the coverage-cleanup setup
// hook, tool-test enumeration, and the `--list` CLI contract.

import 'dart:io';

import 'package:test/test.dart';

import 'release_checklist.dart';

void main() {
  test('required steps run in the documented order', () {
    final steps = buildSteps(coverage: false);
    final labels = steps.map((s) => s.label).toList();

    int indexOf(String needle) => labels.indexWhere(
      (label) => label.toLowerCase().contains(needle.toLowerCase()),
    );

    final order = <String>[
      'Dart analyze',
      'Full Dart test suite',
      'Tool tests',
      'Offline lint',
      'Security review',
      'Traceability check',
      'API snapshot regenerated',
      'API snapshot clean',
      'API contract gate',
      'Bindings in sync',
      'Rust check',
      'Rust tests',
      'Rust clippy',
    ];
    final positions = [for (final needle in order) indexOf(needle)];
    for (final position in positions) {
      expect(position, isNonNegative, reason: 'step must exist');
    }
    for (var i = 1; i < positions.length; i++) {
      expect(
        positions[i],
        greaterThan(positions[i - 1]),
        reason: '${order[i]} must run after ${order[i - 1]}',
      );
    }
  });

  test('optional flag combinations each add exactly their own blocks', () {
    int count(List<GateStep> steps, String needle) =>
        steps.where((s) => s.label.toLowerCase().contains(needle)).length;

    expect(count(buildSteps(), 'long suite'), 0);
    expect(count(buildSteps(long: true), 'long suite'), 1);

    expect(count(buildSteps(), 'perf gate'), 0);
    expect(count(buildSteps(perf: true), 'perf gate'), 1);

    expect(count(buildSteps(), 'rust coverage'), 0);
    expect(count(buildSteps(rustCoverage: true), 'rust coverage'), 2);

    // Combined flags add all of their blocks independently.
    final combined = buildSteps(long: true, perf: true, rustCoverage: true);
    expect(count(combined, 'long suite'), 1);
    expect(count(combined, 'perf gate'), 1);
    expect(count(combined, 'rust coverage'), 2);
  });

  test('coverage=false removes exactly the three coverage steps', () {
    final withCoverage = buildSteps();
    final without = buildSteps(coverage: false);

    int covCount(List<GateStep> steps) =>
        steps.where((s) => s.label.toLowerCase().contains('coverage')).length;

    expect(covCount(withCoverage), 3);
    expect(covCount(without), 0);
    expect(without.length, lessThan(withCoverage.length));
  });

  test('the long suite step carries GECKO_LONG_TEST and runs from the root',
      () {
    final long = buildSteps(long: true).firstWhere(
      (s) => s.label.toLowerCase().contains('long suite'),
    );
    expect(long.env, {'GECKO_LONG_TEST': '1'});
    expect(long.workingDirectory, repoRoot());
    expect(long.command.first, 'dart');
  });

  test('rust steps run from the rust working directory', () {
    final steps = buildSteps(coverage: false);
    final rustRoot = '${repoRoot()}${Platform.pathSeparator}rust';
    for (final step in steps.where((s) => s.command.first == 'cargo')) {
      // buildSteps uses a forward-slash join for the rust root.
      final normalized = (step.workingDirectory ?? '').replaceAll('\\', '/');
      expect(
        normalized,
        rustRoot.replaceAll('\\', '/'),
        reason: step.label,
      );
    }
  });

  test('the coverage collection step cleans stale output before running', () {
    final step = buildSteps().firstWhere(
      (s) => s.label.toLowerCase().contains('coverage collection'),
    );
    expect(step.setup, isNotNull);
    expect(
      step.command.any((c) => c.startsWith('--coverage=')),
      isTrue,
      reason: 'command must carry the coverage output flag',
    );
  });

  test('toolTestFiles returns sorted repo-root-relative paths that all exist',
      () {
    final files = toolTestFiles();
    expect(files, isNotEmpty);
    final sorted = [...files]..sort();
    expect(files, sorted, reason: 'must be sorted for stable command lines');
    for (final f in files) {
      expect(f, startsWith('tool/'));
      expect(f, endsWith('_test.dart'));
      expect(
        File('${repoRoot()}${Platform.pathSeparator}${f.replaceAll('/', Platform.pathSeparator)}')
            .existsSync(),
        isTrue,
        reason: f,
      );
    }
  });

  test('repoRoot resolves from the current directory to the repository root',
      () {
    final root = repoRoot();
    expect(
      File('$root${Platform.pathSeparator}tool'
          '${Platform.pathSeparator}build_artifacts.dart').existsSync(),
      isTrue,
    );
    expect(
      Directory('$root${Platform.pathSeparator}packages'
          '${Platform.pathSeparator}gecko_db').existsSync(),
      isTrue,
    );
  });

  test('every step has a non-empty label and a non-empty command', () {
    for (final step in buildSteps(coverage: false)) {
      expect(step.label.trim(), isNotEmpty);
      expect(step.command, isNotEmpty);
      expect(step.command.first.trim(), isNotEmpty);
    }
  });

  test('--list prints the ordered steps and exits 0', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      '${repoRoot()}${Platform.pathSeparator}tool'
      '${Platform.pathSeparator}release_checklist.dart',
      '--list',
      '--no-coverage',
    ], workingDirectory: repoRoot());
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final out = result.stdout as String;
    expect(out, contains('[1/'));
    expect(out, contains('Dart analyze'));
    expect(out, contains('Rust clippy'));
    // The --no-coverage flag must have removed the coverage steps.
    expect(out, isNot(contains('Coverage gate')));
  });
}
