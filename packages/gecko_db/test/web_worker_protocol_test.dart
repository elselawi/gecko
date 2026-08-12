// Tests for the web-worker protocol codec and the VM-side stubs of the
// web-only client. The codec is platform-neutral; the live browser path is
// validated by `tool/web_smoke` (the reusable `gecko_db_worker.dart`).
library;

import 'dart:convert';
import 'dart:typed_data';

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

    test('List<int> round-trips as Uint8List (type identity lost)', () {
      final decoded = decodeValue(encodeValue(<int>[1, 2, 3]));
      expect(
        decoded,
        isA<Uint8List>(),
        reason: 'base64 decode yields Uint8List',
      );
      expect(List<int>.from(decoded as Uint8List), [1, 2, 3]);
    });

    test('map keys are coerced via toString (lossy)', () {
      final encoded = encodeValue(<Object?, Object?>{1: 'int', true: 'bool'});
      // Both keys stringify to "1" / "true"; the original key type is lost.
      final map = encoded as Map<String, Object?>;
      expect(map['1'], 'int');
      expect(map['true'], 'bool');
      final decoded = decodeValue(encoded) as Map<String, Object?>;
      expect(decoded['1'], 'int');
      expect(decoded['true'], 'bool');
    });

    test("a {'b64': non-string} map falls through to the generic map", () {
      final decoded = decodeValue(<String, Object?>{'b64': 42});
      expect(decoded, isA<Map<String, Object?>>());
      expect((decoded as Map<String, Object?>)['b64'], 42);
    });

    test('malformed storageStats throws a FormatException', () {
      expect(
        () => decodeValue(<String, Object?>{
          'storageStats': <String, Object?>{'physicalBytes': 'not-a-number'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('malformed JSON message throws a FormatException', () {
      expect(() => decodeMessage('{not json'), throwsA(isA<FormatException>()));
      expect(
        () => decodeMessage('[1, 2]'),
        throwsA(isA<TypeError>()),
        reason: 'a non-map JSON root cannot be cast to a message map',
      );
    });

    test(
      'round-trip preserves JS-safe and unsafe integer values as strings',
      () {
        // The dispatch layer converts big ints to strings; a string that looks
        // like a huge integer survives as a string.
        final payload = <Object?>[
          '9007199254740993', // 2^53 + 1, not JS-safe
          '18446744073709551615',
        ];
        final roundTrip = decodeValue(encodeValue(payload)) as List;
        expect(roundTrip, payload);
      },
    );
  });

  group('protocol malformed-input matrix', () {
    test('a b64 map with non-base64 payload throws FormatException', () {
      expect(
        () => decodeValue(<String, Object?>{'b64': '!! not base64 !!'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('a b64 map with an odd-length payload throws FormatException', () {
      expect(
        () => decodeValue(<String, Object?>{'b64': 'aGVsbG'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('an empty b64 payload decodes to an empty byte array', () {
      final decoded = decodeValue(<String, Object?>{'b64': ''});
      expect(decoded, isA<Uint8List>());
      expect(decoded as Uint8List, isEmpty);
    });

    test('storageStats with a missing field throws a raw TypeError', () {
      expect(
        () => decodeValue(<String, Object?>{
          'storageStats': <String, Object?>{'physicalBytes': '1024'},
        }),
        throwsA(isA<TypeError>()),
        reason: 'missing fields cast null to String',
      );
    });

    test('storageStats with a non-string numeric field throws a TypeError', () {
      expect(
        () => decodeValue(<String, Object?>{
          'storageStats': <String, Object?>{
            'physicalBytes': 1024,
            'logicalBytes': '512',
            'tableCount': '3',
            'openSnapshots': '1',
            'commitSequence': '99',
          },
        }),
        throwsA(isA<TypeError>()),
        reason: 'an int cannot cast to String',
      );
    });

    test("a storageStats tag with a non-map value falls through to a map", () {
      final decoded = decodeValue(<String, Object?>{'storageStats': 'nope'});
      expect(decoded, isA<Map<String, Object?>>());
      expect((decoded as Map<String, Object?>)['storageStats'], 'nope');
    });

    test('duplicate JSON keys keep the last occurrence (pinned)', () {
      final decoded = decodeMessage('{"id": 1, "id": 2}');
      expect(decoded['id'], 2);
    });

    test('a null JSON root cannot cast to a message map', () {
      expect(() => decodeMessage('null'), throwsA(isA<TypeError>()));
    });

    test('an empty string is not valid JSON', () {
      expect(() => decodeMessage(''), throwsA(isA<FormatException>()));
    });

    test('non-string cmd/op fields survive decode (no validation)', () {
      final decoded = decodeMessage('{"cmd": 42, "op": ["x"], "id": 1}');
      expect(decoded['cmd'], 42);
      expect(decoded['op'], ['x']);
    });

    test('nested b64 tags decode recursively inside lists and maps', () {
      final wrapped = <String, Object?>{
        'b64': base64Encode(<int>[7, 8, 9]),
      };
      final decoded = decodeValue(<Object?>[
        <String, Object?>{'inner': wrapped},
        <Object?>[wrapped],
      ]);
      final outer = decoded as List<Object?>;
      final innerMap = outer[0] as Map<String, Object?>;
      expect(innerMap['inner'], <int>[7, 8, 9]);
      final innerList = outer[1] as List<Object?>;
      expect(innerList[0], <int>[7, 8, 9]);
    });

    test('encodeValue wraps empty and single-byte arrays as b64', () {
      final empty = encodeValue(<int>[]) as Map<String, Object?>;
      expect(empty[b64Tag], '');
      final single = encodeValue(<int>[255]) as Map<String, Object?>;
      expect(single[b64Tag], base64Encode(<int>[255]));
    });

    test('StorageStats with huge BigInt fields round-trips exactly', () {
      final stats = StorageStats(
        physicalBytes: BigInt.parse('18446744073709551615'),
        logicalBytes: BigInt.parse('9007199254740993'),
        tableCount: BigInt.from(1),
        openSnapshots: BigInt.zero,
        commitSequence: BigInt.parse('99999999999999999999'),
      );
      final decoded = decodeValue(encodeValue(stats)) as StorageStats;
      expect(decoded.physicalBytes, stats.physicalBytes);
      expect(decoded.logicalBytes, stats.logicalBytes);
      expect(decoded.tableCount, stats.tableCount);
      expect(decoded.openSnapshots, stats.openSnapshots);
      expect(decoded.commitSequence, stats.commitSequence);
    });

    test('a map with mixed key types stringifies all keys (lossy)', () {
      final encoded =
          encodeValue(<Object?, Object?>{
                'k': <int>[1],
                7: <int>[2],
              })
              as Map<String, Object?>;
      expect(encoded['k'], isA<Map<String, Object?>>());
      expect(encoded['7'], isA<Map<String, Object?>>());
    });
  });

  group('web worker protocol binary codec', () {
    test('byte arrays round-trip as transferable bytes tags (zero copy)',
        () {
      final bytes = Uint8List.fromList(<int>[0, 1, 2, 250, 251, 252]);
      final encoded = encodeValueBinary(bytes);
      expect(encoded, isA<Map<String, Object?>>());
      expect((encoded as Map<String, Object?>)[bytesTag], same(bytes),
          reason: 'a Uint8List leaf is wrapped without copying');
      final decoded = decodeValueBinary(encoded);
      expect(decoded, same(bytes));
    });

    test('plain List<int> leaves are converted once to Uint8List', () {
      final encoded = encodeValueBinary(<int>[1, 2, 3]);
      final leaf = (encoded as Map<String, Object?>)[bytesTag];
      expect(leaf, isA<Uint8List>());
      final decoded = decodeValueBinary(encoded);
      expect(decoded, isA<Uint8List>());
      expect(List<int>.from(decoded as Uint8List), [1, 2, 3]);
    });

    test('binary request messages round-trip structure and bytes', () {
      final request = <String, Object?>{
        'cmd': 'request',
        'id': 7,
        'op': 'applyBatch',
        'args': <Object?>[
          encodeValueBinary(<int>[9, 8, 7]),
          <String, Object?>{'inner': encodeValueBinary(<int>[4, 5])},
        ],
      };
      final encoded = encodeRequestBinary(request);
      final decoded = decodeMessageBinary(encoded);
      expect(decoded['cmd'], 'request');
      expect(decoded['id'], 7);
      expect(decoded['op'], 'applyBatch');
      final args = (decoded['args'] as List).cast<Object?>();
      expect(decodeValueBinary(args[0]), <int>[9, 8, 7]);
      final inner = (args[1] as Map)['inner'];
      expect(decodeValueBinary(inner), <int>[4, 5]);
    });

    test('binary decoder accepts a JSON string message (interop fallback)',
        () {
      final jsonString = encodeRequest(<String, Object?>{
        'cmd': 'request',
        'id': 1,
        'args': <Object?>[encodeValue(<int>[1, 2])],
      });
      final decoded = decodeMessageBinary(jsonString);
      expect(decoded['cmd'], 'request');
      expect(decoded['id'], 1);
    });

    test('binary decoder accepts legacy b64 leaves (mixed-version interop)',
        () {
      final decoded = decodeValueBinary(<String, Object?>{
        'b64': base64Encode(<int>[1, 2, 3]),
      });
      expect(List<int>.from(decoded as Uint8List), [1, 2, 3]);
    });

    test('binary codec round-trips StorageStats and non-byte values', () {
      final stats = StorageStats(
        physicalBytes: BigInt.from(1024),
        logicalBytes: BigInt.from(512),
        tableCount: BigInt.from(3),
        openSnapshots: BigInt.from(1),
        commitSequence: BigInt.from(99),
      );
      final decoded = decodeValueBinary(encodeValueBinary(stats));
      expect(decoded, isA<StorageStats>());
      expect((decoded as StorageStats).physicalBytes, BigInt.from(1024));
      final list = decodeValueBinary(encodeValueBinary(<Object?>[
        'hello',
        42,
        true,
        null,
      ])) as List<Object?>;
      expect(list[0], 'hello');
      expect(list[1], 42);
      expect(list[2], true);
      expect(list[3], isNull);
    });
  });

  group('web worker client (VM stub)', () {
    test('open throws UnsupportedError on the VM', () async {
      await expectLater(
        () => WebWorkerClient.open(workerUrl: 'w.js', path: 'web.db'),
        throwsUnsupportedError,
      );
    });
  });
}
