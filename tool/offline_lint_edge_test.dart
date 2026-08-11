// Audit-driven offline-lint edge tests (audited-test-gaps Part 4).
//
// The lint scans the repo-relative `packages/gecko_db/test`, `tool`, and
// `examples` trees, so these tests pin the detection semantics of the exact
// regexes the lint uses (semantically identical copies, with the forbidden
// tokens escaped so this file's own source does not trip the very lint it
// tests), plus a regression run on the real tree.

import 'dart:io';

import 'package:test/test.dart';

// Runtime token builders: the source never contains the forbidden substrings
// (the token characters are assembled at runtime).
String _clientToken() => 'Http' 'Client';
String _connectToken() => 'Socket' '.connect';
String _wsToken() => 'Web' 'Socket';
String _callToken() => 'fetch' '(';
String _nowToken() => 'DateTime' '.now' '()';

// Semantically identical copies of tool/offline_lint.dart's patterns. The
// tokens use `[x]` character classes (which match the same text) so the raw
// source here is not itself flagged.
final RegExp _networkPattern = RegExp(
  r'Http[C]lient|package:ht[t]p|dart:io.*Socke[t]|Web[S]ocket|'
  r'Internet[A]ddress|Http[S]erver|dart:html.*Http[R]equest|XMLHttp[R]equest|'
  r'fet[c]h\(|package:web_[s]ocket|Socke[t]\.(connect|startConnect)|'
  r'Internet[A]ddress\.lookup',
);
final RegExp _clockPattern = RegExp(r'DateTime\.no[w]\(\)');

void main() {
  group('network pattern semantics', () {
    test('real network reach is matched', () {
      expect(
        _networkPattern.hasMatch("import 'dart:io'; ${_clientToken()}();"),
        isTrue,
      );
      expect(
        _networkPattern.hasMatch("import 'package:${'http'}/${'http'}.dart'"),
        isTrue,
      );
      expect(
        _networkPattern.hasMatch('${_connectToken()}(host, port)'),
        isTrue,
      );
      expect(_networkPattern.hasMatch('${_wsToken()}.connect(url)'), isTrue);
      expect(
        _networkPattern.hasMatch('${'Internet'}Address.lookup(name)'),
        isTrue,
      );
      expect(_networkPattern.hasMatch('await ${_callToken()}url)'), isTrue);
    });

    test('comment-only mentions are also matched (pinned false positive)',
        () {
      // The lint regex scans whole non-comment lines, so a comment that is
      // not line-prefixed (or a string) mentioning the client IS flagged
      // today. Pinned so a smarter scanner is deliberate.
      final inline = 'final String note = "uses ${_clientToken()}";';
      expect(
        _networkPattern.hasMatch(inline),
        isTrue,
        reason: 'a string mentioning the token is currently flagged',
      );
    });

    test('unrelated words are not matched', () {
      expect(_networkPattern.hasMatch('final parser = something;'), isFalse);
      expect(_networkPattern.hasMatch('http_parser is fine'), isFalse);
      expect(
        _networkPattern.hasMatch('final clientName = Socket-ish;'),
        isFalse,
      );
    });
  });

  group('clock pattern semantics', () {
    test('a now() call is matched', () {
      expect(_clockPattern.hasMatch('final t = ${_nowToken()}();'), isTrue);
    });

    test('DateTime.utc / DateTime.fromX are not matched (no false positive)',
        () {
      expect(_clockPattern.hasMatch('final t = DateTime.utc(2024, 1, 1);'), isFalse);
      expect(
        _clockPattern.hasMatch(
          'final t = DateTime.fromMillisecondsSinceEpoch(0);',
        ),
        isFalse,
      );
      expect(_clockPattern.hasMatch('now is not a call'), isFalse);
    });
  });

  group('real lint on a fixture tree', () {
    Future<Directory> tempTree() async {
      final dir = await Directory.systemTemp.createTemp('gecko-lint-edge-');
      addTearDown(() => dir.delete(recursive: true));
      Directory(
        '${dir.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}test',
      ).createSync(recursive: true);
      return dir;
    }

    Future<ProcessResult> runLint(String workingDir) => Process.run(
          Platform.resolvedExecutable,
          [
            '${Directory.current.path}${Platform.pathSeparator}tool'
            '${Platform.pathSeparator}offline_lint.dart',
          ],
          workingDirectory: workingDir,
        );

    test('a full-line comment mentioning a token is skipped', () async {
      final dir = await tempTree();
      final testDir = Directory(
        '${dir.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}test',
      );
      File(
        '${testDir.path}${Platform.pathSeparator}comment_only_test.dart',
      ).writeAsStringSync(
        '// A comment mentioning ${_clientToken()} is documentation.\n'
        'void main() {}\n',
      );
      final result = await runLint(dir.path);
      expect(
        result.exitCode,
        0,
        reason: 'comment-only mentions must pass:\n${result.stdout}',
      );
    });

    test('a real network reach in test code fails the lint', () async {
      final dir = await tempTree();
      final testDir = Directory(
        '${dir.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}test',
      );
      File(
        '${testDir.path}${Platform.pathSeparator}network_test.dart',
      ).writeAsStringSync(
        "import 'dart:io';\n"
        'void main() { ${_clientToken()}().getUrl(Uri.parse("x")); }\n',
      );
      final result = await runLint(dir.path);
      expect(result.exitCode, 1);
      expect((result.stdout as String), contains('OFFLINE LINT FAILED'));
      expect((result.stdout as String), contains('network'));
    });

    test('a real-clock call in test code fails the lint', () async {
      final dir = await tempTree();
      final testDir = Directory(
        '${dir.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}test',
      );
      File(
        '${testDir.path}${Platform.pathSeparator}clock_test.dart',
      ).writeAsStringSync(
        'void main() { final t = ${_nowToken()}(); }\n',
      );
      final result = await runLint(dir.path);
      expect(result.exitCode, 1);
      expect((result.stdout as String), contains('real-clock'));
    });

    test('generated test files are still scanned (no exclusion)', () async {
      final dir = await tempTree();
      final testDir = Directory(
        '${dir.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}test',
      );
      File(
        '${testDir.path}${Platform.pathSeparator}gen_frb_test.dart',
      ).writeAsStringSync(
        'void main() { final t = ${_nowToken()}(); }\n',
      );
      final result = await runLint(dir.path);
      expect(
        result.exitCode,
        1,
        reason: 'generated-named test files are still linted:\n${result.stdout}',
      );
      expect((result.stdout as String), contains('real-clock'));
    });
  });

  test('regression: the offline lint passes on the real tree', () async {
    final proc = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/offline_lint.dart',
    ]);
    expect(
      proc.exitCode,
      0,
      reason: 'offline lint must pass on the tree:\n${proc.stdout}',
    );
    expect((proc.stdout as String), contains('OFFLINE LINT PASSED'));
  });
}
