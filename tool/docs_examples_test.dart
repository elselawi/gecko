// documentation and example drift guards.
//
// 1. Every `dart run <path>` referenced in the docs (README, AGENTS,
//    Copilot instructions, examples/README) must point at a real file.
// 2. Every example under examples/ must be referenced by the docs or covered
//    by examples_test.dart (so an example can never silently rot).
// 3. The runnable examples actually run (`dart run`).
// 4. The README must link the key consumer/developer references (SECURITY,
//    CHANGELOG, AGENTS, examples) so they can be found (prevents doc drift).
// 5. The required release docs exist (README, AGENTS, Copilot instructions,
//    SECURITY, CHANGELOG, examples/README, traceability checker).
import 'dart:io';

import 'package:test/test.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

/// The docs that must reference every runnable target and every example.
List<String> _docFiles(String root) => [
      'README.md',
      'AGENTS.md',
      '.github/copilot-instructions.md',
      'examples/README.md',
    ]
        .where(
          (name) => File('$root${Platform.pathSeparator}$name').existsSync(),
        )
        .toList();

List<String> _dartRunTargets(String text) {
  final regex = RegExp(r'dart run ([A-Za-z0-9_./\\-]+\.dart)');
  return [for (final m in regex.allMatches(text)) m.group(1)!];
}

/// Resolves a `dart run <target>` from the docs. Benchmark targets run from
/// the benchmark package (`cd benchmark && dart run ...`), so a bare name
/// that is not at the repo root may live under benchmark/.
bool _targetExists(String root, String target) {
  final direct =
      '$root${Platform.pathSeparator}${target.replaceAll('/', Platform.pathSeparator)}';
  if (File(direct).existsSync()) return true;
  final benchmarkFallback =
      '$root${Platform.pathSeparator}benchmark'
      '${Platform.pathSeparator}${target.replaceAll('/', Platform.pathSeparator)}';
  return File(benchmarkFallback).existsSync();
}

void main() {
  final root = _repoRoot();

  test('every `dart run <file>` referenced in docs points at a real file', () {
    final missing = <String>[];
    for (final doc in _docFiles(root)) {
      final path =
          '$root${Platform.pathSeparator}${doc.replaceAll('/', Platform.pathSeparator)}';
      final text = File(path).readAsStringSync();
      for (final target in _dartRunTargets(text)) {
        if (!_targetExists(root, target)) missing.add('$doc -> $target');
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'docs reference non-existent run targets: $missing',
    );
  });

  test('every example is referenced by docs or covered by a test', () {
    final examplesDir = '$root${Platform.pathSeparator}examples';
    final exampleFiles = Directory(examplesDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.uri.pathSegments.last)
        .toList();

    final docText = [
      for (final name in _docFiles(root))
        File('$root${Platform.pathSeparator}$name').readAsStringSync(),
    ].join('\n');
    final testText = File(
      '$root${Platform.pathSeparator}packages${Platform.pathSeparator}gecko_db'
      '${Platform.pathSeparator}test${Platform.pathSeparator}examples_test.dart',
    ).readAsStringSync();

    final orphaned = exampleFiles.where((file) {
      return !docText.contains(file) && !testText.contains(file);
    }).toList();
    expect(
      orphaned,
      isEmpty,
      reason: 'example files must be referenced by docs or tests: $orphaned',
    );
  });

  test(
    'runnable examples execute end-to-end',
    () async {
      for (final example in [
        'quickstart.dart',
        'advanced.dart',
      ]) {
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          'examples/$example',
        ], workingDirectory: root);
        expect(
          result.exitCode,
          0,
          reason: '$example failed:\n${result.stderr}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('README links the key consumer/developer references', () {
    final readme = File(
      '$root${Platform.pathSeparator}README.md',
    ).readAsStringSync();
    for (final link in [
      'SECURITY.md',
      'CHANGELOG.md',
      'AGENTS.md',
      'examples/README.md',
    ]) {
      expect(
        readme,
        contains(link),
        reason: 'README must link $link so consumers can find the docs',
      );
    }
  });

  test('required release docs exist', () {
    for (final file in [
      'README.md',
      'AGENTS.md',
      '.github/copilot-instructions.md',
      'SECURITY.md',
      'CHANGELOG.md',
      'examples/README.md',
      'tool/traceability_check.dart',
    ]) {
      expect(
        File('$root${Platform.pathSeparator}$file').existsSync(),
        isTrue,
        reason: 'required release artifact $file is missing',
      );
    }
  });
}
