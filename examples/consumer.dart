// Minimal consumer fixture (Workstream 6).
//
// This file deliberately imports ONLY the public `package:gecko_db/gecko_db.dart`
// surface — exactly what an external consumer would write, with no
// repository-internal (`package:gecko_db/src/...`) imports. It exercises the
// full flow: import → open → write → read → watch → query → migrate → encrypt
// → maintain → close, and prints `CONSUMER-OK` on success. M6.5 uses one raw
// key and removes custom providers.
//
// Usage:
//   dart run examples/consumer.dart <dbPath> <nativeLibPath> [hexEncryptionKey]
//
// `tool/consumer_fixture_test.dart` runs this in a subprocess and asserts both
// the success marker and that no internal imports crept in.
library;

import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

List<int> _decodeHexKey(String value) {
  final cleaned = value.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) {
    throw const FormatException('expected exactly 64 hexadecimal characters');
  }
  return [
    for (var i = 0; i < cleaned.length; i += 2)
      int.parse(cleaned.substring(i, i + 2), radix: 16),
  ];
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    throw ArgumentError('usage: consumer.dart <dbPath> <nativeLib> [hexKey]');
  }
  final dbPath = args[0];
  final nativeLib = args[1];
  final key = args.length > 2 ? _decodeHexKey(args[2]) : null;

  final db = await Database.open(
    dbPath,
    config: DatabaseConfig(nativeLibraryPath: nativeLib, encryptionKey: key),
  );
  try {
    final notes = db.collection<Map<String, Object?>>(
      'notes',
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );

    // Write.
    await notes.put({'id': 'n1', 'text': 'hello', 'priority': 1});

    // Read.
    final read = await notes.get('n1');
    if (read == null || read['text'] != 'hello') {
      throw StateError('consumer: read-back mismatch');
    }

    // Watch (reactive).
    final seen = <String?>[];
    final sub = notes
        .watch('n1')
        .listen((n) => seen.add(n?['text'] as String?));
    await notes.patch('n1', {'text': 'updated'});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await sub.cancel();
    if (!seen.contains('updated')) {
      throw StateError('consumer: watch did not emit the update');
    }

    // Query.
    final high = await notes.where().range('priority', min: 1).findAll();
    if (high.length != 1) {
      throw StateError('consumer: indexed query returned ${high.length} rows');
    }

    // Migrate.
    await db.schema.stamp(1);
    await db.schema.migrateStep(
      const MigrationStep(
        name: 'v1',
        fromVersion: 1,
        toVersion: 2,
        rewritesRecords: false,
      ),
    );

    // Maintain (compaction + size reporting).
    await db.maintenance.compact();
    final stats = await db.maintenance.storageStats();
    if (stats.physicalBytes <= 0 || stats.logicalBytes <= 0) {
      throw StateError('consumer: storage stats look wrong: $stats');
    }

    await db.close();
    stdout.writeln('CONSUMER-OK');
  } finally {
    await db.close();
  }
}
