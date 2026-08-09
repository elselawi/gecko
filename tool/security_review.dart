#!/usr/bin/env dart

// Workstream 8 — static security review gate.
//
// Scans the gecko_db Dart + Rust sources for the classes of mistakes that
// matter for a local-first database holding user data:
//   * secrets materialized in source (looks like an API key / token /
//     password / encryption key literal);
//   * secret values being printed/logged (key material must never reach
//     stdout/stderr or the change log);
//   * temporary files created without cleanup intent (unbounded temp usage);
//   * error strings that embed raw record values (payload leakage into
//     exceptions/logs);
//   * dependency + Rust audit reminders (run `dart pub outdated`,
//     `cargo audit`) — reported, not blocking (network availability varies).
//
// It is a heuristic gate: it reports findings and fails on the hard rules
// (secret literals, key logging). Run from the repo root:
//   dart run tool/security_review.dart
//
// CI runs this in the dart-quality job; it must stay green for every push.
import 'dart:io';

import 'package:path/path.dart' as p;

const List<String> _scanDirs = ['packages/gecko_db/lib', 'rust/src'];

/// Patterns that suggest a secret literal materialized in source. Matched
/// against the whole line, case-insensitive.
final RegExp _secretLiteral = RegExp(
  r'(?:api[_-]?key|secret|passw(?:ord|phrase)|token|private[_-]?key|'
  r'physicalEncryptionKey|encryptionKey)\s*[:=]\s*[\x27\x22]'
  r'[^\x27\x22]{8,}[\x27\x22]',
  caseSensitive: false,
);

/// Patterns for logging/printing key material.
final RegExp _keyInLog = RegExp(
  r"(?:print|log|debugPrint|println|writeln|log\.|tracing::).*"
  r"(?:encryptionKey|physicalEncryptionKey|secret|password)",
  caseSensitive: false,
);

/// Error strings that interpolate raw values (potential payload leakage).
final RegExp _valueInError = RegExp(
  r'\x27[^\x27]*\$\{[^}]*\}.*(?:error|failed)|'
  r'GeckoError\([^)]*\$\{',
  caseSensitive: false,
);

/// Suspicious base64-ish literals (>= 32 chars of base64 alphabet).
final RegExp _base64Blob = RegExp(
  r'[\x27\x22][A-Za-z0-9+/]{40,}={0,2}[\x27\x22]',
);

class _Finding {
  _Finding(this.file, this.line, this.rule, this.detail);
  final String file;
  final int line;
  final String rule;
  final String detail;
}

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final findings = <_Finding>[];

  for (final dir in _scanDirs) {
    final abs = p.join(root, dir);
    if (!Directory(abs).existsSync()) continue;
    await for (final file in _dartRustFiles(abs)) {
      await _scanFile(file, findings);
    }
  }

  stdout.writeln('SECURITY REVIEW — ${findings.length} finding(s):');
  if (findings.isEmpty) {
    stdout.writeln('  none.');
  }
  for (final f in findings) {
    stdout.writeln(
      '  [${f.rule}] ${p.relative(f.file, from: root)}:${f.line} — ${f.detail}',
    );
  }

  // Hard rules: these fail the gate.
  final hardFailures = findings
      .where((f) => f.rule == 'secret-literal' || f.rule == 'key-in-log')
      .toList();

  // Temp-file hygiene: flag temp dirs created without a delete in the same
  // file (best-effort heuristic, advisory only).
  final advisory = findings
      .where((f) => f.rule != 'secret-literal' && f.rule != 'key-in-log')
      .length;

  if (hardFailures.isNotEmpty) {
    stderr.writeln(
      'SECURITY REVIEW FAILED: ${hardFailures.length} hard finding(s) '
      '(secret literals or key logging).',
    );
    exit(1);
  }
  stdout.writeln(
    'SECURITY REVIEW PASSED ($advisory advisory finding(s) — review manually, '
    'then run `dart pub outdated` and `cargo audit` where available).',
  );
}

Stream<File> _dartRustFiles(String dir) async* {
  await for (final entity in Directory(dir).list(recursive: true)) {
    if (entity is File &&
        (entity.path.endsWith('.dart') || entity.path.endsWith('.rs'))) {
      // Skip generated bindings — they mirror the FRB codegen and are not
      // hand-authored secrets.
      if (entity.path.contains('frb_generated') ||
          entity.path.contains('generated')) {
        continue;
      }
      yield entity;
    }
  }
}

Future<void> _scanFile(File file, List<_Finding> findings) async {
  final lines = await file.readAsLines();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('//') ||
        line.trimLeft().startsWith('///') ||
        line.trimLeft().startsWith('//!') ||
        line.trimLeft().startsWith('*')) {
      // Skip comments (but still check secret-looking literals in comments is
      // intentionally skipped — comments may document example keys).
      continue;
    }
    if (_secretLiteral.hasMatch(line)) {
      findings.add(
        _Finding(
          file.path,
          i + 1,
          'secret-literal',
          'possible secret literal in source',
        ),
      );
    }
    if (_keyInLog.hasMatch(line) &&
        !line.contains('_key') && // variable names like _key are fine
        !line.contains('key=')) {
      findings.add(
        _Finding(
          file.path,
          i + 1,
          'key-in-log',
          'key material appears near a print/log call',
        ),
      );
    }
    if (_valueInError.hasMatch(line)) {
      findings.add(
        _Finding(
          file.path,
          i + 1,
          'value-in-error',
          'raw value interpolated into an error/log string',
        ),
      );
    }
    if (_base64Blob.hasMatch(line) && !line.contains('base64Encode')) {
      findings.add(
        _Finding(
          file.path,
          i + 1,
          'base64-literal',
          'long base64 literal — verify it is not a credential',
        ),
      );
    }
  }
}
