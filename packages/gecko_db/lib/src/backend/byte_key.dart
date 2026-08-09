/// Raw byte-key wrapper used by the engine layer.
///
/// Keys at the engine boundary are raw bytes (wire-encoded). Ordering is
/// byte-wise (unsigned), matching the sort ordering contract in
/// `wire/sort_rules.dart`. Phase 3 layers the typed encodings on top.
library;

import 'dart:typed_data';

/// An immutable byte key with byte-wise ordering semantics.
///
/// Equality and ordering compare bytes, not identity, so two separately-built
/// keys with the same bytes are interchangeable. This is what makes range
/// scans deterministic and cross-platform.
class ByteKey implements Comparable<ByteKey> {
  ByteKey(List<int> bytes) : _bytes = _copy(bytes);

  final Uint8List _bytes;

  static Uint8List _copy(List<int> bytes) => Uint8List.fromList(bytes);

  /// The underlying bytes (a fresh copy — do not mutate in place).
  Uint8List get bytes => Uint8List.fromList(_bytes);

  int get length => _bytes.length;

  bool get isEmpty => _bytes.isEmpty;

  @override
  int compareTo(ByteKey other) => _compareBytes(_bytes, other._bytes);

  @override
  bool operator ==(Object other) =>
      other is ByteKey && _bytesEquals(_bytes, other._bytes);

  @override
  int get hashCode {
    var h = 0;
    for (final b in _bytes) {
      h = (h * 31 + b) & 0x7FFFFFFF;
    }
    return h;
  }

  @override
  String toString() => 'ByteKey(${_hex(_bytes)})';

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static int _compareBytes(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.length.compareTo(b.length);
  }

  static bool _bytesEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
