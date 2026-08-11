// cross-platform artifact build/verify/bundle tests.
//
// Verifies the target registry, host-buildability classification, manifest
// generation + SHA-256 verification round-trip, and that the bundled native
// directory contains a verifiable artifact for the current host.
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart' show bundledArtifactPath;
import 'package:test/test.dart';

import 'build_artifacts.dart';

void main() {
  test('target registry covers the release matrix with stable names', () {
    final names = kTargets.map((t) => t.name).toSet();
    for (final expected in [
      'windows-x64',
      'linux-x64',
      'macos-x64',
      'macos-arm64',
      'android-arm64',
      'android-arm',
      'android-x86',
      'android-x64',
      'wasm32',
    ]) {
      expect(names, contains(expected));
    }
    // Every android target carries a clang name and needs the NDK.
    for (final target in kTargets.where((t) => t.needsAndroidNdk)) {
      expect(target.androidClang, isNotNull);
    }
    // Windows and wasm keep the bare name in cargo output.
    final windows = kTargets.firstWhere((t) => t.name == 'windows-x64');
    final wasm = kTargets.firstWhere((t) => t.name == 'wasm32');
    expect(windows.cargoOutput, 'gecko_db_rust.dll');
    expect(wasm.cargoOutput, 'gecko_db_rust.wasm');
    final android = kTargets.firstWhere((t) => t.name == 'android-arm64');
    expect(android.cargoOutput, 'libgecko_db_rust.so');
  });

  test('host-buildability matches the current platform', () {
    final windows = kTargets.firstWhere((t) => t.name == 'windows-x64');
    expect(hostBuildable(windows), Platform.isWindows);
    // On every host, wasm is declared buildable (target installed by setup).
    expect(
      hostBuildable(kTargets.firstWhere((t) => t.name == 'wasm32')),
      isTrue,
    );
  });

  test('manifest round-trips and verify accepts a matching artifact', () {
    final dir = Directory.systemTemp.createTempSync('gecko-artifact-');
    try {
      final artifact = File('${dir.path}${Platform.pathSeparator}blob.bin')
        ..writeAsBytesSync(List<int>.generate(1024, (i) => i % 251));
      final target = kTargets.firstWhere((t) => t.name == 'windows-x64');
      final manifest = makeManifest(target, artifact);
      expect(manifest['sha256'], hasLength(64));
      expect(manifest['target'], 'windows');
      expect(manifest['sizeBytes'], 1024);
      final manifestFile = File('${dir.path}${Platform.pathSeparator}m.json')
        ..writeAsStringSync(jsonEncode(manifest));
      expect(verifyArtifact(artifact, manifestFile), isTrue);
      // A tampered artifact is rejected.
      artifact.writeAsBytesSync(List<int>.filled(1024, 1));
      expect(verifyArtifact(artifact, manifestFile), isFalse);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('the current host has a bundled, verifiable artifact', () async {
    final bundled = await bundledArtifactPath();
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      expect(bundled, isNull, reason: 'unsupported host must not resolve');
      return;
    }
    expect(bundled, isNotNull);
    final artifact = File(bundled!);
    expect(
      artifact.existsSync(),
      isTrue,
      reason: 'bundled artifact must exist at $bundled',
    );
    final manifestFile = File(
      '${artifact.parent.path}${Platform.pathSeparator}manifest.json',
    );
    expect(manifestFile.existsSync(), isTrue);
    expect(verifyArtifact(artifact, manifestFile), isTrue);
  });
}
