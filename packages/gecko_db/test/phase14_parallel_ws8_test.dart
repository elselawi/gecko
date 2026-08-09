// Workstream 8 — parallel isolated databases (reliability / isolation).
//
// Opens many databases CONCURRENTLY (in-memory and native on distinct
// files), interleaves writes across them, and verifies:
//   * each instance sees only its own data (no cross-talk between backends,
//     URIs, or files);
//   * native databases on distinct paths do not contend for a file lock;
//   * all instances survive a mixed in-memory + native run;
//   * every native instance persists exactly its own rows across a reopen.
//
// Together with the runner's `--concurrency=N`, this exercises the worker
// isolate pool under contention (see tool/README + ci.yml).
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

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

class _Item {
  const _Item(this.id, this.owner);
  final int id;
  final String owner;

  Map<String, Object?> toMap() => {'id': id, 'owner': owner};

  static _Item fromMap(Object? row) {
    final map = row as Map;
    return _Item(map['id'] as int, map['owner'] as String);
  }
}

Future<void> _writeSentinel(Database db, String owner) async {
  final coll = db.collection<_Item>(
    'items',
    toRow: (r) => r.toMap(),
    fromRow: _Item.fromMap,
    id: (r) => r.id,
  );
  for (var i = 0; i < 25; i++) {
    await coll.put(_Item(i, owner));
  }
}

Future<void> _verifyIsolation(Database db, String owner) async {
  final coll = db.collection<_Item>(
    'items',
    toRow: (r) => r.toMap(),
    fromRow: _Item.fromMap,
    id: (r) => r.id,
  );
  final all = await coll.getAll();
  expect(all.length, 25, reason: '$owner: row count');
  for (final row in all) {
    expect(row.owner, owner, reason: '$owner: cross-talk detected!');
  }
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  test('N in-memory databases run concurrently and stay isolated', () async {
    const n = 6;
    final dbs = await Future.wait([
      for (var i = 0; i < n; i++)
        Database.open(
          'mem://ws8-parallel-$i',
          config: const DatabaseConfig(inMemory: true),
        ),
    ]);
    try {
      // Interleave writes across all instances.
      await Future.wait([
        for (var i = 0; i < n; i++) _writeSentinel(dbs[i], 'mem-$i'),
      ]);
      // Interleave reads + verification.
      await Future.wait([
        for (var i = 0; i < n; i++) _verifyIsolation(dbs[i], 'mem-$i'),
      ]);
    } finally {
      await Future.wait([for (final db in dbs) db.close()]);
    }
  });

  test('N native databases on distinct files run concurrently, no lock '
      'contention, and persist isolation across reopen', () async {
    const n = 4;
    final dir = await Directory.systemTemp.createTemp('gecko-parallel-');
    final paths = [
      for (var i = 0; i < n; i++)
        '${dir.path}${Platform.pathSeparator}db$i.redb',
    ];
    try {
      final dbs = await Future.wait([
        for (final p in paths)
          Database.open(p, config: DatabaseConfig(nativeLibraryPath: nativePath)),
      ]);
      await Future.wait([
        for (var i = 0; i < n; i++) _writeSentinel(dbs[i], 'native-$i'),
      ]);
      await Future.wait([
        for (var i = 0; i < n; i++) _verifyIsolation(dbs[i], 'native-$i'),
      ]);
      await Future.wait([for (final db in dbs) db.close()]);

      // Reopen every file; each must contain exactly its own rows.
      final reopened = await Future.wait([
        for (final p in paths)
          Database.open(p, config: DatabaseConfig(nativeLibraryPath: nativePath)),
      ]);
      try {
        await Future.wait([
          for (var i = 0; i < n; i++) _verifyIsolation(reopened[i], 'native-$i'),
        ]);
      } finally {
        await Future.wait([for (final db in reopened) db.close()]);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('mixed in-memory + native databases stay isolated under contention',
      () async {
    final dir = await Directory.systemTemp.createTemp('gecko-parallel-mixed-');
    final nativeDbPath =
        '${dir.path}${Platform.pathSeparator}mixed.redb';
    try {
      final dbs = await Future.wait([
        Database.open('mem://ws8-mixed-a', config: const DatabaseConfig(inMemory: true)),
        Database.open('mem://ws8-mixed-b', config: const DatabaseConfig(inMemory: true)),
        Database.open(
          nativeDbPath,
          config: DatabaseConfig(nativeLibraryPath: nativePath),
        ),
      ]);
      try {
        await Future.wait([
          _writeSentinel(dbs[0], 'mixed-mem-a'),
          _writeSentinel(dbs[1], 'mixed-mem-b'),
          _writeSentinel(dbs[2], 'mixed-native'),
        ]);
        await Future.wait([
          _verifyIsolation(dbs[0], 'mixed-mem-a'),
          _verifyIsolation(dbs[1], 'mixed-mem-b'),
          _verifyIsolation(dbs[2], 'mixed-native'),
        ]);
      } finally {
        await Future.wait([for (final db in dbs) db.close()]);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
