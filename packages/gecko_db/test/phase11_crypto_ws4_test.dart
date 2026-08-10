// Workstream 4: physical page encryption and key management tests.
//
// Physical encryption sits *below* redb: every native file page is wrapped in
// AES-256-GCM (key-gen marker + ciphertext + tag + random nonce), so a raw
// scan of the file never finds plaintext. These tests verify:
//   * round-trips across close/reopen with the same key,
//   * wrong/missing keys and corrupted pages/tags fail with typed errors
//     before any data is returned,
//   * no sentinel plaintext ever appears in the raw file,
//   * nonces are unique across writes, sessions, and rotations,
//   * raw keys validate before the file is created (fail-before-open),
//   * tenant separation (two keys cannot read each other's files),
//   * atomic key rotation with crash recovery to either the old or new key,
//   * encrypted and unencrypted backends pass equivalent logical behavior.
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

// Physical page layout matches rust/src/crypto_storage.rs:
// [key-gen 1][ciphertext||tag 4112][nonce 12] => 4125 bytes per physical page.
const int _logicalPageSize = 4096;
const int _pageOverhead = 1 + 16 + 12;
const int _physicalPageSize = _logicalPageSize + _pageOverhead;

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

List<int> _keyA() => List<int>.filled(32, 0x41);
List<int> _keyB() => List<int>.filled(32, 0x42);

/// All physical nonces currently present in the raw file (last 12 bytes of
/// every non-zero physical page), in file order (may contain duplicates if a
/// bug ever reuses a nonce).
List<List<int>> _fileNonces(String path) {
  final bytes = File(path).readAsBytesSync();
  final nonces = <List<int>>[];
  for (var page = 0; page * _physicalPageSize < bytes.length; page++) {
    final start = page * _physicalPageSize;
    final end = (start + _physicalPageSize).clamp(0, bytes.length);
    final slice = bytes.sublist(start, end);
    if (slice.every((b) => b == 0)) continue;
    final nonceStart = (end - 12).clamp(start, end);
    nonces.add(bytes.sublist(nonceStart, end));
  }
  return nonces;
}

/// True when every nonce in [nonces] is distinct (no reuse).
bool _allNoncesUnique(List<List<int>> nonces) =>
    nonces.length == nonces.toSet().length;

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-ws4-');
    path = '${tempDir.path}${Platform.pathSeparator}database.redb';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<DatabaseImpl> openEncrypted({
    required List<int> key,
    int keyGeneration = initialPhysicalKeyGeneration,
  }) => DatabaseImpl.open(
    path,
    useInMemory: false,
    config: DatabaseConfig(
      nativeLibraryPath: nativePath,
      encryptionKey: key,
      encryptionKeyGeneration: keyGeneration,
    ),
  );

  Future<void> writeSample(Database db, String prefix) async {
    final col = db.collection<String>(
      'items',
      toRow: (v) => v,
      fromRow: (r) => r as String,
      id: (v) => v,
    );
    for (var i = 0; i < 50; i++) {
      await col.put('$prefix-$i');
    }
  }

  Future<List<String>> readAll(Database db) async {
    final col = db.collection<String>(
      'items',
      toRow: (v) => v,
      fromRow: (r) => r as String,
      id: (v) => v,
    );
    return col.getAll();
  }

  group('Workstream 4 physical encryption', () {
    test('encrypted database round-trips across close and reopen', () async {
      var db = await openEncrypted(key: _keyA());
      await writeSample(db, 's');
      expect(await readAll(db), hasLength(50));
      await db.close();

      db = await openEncrypted(key: _keyA());
      final all = await readAll(db);
      expect(all, hasLength(50));
      expect(all, contains('s-17'));
      await db.close();
    });

    test('wrong key fails with a typed error before returning data', () async {
      final db = await openEncrypted(key: _keyA());
      await writeSample(db, 'tenant');
      await db.close();

      await expectLater(
        openEncrypted(key: _keyB()),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.unknown,
          ),
        ),
      );
    });

    test('raw file scan never finds sentinel plaintext', () async {
      const sentinel = 'GECKO_PLAINTEXT_SENTINEL_WS4_XYZ_9876543210';
      final db = await openEncrypted(key: _keyA());
      await writeSample(db, 'secret');
      // Write the sentinel through the typed API too.
      final col = db.collection<String>(
        'secrets',
        toRow: (v) => v,
        fromRow: (r) => r as String,
        id: (v) => v,
      );
      await col.put(sentinel);
      await db.close();

      final raw = File(path).readAsBytesSync();
      expect(raw.length, greaterThan(0));
      expect(
        raw,
        isNot(contains(utf8.encode(sentinel))),
        reason: 'plaintext must never appear in the raw file',
      );
      // Sanity: the file must actually be page-encrypted (non-zero header).
      expect(raw.sublist(0, _physicalPageSize).any((b) => b != 0), isTrue);
    });

    test(
      'every physical page nonce is unique across sessions and rotation',
      () async {
        final db = await openEncrypted(key: _keyA());
        await writeSample(db, 'n');
        await db.close();
        final noncesAfterFirst = _fileNonces(path);
        expect(noncesAfterFirst, isNotEmpty);
        expect(
          _allNoncesUnique(noncesAfterFirst),
          isTrue,
          reason: 'nonces must be unique after the first session',
        );

        // Reopen and write more: new pages must not reuse nonces.
        final db2 = await openEncrypted(key: _keyA());
        await writeSample(db2, 'm');
        await db2.close();
        final noncesAfterSecond = _fileNonces(path);
        expect(noncesAfterSecond.length, greaterThan(noncesAfterFirst.length));
        expect(
          _allNoncesUnique(noncesAfterSecond),
          isTrue,
          reason: 'nonces must be unique across sessions',
        );

        // Rotation re-encrypts with fresh nonces.
        await rotatePhysicalKey(
          path: path,
          oldKey: _keyA(),
          newKey: _keyB(),
          oldGeneration: initialPhysicalKeyGeneration,
          nativeLibraryPath: nativePath,
        );
        final noncesAfterRotation = _fileNonces(path);
        expect(
          noncesAfterRotation.length,
          greaterThanOrEqualTo(noncesAfterSecond.length),
        );
        expect(
          _allNoncesUnique(noncesAfterRotation),
          isTrue,
          reason: 'nonces must be unique after rotation',
        );
      },
    );

    test('corrupted page/tag fails with a typed error on reopen', () async {
      final db = await openEncrypted(key: _keyA());
      await writeSample(db, 'corrupt');
      await db.close();

      // Flip a byte inside physical page 0's ciphertext (page 0 is read to
      // validate the database header, so the GCM tag must fail on open).
      final bytes = File(path).readAsBytesSync();
      final offset = 100;
      expect(
        bytes[offset],
        isNot(0),
        reason: 'header region is encrypted data',
      );
      bytes[offset] ^= 0x01;
      File(path).writeAsBytesSync(bytes);

      await expectLater(
        openEncrypted(key: _keyA()),
        throwsA(isA<GeckoError>()),
      );
    });

    test('invalid raw key fails before the file is created', () async {
      await expectLater(
        DatabaseImpl.open(
          path,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            encryptionKey: const [1, 2],
          ),
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
      expect(
        File(path).existsSync(),
        isFalse,
        reason: 'an invalid key must never create a database file',
      );
    });

    test('raw 32-byte key opens and persists', () async {
      final encrypted = await openEncrypted(key: _keyA());
      await writeSample(encrypted, 'raw');
      await encrypted.close();
      final reopened = await openEncrypted(key: _keyA());
      expect(await readAll(reopened), hasLength(50));
      await reopened.close();
    });

    test('two tenants cannot read each other files', () async {
      final tenantA = await DatabaseImpl.open(
        path,
        useInMemory: false,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          encryptionKey: _keyA(),
        ),
      );
      await writeSample(tenantA, 'tenant-a');
      await tenantA.close();

      final otherPath = '${tempDir.path}${Platform.pathSeparator}other.redb';
      final tenantB = await DatabaseImpl.open(
        otherPath,
        useInMemory: false,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          encryptionKey: _keyB(),
        ),
      );
      await writeSample(tenantB, 'tenant-b');
      await tenantB.close();

      // A cannot read B's file and vice versa.
      await expectLater(
        DatabaseImpl.open(
          otherPath,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            encryptionKey: _keyA(),
          ),
        ),
        throwsA(isA<GeckoError>()),
      );
      await expectLater(
        DatabaseImpl.open(
          path,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            encryptionKey: _keyB(),
          ),
        ),
        throwsA(isA<GeckoError>()),
      );
    });

    test(
      'key rotation: new key works, old key rejected, no plaintext',
      () async {
        const sentinel = 'GECKO_ROTATION_SENTINEL_0123456789';
        final db = await openEncrypted(key: _keyA());
        await writeSample(db, 'rot');
        final col = db.collection<String>(
          'secrets',
          toRow: (v) => v,
          fromRow: (r) => r as String,
          id: (v) => v,
        );
        await col.put(sentinel);
        await db.close();

        final newGeneration = await rotatePhysicalKey(
          path: path,
          oldKey: _keyA(),
          newKey: _keyB(),
          oldGeneration: initialPhysicalKeyGeneration,
          nativeLibraryPath: nativePath,
        );
        expect(newGeneration, initialPhysicalKeyGeneration + 1);

        // Old key no longer works.
        await expectLater(
          openEncrypted(key: _keyA()),
          throwsA(isA<GeckoError>()),
        );

        // New key (generation 2) works.
        final reopened = await DatabaseImpl.open(
          path,
          useInMemory: false,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            encryptionKey: _keyB(),
            encryptionKeyGeneration: 2,
          ),
        );
        final all = await readAll(reopened);
        expect(all, hasLength(50));
        expect(all, contains('rot-0'));
        await reopened.close();

        // No plaintext after rotation either.
        final raw = File(path).readAsBytesSync();
        expect(raw, isNot(contains(utf8.encode(sentinel))));
        // Rotation artifacts cleaned up.
        expect(File('$path.rotating').existsSync(), isFalse);
        expect(File('$path.rekey.tmp').existsSync(), isFalse);
      },
    );

    test('rotation crash recovery rolls forward with the new key', () async {
      // Database A (key A, gen 1) at the main path.
      final dbA = await openEncrypted(key: _keyA());
      await writeSample(dbA, 'fwd');
      await dbA.close();

      // A same-content database B (key B, generation 2) to act as the
      // complete rekeyed sibling.
      final siblingPath =
          '${tempDir.path}${Platform.pathSeparator}sibling.redb';
      final dbB = await DatabaseImpl.open(
        siblingPath,
        useInMemory: false,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          encryptionKey: _keyB(),
          encryptionKeyGeneration: 2,
        ),
      );
      await writeSample(dbB, 'fwd');
      await dbB.close();

      // Simulate a crash after the sibling was fully built: copy it into the
      // rekey tmp slot with the completion footer, then write the marker.
      File(siblingPath).copySync('$path.rekey.tmp');
      final tmp = File('$path.rekey.tmp').openSync(mode: FileMode.append);
      tmp.writeStringSync('gecko_rekey_done\n');
      tmp.closeSync();
      File('$path.rotating').writeAsStringSync('gecko_rekey_v1\n1\n2\n');

      // Opening with the NEW key (generation 2) rolls forward.
      final reopened = await DatabaseImpl.open(
        path,
        useInMemory: false,
        config: DatabaseConfig(
          nativeLibraryPath: nativePath,
          encryptionKey: _keyB(),
          encryptionKeyGeneration: 2,
        ),
      );
      expect(await readAll(reopened), hasLength(50));
      await reopened.close();
      expect(File('$path.rotating').existsSync(), isFalse);
      expect(File('$path.rekey.tmp').existsSync(), isFalse);
    });

    test('rotation crash recovery rolls back with the old key', () async {
      final dbA = await openEncrypted(key: _keyA());
      await writeSample(dbA, 'back');
      await dbA.close();

      // Simulate a crash mid-rotation: incomplete sibling (no footer) + marker.
      File('$path.rekey.tmp').writeAsBytesSync(List<int>.filled(64, 0xEE));
      File('$path.rotating').writeAsStringSync('gecko_rekey_v1\n1\n2\n');

      // Opening with the OLD key (generation 1) rolls back and the database
      // remains fully usable.
      final reopened = await openEncrypted(key: _keyA());
      final all = await readAll(reopened);
      expect(all, hasLength(50));
      expect(all, contains('back-0'));
      await reopened.close();
      expect(File('$path.rotating').existsSync(), isFalse);
      expect(File('$path.rekey.tmp').existsSync(), isFalse);
    });

    test(
      'encrypted and unencrypted backends pass equivalent behavior',
      () async {
        Future<void> exercise(Database db) async {
          final col = db.collection<String>(
            'items',
            toRow: (v) => v,
            fromRow: (r) => r as String,
            id: (v) => v,
          );
          for (var i = 0; i < 20; i++) {
            await col.put('k$i');
          }
          final one = await col.get('k7');
          expect(one, 'k7');
          final missing = await col.get('nope');
          expect(missing, isNull);
          final rows = await col.getAll();
          expect(rows, hasLength(20));
          await col.delete('k3');
          expect(await col.get('k3'), isNull);
        }

        final encrypted = await openEncrypted(key: _keyA());
        await exercise(encrypted);
        await encrypted.close();

        final plainPath = '${tempDir.path}${Platform.pathSeparator}plain.redb';
        final plain = await DatabaseImpl.open(
          plainPath,
          useInMemory: false,
          config: DatabaseConfig(nativeLibraryPath: nativePath),
        );
        await exercise(plain);
        await plain.close();
      },
    );

    test('in-memory backend rejects an encryption key', () async {
      await expectLater(
        DatabaseImpl.open(
          path,
          useInMemory: true,
          config: DatabaseConfig(encryptionKey: _keyA()),
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
    });
  });
}
