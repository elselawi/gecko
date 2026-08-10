// M12: single-command local release checklist.
//
// The repo uses RELEASE-ONLY CI (`.github/workflows/release-matrix.yml`): a
// manually-triggered workflow that builds + verifies platform artifacts on
// hardware the maintainer does not own (macOS runners, and iOS once the FRB
// plugin scaffold lands). It deliberately does NOT run quality gates — every
// gate below is a local step, run before a release in one command:
//
//     dart run tool/release_checklist.dart
//
// Flags:
//   --long            also run the WS8 heavy suites (randomized, differential,
//                     parallel, crash-injection, 200k-row, soak) with
//                     GECKO_LONG_TEST=1 (slow; crash-injection spawns OS
//                     processes — do not run it alongside other heavy tests)
//   --perf            also run the strict perf gate (machine-load sensitive)
//   --rust-coverage   also run `cargo llvm-cov` + the Rust coverage gate
//                     (requires cargo-llvm-cov)
//   --no-coverage     skip the (slow) Dart coverage collection + gate
//   --list            print the ordered step list and exit
//   --help            this help
//
// The checklist fails (exit 1) at the first failing step and prints the tail
// of the failing command's output.
library;

import 'dart:io';

/// One step of the release checklist.
class GateStep {
  const GateStep(
    this.label,
    this.command, {
    this.workingDirectory,
    this.env,
    this.setup,
  });

  /// Human-readable label printed before the step runs.
  final String label;

  /// The command to run (argv-style; the first element is the executable).
  final List<String> command;

  /// Optional working directory (relative paths are resolved against the repo
  /// root; null = the repo root).
  final String? workingDirectory;

  /// Optional environment overrides (e.g. GECKO_LONG_TEST=1).
  final Map<String, String>? env;

  /// Optional async setup that runs before the command — e.g. clearing stale
  /// coverage output that would otherwise be merged into this run.
  final Future<void> Function()? setup;
}

/// The repo root, resolved by walking up from the current working directory
/// until a directory containing both `tool/build_artifacts.dart` and
/// `packages/gecko_db` is found. This works both under `dart run` (from the
/// repo root) and under `dart test` (where `Platform.script` points at the
/// test runner, not this file).
String repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/tool/build_artifacts.dart').existsSync() &&
        Directory('${dir.path}/packages/gecko_db').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate the gecko repo root (no tool/build_artifacts.dart '
    'found in the current directory or any parent). Run the checklist from '
    'the repo root.',
  );
}

/// Every `tool/*_test.dart` file, sorted, as repo-root-relative paths.
/// (`dart test tool` alone does not work on this repo — tests must be
/// enumerated explicitly.)
List<String> toolTestFiles() {
  final dir = Directory('${repoRoot()}/tool');
  if (!dir.existsSync()) return const [];
  final names = dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((name) => name.endsWith('_test.dart'))
      .toList()
    ..sort();
  return [for (final name in names) 'tool/$name'];
}

/// Builds the ordered checklist. Required steps always run; optional blocks
/// (heavy / environment-sensitive) are appended only when their flag is set.
List<GateStep> buildSteps({
  bool long = false,
  bool perf = false,
  bool rustCoverage = false,
  bool coverage = true,
}) {
  final root = repoRoot();
  final tests = toolTestFiles();
  final steps = <GateStep>[
    GateStep(
      'Dart analyze (lib + test)',
      ['dart', 'analyze', 'packages/gecko_db/lib', 'packages/gecko_db/test'],
      workingDirectory: root,
    ),
    GateStep(
      'Full Dart test suite',
      ['dart', 'test', 'packages/gecko_db/test', '--reporter=compact'],
      workingDirectory: root,
    ),
    GateStep(
      'Tool tests (${tests.length} files)',
      ['dart', 'test', ...tests, '--reporter=compact'],
      workingDirectory: root,
    ),
    GateStep(
      'Offline lint',
      ['dart', 'run', 'tool/offline_lint.dart'],
      workingDirectory: root,
    ),
    GateStep(
      'Security review',
      ['dart', 'run', 'tool/security_review.dart'],
      workingDirectory: root,
    ),
    GateStep(
      'Traceability check',
      ['dart', 'run', 'tool/traceability_check.dart'],
      workingDirectory: root,
    ),
    GateStep(
      'API snapshot regenerated',
      ['dart', 'run', 'tool/api_snapshot.dart', 'tool/api_snapshot.txt'],
      workingDirectory: root,
    ),
    GateStep(
      'API snapshot clean (commit the change if intentional)',
      ['git', 'diff', '--exit-code', '--', 'tool/api_snapshot.txt'],
      workingDirectory: root,
    ),
    GateStep(
      'API contract gate',
      ['dart', 'run', 'tool/api_contract_gate.dart', '--base=HEAD'],
      workingDirectory: root,
    ),
    GateStep(
      'Bindings in sync (check-bindings; needs a clean tree)',
      ['dart', 'run', 'tool/build_artifacts.dart', 'check-bindings'],
      workingDirectory: root,
    ),
    GateStep(
      'Rust check',
      ['cargo', 'check', '--all-targets'],
      workingDirectory: '$root/rust',
    ),
    GateStep(
      'Rust tests',
      ['cargo', 'test'],
      workingDirectory: '$root/rust',
    ),
    GateStep(
      'Rust clippy (-D warnings)',
      ['cargo', 'clippy', '--all-targets', '--all-features', '--', '-D', 'warnings'],
      workingDirectory: '$root/rust',
    ),
  ];

  if (coverage) {
    steps.addAll([
      GateStep(
        'Coverage collection',
        [
          'dart',
          'test',
          'packages/gecko_db/test',
          '--coverage=packages/gecko_db/coverage',
        ],
        workingDirectory: root,
        // `dart test --coverage` appends per-isolate JSON and format_coverage
        // merges EVERY file in the dir — stale output from earlier runs would
        // dilute the gate. Start clean every time.
        setup: () async {
          final covDir = Directory('$root/packages/gecko_db/coverage');
          if (covDir.existsSync()) {
            await covDir.delete(recursive: true);
          }
          await covDir.create(recursive: true);
        },
      ),
      GateStep(
        'Coverage → lcov',
        [
          'dart',
          'run',
          'coverage:format_coverage',
          '--lcov',
          '--check-ignore',
          '--in=packages/gecko_db/coverage',
          '-o',
          'packages/gecko_db/coverage/lcov.info',
          '--report-on=packages/gecko_db/lib',
          '--ignore-files=**/native/generated/**',
        ],
        workingDirectory: root,
      ),
      GateStep(
        'Coverage gate (≥95% line / 100% branch)',
        [
          'dart',
          'run',
          'tool/coverage_gate.dart',
          'packages/gecko_db/coverage/lcov.info',
        ],
        workingDirectory: root,
      ),
    ]);
  }

  if (long) {
    steps.add(
      GateStep(
        'WS8 long suite (randomized/differential/parallel/crash/200k/soak)',
        [
          'dart',
          'test',
          'packages/gecko_db/test/phase14_randomized_ws8_test.dart',
          'packages/gecko_db/test/phase14_differential_ws8_test.dart',
          'packages/gecko_db/test/phase14_parallel_ws8_test.dart',
          'packages/gecko_db/test/phase14_crash_injection_ws8_test.dart',
          'packages/gecko_db/test/phase14_large_data_ws8_test.dart',
          'packages/gecko_db/test/phase14_soak_ws8_test.dart',
          '--reporter=compact',
        ],
        workingDirectory: root,
        env: const <String, String>{'GECKO_LONG_TEST': '1'},
      ),
    );
  }

  if (perf) {
    steps.add(
      GateStep(
        'Perf gate (strict, local)',
        ['dart', 'run', 'tool/perf_gate.dart'],
        workingDirectory: root,
      ),
    );
  }

  if (rustCoverage) {
    steps.addAll([
      GateStep(
        'Rust coverage (llvm-cov)',
        [
          'cargo',
          'llvm-cov',
          '--all-features',
          '--workspace',
          '--lcov',
          '--output-path',
          'coverage.lcov',
        ],
        workingDirectory: '$root/rust',
      ),
      GateStep(
        'Rust coverage gate',
        ['dart', 'run', 'tool/rust_coverage_gate.dart', 'rust/coverage.lcov'],
        workingDirectory: root,
      ),
    ]);
  }

  return steps;
}

Future<int> _runStep(GateStep step) async {
  if (step.setup != null) {
    try {
      await step.setup!();
    } catch (error) {
      stderr.writeln('    setup failed: $error');
      return 1;
    }
  }
  final result = await Process.run(
    step.command.first,
    step.command.skip(1).toList(),
    workingDirectory: step.workingDirectory,
    environment: step.env,
  );
  final out = '${result.stdout}${result.stderr}';
  if (result.exitCode != 0) {
    final lines = out.trim().split('\n');
    final tail = lines.length > 30 ? lines.sublist(lines.length - 30) : lines;
    stdout.writeln(tail.map((l) => '    | $l').join('\n'));
  }
  return result.exitCode;
}

Future<void> main(List<String> args) async {
  final long = args.contains('--long');
  final perf = args.contains('--perf');
  final rustCoverage = args.contains('--rust-coverage');
  final noCoverage = args.contains('--no-coverage');

  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(
      'Usage: dart run tool/release_checklist.dart [--long] [--perf] '
      '[--rust-coverage] [--no-coverage] [--list]',
    );
    return;
  }

  final steps = buildSteps(
    long: long,
    perf: perf,
    rustCoverage: rustCoverage,
    coverage: !noCoverage,
  );

  if (args.contains('--list')) {
    for (final (i, step) in steps.indexed) {
      stdout.writeln('[${i + 1}/${steps.length}] ${step.label}');
    }
    return;
  }

  stdout.writeln('gecko_db release checklist (${steps.length} steps)');
  GateStep? failedStep;
  var failedIndex = -1;
  for (final (i, step) in steps.indexed) {
    stdout.writeln('\n==> [${i + 1}/${steps.length}] ${step.label}');
    stdout.writeln('    \$ ${step.command.join(' ')}');
    final exit = await _runStep(step);
    if (exit == 0) {
      stdout.writeln('    ✓ passed');
      continue;
    }
    failedStep = step;
    failedIndex = i;
    stdout.writeln('    ✗ FAILED (exit $exit)');
    break;
  }

  stdout.writeln('');
  if (failedStep == null) {
    stdout.writeln(
      'ALL ${steps.length} CHECKLIST STEPS PASSED.\n'
      'Now trigger the release workflow: GitHub → Actions → release-matrix → '
      'Run workflow (manual), then bundle the uploaded artifacts into '
      'packages/gecko_db/lib/native/ and publish.',
    );
    exit(0);
  } else {
    stdout.writeln(
      'CHECKLIST FAILED at step ${failedIndex + 1} '
      '("${failedStep.label}"). Fix and re-run.',
    );
    exit(1);
  }
}
