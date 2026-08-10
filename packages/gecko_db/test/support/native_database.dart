import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

/// Opens an isolated native database for a test and registers deterministic
/// temporary-directory cleanup. This is the M7.5 replacement for `mem://`
/// fixtures; tests exercise the same Rust/redb path used by the product.
Future<DatabaseImpl> openNativeTestDatabase(
  String name, {
  DatabaseConfig config = const DatabaseConfig(),
}) async {
  final directory = await Directory.systemTemp.createTemp('gecko-$name-');
  addTearDown(() async {
    try {
      await directory.delete(recursive: true);
    } catch (_) {
      // A crash-injection test may already have removed the directory.
    }
  });
  final path = '${directory.path}${Platform.pathSeparator}db.redb';
  final configured = DatabaseConfig(
    readOnly: config.readOnly,
    encryptionKey: config.encryptionKey,
    encryptionKeyGeneration: config.encryptionKeyGeneration,
    nativeLibraryPath: config.nativeLibraryPath ?? _nativeLibraryPath(),
    inFlightBatchLimit: config.inFlightBatchLimit,
    lruCapacity: config.lruCapacity,
    lruMaxWeight: config.lruMaxWeight,
    clock: config.clock,
    changeLogMaxEntries: config.changeLogMaxEntries,
    maxKnownSchemaVersion: config.maxKnownSchemaVersion,
    slowQueryThresholdMicros: config.slowQueryThresholdMicros,
    compactionSnapshotDrainTimeout: config.compactionSnapshotDrainTimeout,
  );
  return DatabaseImpl.open(path, config: configured, useInMemory: false);
}

String _nativeLibraryPath() {
  final root = Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )
      ? Directory.current.parent.parent.path
      : Directory.current.path;
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}
