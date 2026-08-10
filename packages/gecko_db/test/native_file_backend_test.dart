import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test(
    'file-backed redb worker opens, writes, reads, scans, and reopens',
    () async {
      final root = await Directory.systemTemp.createTemp('gecko-native-test-');
      final path = '${root.path}${Platform.pathSeparator}database.redb';
      final repositoryRoot =
          Directory.current.path.endsWith(
            'packages${Platform.pathSeparator}gecko_db',
          )
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final nativeLibraryName = Platform.isWindows
          ? 'gecko_db_rust.dll'
          : Platform.isMacOS
          ? 'libgecko_db_rust.dylib'
          : 'libgecko_db_rust.so';
      final nativePath =
          '$repositoryRoot${Platform.pathSeparator}rust${Platform.pathSeparator}target${Platform.pathSeparator}release${Platform.pathSeparator}$nativeLibraryName';
      final config = DatabaseConfig(nativeLibraryPath: nativePath);

      DatabaseImpl? db;
      try {
        db = await DatabaseImpl.open(path, config: config);
        const codec = DefaultWireCodec();
        final key = ByteKey(codec.encode('key'));
        await db.engine.rawPut('items', key, codec.encode({'value': 42}));
        final raw = await db.rawGet('items', key);
        expect(codec.decode(raw!), {'value': 42});
        final scan = await db.engine.rawRangeScan('items');
        expect(scan, hasLength(1));
        expect(scan.single.key, key);
        expect(await db.engine.backend.lastCommitSeq(), greaterThan(0));
        await db.close();
        db = null;

        final reopened = await DatabaseImpl.open(
          path,
          config: config,
        );
        final reopenedRaw = await reopened.rawGet('items', key);
        expect(codec.decode(reopenedRaw!), {'value': 42});
        await reopened.close();
      } finally {
        await db?.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
