// M12 comparative-benchmark schema: drift database.
//
// DEV TOOLING ONLY (not part of the gecko_db product). This is a minimal
// drift database so `benchmark/comparative.dart` can race gecko_db against
// Drift under the same fixtures. The generated file (`drift_database.g.dart`)
// is produced by `dart run build_runner build` and committed so the benchmark
// runs without a build step.
//
// Drift is a typed layer over SQLite; the native library is provided by
// `package:sqlite3`, so the vendored public-domain `sqlite3.dll` is shared
// with the plain-SQLite backend (see `comparative.dart`).
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'drift_database.g.dart';

/// One benchmark row, mirroring the `_row(id, num, group)` fixture shared by
/// every backend.
@DataClassName('ItemRow')
class Items extends Table {
  IntColumn get id => integer()();
  IntColumn get num => integer()();
  TextColumn get group => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DriftDatabase(tables: [Items])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  AppDatabase.openFile(String path) : super(NativeDatabase(File(path)));

  @override
  int get schemaVersion => 1;
}
