import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a second native open reports a typed databaseLocked error',
    () async {
      final root = await Directory.systemTemp.createTemp('gecko-lock-');
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
      DatabaseImpl? first;
      try {
        first = await DatabaseImpl.open(
          path,
          config: config,
        );
        await expectLater(
          DatabaseImpl.open(path, config: config),
          throwsA(
            isA<GeckoError>().having(
              (error) => error.type,
              'type',
              GeckoErrorType.databaseAlreadyOpen,
            ),
          ),
        );
      } finally {
        await first?.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
