// consumer-fixture gate.
//
// The consumer fixture (`examples/consumer.dart`) is exactly what an external
// consumer would write — it must import ONLY the public
// `package:gecko_db/gecko_db.dart` surface (no `package:gecko_db/src/...`
// internals), and it must actually run end-to-end: import → open → write →
// read → watch → query → migrate → encrypt → maintain → close.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

void main() {
  final root = _repoRoot();

  test('consumer fixture imports only the public package surface', () {
    final source = File(
      '$root${Platform.pathSeparator}examples'
      '${Platform.pathSeparator}consumer.dart',
    ).readAsStringSync();
    // Only `package:gecko_db/gecko_db.dart` (the barrel) is allowed.
    final forbidden = source
        .split('\n')
        .where((l) => l.contains("import 'package:gecko_db/src/"))
        .toList();
    expect(
      forbidden,
      isEmpty,
      reason:
          'the consumer fixture must not use repository-internal imports: '
          '$forbidden',
    );
    expect(source, contains('package:gecko_db/gecko_db.dart'));
  });

  test(
    'consumer fixture runs end-to-end (plaintext)',
    () async {
      final dir = await Directory.systemTemp.createTemp('gecko-consumer-');
      final dbPath = '${dir.path}${Platform.pathSeparator}db.redb';
      try {
        final process = await Process.start(
          Platform.resolvedExecutable,
          ['run', 'examples/consumer.dart', dbPath, _nativeLibraryPath(root)],
          workingDirectory: root,
          mode: ProcessStartMode.normal,
        );
        final stdout = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .join();
        final stderr = await process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .join();
        final exit = await process.exitCode;
        expect(exit, 0, reason: 'stderr: $stderr');
        expect(stdout, contains('CONSUMER-OK'));
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'consumer fixture runs end-to-end (physically encrypted)',
    () async {
      final dir = await Directory.systemTemp.createTemp('gecko-consumer-enc-');
      final dbPath = '${dir.path}${Platform.pathSeparator}db.redb';
      final key = List<int>.filled(
        32,
        0x7C,
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      try {
        final process = await Process.start(
          Platform.resolvedExecutable,
          [
            'run',
            'examples/consumer.dart',
            dbPath,
            _nativeLibraryPath(root),
            key,
          ],
          workingDirectory: root,
          mode: ProcessStartMode.normal,
        );
        final stdout = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .join();
        final stderr = await process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .join();
        final exit = await process.exitCode;
        expect(exit, 0, reason: 'stderr: $stderr');
        expect(stdout, contains('CONSUMER-OK'));
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
