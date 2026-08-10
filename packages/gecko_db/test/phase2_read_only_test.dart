import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

void main() {
  test('native read-only database rejects all write entry points', () async {
    final directory = await Directory.systemTemp.createTemp('gecko-readonly-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}db.redb';
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
    expect(
      () => collection.put({'id': 'a', 'value': 1}),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.invalidOperation,
        ),
      ),
    );
    expect(() => collection.delete('a'), throwsA(isA<GeckoError>()));
    expect(() => db.bulkWrite(const []), throwsA(isA<GeckoError>()));
    expect(() => db.writeTxn((_) async {}), throwsA(isA<GeckoError>()));
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
        writer = await DatabaseImpl.open(
          path,
          useInMemory: false,
          config: config,
        );
        const codec = DefaultWireCodec();
        final key = ByteKey(codec.encode('key'));
        await writer.engine.rawPut('items', key, codec.encode({'value': 42}));
        await writer.close();
        writer = null;

        reader = await DatabaseImpl.open(
          path,
          useInMemory: false,
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
