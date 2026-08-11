// Audit-driven native-resolver / platform-seam edge tests (audited-test-gaps
// 2.18). Covers path splitting/ordering from GECKO_DB_RESOLVER_PATHS,
// bundledArtifactPath per host, checksum verification, and manifest output.

import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

Future<Directory> _temp() async {
  final dir = await Directory.systemTemp.createTemp('gecko-resolver-');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

NativeArtifact _artifact(String path) {
  final bytes = File(path).readAsBytesSync();
  return NativeArtifact(
    version: '0.0.1-test',
    sha256: nativeArtifactSha256(bytes),
    bundledPath: path,
  );
}

void main() {
  group('2.18 native resolver', () {
    test(
      'override paths split on the platform separator, skipping empties',
      () async {
        final dir = await _temp();
        final validFile = File('${dir.path}${Platform.pathSeparator}good.bin')
          ..writeAsBytesSync([1, 2, 3]);
        final artifact = _artifact(validFile.path);
        final separator = Platform.isWindows ? ';' : ':';
        final resolver = NativeResolver(
          overridePaths:
              '${dir.path}${Platform.pathSeparator}missing-1$separator'
              '${dir.path}${Platform.pathSeparator}missing-2$separator'
              '$separator'
              '${validFile.path}$separator'
              '${dir.path}${Platform.pathSeparator}missing-3',
        );
        // Empty segments are skipped; the valid file (third real segment) wins.
        expect(await resolver.resolve(artifact), validFile.path);
      },
    );

    test('override paths take precedence over the bundled artifact', () async {
      final dir = await _temp();
      final override = File('${dir.path}${Platform.pathSeparator}override.bin')
        ..writeAsBytesSync([9, 9, 9]);
      final artifact = _artifact(override.path);
      final resolver = NativeResolver(overridePaths: override.path);
      expect(await resolver.resolve(artifact), override.path);
    });

    test('checksum mismatch skips a candidate (no crash)', () async {
      final dir = await _temp();
      final bad = File('${dir.path}${Platform.pathSeparator}bad.bin')
        ..writeAsBytesSync([1, 2, 3]);
      final artifact = NativeArtifact(
        version: '0.0.1-test',
        sha256: '0' * 64, // wrong checksum
        downloadUri: null,
      );
      final resolver = NativeResolver(overridePaths: bad.path);
      await expectLater(
        resolver.resolve(artifact),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
    });

    test('bundledArtifactPath returns the current-host artifact', () async {
      final path = await bundledArtifactPath();
      if (Platform.isWindows) {
        expect(path, isNotNull);
        expect(path, endsWith('gecko_db_rust.dll'));
      } else if (Platform.isMacOS) {
        expect(path, endsWith('libgecko_db_rust.dylib'));
      } else if (Platform.isLinux) {
        expect(path, endsWith('libgecko_db_rust.so'));
      }
    });

    test('nativeArtifactSha256 and manifest round-trip', () async {
      final dir = await _temp();
      final bytes = List<int>.generate(64, (i) => i * 3 % 251);
      final file = File('${dir.path}${Platform.pathSeparator}a.bin')
        ..writeAsBytesSync(bytes);
      final artifact = _artifact(file.path);
      expect(nativeArtifactSha256(bytes), artifact.sha256);
      final manifest = jsonDecode(nativeArtifactManifest(artifact)) as Map;
      expect(manifest['version'], artifact.version);
      expect(manifest['sha256'], artifact.sha256);
      expect(manifest['bundledPath'], artifact.bundledPath);
    });

    test(
      'isWeb is false and registerOpfsHandle is web-only on the VM',
      () async {
        expect(isWeb, isFalse);
        final error = await registerOpfsHandle('vm.db');
        expect(error, isNotNull);
        expect(error, contains('web'));
      },
    );
  });
}
