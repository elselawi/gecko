import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

void main() {
  group('Phase 11 crypto backend', () {
    test('AES-256-GCM round-trips and authenticates page metadata', () {
      final key = List<int>.filled(32, 7);
      final crypto = Aes256GcmCryptoBackend(key);
      final plaintext = <int>[1, 2, 3, 4, 5, 6, 7];
      final nonce = List<int>.filled(12, 9);
      final encrypted = crypto.encryptPage(plaintext, 4, nonce);
      expect(encrypted.ciphertext, isNot(plaintext));
      expect(encrypted.ciphertext.length, plaintext.length);
      expect(
        crypto.decryptPage(encrypted.ciphertext, encrypted.tag, 4, nonce),
        plaintext,
      );
      expect(
        () => crypto.decryptPage(encrypted.ciphertext, encrypted.tag, 5, nonce),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.decryption,
          ),
        ),
      );
    });

    test('wrong key and tampered ciphertext fail with typed decryption', () {
      final encrypted = Aes256GcmCryptoBackend(
        List<int>.filled(32, 1),
      ).encryptPage([10, 20, 30], 1, List<int>.filled(12, 2));
      final wrong = Aes256GcmCryptoBackend(List<int>.filled(32, 3));
      expect(
        () => wrong.decryptPage(
          encrypted.ciphertext,
          encrypted.tag,
          1,
          List<int>.filled(12, 2),
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.decryption,
          ),
        ),
      );
      final tampered = List<int>.from(encrypted.ciphertext)..[0] ^= 1;
      expect(
        () => Aes256GcmCryptoBackend(
          List<int>.filled(32, 1),
        ).decryptPage(tampered, encrypted.tag, 1, List<int>.filled(12, 2)),
        throwsA(isA<GeckoError>()),
      );
    });

    test(
      'encrypted RawBackend stores opaque values and round-trips scans',
      () async {
        final inner = InMemoryBackend();
        final encrypted = EncryptedRawBackend(
          inner,
          crypto: Aes256GcmCryptoBackend(List<int>.filled(32, 4)),
          random: Random(1),
        );
        final key = ByteKey(const [1]);
        const secret = [0x53, 0x45, 0x43, 0x52, 0x45, 0x54];
        await encrypted.applyBatch([RawPut('items', key, secret)]);
        final stored = await (await inner.snapshot()).read('items', key);
        expect(stored, isNotNull);
        expect(stored, isNot(secret));
        expect(await (await encrypted.snapshot()).read('items', key), secret);
        final entries = await (await encrypted.snapshot()).scanAll('items');
        expect(entries.single.value, secret);
        await encrypted.close();
      },
    );

    test('registered custom backend follows the same wrapper path', () async {
      final custom = _XorBackend();
      CryptoBackend.register('testXor', custom);
      expect(CryptoBackend.isRegistered('testXor'), isTrue);
      final encrypted = EncryptedRawBackend(
        InMemoryBackend(),
        crypto: CryptoBackend.resolve('testXor'),
        random: Random(2),
      );
      await encrypted.applyBatch([
        RawPut('items', ByteKey(const [1]), const [1, 2, 3]),
      ]);
      expect(
        await (await encrypted.snapshot()).read('items', ByteKey(const [1])),
        [1, 2, 3],
      );
      await encrypted.close();
      CryptoBackend.restoreDefaults();
    });

    test('non-length-preserving and unknown backends fail typed', () {
      expect(
        () => CryptoBackend.register('bad', _BadBackend()),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.cryptoBackend,
          ),
        ),
      );
      expect(
        () => CryptoBackend.resolve('missing'),
        throwsA(isA<GeckoError>()),
      );
    });

    test('key and nonce lengths are validated', () {
      expect(
        () => Aes256GcmCryptoBackend(const [1, 2]),
        throwsA(isA<GeckoError>()),
      );
      final crypto = Aes256GcmCryptoBackend(List<int>.filled(32, 1));
      expect(
        () => crypto.encryptPage([1], 1, const [1]),
        throwsA(isA<GeckoError>()),
      );
    });

    test('encrypted snapshot getMany batches decrypted rows in input order', () async {
      final inner = InMemoryBackend();
      final encrypted = EncryptedRawBackend(
        inner,
        crypto: Aes256GcmCryptoBackend(List<int>.filled(32, 6)),
        random: Random(3),
      );
      const rows = {1: [1], 2: [2, 2], 3: [3, 3, 3]};
      await encrypted.applyBatch([
        for (final entry in rows.entries)
          RawPut('items', ByteKey([entry.key]), entry.value),
      ]);
      final snap = await encrypted.snapshot();
      // Input order preserved; a missing key is skipped.
      final got = await snap.getMany('items', [
        ByteKey(const [3]),
        ByteKey(const [99]),
        ByteKey(const [1]),
      ]);
      expect(got, hasLength(2));
      expect(got[0].value, [3, 3, 3]);
      expect(got[1].value, [1]);
      expect(await snap.getMany('items', []), isEmpty);
      await snap.dispose();
      await encrypted.close();
    });
  });

  group('Phase 11 DatabaseConfig encryption', () {
    test(
      'DatabaseImpl encrypts logical values when a key is configured',
      () async {
        final db = await DatabaseImpl.open(
          'mem://phase11-config',
          useInMemory: true,
          config: DatabaseConfig(encryptionKey: List<int>.filled(32, 8)),
        );
        final key = ByteKey(const [1]);
        await db.engine.rawPut('items', key, const [9, 8, 7]);
        expect(await db.engine.rawGet('items', key), [9, 8, 7]);
        await db.close();
      },
    );
  });

  group('Phase 11 physical key decoding and providers', () {
    final key32 = List<int>.filled(32, 7);
    String hex32() => [for (final b in key32) b.toRadixString(16).padLeft(2, '0')].join();

    test('decodeKey accepts hex/base64 and rejects malformed input', () {
      expect(decodeKey(hex32()), key32);
      // Whitespace is stripped before decoding.
      expect(decodeKey('  ${hex32()} \n'), key32);
      final base64Key = base64Encode(key32);
      expect(decodeKey(base64Key, encoding: KeyEncoding.base64), key32);
      // Raw encoding is binary-only.
      expect(
        () => decodeKey('anything', encoding: KeyEncoding.raw),
        throwsA(
          isA<GeckoError>().having((e) => e.type, 'type', GeckoErrorType.cryptoBackend),
        ),
      );
      // Malformed hex: odd length and non-hex characters.
      expect(() => decodeKey('a'), throwsA(isA<GeckoError>()));
      expect(() => decodeKey('zz'), throwsA(isA<GeckoError>()));
      // Wrong length.
      expect(() => decodeKey('abcd'), throwsA(isA<GeckoError>()));
    });

    test('validatePhysicalKey enforces 32 bytes', () {
      validatePhysicalKey(key32);
      expect(
        () => validatePhysicalKey(const [1, 2]),
        throwsA(
          isA<GeckoError>().having((e) => e.type, 'type', GeckoErrorType.cryptoBackend),
        ),
      );
    });

    test('FileKeyProvider reads keys from files and handles missing/empty/raw', () async {
      final dir = await Directory.systemTemp.createTemp('gecko-keyfile-');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final hexFile = File('${dir.path}${Platform.pathSeparator}key.hex');
      await hexFile.writeAsString(hex32());
      expect(await FileKeyProvider(hexFile.path).obtain(), key32);
      // Missing file → null.
      expect(await FileKeyProvider('${dir.path}${Platform.pathSeparator}nope').obtain(), isNull);
      // Empty file → null.
      final emptyFile = File('${dir.path}${Platform.pathSeparator}empty');
      await emptyFile.writeAsString('');
      expect(await FileKeyProvider(emptyFile.path).obtain(), isNull);
      // Raw encoding returns the file bytes verbatim.
      final rawFile = File('${dir.path}${Platform.pathSeparator}raw');
      await rawFile.writeAsBytes(key32);
      expect(await FileKeyProvider(rawFile.path, encoding: KeyEncoding.raw).obtain(), key32);
    });

    test('EnvironmentKeyProvider returns null when the variable is absent', () async {
      // The test process cannot mutate Platform.environment, so we only assert
      // the absent-variable branch (never a real key in a default var).
      final provider = EnvironmentKeyProvider(
        environmentVariable: 'GECKO_DB_TEST_VAR_THAT_IS_ABSENT_xyz',
      );
      expect(await provider.obtain(), isNull);
    });
  });
}

class _XorBackend implements CryptoBackend {
  @override
  String get name => 'testXor';

  @override
  bool get lengthPreserving => true;

  @override
  CryptoPage encryptPage(List<int> plaintext, int pageId, List<int> nonce) =>
      CryptoPage(
        ciphertext: [for (final byte in plaintext) byte ^ 0xaa],
        tag: [pageId & 0xff, nonce.first],
      );

  @override
  List<int> decryptPage(
    List<int> ciphertext,
    List<int> tag,
    int pageId,
    List<int> nonce,
  ) {
    if (tag.length != 2 || tag[0] != (pageId & 0xff) || tag[1] != nonce.first) {
      throw const GeckoError(GeckoErrorType.decryption, 'bad test tag');
    }
    return [for (final byte in ciphertext) byte ^ 0xaa];
  }
}

class _BadBackend extends _XorBackend {
  @override
  String get name => 'bad';

  @override
  bool get lengthPreserving => false;
}
