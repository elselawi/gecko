import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  test(
    'failed native startup can be retried after the bad library path',
    () async {
      final root = await Directory.systemTemp.createTemp('gecko-retry-');
      final path = '${root.path}${Platform.pathSeparator}database.redb';
      try {
        await expectLater(
          DatabaseImpl.open(
            path,
            useInMemory: false,
            config: const DatabaseConfig(
              nativeLibraryPath: 'missing-native.dll',
            ),
          ),
          throwsA(isA<GeckoError>()),
        );
        expect(DatabaseImpl.isOpenAt(path), isFalse);

        final db = await DatabaseImpl.open(path);
        expect(DatabaseImpl.isOpenAt(path), isTrue);
        await db.close();
        expect(DatabaseImpl.isOpenAt(path), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('concurrent same-path opens admit only one database', () async {
    final directory = await Directory.systemTemp.createTemp('gecko-concurrent-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}db.redb';
    final attempts = await Future.wait<Object?>([
      DatabaseImpl.open(path).then<Object?>((db) => db),
      DatabaseImpl.open(path).then<Object?>(
        (db) => db,
        onError: (Object error, StackTrace stack) => error,
      ),
    ]);
    final live = attempts.whereType<DatabaseImpl>().toList();
    expect(live, hasLength(1));
    expect(attempts.whereType<GeckoError>(), hasLength(1));
    expect(DatabaseImpl.isOpenAt(path), isTrue);
    await live.single.close();
  });

  test('close is idempotent and rejects new operations', () async {
    final directory = await Directory.systemTemp.createTemp('gecko-close-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}db.redb';
    final db = await DatabaseImpl.open(path);
    await Future.wait([db.close(), db.close()]);
    expect(DatabaseImpl.isOpenAt(path), isFalse);
    expect(
      () => db.collection<Object?>(
        'items',
        toRow: (value) => value,
        fromRow: (row) => row,
      ),
      throwsA(isA<GeckoError>()),
    );
  });
}
