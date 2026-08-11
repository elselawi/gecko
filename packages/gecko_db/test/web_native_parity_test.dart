// web-vs-native parity property (audited-test-gaps 2.21).
//
// The web worker transports the exact same encoded row bytes as the native
// isolate worker, but across a postMessage JSON boundary (b64-wrapped via
// `web_worker_protocol.dart`). This property test runs one scenario over BOTH
// transports:
//   * native: rich values are codec-encoded, written to and read back from
//     the real redb worker;
//   * web: the same encoded bytes are pushed through
//     `encodeValue -> jsonEncode -> jsonDecode -> decodeValue` (the web wire)
//     and then decoded to their logical values.
// and asserts both produce byte-identical encoded results — i.e. a value
// stored by native and delivered to a web client decodes to exactly the same
// logical value.

import 'dart:convert';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/worker/web_worker_protocol.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

const _codec = DefaultWireCodec();

/// Rich payloads exercising every wire tag: string, int, double, bool, null,
/// bytes, nested list/map, DateTime, BigInt, negative int.
final List<Object?> _payloads = <Object?>[
  'hello',
  42,
  -123456789,
  3.5,
  true,
  null,
  <int>[1, 2, 250, 255],
  <Object?>['a', 1, true, null, <int>[9, 8]],
  <String, Object?>{'k': 'v', 'n': 7, 'nested': <int>[5]},
  DateTime.utc(2024, 3, 14, 15, 9, 26, 123456),
  BigInt.parse('18446744073709551615'),
  double.nan,
];

void main() {
  test('the web wire preserves every stored value byte-for-byte', () async {
    final db = await openNativeTestDatabase('web-native-parity');
    try {
      // Store each payload via the native transport (codec-encoded row).
      final nativeBytes = <List<int>>[];
      for (var i = 0; i < _payloads.length; i++) {
        final encoded = _codec.encode(_payloads[i]);
        nativeBytes.add(encoded);
        await db.engine.rawPut('items', ByteKey(_codec.encode(i)), encoded);
      }

      // Read them back through the native path.
      final readBack = <List<int>>[];
      for (var i = 0; i < _payloads.length; i++) {
        readBack.add(
          (await db.engine.rawGet('items', ByteKey(_codec.encode(i))))!,
        );
      }
      expect(readBack, nativeBytes, reason: 'native round-trip is exact');

      // Push every stored byte array through the web wire (b64 + JSON).
      for (var i = 0; i < nativeBytes.length; i++) {
        final encoded = nativeBytes[i];
        final jsonSafe = encodeValue(encoded);
        final json = jsonEncode(jsonSafe);
        final decoded = decodeValue(jsonDecode(json));
        expect(decoded, encoded,
            reason: 'payload $i must survive the web JSON boundary exactly');

        // Decoding the round-tripped bytes must yield the original logical
        // value (byte-stable codec: re-encoding reproduces the same bytes).
        final logical = _codec.decode(decoded as List<int>);
        expect(
          _codec.encode(logical),
          encoded,
          reason: 'payload $i logical value must decode identically',
        );
      }

      // The native getMany path and the web-wire path agree on row count.
      final all = await db.engine.rawScanAll('items');
      expect(all, hasLength(_payloads.length));
    } finally {
      await db.close();
    }
  });

  test('the web request envelope survives the JSON boundary intact', () {
    for (final payload in _payloads) {
      final encoded = _codec.encode(payload);
      final request = <String, Object?>{
        'cmd': 'request',
        'id': 7,
        'op': 'applyBatch',
        'args': <Object?>[encodeValue(encoded)],
      };
      final decoded = decodeMessage(encodeRequest(request));
      expect(decoded['cmd'], 'request');
      expect(decoded['id'], 7);
      expect(decoded['op'], 'applyBatch');
      final args = (decoded['args'] as List).cast<Object?>();
      expect(decodeValue(args[0]), encoded,
          reason: 'request arg must survive the web envelope');
    }
  });
}
