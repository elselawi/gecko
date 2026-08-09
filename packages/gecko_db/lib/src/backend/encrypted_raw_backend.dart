/// RawBackend encryption wrapper for Phase 11.
///
/// Logical values are stored as authenticated ciphertext envelopes. Keys and
/// table names remain redb indexes; values, including reserved metadata values,
/// never reach the wrapped backend in plaintext. The envelope carries the
/// random nonce, page id, tag, and ciphertext so decryption remains possible
/// after close/reopen without a second persistence system.
library;

import 'dart:math';

import '../api/crypto.dart';
import '../errors/errors.dart';
import 'byte_key.dart';
import 'raw_backend.dart';

class EncryptedRawBackend implements RawBackend {
  EncryptedRawBackend(
    this._inner, {
    required CryptoBackend crypto,
    Random? random,
  }) : _crypto = crypto,
       _random = random ?? Random.secure() {
    if (!crypto.lengthPreserving) {
      throw GeckoError(
        GeckoErrorType.cryptoBackend,
        'Crypto backend "${crypto.name}" is not length-preserving',
      );
    }
  }

  final RawBackend _inner;
  final CryptoBackend _crypto;
  final Random _random;

  @override
  bool get isReadOnly => _inner.isReadOnly;
  int _nextPageId = 0;

  /// The wrapped backend, exposed for contract tests that inspect ciphertext.
  RawBackend get inner => _inner;

  @override
  Future<Set<(String, ByteKey)>> applyBatch(RawBatch ops) async {
    final encrypted = <RawOp>[];
    for (final op in ops) {
      switch (op) {
        case RawPut(:final table, :final key, :final value):
          final pageId = ++_nextPageId;
          final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
          final page = _crypto.encryptPage(value, pageId, nonce);
          if (page.ciphertext.length != value.length) {
            throw GeckoError(
              GeckoErrorType.cryptoBackend,
              'Crypto backend "${_crypto.name}" changed plaintext length',
            );
          }
          encrypted.add(
            RawPut(table, key, _encodeEnvelope(pageId, nonce, page)),
          );
        case RawDelete(:final table, :final key):
          encrypted.add(RawDelete(table, key));
        case RawDeleteRange(:final table, :final start, :final end):
          encrypted.add(RawDeleteRange(table, start, end));
        case RawClear(:final table):
          encrypted.add(RawClear(table));
      }
    }
    return _inner.applyBatch(encrypted);
  }

  @override
  Future<RawSnapshot> snapshot() async =>
      _EncryptedSnapshot(await _inner.snapshot(), _crypto);

  @override
  Future<bool> tableExists(String table) => _inner.tableExists(table);

  @override
  Future<List<String>> tables() => _inner.tables();

  @override
  Future<int> lastCommitSeq() => _inner.lastCommitSeq();

  @override
  Future<void> close() => _inner.close();
}

class _EncryptedSnapshot implements RawSnapshot {
  _EncryptedSnapshot(this._inner, this._crypto);

  final RawSnapshot _inner;
  final CryptoBackend _crypto;

  @override
  Future<List<int>?> read(String table, ByteKey key) async {
    final raw = await _inner.read(table, key);
    return raw == null ? null : _decrypt(raw);
  }

  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) async {
    final out = <RawEntry>[];
    for (final key in keys) {
      final value = await read(table, key);
      if (value == null) continue;
      out.add(RawEntry(key, value));
    }
    return out;
  }

  @override
  Future<List<RawEntry>> scan(
    String table, {
    ByteKey? start,
    ByteKey? end,
    bool startInclusive = true,
    bool endInclusive = true,
  }) async {
    final entries = await _inner.scan(
      table,
      start: start,
      end: end,
      startInclusive: startInclusive,
      endInclusive: endInclusive,
    );
    return [
      for (final entry in entries)
        RawEntry(
          entry.key,
          entry.value == null ? null : _decrypt(entry.value!),
        ),
    ];
  }

  @override
  Future<List<RawEntry>> scanAll(String table) => scan(table);

  @override
  Future<void> dispose() => _inner.dispose();

  List<int> _decrypt(List<int> envelope) {
    try {
      if (envelope.length < 4 + 1 + 8 + 12 + 1 + 1) {
        throw const GeckoError(
          GeckoErrorType.decryption,
          'Encrypted value is truncated',
        );
      }
      if (!_startsWith(envelope, _envelopeMagic)) {
        throw const GeckoError(
          GeckoErrorType.decryption,
          'Encrypted value has an invalid envelope',
        );
      }
      var offset = _envelopeMagic.length + 1;
      final pageId = _readU64(envelope, offset);
      offset += 8;
      final nonce = envelope.sublist(offset, offset + 12);
      offset += 12;
      final tagLength = envelope[offset++];
      if (tagLength < 0 || offset + tagLength > envelope.length) {
        throw const GeckoError(
          GeckoErrorType.decryption,
          'Encrypted value has an invalid authentication tag',
        );
      }
      final tag = envelope.sublist(offset, offset + tagLength);
      offset += tagLength;
      final ciphertext = envelope.sublist(offset);
      return _crypto.decryptPage(ciphertext, tag, pageId, nonce);
    } on GeckoError {
      rethrow;
    } catch (error) {
      throw GeckoError(
        GeckoErrorType.decryption,
        'Encrypted value could not be decrypted: $error',
      );
    }
  }
}

const List<int> _envelopeMagic = <int>[0x47, 0x43, 0x52, 0x59];
const int _envelopeVersion = 1;

List<int> _encodeEnvelope(int pageId, List<int> nonce, CryptoPage page) => [
  ..._envelopeMagic,
  _envelopeVersion,
  ..._u64(pageId),
  ...nonce,
  page.tag.length,
  ...page.tag,
  ...page.ciphertext,
];

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

int _readU64(List<int> bytes, int offset) {
  var result = 0;
  for (var i = 0; i < 8; i++) {
    result = (result << 8) | bytes[offset + i];
  }
  return result;
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
