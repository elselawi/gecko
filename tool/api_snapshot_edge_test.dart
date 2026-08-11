// Audit-driven api-snapshot / api-contract gate edge tests
// (audited-test-gaps Part 4).
//
// Exercises tool/api_snapshot.dart and tool/api_contract_gate.dart against
// temp entrypoints: deterministic output, stable ordering, symbol dedupe,
// symbol add/remove, generated-code exclusion, CRLF normalization, deprecated
// declarations, a missing entrypoint, and the contract gate's CLI contract.

import 'dart:io';

import 'package:test/test.dart';

String _repoRoot() {
  if (File('tool/api_snapshot.dart').existsSync()) {
    return Directory.current.path;
  }
  return Directory.current.parent.path;
}

String get _toolPath =>
    '${_repoRoot()}${Platform.pathSeparator}tool${Platform.pathSeparator}'
    'api_snapshot.dart';

Future<ProcessResult> _runSnapshot(
  String workingDir,
  List<String> args,
) =>
    Process.run(
      Platform.resolvedExecutable,
      [_toolPath, ...args],
      workingDirectory: workingDir,
    );

/// Creates a temp repo-like tree with the given entrypoint source and returns
/// the working directory (its `packages/gecko_db/lib/gecko_db.dart` holds the
/// entrypoint).
Future<Directory> _tempRepo(String entrypoint) async {
  final dir = await Directory.systemTemp.createTemp('gecko-api-edge-');
  addTearDown(() => dir.delete(recursive: true));
  final lib = Directory(
    '${dir.path}${Platform.pathSeparator}packages'
    '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}lib',
  )..createSync(recursive: true);
  File(
    '${lib.path}${Platform.pathSeparator}gecko_db.dart',
  ).writeAsStringSync(entrypoint);
  return dir;
}

const _entry = '''
export 'src/api/database.dart' show GeckoDatabase, GeckoConfig;
export 'src/api/errors.dart';

abstract class GeckoDatabase {}
class GeckoConfig {}
enum ConflictStrategy { lastWriteWins, manualReview }
typedef RowAccessors = Map<String, Function>;
mixin WatcherMixin {}
''';

void main() {
  test('snapshot output is deterministic and byte-stable across runs', () async {
    final dir = await _tempRepo(_entry);
    final outA = '${dir.path}${Platform.pathSeparator}a.txt';
    final outB = '${dir.path}${Platform.pathSeparator}b.txt';
    final first = await _runSnapshot(dir.path, [outA]);
    final second = await _runSnapshot(dir.path, [outB]);
    expect(first.exitCode, 0, reason: first.stderr.toString());
    expect(second.exitCode, 0, reason: second.stderr.toString());
    expect(
      File(outA).readAsStringSync(),
      File(outB).readAsStringSync(),
      reason: 'identical input must produce identical snapshot',
    );
  });

  test('exports and declarations are sorted; duplicate declarations dedupe',
      () async {
    final dir = await _tempRepo('''
export 'src/b.dart';
export 'src/a.dart' show Alpha;
class Zulu {}
class Alpha {}
class Alpha {}
''');
    final out = '${dir.path}${Platform.pathSeparator}snap.txt';
    final result = await _runSnapshot(dir.path, [out]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final text = File(out).readAsStringSync();
    final exportLines = [
      for (final line in text.split('\n'))
        if (line.startsWith('export:')) line,
    ];
    final declLines = [
      for (final line in text.split('\n'))
        if (line.startsWith('declaration:')) line,
    ];
    expect(exportLines, [
      'export: src/a.dart show: Alpha',
      'export: src/b.dart',
    ]);
    expect(declLines, [
      'declaration: Alpha',
      'declaration: Zulu',
    ]);
  });

  test('a CRLF entrypoint produces a byte-identical snapshot to LF', () async {
    final lfDir = await _tempRepo(_entry);
    final crlfDir = await _tempRepo(_entry.replaceAll('\n', '\r\n'));
    final lfOut = '${lfDir.path}${Platform.pathSeparator}lf.txt';
    final crlfOut = '${crlfDir.path}${Platform.pathSeparator}crlf.txt';
    final a = await _runSnapshot(lfDir.path, [lfOut]);
    final b = await _runSnapshot(crlfDir.path, [crlfOut]);
    expect(a.exitCode, 0, reason: a.stderr.toString());
    expect(b.exitCode, 0, reason: b.stderr.toString());
    expect(
      File(lfOut).readAsStringSync(),
      File(crlfOut).readAsStringSync(),
      reason: 'line endings must normalize to the same snapshot',
    );
  });

  test('adding and removing a symbol is reflected in the snapshot', () async {
    final withExtra = await _tempRepo('$_entry\nclass BrandNew {}\n');
    final outA = '${withExtra.path}${Platform.pathSeparator}a.txt';
    await _runSnapshot(withExtra.path, [outA]);
    final textA = File(outA).readAsStringSync();
    expect(textA, contains('declaration: BrandNew'));

    final without = await _tempRepo(_entry);
    final outB = '${without.path}${Platform.pathSeparator}b.txt';
    await _runSnapshot(without.path, [outB]);
    final textB = File(outB).readAsStringSync();
    expect(textB, isNot(contains('declaration: BrandNew')));
    expect(textB, contains('declaration: GeckoDatabase'));
  });

  test('declarations outside the entrypoint (generated code) are excluded',
      () async {
    // The snapshot is entrypoint-source-based: a class defined in a file that
    // is merely exported (generated bindings, impl files) never appears.
    final dir = await _tempRepo("export 'src/native/generated/frb.dart';\n");
    final lib = Directory(
      '${dir.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}gecko_db${Platform.pathSeparator}lib',
    );
    final impl = File(
      '${lib.path}${Platform.pathSeparator}src${Platform.pathSeparator}'
      'native${Platform.pathSeparator}generated${Platform.pathSeparator}'
      'frb.dart',
    )..createSync(recursive: true);
    impl.writeAsStringSync('class HiddenFromSnapshot {}\n');
    final out = '${dir.path}${Platform.pathSeparator}snap.txt';
    final result = await _runSnapshot(dir.path, [out]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      File(out).readAsStringSync(),
      isNot(contains('HiddenFromSnapshot')),
    );
  });

  test('deprecated declarations are preserved in the snapshot', () async {
    final dir = await _tempRepo('@Deprecated("use newer")\nclass OldApi {}\n');
    final out = '${dir.path}${Platform.pathSeparator}snap.txt';
    final result = await _runSnapshot(dir.path, [out]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(File(out).readAsStringSync(), contains('declaration: OldApi'));
  });

  test('commented-out declarations are not captured', () async {
    // The declaration regex anchors at a line start with optional leading
    // whitespace only, so a `//`-prefixed (commented-out) declaration is NOT
    // captured. Pinned so a future tokenizer change is deliberate.
    final dir = await _tempRepo('// class Ghost {}\n');
    final out = '${dir.path}${Platform.pathSeparator}snap.txt';
    final result = await _runSnapshot(dir.path, [out]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      File(out).readAsStringSync(),
      isNot(contains('declaration: Ghost')),
    );
  });

  test('a missing entrypoint fails with a typed message and exit 1', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-api-edge-');
    addTearDown(() => dir.delete(recursive: true));
    final out = '${dir.path}${Platform.pathSeparator}snap.txt';
    final result = await _runSnapshot(dir.path, [out]);
    expect(result.exitCode, 1);
    expect((result.stderr as String), contains('API SNAPSHOT FAILED'));
  });

  group('api contract gate', () {
    test('without --base the gate prints usage and exits 2', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '${_repoRoot()}${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}api_contract_gate.dart',
      ], workingDirectory: _repoRoot());
      expect(result.exitCode, 2);
      expect((result.stderr as String), contains('--base='));
    });

    test('against HEAD the gate passes when nothing changed', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '${_repoRoot()}${Platform.pathSeparator}tool'
        '${Platform.pathSeparator}api_contract_gate.dart',
        '--base=HEAD',
      ], workingDirectory: _repoRoot());
      // HEAD...HEAD is an empty diff, so the gate always passes here.
      expect(result.exitCode, 0);
      expect((result.stdout as String), contains('API CONTRACT GATE PASSED'));
    });
  });
}
