#!/usr/bin/env dart
// Verifies that public contract changes are accompanied by an ADR or version
// bump. Intended for CI, where the repository has a merge-base reference.
//
// Usage:
//   dart run tool/api_contract_gate.dart --base=origin/main

import 'dart:io';

const _contractPrefixes = <String>[
  'packages/gecko_db/lib/gecko_db.dart',
  'packages/gecko_db/lib/src/api/',
  'packages/gecko_db/lib/src/errors/',
  'packages/gecko_db/lib/src/wire/',
  'tool/api_snapshot.txt',
];

void main(List<String> args) {
  final baseArg = args
      .where((arg) => arg.startsWith('--base='))
      .map((arg) => arg.substring('--base='.length))
      .firstOrNull;
  if (baseArg == null || baseArg.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/api_contract_gate.dart --base=<git-ref>',
    );
    exitCode = 2;
    return;
  }

  final result = Process.runSync('git', [
    'diff',
    '--name-only',
    '--diff-filter=ACMRTUXB',
    '$baseArg...HEAD',
  ]);
  if (result.exitCode != 0) {
    stderr.writeln(
      'API CONTRACT GATE FAILED: could not inspect $baseArg...HEAD',
    );
    stderr.write(result.stderr);
    exitCode = 1;
    return;
  }

  final changed = result.stdout
      .toString()
      .split(RegExp(r'\r?\n'))
      .where((path) => path.isNotEmpty)
      .toList();
  final contractChanged = changed.where(_isContractPath).toList();
  if (contractChanged.isEmpty) {
    stdout.writeln('API CONTRACT GATE PASSED: no public contract changes.');
    return;
  }

  final hasAdr = changed.any(
    (path) => path.startsWith('docs/adr/') && path != 'docs/adr/README.md',
  );
  final hasVersionBump =
      changed.contains('packages/gecko_db/pubspec.yaml') ||
      changed.contains('pubspec.yaml');
  if (!hasAdr && !hasVersionBump) {
    stderr.writeln(
      'API CONTRACT GATE FAILED: public contract changes require an ADR '
      'or package version bump.',
    );
    stderr.writeln('Changed contract files:');
    for (final path in contractChanged) {
      stderr.writeln('  $path');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'API CONTRACT GATE PASSED: public changes have an ADR or version bump.',
  );
}

bool _isContractPath(String path) => _contractPrefixes.any(
  (prefix) => path == prefix || path.startsWith(prefix),
);

extension on Iterable<String> {
  String? get firstOrNull => isEmpty ? null : first;
}
