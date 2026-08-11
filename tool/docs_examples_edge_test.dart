// Audit-driven docs/examples edge tests (audited-test-gaps Part 4).
//
// Guards beyond the existing docs_examples_test.dart: markdown links in the
// README resolve to real files, examples import only the public entrypoint
// (never internal sources), docs do not reference the removed docs/ directory
// or ADRs, benchmark targets are never invoked from the repo root, and the
// README links the key developer references.

import 'dart:io';

import 'package:test/test.dart';

String _repoRoot() {
  if (Directory('packages/gecko_db').existsSync() &&
      Directory('examples').existsSync()) {
    return Directory.current.path;
  }
  if (Directory.current.path.endsWith('gecko')) {
    return Directory.current.path;
  }
  return Directory.current.parent.path;
}

String get _sep => Platform.pathSeparator;

void main() {
  final root = _repoRoot();

  test('markdown links in the README resolve to real files', () {
    final readme = File('$root$_sep' 'README.md').readAsStringSync();
    final linkPattern = RegExp(r'\[[^\]]*\]\(([^)]+)\)');
    final missing = <String>[];
    for (final match in linkPattern.allMatches(readme)) {
      final target = match.group(1)!.trim();
      if (target.isEmpty) continue;
      // Skip external URLs, anchors, and mailto links.
      if (target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:') ||
          target.startsWith('#')) {
        continue;
      }
      // Skip image links (they are not repo files).
      final before = readme.substring(0, match.start);
      if (before.endsWith('!')) continue;
      final path =
          '$root$_sep${target.replaceAll('/', _sep).replaceAll('\\', _sep)}';
      if (!File(path).existsSync() && !Directory(path).existsSync()) {
        missing.add(target);
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'README links to non-existent targets: $missing',
    );
  });

  test('examples import only the public entrypoint, never internal sources',
      () {
    final examplesDir = Directory('$root$_sep' 'examples');
    final offenders = <String>[];
    for (final file in examplesDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      for (final line in file.readAsLinesSync()) {
        final import = RegExp(r"^\s*import\s+'([^']+)';").firstMatch(line);
        if (import == null) continue;
        final uri = import.group(1)!;
        if (uri.startsWith('dart:')) continue;
        if (uri == 'package:gecko_db/gecko_db.dart') continue;
        if (uri.startsWith('package:gecko_db/')) {
          offenders.add('${file.uri.pathSegments.last}: $uri');
        } else {
          offenders.add('${file.uri.pathSegments.last}: non-gecko $uri');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'examples must use only the public entrypoint: $offenders',
    );
  });

  test('docs never reference the removed docs/ directory or ADRs', () {
    final docNames = [
      'README.md',
      'AGENTS.md',
      '.github$_sep' 'copilot-instructions.md',
      'examples$_sep' 'README.md',
      'SECURITY.md',
      'CHANGELOG.md',
    ];
    // Reference patterns only: a markdown link into docs/, a backticked path
    // with a filename under docs/, or an ADR-xxx identifier. The word "ADR"
    // in a prohibition sentence ("do not reference ... ADRs") is not a
    // reference and must not be flagged.
    final reference = RegExp(
      r'\]\(docs/|`docs/[A-Za-z0-9_./-]+`|\bADR-\w',
    );
    final offenders = <String>[];
    for (final name in docNames) {
      final file = File('$root$_sep$name');
      if (!file.existsSync()) continue;
      if (reference.hasMatch(file.readAsStringSync())) {
        offenders.add(name);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'docs must not reference the removed docs/ dir or ADRs: '
          '$offenders',
    );
  });

  test('no doc instructs a benchmark run from the repo root', () {
    final docs = [
      'README.md',
      'AGENTS.md',
      '.github$_sep' 'copilot-instructions.md',
      'examples$_sep' 'README.md',
    ];
    final offenders = <String>[];
    for (final name in docs) {
      final file = File('$root$_sep$name');
      if (!file.existsSync()) continue;
      final text = file.readAsStringSync();
      // Benchmark is a standalone package: `dart run benchmark/...` from the
      // repo root pollutes dart run output. Only `cd benchmark && dart run`
      // is correct.
      if (RegExp(r'dart\s+run\s+benchmark/').hasMatch(text)) {
        offenders.add(name);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'benchmark targets must run from benchmark/: $offenders',
    );
  });

  test('the README links the key developer references', () {
    final readme = File('$root$_sep' 'README.md').readAsStringSync();
    for (final name in [
      'SECURITY.md',
      'CHANGELOG.md',
      'AGENTS.md',
      'examples/README.md',
    ]) {
      expect(
        readme,
        contains('($name)'),
        reason: 'README must link $name',
      );
    }
  });

  test('every doc that references a release gate file points at a real file',
      () {
    final docs = [
      'README.md',
      'AGENTS.md',
      '.github$_sep' 'copilot-instructions.md',
    ];
    final missing = <String>[];
    for (final name in docs) {
      final file = File('$root$_sep$name');
      if (!file.existsSync()) continue;
      final text = file.readAsStringSync();
      for (final match in RegExp(r'tool/([A-Za-z0-9_]+\.dart)')
          .allMatches(text)) {
        final target = match.group(1)!;
        if (!File('$root$_sep' 'tool$_sep$target').existsSync()) {
          missing.add('$name -> tool/$target');
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'docs reference non-existent tool files: $missing',
    );
  });
}
