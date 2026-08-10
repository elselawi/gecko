// Workstream 6: `Database.open` is the supported public entry point.
//
// Verifies the seam: `Database.open` delegates to the concrete implementation
// (file-backed by default, in-memory when `config.inMemory` is set), and the
// returned handle is the public `Database` abstraction.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

void main() {
  test(
    'Database.open with a temporary native file returns a usable public handle',
    () async {
      final directory = await Directory.systemTemp.createTemp('gecko-entry-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}db.redb';
      final db = await Database.open(path);
      expect(db, isA<Database>());
      final notes = db.collection<Map<String, Object?>>(
        'notes',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      await notes.put({'id': 'n1', 'text': 'hello'});
      expect((await notes.get('n1'))!['text'], 'hello');
      await db.close();
    },
  );

  test('Database.open with a file path uses the native backend', () async {
    final root = _repoRoot();
    final dir = await Directory.systemTemp.createTemp('gecko-ws6-entry-');
    final path = '${dir.path}${Platform.pathSeparator}db.redb';
    try {
      final db = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: _nativeLibraryPath(root)),
      );
      expect(db, isA<Database>());
      final col = db.collection<Map<String, Object?>>(
        'items',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      await col.put({'id': 'one', 'n': 1});
      expect((await col.get('one'))!['n'], 1);
      await db.close();

      // Reopen through the public entry point; data persists.
      final reopened = await Database.open(
        path,
        config: DatabaseConfig(nativeLibraryPath: _nativeLibraryPath(root)),
      );
      final col2 = reopened.collection<Map<String, Object?>>(
        'items',
        toRow: (m) => m,
        fromRow: (m) => Map<String, Object?>.from(m as Map),
        id: (m) => m['id'],
      );
      expect((await col2.get('one'))!['n'], 1);
      await reopened.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'Database.open with a physical key opens an encrypted database',
    () async {
      final root = _repoRoot();
      final dir = await Directory.systemTemp.createTemp('gecko-ws6-enc-');
      final path = '${dir.path}${Platform.pathSeparator}db.redb';
      final key = List<int>.filled(32, 0x3C);
      try {
        final db = await Database.open(
          path,
          config: DatabaseConfig(
            nativeLibraryPath: _nativeLibraryPath(root),
            encryptionKey: key,
          ),
        );
        final col = db.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        await col.put({'id': 'secret', 'v': 'x'});
        await db.close();
        // Wrong key fails with a typed error through the public entry point.
        await expectLater(
          Database.open(
            path,
            config: DatabaseConfig(
              nativeLibraryPath: _nativeLibraryPath(root),
              encryptionKey: List<int>.filled(32, 0x99),
            ),
          ),
          throwsA(isA<GeckoError>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
