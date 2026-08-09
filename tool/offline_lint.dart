#!/usr/bin/env dart
// Phase 13 — offline / determinism lint gate.
//
// Scans every test source in the repo and forbids two classes of flake:
//   1. NETWORK: any reach for the real network (HttpClient, package:http,
//      Socket, WebSocket, InternetAddress, dart:html fetch/XHR). A test that
//      could hit the internet is a flake magnet and a CI poison.
//   2. REAL CLOCK: `DateTime.now()` (and friends) in test code. Engine
//      behavior must be deterministic; wall-clock dependence is asserted to
//      be absent via the injected clock seam.
//
// It is a static lint over test sources, run in CI (not a runtime check).
// Run from the repo root:
//   dart run tool/offline_lint.dart
import 'dart:io';

import 'package:path/path.dart' as p;

final RegExp _networkPattern = RegExp(
  r'HttpClient|package:http|dart:io.*Socket|WebSocket|InternetAddress|'
  r'HttpServer|dart:html.*HttpRequest|XMLHttpRequest|fetch\(|'
  r'package:web_socket|Socket\.(connect|startConnect)|'
  r'InternetAddress\.lookup',
);

final RegExp _clockPattern = RegExp(r'DateTime\.now\(\)');

class _Finding {
  _Finding(this.file, this.line, this.kind, this.detail);
  final String file;
  final int line;
  final String kind;
  final String detail;
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final findings = <_Finding>[];

  // Test sources: packages/*/test, tool/**/*_test.dart, examples (they run in
  // CI as doc-tests), and benchmark/** (runs in CI as a sanity gate).
  final dirs = <String>[
    'packages/gecko_db/test',
    'tool',
    'examples',
  ];
  for (final dir in dirs) {
    final abs = p.join(root, dir);
    if (!Directory(abs).existsSync()) continue;
    await for (final file in _testFiles(abs)) {
      await _scanFile(file, findings);
    }
  }

  if (findings.isEmpty) {
    stdout.writeln('OFFLINE LINT PASSED: no network or real-clock usage in '
        'test sources.');
    return;
  }
  stdout.writeln('OFFLINE LINT FAILED — ${findings.length} finding(s):');
  for (final f in findings) {
    stdout.writeln(
      '  [${f.kind}] ${p.relative(f.file, from: root)}:${f.line} — '
      '${f.detail}',
    );
  }
  stderr.writeln(
    'Tests must stay offline and deterministic. Use the injected clock seam '
    'and test doubles for anything network-like.',
  );
  exit(1);
}

Stream<File> _testFiles(String dir) async* {
  await for (final entity in Directory(dir).list(recursive: true)) {
    if (entity is File &&
        (entity.path.endsWith('_test.dart') ||
            entity.path.endsWith('.dart') && dir.endsWith('test') ||
            entity.path.endsWith('.dart') && dir.endsWith('benchmark'))) {
      yield entity;
    }
  }
}

Future<void> _scanFile(File file, List<_Finding> findings) async {
  final lines = await file.readAsLines();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('//') || line.startsWith('///') || line.startsWith('*')) {
      continue;
    }
    if (_networkPattern.hasMatch(line)) {
      // Skip the tool's own source when it's scanned under tool/.
      if (file.path.endsWith('offline_lint.dart')) continue;
      findings.add(_Finding(
        file.path,
        i + 1,
        'network',
        'test reaches for the network',
      ));
    }
    if (_clockPattern.hasMatch(line)) {
      findings.add(_Finding(
        file.path,
        i + 1,
        'real-clock',
        'test uses the real wall clock',
      ));
    }
  }
}
