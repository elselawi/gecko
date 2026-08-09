#!/usr/bin/env dart
// Generates a checksum and provenance manifest for a native release artifact.
//
// Example:
// dart run tool/artifact_manifest.dart \
//   --artifact=rust/target/release/libgecko_db_rust.so \
//   --target=linux --arch=x64 --version=0.0.1 \
//   --output=rust/artifact-manifest.json

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(List<String> args) {
  final values = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--') || !arg.contains('=')) continue;
    final separator = arg.indexOf('=');
    values[arg.substring(2, separator)] = arg.substring(separator + 1);
  }

  final artifactPath = values['artifact'];
  final target = values['target'];
  final architecture = values['arch'];
  final version = values['version'];
  final outputPath = values['output'] ?? 'artifact-manifest.json';
  if ([
    artifactPath,
    target,
    architecture,
    version,
  ].any((value) => value == null || value.isEmpty)) {
    stderr.writeln(
      'Usage: dart run tool/artifact_manifest.dart '
      '--artifact=PATH --target=TARGET --arch=ARCH --version=VERSION '
      '[--output=PATH]',
    );
    exitCode = 2;
    return;
  }

  final artifact = File(artifactPath!);
  if (!artifact.existsSync()) {
    stderr.writeln('ARTIFACT MANIFEST FAILED: missing ${artifact.path}');
    exitCode = 1;
    return;
  }

  final digest = sha256.convert(artifact.readAsBytesSync()).toString();
  final environment = Platform.environment;
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'artifact': artifact.uri.pathSegments.last,
    'target': target,
    'architecture': architecture,
    'version': version,
    'sha256': digest,
    'sizeBytes': artifact.lengthSync(),
    'build': <String, Object?>{
      'commit': environment['GITHUB_SHA'] ?? 'local',
      'workflow': environment['GITHUB_WORKFLOW'] ?? 'local',
      'rustToolchain': environment['RUST_VERSION'] ?? 'unknown',
      'frbCodegenVersion': '2.12.0',
      'sourceDateEpoch': environment['SOURCE_DATE_EPOCH'] ?? 'unset',
    },
  };

  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  stdout.writeln('Wrote ${output.path} (${digest.substring(0, 12)}...)');
}
