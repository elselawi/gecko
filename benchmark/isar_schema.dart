// comparative-benchmark schema: isar_community collection.
//
// This file is DEV TOOLING ONLY (not part of the gecko_db product). It exists
// so `benchmark/comparative.dart` can race gecko_db against Isar under the
// same fixtures. The generated file (`isar_schema.g.dart`) is produced by
// `dart run build_runner build` and is committed so the benchmark runs
// without a build step.
//
// Note on the fork: the original `isar`/`isar_generator` packages are in
// maintenance mode and the generator rejects the current Dart SDK (pre
// null-safety constraint), so the actively-maintained `isar_community` fork
// is used instead. API and file layout are the same.
import 'package:isar_community/isar.dart';

part 'isar_schema.g.dart';

/// One benchmark row, mirroring the `_row(id, num, group)` fixture shared by
/// every backend. The benchmark offsets the external id by +1 because Isar
/// ids must be non-zero; the accessor maps back to the external id.
@collection
class Item {
  /// Isar row id = external id + 1.
  Id id = Isar.autoIncrement;

  late int num;

  @Index()
  late String group;
}
