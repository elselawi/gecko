// Audit-driven artifact-manifest edge tests (audited-test-gaps Part 4).
//
// Exercises tool/artifact_manifest.dart end to end: arg validation, missing
// artifact, checksum + size correctness, default/custom output, basename-only
// artifact naming (path-traversal safe), native path separators, provenance
// fields, and every release target/arch combination.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'build_artifacts.dart' show kTargets;

String _repoRoot() {
  if (File('tool/artifact_manifest.dart').existsSync()) {
    return Directory.current.path;
  }
  return Directory.current.parent.path;
}

String get _toolPath =>
    '${_repoRoot()}${Platform.pathSeparator}tool${Platform.pathSeparator}'
    'artifact_manifest.dart';

Future<ProcessResult> _runManifest(
  List<String> args, {
  required String workingDir,
}) =>
    Process.run(
      Platform.resolvedExecutable,
      [_toolPath, ...args],
      workingDirectory: workingDir,
    );

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('gecko-manifest-edge-');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

Future<File> _blob(Directory dir, {int size = 1024}) async {
  final file = File('${dir.path}${Platform.pathSeparator}blob.bin');
  file.writeAsBytesSync(List<int>.generate(size, (i) => i % 251));
  return file;
}

void main() {
  test('missing required arguments prints usage and exits 2', () async {
    final dir = await _tempDir();
    for (final args in <List<String>>[
      const [],
      const ['--artifact=x'],
      const ['--artifact=x', '--target=windows'],
      const ['--artifact=x', '--target=windows', '--arch=x64'],
    ]) {
      final result = await _runManifest(args, workingDir: dir.path);
      expect(result.exitCode, 2, reason: 'args=$args');
      expect((result.stderr as String), contains('Usage:'));
    }
  });

  test('a missing artifact file fails with a clear message and exit 1',
      () async {
    final dir = await _tempDir();
    final result = await _runManifest([
      '--artifact=${dir.path}${Platform.pathSeparator}nope.bin',
      '--target=windows',
      '--arch=x64',
      '--version=0.0.1',
    ], workingDir: dir.path);
    expect(result.exitCode, 1);
    expect((result.stderr as String), contains('ARTIFACT MANIFEST FAILED'));
  });

  test('a valid run writes the correct checksum, size, and identity fields',
      () async {
    final dir = await _tempDir();
    final blob = await _blob(dir, size: 4096);
    final out = '${dir.path}${Platform.pathSeparator}manifest.json';
    final result = await _runManifest([
      '--artifact=${blob.path}',
      '--target=windows',
      '--arch=x64',
      '--version=1.2.3',
      '--output=$out',
    ], workingDir: dir.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    final manifest =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(manifest['schemaVersion'], 1);
    expect(manifest['artifact'], 'blob.bin');
    expect(manifest['target'], 'windows');
    expect(manifest['architecture'], 'x64');
    expect(manifest['version'], '1.2.3');
    expect(manifest['sizeBytes'], 4096);
    final expectedSha =
        sha256.convert(blob.readAsBytesSync()).toString();
    expect(manifest['sha256'], expectedSha);
  });

  test('default output is artifact-manifest.json in the working directory',
      () async {
    final dir = await _tempDir();
    final blob = await _blob(dir);
    final result = await _runManifest([
      '--artifact=${blob.path}',
      '--target=linux',
      '--arch=x64',
      '--version=0.0.1',
    ], workingDir: dir.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      File('${dir.path}${Platform.pathSeparator}artifact-manifest.json')
          .existsSync(),
      isTrue,
    );
  });

  test('the artifact field is the basename only (path-traversal safe)',
      () async {
    final dir = await _tempDir();
    final nested = Directory(
      '${dir.path}${Platform.pathSeparator}..${Platform.pathSeparator}'
      '${dir.uri.pathSegments.last}${Platform.pathSeparator}sub',
    );
    nested.createSync(recursive: true);
    final blob = File(
      '${nested.path}${Platform.pathSeparator}deep.bin',
    )..writeAsBytesSync([1, 2, 3]);
    final out = '${dir.path}${Platform.pathSeparator}m.json';
    final result = await _runManifest([
      '--artifact=${blob.path}',
      '--target=macos',
      '--arch=arm64',
      '--version=0.0.1',
      '--output=$out',
    ], workingDir: dir.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final manifest =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(
      manifest['artifact'],
      'deep.bin',
      reason: 'directory components must never leak into the manifest',
    );
  });

  test('native path separators in the artifact path are honored', () async {
    final dir = await _tempDir();
    final nested = Directory(
      '${dir.path}${Platform.pathSeparator}build${Platform.pathSeparator}'
      'native',
    )..createSync(recursive: true);
    final blob = File(
      '${nested.path}${Platform.pathSeparator}libgecko_db_rust.so',
    )..writeAsBytesSync([9, 9, 9]);
    final out = '${dir.path}${Platform.pathSeparator}m.json';
    final result = await _runManifest([
      '--artifact=${blob.path}',
      '--target=linux',
      '--arch=x64',
      '--version=0.0.1',
      '--output=$out',
    ], workingDir: dir.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final manifest =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect(manifest['artifact'], 'libgecko_db_rust.so');
  });

  test('every release target/arch combination is accepted', () async {
    final dir = await _tempDir();
    final blob = await _blob(dir);
    // Dedupe (target, arch) pairs — several android targets share arch keys.
    final seen = <String>{};
    for (final target in kTargets) {
      final key = '${target.targetKey}/${target.archKey}';
      if (!seen.add(key)) continue;
      final out = '${dir.path}${Platform.pathSeparator}$key.json';
      final result = await _runManifest([
        '--artifact=${blob.path}',
        '--target=${target.targetKey}',
        '--arch=${target.archKey}',
        '--version=0.0.1',
        '--output=$out',
      ], workingDir: dir.path);
      expect(result.exitCode, 0, reason: 'target=${target.name}: ${result.stderr}');
      final manifest =
          jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
      expect(manifest['target'], target.targetKey);
      expect(manifest['architecture'], target.archKey);
    }
  });

  test('build provenance fields are present and typed', () async {
    final dir = await _tempDir();
    final blob = await _blob(dir);
    final out = '${dir.path}${Platform.pathSeparator}m.json';
    final result = await _runManifest([
      '--artifact=${blob.path}',
      '--target=windows',
      '--arch=x64',
      '--version=0.0.1',
      '--output=$out',
    ], workingDir: dir.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final manifest =
        jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    final build = manifest['build'] as Map<String, dynamic>;
    for (final field in ['commit', 'workflow', 'rustToolchain',
        'frbCodegenVersion', 'sourceDateEpoch']) {
      expect(build[field], isA<String>(), reason: field);
    }
    expect(build['frbCodegenVersion'], '2.12.0');
  });

  test('the stdout reports the short checksum and the output path', () async {
    final dir = await _tempDir();
    final blob = await _blob(dir);
    final out = '${dir.path}${Platform.pathSeparator}m.json';
    final result = await _runManifest([
      '--artifact=${blob.path}',
      '--target=windows',
      '--arch=x64',
      '--version=0.0.1',
      '--output=$out',
    ], workingDir: dir.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final stdoutText = result.stdout as String;
    expect(stdoutText, contains('Wrote $out'));
    final expectedSha =
        sha256.convert(blob.readAsBytesSync()).toString();
    expect(stdoutText, contains(expectedSha.substring(0, 12)));
  });
}
