// Workstream 8 — parallel isolated databases (reliability / isolation).
//
// Opens many native databases CONCURRENTLY on distinct files, interleaves
// writes across them, and verifies:
//   * each instance sees only its own data (no cross-talk between files);
//   * native databases on distinct paths do not contend for a file lock;
//   * all instances survive a multi-file parallel run;
//   * every native instance persists exactly its own rows across a reopen.
//
// Together with the runner's `--concurrency=N`, this exercises the worker
// isolate pool under contention (see tool/release_checklist.dart --long).
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

  test('N native databases on distinct files run concurrently and stay '
      'isolated', () async {
    const n = 6;
    final dir = await Directory.systemTemp.createTemp('gecko-parallel-n-');
    final paths = [
      for (var i = 0; i < n; i++)
        '${dir.path}${Platform.pathSeparator}db$i.redb',
    ];
    try {
      final dbs = await Future.wait([
        for (final p in paths)
          Database.open(
            p,
            config: DatabaseConfig(nativeLibraryPath: nativePath),
          ),
      ]);
      try {
        // Interleave writes across all instances.
        await Future.wait([
          for (var i = 0; i < n; i++) _writeSentinel(dbs[i], 'native-$i'),
        ]);
        // Interleave reads + verification.
        await Future.wait([
          for (var i = 0; i < n; i++) _verifyIsolation(dbs[i], 'native-$i'),
        ]);
      } finally {
        await Future.wait([for (final db in dbs) db.close()]);
      }
    } finally {
      await dir.delete(recursive: true);
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
          Database.open(
            p,
            config: DatabaseConfig(nativeLibraryPath: nativePath),
          ),
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
          Database.open(
            p,
            config: DatabaseConfig(nativeLibraryPath: nativePath),
          ),
      ]);
      try {
        await Future.wait([
          for (var i = 0; i < n; i++)
            _verifyIsolation(reopened[i], 'native-$i'),
        ]);
      } finally {
        await Future.wait([for (final db in reopened) db.close()]);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('independent native databases stay isolated under contention', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-parallel-mixed-');
    final paths = [
      '${dir.path}${Platform.pathSeparator}a.redb',
      '${dir.path}${Platform.pathSeparator}b.redb',
      '${dir.path}${Platform.pathSeparator}mixed.redb',
    ];
    try {
      final dbs = await Future.wait([
        for (final p in paths)
          Database.open(
            p,
            config: DatabaseConfig(nativeLibraryPath: nativePath),
          ),
      ]);
      try {
        await Future.wait([
          _writeSentinel(dbs[0], 'native-a'),
          _writeSentinel(dbs[1], 'native-b'),
          _writeSentinel(dbs[2], 'native-mixed'),
        ]);
        await Future.wait([
          _verifyIsolation(dbs[0], 'native-a'),
          _verifyIsolation(dbs[1], 'native-b'),
          _verifyIsolation(dbs[2], 'native-mixed'),
        ]);
      } finally {
        await Future.wait([for (final db in dbs) db.close()]);
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
