import 'dart:io';

import 'package:gecko_db/gecko_db.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('gecko-advanced-');
  final db = await DatabaseImpl.open(
    '${dir.path}${Platform.pathSeparator}db.redb',
  );
  db.diagnostics.enable();

  await db.bulkWrite([
    const BulkMutation.put(
      table: 'settings',
      key: 'theme',
      value: {'value': 'dark'},
    ),
    const BulkMutation.put(
      table: 'settings',
      key: 'sync',
      value: {'value': 'enabled'},
    ),
  ]);

  final stats = db.diagnostics.snapshot();
  if (stats.totalWrites == 0 || stats.inFlightLimit <= 0) {
    throw StateError('Diagnostics did not observe the bulk write');
  }

  await db.schema.stamp(1);
  await db.schema.migrateStep(
    const MigrationStep(
      name: 'add-settings-version',
      fromVersion: 1,
      toVersion: 2,
      rewritesRecords: false,
    ),
  );

  await db.close();
  await dir.delete(recursive: true);
}
