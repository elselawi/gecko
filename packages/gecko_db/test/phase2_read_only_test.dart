import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test('native read-only database rejects all write entry points', () async {
    final directory = await Directory.systemTemp.createTemp('gecko-readonly-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}db.redb';
    // A native read-only open requires an existing store: create it first.
    final writer = await DatabaseImpl.open(path);
    await writer.close();

    final db = await DatabaseImpl.open(
      path,
      config: const DatabaseConfig(readOnly: true),
    );
    final collection = db.collection<Map<String, Object?>>(
      'items',
      toRow: (value) => value,
      fromRow: (row) => Map<String, Object?>.from(row as Map),
      id: (value) => value['id'],
    );

    expect(db.isReadOnly, isTrue);
    await expectLater(
      collection.put({'id': 'a', 'value': 1}),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.invalidOperation,
        ),
      ),
    );
    await expectLater(collection.delete('a'), throwsA(isA<GeckoError>()));
    await expectLater(db.bulkWrite(const []), throwsA(isA<GeckoError>()));
    await expectLater(db.writeTxn((_) async {}), throwsA(isA<GeckoError>()));
    await db.close();
  });

  test(
    'native read-only database can read but cannot write',
    () async {
      final root = await Directory.systemTemp.createTemp('gecko-read-only-');
      final path = '${root.path}${Platform.pathSeparator}database.redb';
      final repositoryRoot =
          Directory.current.path.endsWith(
            'packages${Platform.pathSeparator}gecko_db',
          )
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final libraryName = Platform.isWindows
          ? 'gecko_db_rust.dll'
          : Platform.isMacOS
          ? 'libgecko_db_rust.dylib'
          : 'libgecko_db_rust.so';
      final nativePath =
          '$repositoryRoot${Platform.pathSeparator}rust${Platform.pathSeparator}'
          'target${Platform.pathSeparator}release${Platform.pathSeparator}$libraryName';
      final config = DatabaseConfig(nativeLibraryPath: nativePath);

      DatabaseImpl? writer;
      DatabaseImpl? reader;
      try {
        writer = await DatabaseImpl.open(path, config: config);
        const codec = DefaultWireCodec();
        final key = ByteKey(codec.encode('key'));
        await writer.engine.rawPut('items', key, codec.encode({'value': 42}));
        await writer.close();
        writer = null;

        reader = await DatabaseImpl.open(
          path,
          config: DatabaseConfig(nativeLibraryPath: nativePath, readOnly: true),
        );
        expect(reader.isReadOnly, isTrue);
        expect(await reader.rawGet('items', key), isNotNull);
        expect(
          () => reader!.engine.rawPut('items', key, [1]),
          throwsA(isA<GeckoError>()),
        );
        await reader.close();
        reader = null;
      } finally {
        await reader?.close();
        await writer?.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
