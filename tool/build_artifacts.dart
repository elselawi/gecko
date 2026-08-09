#!/usr/bin/env dart
// Workstream 7: cross-platform native artifact build orchestrator.
//
// Builds the `gecko_db_rust` cdylib for every release target from a pinned
// Rust toolchain, copies the artifact to an output directory, and writes a
// checksum + provenance manifest (the artifact the native resolver verifies).
//
// Targets buildable on the current host are built locally; the others are
// built by the CI release matrix (`.github/workflows/release-matrix.yml`) and
// are explicitly marked in `docs/compatibility.md` — a target is never
// silently skipped.
//
// Usage:
//   dart run tool/build_artifacts.dart list
//   dart run tool/build_artifacts.dart build windows-x64 --out=build/native
//   dart run tool/build_artifacts.dart build android-arm64 --out=build/native
//   dart run tool/build_artifacts.dart all --out=build/native
//   dart run tool/build_artifacts.dart verify --artifact=FILE --manifest=FILE
//   dart run tool/build_artifacts.dart bundle --from=build/native
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const String _packageVersion = '0.0.1';
const String _frbVersion = '2.12.0';
const int _androidApi = 24;

/// A release target in the compatibility matrix.
class BuildTarget {
  const BuildTarget({
    required this.name,
    required this.triple,
    required this.artifactName,
    required this.targetKey,
    required this.archKey,
    this.androidClang,
    this.needsAndroidNdk = false,
  });

  final String name;
  final String triple;
  final String artifactName;
  final String targetKey;
  final String archKey;
  final String? androidClang;
  final bool needsAndroidNdk;

  /// The produced file name inside cargo's `<triple>/release` directory.
  /// Windows and wasm cdylibs keep the bare name (`foo.dll`/`foo.wasm`);
  /// unix-like targets add a `lib` prefix (`libfoo.so`, `libfoo.dylib`).
  String get cargoOutput =>
      (triple.contains('windows') || triple.contains('wasm'))
      ? artifactName
      : 'lib$artifactName';
}

/// The full target registry (mirrors `docs/compatibility.md`).
const List<BuildTarget> kTargets = [
  BuildTarget(
    name: 'windows-x64',
    triple: 'x86_64-pc-windows-msvc',
    artifactName: 'gecko_db_rust.dll',
    targetKey: 'windows',
    archKey: 'x64',
  ),
  BuildTarget(
    name: 'linux-x64',
    triple: 'x86_64-unknown-linux-gnu',
    artifactName: 'libgecko_db_rust.so',
    targetKey: 'linux',
    archKey: 'x64',
  ),
  BuildTarget(
    name: 'macos-x64',
    triple: 'x86_64-apple-darwin',
    artifactName: 'libgecko_db_rust.dylib',
    targetKey: 'macos',
    archKey: 'x64',
  ),
  BuildTarget(
    name: 'macos-arm64',
    triple: 'aarch64-apple-darwin',
    artifactName: 'libgecko_db_rust.dylib',
    targetKey: 'macos',
    archKey: 'arm64',
  ),
  BuildTarget(
    name: 'android-arm64',
    triple: 'aarch64-linux-android',
    artifactName: 'gecko_db_rust.so',
    targetKey: 'android',
    archKey: 'arm64-v8a',
    androidClang: 'aarch64-linux-android$_androidApi-clang',
    needsAndroidNdk: true,
  ),
  BuildTarget(
    name: 'android-arm',
    triple: 'armv7-linux-androideabi',
    artifactName: 'gecko_db_rust.so',
    targetKey: 'android',
    archKey: 'armeabi-v7a',
    androidClang: 'armv7a-linux-androideabi$_androidApi-clang',
    needsAndroidNdk: true,
  ),
  BuildTarget(
    name: 'android-x86',
    triple: 'i686-linux-android',
    artifactName: 'gecko_db_rust.so',
    targetKey: 'android',
    archKey: 'x86',
    androidClang: 'i686-linux-android$_androidApi-clang',
    needsAndroidNdk: true,
  ),
  BuildTarget(
    name: 'android-x64',
    triple: 'x86_64-linux-android',
    artifactName: 'gecko_db_rust.so',
    targetKey: 'android',
    archKey: 'x86_64',
    androidClang: 'x86_64-linux-android$_androidApi-clang',
    needsAndroidNdk: true,
  ),
  BuildTarget(
    name: 'wasm32',
    triple: 'wasm32-unknown-unknown',
    artifactName: 'gecko_db_rust.wasm',
    targetKey: 'web',
    archKey: 'wasm32',
  ),
];

/// The monorepo root (parent of `rust/`).
String repoRoot() {
  final current = Directory.current.absolute.path;
  if (Directory('$current${Platform.pathSeparator}rust').existsSync()) {
    return current;
  }
  return Directory.current.parent.path;
}

/// Best-effort NDK llvm bin directory (Windows/macOS/Linux host layouts).
String? findAndroidNdkBin() {
  final sdk = Platform.environment['ANDROID_SDK_ROOT'] ??
      Platform.environment['ANDROID_HOME'] ??
      (Platform.isWindows
          ? '${Platform.environment['LOCALAPPDATA']}${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk'
          : null);
  if (sdk == null) return null;
  final ndkRoot = Directory('$sdk${Platform.pathSeparator}ndk');
  if (!ndkRoot.existsSync()) return null;
  final host = Platform.isWindows
      ? 'windows-x86_64'
      : Platform.isMacOS
      ? 'darwin-x86_64'
      : 'linux-x86_64';
  final versions = ndkRoot.listSync().whereType<Directory>().toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  for (final version in versions) {
    final bin = Directory(
      '${version.path}${Platform.pathSeparator}toolchains'
      '${Platform.pathSeparator}llvm${Platform.pathSeparator}prebuilt'
      '${Platform.pathSeparator}$host${Platform.pathSeparator}bin',
    );
    if (bin.existsSync()) return bin.path;
  }
  return null;
}

/// Whether this target can be built on the current host without a remote
/// runner (cargo target installed, and NDK present for android targets).
bool hostBuildable(BuildTarget target) {
  if (target.name == 'windows-x64') return Platform.isWindows;
  if (target.name == 'linux-x64') return Platform.isLinux;
  if (target.name.startsWith('macos-')) return Platform.isMacOS;
  if (target.name == 'wasm32') return true; // target installed by CI/bootstrap
  if (target.needsAndroidNdk) return findAndroidNdkBin() != null;
  return false;
}

/// Returns the cross-compilation environment cargo/cc-rs need for [target],
/// or an empty map when the host compiler suffices.
Map<String, String> crossEnv(BuildTarget target) {
  if (!target.needsAndroidNdk) return const {};
  final bin = findAndroidNdkBin();
  if (bin == null) return const {};
  final linker = '$bin${Platform.pathSeparator}${target.androidClang}'
      '${Platform.isWindows ? '.cmd' : ''}';
  final key = 'CARGO_TARGET_${target.triple.toUpperCase().replaceAll('-', '_')}';
  final ccKey = 'CC_${target.triple.replaceAll('-', '_')}';
  return {
    '${key}_LINKER': linker,
    ccKey: linker,
    'CXX_${target.triple.replaceAll('-', '_')}': linker,
    'AR_${target.triple.replaceAll('-', '_')}': '$bin${Platform.pathSeparator}llvm-ar${Platform.isWindows ? '.exe' : ''}',
    'RANLIB_${target.triple.replaceAll('-', '_')}': '$bin${Platform.pathSeparator}llvm-ranlib${Platform.isWindows ? '.exe' : ''}',
  };
}

/// Verifies FRB bindings are up to date (regenerate + clean git diff).
Future<void> checkBindings() async {
  final root = repoRoot();
  final result = await Process.run(
    'flutter_rust_bridge_codegen',
    ['generate', '--config-file', '$root${Platform.pathSeparator}frb.yaml'],
    workingDirectory: root,
  );
  if (result.exitCode != 0) {
    throw StateError('FRB codegen failed:\n${result.stderr}');
  }
  final diff = await Process.run('git', ['diff', '--exit-code'], workingDirectory: root);
  if (diff.exitCode != 0) {
    throw StateError(
      'FRB bindings are not in sync; run '
      '`flutter_rust_bridge_codegen generate --config-file frb.yaml`',
    );
  }
}

/// Builds [target] into [outDir] and writes its manifest. Returns the manifest
/// map. Buildable only when [hostBuildable] is true (CI builds the rest).
Future<Map<String, Object?>> build(BuildTarget target, String outDir) async {
  final root = repoRoot();
  if (!hostBuildable(target)) {
    throw StateError(
      'target "${target.name}" is not buildable on this host; it is built by '
      'the CI release matrix (see .github/workflows/release-matrix.yml)',
    );
  }
  final rustDir = '$root${Platform.pathSeparator}rust';
  final cargoResult = await Process.run(
    'cargo',
    ['build', '--release', '--target', target.triple],
    workingDirectory: rustDir,
    environment: {
      ...Platform.environment,
      ...crossEnv(target),
    },
  );
  if (cargoResult.exitCode != 0) {
    throw StateError(
      'cargo build --target ${target.triple} failed:\n${cargoResult.stdout}\n'
      '${cargoResult.stderr}',
    );
  }
  final source = File(
    '$rustDir${Platform.pathSeparator}target${Platform.pathSeparator}'
    '${target.triple}${Platform.pathSeparator}release'
    '${Platform.pathSeparator}${target.cargoOutput}',
  );
  if (!source.existsSync()) {
    throw StateError('build succeeded but artifact is missing: ${source.path}');
  }
  Directory(outDir).createSync(recursive: true);
  final destination = File('$outDir${Platform.pathSeparator}${target.artifactName}');
  source.copySync(destination.path);
  final manifest = makeManifest(target, destination);
  File('$outDir${Platform.pathSeparator}${target.name}.json')
      .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  return manifest;
}

/// Builds a manifest for [artifact] (produced by [target]).
Map<String, Object?> makeManifest(BuildTarget target, File artifact) {
  final digest = sha256.convert(artifact.readAsBytesSync()).toString();
  return {
    'schemaVersion': 1,
    'artifact': artifact.uri.pathSegments.last,
    'target': target.targetKey,
    'architecture': target.archKey,
    'triple': target.triple,
    'version': _packageVersion,
    'sha256': digest,
    'sizeBytes': artifact.lengthSync(),
    'build': {
      'commit': Platform.environment['GITHUB_SHA'] ?? _gitCommit() ?? 'local',
      'workflow': Platform.environment['GITHUB_WORKFLOW'] ?? 'local',
      'rustToolchain': Platform.environment['RUST_VERSION'] ?? _rustVersion() ?? 'unknown',
      'frbCodegenVersion': _frbVersion,
      'hostPlatform': '${Platform.operatingSystem}-${Platform.version}',
      'sourceDateEpoch': Platform.environment['SOURCE_DATE_EPOCH'] ?? 'unset',
    },
  };
}

String? _gitCommit() {
  final result = Process.runSync('git', ['rev-parse', 'HEAD']);
  if (result.exitCode != 0) return null;
  return (result.stdout as String).trim();
}

String? _rustVersion() {
  final result = Process.runSync('rustc', ['--version']);
  if (result.exitCode != 0) return null;
  return (result.stdout as String).trim();
}

/// Copies every built artifact in [fromDir] into the package's bundled
/// `packages/gecko_db/lib/native/<target>/<arch>/` layout so the native
/// resolver can find it without build steps (bundledArtifactPath). Artifacts
/// live under `lib/` because `package:` URIs resolve there.
void bundle(String fromDir) {
  final root = repoRoot();
  final manifests = Directory(fromDir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList();
  if (manifests.isEmpty) {
    stderr.writeln('BUNDLE FAILED: no manifests found in $fromDir');
    exitCode = 1;
    return;
  }
  for (final manifestFile in manifests) {
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final artifactName = manifest['artifact'] as String;
    final target = manifest['target'] as String;
    final arch = manifest['architecture'] as String;
    final source = File('$fromDir${Platform.pathSeparator}$artifactName');
    final destDir = Directory(
      '$root${Platform.pathSeparator}packages${Platform.pathSeparator}gecko_db'
      '${Platform.pathSeparator}lib${Platform.pathSeparator}native'
      '${Platform.pathSeparator}$target${Platform.pathSeparator}$arch',
    )..createSync(recursive: true);
    final dest = File('${destDir.path}${Platform.pathSeparator}$artifactName');
    source.copySync(dest.path);
    manifestFile.copySync(
      '${destDir.path}${Platform.pathSeparator}manifest.json',
    );
    stdout.writeln('BUNDLED $target/$arch/$artifactName');
  }
}

/// Verifies [artifact] against a manifest written by `makeManifest`. Returns
/// true when the SHA-256 matches.
bool verifyArtifact(File artifact, File manifestFile) {
  final decoded =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final expected = decoded['sha256'] as String;
  final actual = sha256.convert(artifact.readAsBytesSync()).toString();
  if (actual.toLowerCase() != expected.toLowerCase()) {
    stderr.writeln(
      'ARTIFACT VERIFY FAILED: sha256 mismatch for ${artifact.path} '
      '(expected $expected, actual $actual)',
    );
    return false;
  }
  stdout.writeln('ARTIFACT VERIFY PASSED: ${artifact.path}');
  return true;
}

void main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    return;
  }
  switch (args[0]) {
    case 'list':
      for (final target in kTargets) {
        final status = hostBuildable(target) ? 'host-buildable' : 'ci-only';
        stdout.writeln(
          '${target.name.padRight(16)} ${target.triple.padRight(26)} '
          '${target.artifactName.padRight(24)} $status',
        );
      }
      return;
    case 'build':
      final name = args[1];
      final out = _argValue(args, '--out') ?? 'build/native';
      BuildTarget? target;
      for (final candidate in kTargets) {
        if (candidate.name == name) {
          target = candidate;
          break;
        }
      }
      if (target == null) {
        stderr.writeln('unknown target "$name"');
        _usage();
        exitCode = 2;
        return;
      }
      try {
        final manifest = await build(target, out);
        stdout.writeln(
          'BUILT ${target.name} -> $out/${target.artifactName} '
          '(sha256 ${(manifest['sha256'] as String).substring(0, 12)}...)',
        );
      } on StateError catch (error) {
        stderr.writeln('BUILD FAILED: $error');
        exitCode = 1;
      }
    case 'all':
      final out = _argValue(args, '--out') ?? 'build/native';
      var failed = false;
      for (final target in kTargets) {
        if (!hostBuildable(target)) continue;
        try {
          final manifest = await build(target, out);
          stdout.writeln(
            'BUILT ${target.name} -> $out/${target.artifactName} '
            '(sha256 ${(manifest['sha256'] as String).substring(0, 12)}...)',
          );
        } on StateError catch (error) {
          stderr.writeln('BUILD FAILED ${target.name}: $error');
          failed = true;
        }
      }
      if (failed) exitCode = 1;
    case 'verify':
      final artifact = _argValue(args, '--artifact');
      final manifest = _argValue(args, '--manifest');
      if (artifact == null || manifest == null) {
        _usage();
        exitCode = 2;
        return;
      }
      if (!verifyArtifact(File(artifact), File(manifest))) {
        exitCode = 1;
      }
    case 'bundle':
      final from = _argValue(args, '--from') ?? 'build/native';
      bundle(from);
    case 'check-bindings':
      try {
        await checkBindings();
        stdout.writeln('BINDINGS OK');
      } on StateError catch (error) {
        stderr.writeln('BINDINGS CHECK FAILED: $error');
        exitCode = 1;
      }
    default:
      _usage();
      exitCode = 2;
  }
}

String? _argValue(List<String> args, String name) {
  for (final arg in args.skip(1)) {
    if (arg.startsWith('$name=')) return arg.substring(name.length + 1);
  }
  return null;
}

void _usage() {
  stdout.writeln(
    'usage: dart run tool/build_artifacts.dart <list|build|all|bundle|verify|check-bindings> '
    '[target] [--out=DIR] [--from=DIR] [--artifact=FILE --manifest=FILE]',
  );
}
