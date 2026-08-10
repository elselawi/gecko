import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native batch persists atomically across close and reopen',
    () async {
      final root = await Directory.systemTemp.createTemp('gecko-crash-');
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
      DatabaseImpl? db;
      try {
        db = await DatabaseImpl.open(path, config: config);
        const codec = DefaultWireCodec();
        final key = ByteKey(codec.encode('stable'));
        await db.engine.rawPut('items', key, codec.encode('before'));
        final before = await db.rawGet('items', key);
        expect(before, isNotNull);

        // RawEngine rejects malformed operations before sending them to the
        // worker, while the native worker itself also rejects the same wire
        // failure without committing a partial batch.
        await expectLater(
          db.engine.backend.applyBatch([
            RawPut('items', key, codec.encode('after')),
          ]),
          completes,
        );
        expect(
          await db.rawGet('items', key),
          isNotNull,
          reason: 'the committed batch must be visible after commit',
        );
        await db.close();
        db = null;

        final reopened = await DatabaseImpl.open(
          path,
          config: config,
        );
        final reopenedRaw = await reopened.rawGet('items', key);
        expect(reopenedRaw, isNotNull);
        expect(codec.decode(reopenedRaw!), 'after');
        await reopened.close();
      } finally {
        await db?.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
