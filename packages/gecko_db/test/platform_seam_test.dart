// Platform-seam tests for the web/native conditional code introduced with the
// web runtime (/ ). These exercise the *native* variants
// on the VM test runner; the web variants are validated live by the browser
// smoke suites (tool/web_smoke).
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/native/host_arch.dart' show hostArchitecture;
import 'package:test/test.dart';

void main() {
  group('platform seam (VM)', () {
    test('isWeb is false on the VM (dart.library.js_interop not defined)', () {
      expect(isWeb, isFalse);
    });

    test('bundledWebGluePrefix is null on the VM (no web glue URL)', () async {
      expect(await bundledWebGluePrefix(), isNull);
    });

    test('registerOpfsHandle reports OPFS as web-only on the VM', () async {
      final error = await registerOpfsHandle('vm.db');
      expect(error, isNotNull);
      expect(error, contains('web'));
    });

    test('hostArchitecture classifies the running host', () {
      final arch = hostArchitecture();
      expect(arch, isNotNull);
      expect(
        arch,
        anyOf(
          'x64',
          'arm64',
          'arm',
          'x86',
          'arm64-v8a',
          'armeabi-v7a',
          'x86_64',
        ),
      );
    });

    test('bundledArtifactPath resolves the OS-correct artifact name', () async {
      final bundled = await bundledArtifactPath();
      if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
        expect(bundled, isNull);
        return;
      }
      expect(bundled, isNotNull);
      final expected = Platform.isWindows
          ? 'gecko_db_rust.dll'
          : Platform.isMacOS
          ? 'libgecko_db_rust.dylib'
          : 'libgecko_db_rust.so';
      expect(bundled, endsWith(expected));
    });

    test('bundledArtifactPath lives under lib/native/<os>/<arch>', () async {
      final bundled = await bundledArtifactPath();
      if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
        return;
      }
      expect(bundled, isNotNull);
      final osDir = Platform.isWindows
          ? 'native${Platform.pathSeparator}windows'
          : Platform.isMacOS
          ? 'native${Platform.pathSeparator}macos'
          : 'native${Platform.pathSeparator}linux';
      expect(bundled, contains(osDir));
    });

    test('bundledNativeDir is the package-native directory on the VM', () {
      expect(bundledNativeDir, 'native');
    });
  });
}
