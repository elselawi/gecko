// Audit-driven security-review edge tests (audited-test-gaps Part 4).
//
// The review scans the repo-relative `packages/gecko_db/lib` and `rust/src`
// trees, so these tests pin the detection semantics of the exact regexes the
// review uses (copied verbatim to lock behavior), plus a regression run on
// the real tree.

import 'dart:io';

import 'package:test/test.dart';

// Verbatim copies of tool/security_review.dart's patterns.
final RegExp _secretLiteral = RegExp(
  r'(?:api[_-]?key|secret|passw(?:ord|phrase)|token|private[_-]?key|'
  r'physicalEncryptionKey|encryptionKey)\s*[:=]\s*[\x27\x22]'
  r'[^\x27\x22]{8,}[\x27\x22]',
  caseSensitive: false,
);
final RegExp _keyInLog = RegExp(
  r"(?:print|log|debugPrint|println|writeln|log\.|tracing::).*"
  r"(?:encryptionKey|physicalEncryptionKey|secret|password)",
  caseSensitive: false,
);
final RegExp _valueInError = RegExp(
  r'\x27[^\x27]*\$\{[^}]*\}.*(?:error|failed)|'
  r'GeckoError\([^)]*\$\{',
  caseSensitive: false,
);
final RegExp _base64Blob = RegExp(
  r'[\x27\x22][A-Za-z0-9+/]{40,}={0,2}[\x27\x22]',
);

String _repoRoot() {
  if (File('tool/security_review.dart').existsSync()) {
    return Directory.current.path;
  }
  return Directory.current.parent.path;
}

String get _sep => Platform.pathSeparator;

/// Creates a temp tree with a `packages/gecko_db/lib` (and optional
/// `rust/src`) so the real review can be exercised against it.
Future<Directory> _tempLibTree() async {
  final dir = await Directory.systemTemp.createTemp('gecko-sec-edge-');
  addTearDown(() => dir.delete(recursive: true));
  final lib = Directory(
    '${dir.path}${_sep}packages${_sep}gecko_db${_sep}lib',
  )..createSync(recursive: true);
  // A benign file so the tree is non-empty before the failing fixtures land.
  File(
    '${lib.path}${_sep}src${_sep}ok.dart',
  )
    ..createSync(recursive: true)
    ..writeAsStringSync('final int answer = 42;\n');
  return dir;
}

Future<ProcessResult> _runReview(String workingDir) => Process.run(
      Platform.resolvedExecutable,
      ['${_repoRoot()}${_sep}tool${_sep}security_review.dart'],
      workingDirectory: workingDir,
    );

void main() {
  group('secret-literal semantics', () {
    test('key material literals are matched', () {
      expect(
        _secretLiteral.hasMatch("final encryptionKey = 'averylongsecret123456';"),
        isTrue,
      );
      expect(
        _secretLiteral.hasMatch("final apiKey = 'abcdefghijklmnopqrstuvwxyz';"),
        isTrue,
      );
      expect(
        _secretLiteral.hasMatch("password = 'hunter2hunter2hunter2'"),
        isTrue,
      );
    });

    test('short values are not matched (>= 8 chars required)', () {
      expect(_secretLiteral.hasMatch("final encryptionKey = 'abc';"), isFalse);
      expect(_secretLiteral.hasMatch("final key = 'short';"), isFalse);
    });

    test('benign identifiers are not flagged', () {
      expect(_secretLiteral.hasMatch('final threshold = 5;'), isFalse);
      expect(_secretLiteral.hasMatch("final displayName = 'user';"), isFalse);
      expect(
        _secretLiteral.hasMatch('encryptionKey == null // a check, not a literal'),
        isFalse,
      );
    });
  });

  group('key-in-log semantics', () {
    test('printing/ logging key material is matched', () {
      expect(
        _keyInLog.hasMatch("print('key: \$encryptionKey');"),
        isTrue,
      );
      expect(
        _keyInLog.hasMatch("println!(\"{}\", encryptionKey);"),
        isTrue,
      );
      expect(
        _keyInLog.hasMatch("debugPrint('password=\$password');"),
        isTrue,
      );
    });

    test('plain variable reads are not logging', () {
      expect(_keyInLog.hasMatch('final k = encryptionKey;'), isFalse);
      expect(_keyInLog.hasMatch('if (password != null) return;'), isFalse);
    });
  });

  group('value-in-error semantics', () {
    test('raw values interpolated into error/failed strings are matched', () {
      expect(
        _valueInError.hasMatch("throw StateError('invalid: \${row.id} failed');"),
        isTrue,
      );
      expect(
        _valueInError.hasMatch("GeckoError('write of \${record} rejected')"),
        isTrue,
      );
    });

    test('interpolations without error context are not matched', () {
      expect(_valueInError.hasMatch("print('count = \${items.length}');"), isFalse);
      expect(_valueInError.hasMatch("final label = '\${name} is fine';"), isFalse);
    });
  });

  group('base64-literal semantics', () {
    test('long base64-ish literals are flagged', () {
      final blob =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      expect(_base64Blob.hasMatch("final b = '$blob';"), isTrue);
    });

    test('short literals and base64Encode calls are not flagged', () {
      expect(_base64Blob.hasMatch("final b = 'abc';"), isFalse);
      // The review exempts lines that call base64Encode.
      expect(
        _base64Blob.hasMatch('final s = base64Encode(bytes);'),
        isFalse,
      );
    });
  });

  test('regression: the review skips generated binding files', () async {
    final dir = await _tempLibTree();
    final generated = File(
      '${dir.path}${_sep}packages${_sep}gecko_db${_sep}lib'
      '${_sep}src${_sep}native${_sep}generated${_sep}frb_generated.dart',
    )..createSync(recursive: true);
    // Mirrors FRB codegen output shape; even a secret-looking literal inside
    // generated code must not fail the review.
    generated.writeAsStringSync(
      "final String encryptionKey = 'averylongsecret123456';\n",
    );
    final result = await _runReview(dir.path);
    expect(
      result.exitCode,
      0,
      reason: 'generated files must be excluded:\n${result.stdout}',
    );
  });

  test('a real secret literal in lib fails the review', () async {
    final dir = await _tempLibTree();
    File(
      '${dir.path}${_sep}packages${_sep}gecko_db${_sep}lib'
      '${_sep}src${_sep}leak.dart',
    ).writeAsStringSync(
      "final String apiKey = 'abcdefghijklmnopqrstuvwxyz';\n",
    );
    final result = await _runReview(dir.path);
    expect(result.exitCode, 1);
    expect((result.stdout as String), contains('secret-literal'));
  });

  test('advisory findings alone do not fail the review', () async {
    final dir = await _tempLibTree();
    File(
      '${dir.path}${_sep}packages${_sep}gecko_db${_sep}lib'
      '${_sep}src${_sep}advisory.dart',
    ).writeAsStringSync(
      "throw StateError('invalid: \${row.id} failed');\n",
    );
    final result = await _runReview(dir.path);
    expect(
      result.exitCode,
      0,
      reason: 'value-in-error is advisory:\n${result.stdout}',
    );
    expect((result.stdout as String), contains('advisory'));
  });

  test('regression: the security review passes on the real tree', () async {
    final proc = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/security_review.dart',
    ]);
    expect(
      proc.exitCode,
      0,
      reason: 'security review must pass on the tree:\n${proc.stdout}',
    );
  });
}
