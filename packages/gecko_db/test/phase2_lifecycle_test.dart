import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

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

        final db = await DatabaseImpl.open(path, useInMemory: true);
        expect(DatabaseImpl.isOpenAt(path), isTrue);
        await db.close();
        expect(DatabaseImpl.isOpenAt(path), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('concurrent same-path opens admit only one database', () async {
    const path = 'mem://concurrent-open';
    final attempts = await Future.wait<Object?>([
      DatabaseImpl.open(path, useInMemory: true).then<Object?>((db) => db),
      DatabaseImpl.open(path, useInMemory: true).then<Object?>(
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
    final db = await DatabaseImpl.open(
      'mem://close-idempotent',
      useInMemory: true,
    );
    await Future.wait([db.close(), db.close()]);
    expect(DatabaseImpl.isOpenAt('mem://close-idempotent'), isFalse);
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
