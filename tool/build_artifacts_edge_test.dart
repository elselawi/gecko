// Audit-driven build-artifacts edge tests (audited-test-gaps Part 4).
//
// Exercises tool/build_artifacts.dart CLI contracts: target listing, unknown
// and host-incompatible targets failing cleanly (before any cargo work),
// verify accept/reject round-trips, bundle failure with no manifests, and
// manifest/`cargoOutput` edge semantics via the exported functions.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'build_artifacts.dart';

String _repoRoot() {
  if (File('tool/build_artifacts.dart').existsSync()) {
    return Directory.current.path;
  }
  return Directory.current.parent.path;
}

String get _toolPath =>
    '${_repoRoot()}${Platform.pathSeparator}tool${Platform.pathSeparator}'
    'build_artifacts.dart';

Future<ProcessResult> _run(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      [_toolPath, ...args],
      workingDirectory: _repoRoot(),
    );

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('gecko-build-edge-');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

void main() {
  test('list prints every release target with a buildability status and exits 0',
      () async {
    final result = await _run(const ['list']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final out = result.stdout as String;
    for (final target in kTargets) {
      expect(out, contains(target.name), reason: target.name);
      expect(
        out,
        contains(target.triple),
        reason: '${target.name} triple',
      );
      expect(out, contains(target.artifactName), reason: target.artifactName);
      expect(
        out,
        contains(hostBuildable(target) ? 'host-buildable' : 'ci-only'),
        reason: '${target.name} status',
      );
    }
  });

  test('building an unknown target exits 2 with a clear message', () async {
    final result = await _run(const ['build', 'does-not-exist']);
    expect(result.exitCode, 2);
    expect((result.stderr as String), contains('unknown target'));
  });

  test('no arguments prints usage', () async {
    final result = await _run(const []);
    expect(result.exitCode, 0, reason: 'no-args currently prints usage');
    expect((result.stdout as String), contains('usage:'));
  });

  test('an unknown subcommand exits 2', () async {
    final result = await _run(const ['frobnicate']);
    expect(result.exitCode, 2);
  });

  test(
    'building a host-incompatible target fails cleanly before cargo runs',
    () async {
      final ciOnly = kTargets.where((t) => !hostBuildable(t)).toList();
      if (ciOnly.isEmpty) {
        markTestSkipped('all targets are host-buildable here');
        return;
      }
      final dir = await _tempDir();
      final target = ciOnly.first;
      final result = await _run([
        'build',
        target.name,
        '--out=${dir.path}',
      ]);
      expect(result.exitCode, 1);
      final output = '${result.stdout}${result.stderr}';
      expect(output, contains('BUILD FAILED'));
      expect(
        output,
        contains('not buildable on this host'),
        reason: 'must fail before invoking cargo for ${target.name}',
      );
    },
  );

  test('verify accepts a matching artifact and rejects a tampered one',
      () async {
    final dir = await _tempDir();
    final artifact = File('${dir.path}${Platform.pathSeparator}a.bin')
      ..writeAsBytesSync(List<int>.filled(64, 7));
    final manifest = makeManifest(
      kTargets.firstWhere((t) => t.name == 'windows-x64'),
      artifact,
    );
    final manifestFile = File('${dir.path}${Platform.pathSeparator}m.json')
      ..writeAsStringSync(jsonEncode(manifest));

    var result = await _run([
      'verify',
      '--artifact=${artifact.path}',
      '--manifest=${manifestFile.path}',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect((result.stdout as String), contains('ARTIFACT VERIFY PASSED'));

    artifact.writeAsBytesSync(List<int>.filled(64, 8));
    result = await _run([
      'verify',
      '--artifact=${artifact.path}',
      '--manifest=${manifestFile.path}',
    ]);
    expect(result.exitCode, 1);
    expect((result.stderr as String), contains('ARTIFACT VERIFY FAILED'));
    expect((result.stderr as String), contains('sha256 mismatch'));
  });

  test('verify with missing arguments exits 2', () async {
    final result = await _run(const ['verify']);
    expect(result.exitCode, 2);
    expect((result.stdout as String), contains('usage:'));
  });

  test('bundle with no manifests fails with exit 1', () async {
    final dir = await _tempDir();
    final result = await _run(['bundle', '--from=${dir.path}']);
    expect(result.exitCode, 1);
    expect((result.stderr as String), contains('BUNDLE FAILED'));
    expect((result.stderr as String), contains('no manifests'));
  });

  test('verifyArtifact compares sha256 case-insensitively', () {
    final dir = Directory.systemTemp.createTempSync('gecko-build-edge-');
    try {
      final artifact = File('${dir.path}${Platform.pathSeparator}a.bin')
        ..writeAsBytesSync(List<int>.filled(16, 3));
      final manifest = makeManifest(
        kTargets.firstWhere((t) => t.name == 'linux-x64'),
        artifact,
      );
      final manifestFile = File('${dir.path}${Platform.pathSeparator}m.json')
        ..writeAsStringSync(
          jsonEncode(
            {
              ...manifest,
              // Uppercase the digest — verification must still pass.
              'sha256': (manifest['sha256'] as String).toUpperCase(),
            },
          ),
        );
      expect(verifyArtifact(artifact, manifestFile), isTrue);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('makeManifest records triple, version, size and provenance', () {
    final dir = Directory.systemTemp.createTempSync('gecko-build-edge-');
    try {
      final artifact = File('${dir.path}${Platform.pathSeparator}a.bin')
        ..writeAsBytesSync(List<int>.generate(128, (i) => i));
      final target = kTargets.firstWhere((t) => t.name == 'macos-arm64');
      final manifest = makeManifest(target, artifact);
      expect(manifest['triple'], target.triple);
      expect(manifest['target'], 'macos');
      expect(manifest['architecture'], 'arm64');
      expect(manifest['version'], isA<String>());
      expect(manifest['sizeBytes'], 128);
      expect(manifest['sha256'], hasLength(64));
      final build = manifest['build'] as Map<String, dynamic>;
      expect(build['frbCodegenVersion'], '2.12.0');
      expect(build['hostPlatform'], isA<String>());
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('cargoOutput keeps the bare name only for windows and wasm', () {
    for (final target in kTargets) {
      final windowsOrWasm =
          target.triple.contains('windows') || target.triple.contains('wasm');
      if (windowsOrWasm) {
        expect(target.cargoOutput, target.artifactName, reason: target.name);
      } else {
        expect(
          target.cargoOutput,
          'lib${target.artifactName}',
          reason: target.name,
        );
      }
    }
  });

  test('crossEnv returns empty for non-android targets and linkers for android',
      () {
    final windows = kTargets.firstWhere((t) => t.name == 'windows-x64');
    expect(crossEnv(windows), isEmpty);
    final android = kTargets.firstWhere((t) => t.name == 'android-arm64');
    final env = crossEnv(android);
    if (env.isEmpty) {
      // No NDK on this host — the linker map is empty but android targets are
      // still classified as needing the NDK.
      expect(android.needsAndroidNdk, isTrue);
      expect(hostBuildable(android), isFalse);
    } else {
      final key =
          'CARGO_TARGET_${android.triple.toUpperCase().replaceAll('-', '_')}';
      expect(env, containsPair('${key}_LINKER', env['${key}_LINKER']));
      expect(env['CC_${android.triple.replaceAll('-', '_')}'], isNotNull);
    }
  });
}
