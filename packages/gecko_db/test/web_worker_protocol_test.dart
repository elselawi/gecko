// Tests for the web-worker protocol codec and the VM-side stubs of the
// web-only client. The codec is platform-neutral; the live browser path is
// validated by `tool/web_smoke` (the reusable `gecko_db_worker.dart`).
library;

import 'dart:convert';

import 'package:gecko_db/gecko_db.dart' hide StorageStats;
import 'package:gecko_db/src/native/generated/worker.dart' show StorageStats;
import 'package:gecko_db/src/worker/web_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('web worker protocol codec', () {
    test('byte arrays round-trip as base64 tags', () {
      final bytes = <int>[0, 1, 2, 250, 251, 252];
      final encoded = encodeValue(bytes);
      expect(encoded, isA<Map<String, Object?>>());
      expect((encoded as Map<String, Object?>)[b64Tag], base64Encode(bytes));
      final decoded = decodeValue(encoded);
      expect(decoded, bytes);
    });

    test('lists recurse and preserve structure', () {
      final original = <Object?>[
        <int>[1, 2, 3],
        'hello',
        null,
        42,
        true,
        <Object?>[
          <int>[4, 5],
        ],
      ];
      final roundTrip = decodeValue(encodeValue(original));
      expect(roundTrip, isA<List<Object?>>());
      final list = roundTrip as List<Object?>;
      expect(list[0], <int>[1, 2, 3]);
      expect(list[1], 'hello');
      expect(list[2], isNull);
      expect(list[3], 42);
      expect(list[4], true);
      expect((list[5] as List)[0], <int>[4, 5]);
    });

    test('StorageStats round-trips through the tagged map', () {
      final stats = StorageStats(
        physicalBytes: BigInt.from(1024),
        logicalBytes: BigInt.from(512),
        tableCount: BigInt.from(3),
        openSnapshots: BigInt.from(1),
        commitSequence: BigInt.from(99),
      );
      final encoded = encodeValue(stats);
      final decoded = decodeValue(encoded);
      expect(decoded, isA<StorageStats>());
      final back = decoded as StorageStats;
      expect(back.physicalBytes, BigInt.from(1024));
      expect(back.logicalBytes, BigInt.from(512));
      expect(back.tableCount, BigInt.from(3));
      expect(back.openSnapshots, BigInt.from(1));
      expect(back.commitSequence, BigInt.from(99));
    });

    test('full message encode/decode via JSON string survives', () {
      final request = <String, Object?>{
        'cmd': 'request',
        'id': 7,
        'op': 'applyBatch',
        'args': <Object?>[
          encodeValue(<int>[9, 8, 7]),
        ],
      };
      final jsonString = encodeRequest(request);
      final decoded = decodeMessage(jsonString);
      expect(decoded['cmd'], 'request');
      expect(decoded['id'], 7);
      expect(decoded['op'], 'applyBatch');
      final args = (decoded['args'] as List).cast<Object?>();
      expect(decodeValue(args[0]), <int>[9, 8, 7]);
    });

    test('big ints survive as strings', () {
      final original = <Object?>['18446744073709551615'];
      final roundTrip = decodeValue(encodeValue(original));
      expect((roundTrip as List)[0], '18446744073709551615');
    });
  });

  group('web worker client (VM stub)', () {
    test('open throws UnsupportedError on the VM', () async {
      await expectLater(
        () => WebWorkerClient.open(workerUrl: 'w.js', path: ':memory:'),
        throwsUnsupportedError,
      );
    });
  });
}
