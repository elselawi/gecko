/// Phase 11 encryption contracts.
///
/// The current RawBackend seam exposes logical key/value pages rather than
/// redb's physical pages, so the shipped wrapper encrypts logical values while
/// preserving the same atomic batch/snapshot semantics. The backend contract
/// is deliberately page-shaped and length-preserving, so it can move below a
/// future physical page scheduler without changing the public API.
library;

import 'dart:typed_data';

import '../errors/errors.dart';

/// Authenticated encryption output for one logical page.
class CryptoPage {
  const CryptoPage({required this.ciphertext, required this.tag});

  final List<int> ciphertext;
  final List<int> tag;
}

/// Pluggable authenticated page cipher.
abstract interface class CryptoBackend {
  String get name;

  /// Registered implementations must preserve plaintext/ciphertext length.
  bool get lengthPreserving;

  CryptoPage encryptPage(List<int> plaintext, int pageId, List<int> nonce);

  List<int> decryptPage(
    List<int> ciphertext,
    List<int> tag,
    int pageId,
    List<int> nonce,
  );

  static final Map<String, CryptoBackend> _registry = {};
  static bool _defaultsInstalled = false;

  /// Registers a backend by name. Registration is last-wins.
  static void register(String name, CryptoBackend backend) {
    _installDefaults();
    if (name.trim().isEmpty) {
      throw const GeckoError(
        GeckoErrorType.cryptoBackend,
        'Crypto backend name must not be empty',
      );
    }
    if (!backend.lengthPreserving) {
      throw GeckoError(
        GeckoErrorType.cryptoBackend,
        'Crypto backend "$name" violates the length-preserving contract',
        details: <String, Object?>{'backend': name},
      );
    }
    _registry[name] = backend;
  }

  static CryptoBackend resolve(String name) {
    _installDefaults();
    final backend = _registry[name];
    if (backend == null) {
      throw GeckoError(
        GeckoErrorType.cryptoBackend,
        'Crypto backend "$name" is not registered',
        details: <String, Object?>{'backend': name},
      );
    }
    return backend;
  }

  static bool isRegistered(String name) {
    _installDefaults();
    return _registry.containsKey(name);
  }

  static void restoreDefaults() {
    _registry.clear();
    _defaultsInstalled = true;
  }

  static void _installDefaults() {
    if (_defaultsInstalled) return;
    _defaultsInstalled = true;
    // The database-open path supplies the actual key, so the registry stores
    // the backend factory through the per-key registration below. The default
    // name is recognized by Aes256GcmCryptoBackend at open time.
  }
}

/// AES-256-GCM authenticated encryption.
///
/// This is a small self-contained implementation so the core package does not
/// need a platform crypto dependency. The key must be exactly 32 bytes and the
/// nonce exactly 12 bytes. Page id is authenticated as AAD.
class Aes256GcmCryptoBackend implements CryptoBackend {
  Aes256GcmCryptoBackend(List<int> key)
    : key = Uint8List.fromList(key),
      _aes = _Aes256(key) {
    if (key.length != 32) {
      throw const GeckoError(
        GeckoErrorType.cryptoBackend,
        'AES-256-GCM requires a 32-byte key',
      );
    }
  }

  final List<int> key;
  final _Aes256 _aes;

  @override
  String get name => 'aes256Gcm';

  @override
  bool get lengthPreserving => true;

  @override
  CryptoPage encryptPage(List<int> plaintext, int pageId, List<int> nonce) {
    _validateNonce(nonce);
    final j0 = <int>[...nonce, 0, 0, 0, 1];
    final ciphertext = _xorWithCounter(plaintext, j0);
    final tag = _tag(pageId, nonce, ciphertext, j0);
    return CryptoPage(ciphertext: ciphertext, tag: tag);
  }

  @override
  List<int> decryptPage(
    List<int> ciphertext,
    List<int> tag,
    int pageId,
    List<int> nonce,
  ) {
    _validateNonce(nonce);
    final j0 = <int>[...nonce, 0, 0, 0, 1];
    final expected = _tag(pageId, nonce, ciphertext, j0);
    if (!_constantTimeEquals(expected, tag)) {
      throw const GeckoError(
        GeckoErrorType.decryption,
        'Authenticated decryption failed: wrong key or corrupted value',
      );
    }
    return _xorWithCounter(ciphertext, j0);
  }

  void _validateNonce(List<int> nonce) {
    if (nonce.length != 12) {
      throw const GeckoError(
        GeckoErrorType.cryptoBackend,
        'AES-256-GCM requires a 12-byte nonce',
      );
    }
  }

  List<int> _xorWithCounter(List<int> input, List<int> j0) {
    final out = List<int>.filled(input.length, 0);
    var counter = List<int>.from(j0);
    for (var offset = 0; offset < input.length; offset += 16) {
      counter = _inc32(counter);
      final stream = _aes.encryptBlock(counter);
      final end = (offset + 16).clamp(0, input.length);
      for (var i = offset; i < end; i++) {
        out[i] = input[i] ^ stream[i - offset];
      }
    }
    return out;
  }

  List<int> _tag(
    int pageId,
    List<int> nonce,
    List<int> ciphertext,
    List<int> j0,
  ) {
    final h = _aes.encryptBlock(List<int>.filled(16, 0));
    final aad = _u64(pageId);
    final hash = _ghash(h, aad, ciphertext);
    final mask = _aes.encryptBlock(j0);
    return [for (var i = 0; i < 16; i++) mask[i] ^ hash[i]];
  }
}

List<int> _u64(int value) {
  // No 64-bit mask literal (not exactly representable on the web); each byte
  // only needs the low 8 bits of the arithmetic-shifted value.
  var v = value;
  final out = List<int>.filled(8, 0);
  for (var i = 7; i >= 0; i--) {
    out[i] = v & 0xff;
    v >>= 8;
  }
  return out;
}

List<int> _inc32(List<int> value) {
  final out = List<int>.from(value);
  for (var i = 15; i >= 12; i--) {
    out[i] = (out[i] + 1) & 0xff;
    if (out[i] != 0) break;
  }
  return out;
}

List<int> _ghash(List<int> h, List<int> aad, List<int> ciphertext) {
  var y = List<int>.filled(16, 0);
  void absorb(List<int> input) {
    for (var offset = 0; offset < input.length; offset += 16) {
      final block = List<int>.filled(16, 0);
      final end = (offset + 16).clamp(0, input.length);
      for (var i = offset; i < end; i++) {
        block[i - offset] = input[i];
      }
      y = _gf128Multiply(_xor16(y, block), h);
    }
  }

  absorb(aad);
  absorb(ciphertext);
  absorb([..._u64(aad.length * 8), ..._u64(ciphertext.length * 8)]);
  return y;
}

List<int> _xor16(List<int> a, List<int> b) => [
  for (var i = 0; i < 16; i++) a[i] ^ b[i],
];

List<int> _gf128Multiply(List<int> x, List<int> y) {
  var z = BigInt.zero;
  var v = BigInt.zero;
  for (final byte in y) {
    v = (v << 8) | BigInt.from(byte);
  }
  var xi = BigInt.zero;
  for (final byte in x) {
    xi = (xi << 8) | BigInt.from(byte);
  }
  final r = BigInt.parse('e1000000000000000000000000000000', radix: 16);
  for (var i = 127; i >= 0; i--) {
    if (((xi >> i) & BigInt.one) == BigInt.one) {
      z ^= v;
    }
    final lsb = (v & BigInt.one) == BigInt.one;
    v >>= 1;
    if (lsb) {
      v ^= r;
    }
  }
  final out = List<int>.filled(16, 0);
  for (var i = 15; i >= 0; i--) {
    out[i] = (z & BigInt.from(0xff)).toInt();
    z >>= 8;
  }
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  final length = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class _Aes256 {
  _Aes256(List<int> key) : _roundKeys = _expand(key);

  final List<int> _roundKeys;

  List<int> encryptBlock(List<int> input) {
    var state = List<int>.from(input);
    _addRoundKey(state, 0);
    for (var round = 1; round < 14; round++) {
      _subBytes(state);
      state = _shiftRows(state);
      _mixColumns(state);
      _addRoundKey(state, round);
    }
    _subBytes(state);
    state = _shiftRows(state);
    _addRoundKey(state, 14);
    return state;
  }

  void _addRoundKey(List<int> state, int round) {
    final offset = round * 16;
    for (var i = 0; i < 16; i++) {
      state[i] ^= _roundKeys[offset + i];
    }
  }

  void _subBytes(List<int> state) {
    for (var i = 0; i < 16; i++) {
      state[i] = _sbox[state[i]];
    }
  }

  List<int> _shiftRows(List<int> state) {
    final out = List<int>.filled(16, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 4; col++) {
        out[4 * col + row] = state[4 * ((col + row) % 4) + row];
      }
    }
    return out;
  }

  void _mixColumns(List<int> state) {
    for (var col = 0; col < 4; col++) {
      final i = col * 4;
      final a0 = state[i];
      final a1 = state[i + 1];
      final a2 = state[i + 2];
      final a3 = state[i + 3];
      final t = a0 ^ a1 ^ a2 ^ a3;
      state[i] = a0 ^ t ^ _xtime(a0 ^ a1);
      state[i + 1] = a1 ^ t ^ _xtime(a1 ^ a2);
      state[i + 2] = a2 ^ t ^ _xtime(a2 ^ a3);
      state[i + 3] = a3 ^ t ^ _xtime(a3 ^ a0);
    }
  }
}

final List<int> _sbox = List<int>.generate(256, (value) {
  final inverse = value == 0 ? 0 : _gfPow(value, 254);
  return inverse ^
      _rotl8(inverse, 1) ^
      _rotl8(inverse, 2) ^
      _rotl8(inverse, 3) ^
      _rotl8(inverse, 4) ^
      0x63;
});

List<int> _expand(List<int> key) {
  if (key.length != 32) {
    throw const GeckoError(
      GeckoErrorType.cryptoBackend,
      'AES-256-GCM requires a 32-byte key',
    );
  }
  final words = List<int>.filled(240, 0);
  for (var i = 0; i < 32; i++) {
    words[i] = key[i];
  }
  var bytes = 32;
  var rcon = 1;
  while (bytes < 240) {
    final temp = <int>[
      words[bytes - 4],
      words[bytes - 3],
      words[bytes - 2],
      words[bytes - 1],
    ];
    if (bytes % 32 == 0) {
      final first = temp.removeAt(0);
      temp.add(first);
      for (var i = 0; i < 4; i++) {
        temp[i] = _sbox[temp[i]];
      }
      temp[0] ^= rcon;
      rcon = _xtime(rcon);
    } else if (bytes % 32 == 16) {
      for (var i = 0; i < 4; i++) {
        temp[i] = _sbox[temp[i]];
      }
    }
    for (var i = 0; i < 4; i++) {
      words[bytes] = words[bytes - 32] ^ temp[i];
      bytes++;
    }
  }
  return words;
}

int _gfPow(int value, int exponent) {
  var result = 1;
  var base = value;
  var power = exponent;
  while (power > 0) {
    if (power & 1 == 1) {
      result = _gfMul(result, base);
    }
    base = _gfMul(base, base);
    power >>= 1;
  }
  return result;
}

int _gfMul(int a, int b) {
  var result = 0;
  var x = a;
  var y = b;
  for (var i = 0; i < 8; i++) {
    if ((y & 1) != 0) result ^= x;
    final high = x & 0x80;
    x = (x << 1) & 0xff;
    if (high != 0) x ^= 0x1b;
    y >>= 1;
  }
  return result;
}

int _xtime(int value) {
  final shifted = (value << 1) & 0xff;
  return (value & 0x80) == 0 ? shifted : shifted ^ 0x1b;
}

int _rotl8(int value, int shift) =>
    ((value << shift) | (value >> (8 - shift))) & 0xff;
