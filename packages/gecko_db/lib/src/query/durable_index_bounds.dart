// Durable index key bound helpers (Phase 2).
//
// The durable `__gecko_index` table stores one entry per (table, field, value,
// recordId) with the composite key `encode([table, field, value, recordId])`
// (a `DefaultWireCodec` 4-element list). Because the codec encodes a list as
// `0x06 | u32(len) | elem0 | elem1 | elem2 | elem3`, every key for a fixed
// (table, field, value) triple shares the byte prefix
// `0x06 00 00 00 04 | encode(table) | encode(field) | encode(value)`, with the
// variable `recordId` appended. Those keys therefore form a contiguous
// lexicographic range, so an equality lookup on an indexed field can be served
// by one redb range scan over the index table — no Dart decode, no per-id
// point reads (the N+1 the Phase 1 profile identified as 88% of an indexed
// query).
//
// [eqBounds] returns the inclusive `[start, end]` byte bounds for that range
// by encoding `[table, field, value, null]` (null = 0x00 tag, the smallest
// possible 4th element) and stripping the trailing null tag byte to form the
// lower bound, then incrementing the last byte of the prefix (with carry) to
// form an upper bound that sorts after every `[table, field, value, *]` key.
library;

import '../wire/wire_codec.dart';

/// The byte bounds for a durable-index range scan matching every key with the
/// given (table, field, value) triple, regardless of recordId.
///
/// Returns `(start, end)` where `start` is the shared byte prefix and `end`
/// is the exclusive-style upper bound (incremented last byte with carry). Both
/// are inclusive bounds usable directly with `redb`'s `range(start..=end)`:
/// every real key `prefix | <recordId bytes>` is `> prefix` and `< prefix+1`,
/// and `prefix+1` itself is never a stored key.
(List<int>, List<int>) eqBounds(
  String table,
  String field,
  Object? value, {
  WireCodec codec = const DefaultWireCodec(),
}) {
  // Encode the 4-element list with a null 4th element (0x00 tag, the smallest),
  // then drop the trailing null byte to obtain the shared byte prefix.
  final full = codec.encode([table, field, value, null]);
  final prefix = List<int>.of(full.sublist(0, full.length - 1));
  final end = _incrementLastByte(prefix);
  return (prefix, end);
}

/// Increments the last byte of [bytes] with carry: produces a byte sequence
/// that sorts immediately after every longer key sharing the prefix. Trailing
/// 0xFF bytes carry by being dropped (a shorter upper bound still sorts after
/// any longer key with the shared prefix — standard prefix-scan semantics).
List<int> _incrementLastByte(List<int> bytes) {
  final out = List<int>.of(bytes);
  var i = out.length - 1;
  while (i >= 0) {
    if (out[i] < 0xFF) {
      out[i] += 1;
      return out.sublist(0, i + 1);
    }
    out.removeLast();
    i--;
  }
  // All 0xFF bytes: return the original as a safe no-match fallback.
  return bytes;
}
