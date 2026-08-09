/// JSON-safe codec for the web Worker protocol
/// (`package:gecko_db/web/gecko_db_worker.dart` ↔ `WebWorkerClient`).
///
/// Messages cross a real `postMessage` boundary between two compiled JS
/// contexts, so everything must be JSON-encodable. Byte arrays are wrapped as
/// `{"b64": "<base64>"}` maps; everything else keeps its native JSON shape
/// (strings, ints, bools, nulls, nested lists). This file is platform-neutral
/// and unit-tested on the VM.
library;

import 'dart:convert';

import '../native/generated/worker.dart' show StorageStats;

/// The wire key used to tag a base64-encoded byte array.
const String b64Tag = 'b64';

/// Encodes [value] (as returned by `dispatchNativeWorker`) into a JSON-safe
/// form. Byte arrays become `{"b64": ...}` maps; `StorageStats` becomes a
/// tagged map; lists recurse; strings/ints/bools/null pass through. Big
/// integers are already strings (the dispatch layer converts them), so they
/// survive JSON intact.
Object? encodeValue(Object? value) {
  if (value == null) return null;
  if (value is List<int>) {
    return <String, Object?>{b64Tag: base64Encode(value)};
  }
  if (value is StorageStats) {
    return <String, Object?>{
      'storageStats': <String, Object?>{
        'physicalBytes': value.physicalBytes.toString(),
        'logicalBytes': value.logicalBytes.toString(),
        'tableCount': value.tableCount.toString(),
        'openSnapshots': value.openSnapshots.toString(),
        'commitSequence': value.commitSequence.toString(),
      },
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) encodeValue(item)];
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): encodeValue(entry.value),
    };
  }
  return value;
}

/// Decodes a JSON-decoded value back into the shape
/// `dispatchNativeWorker` produces: `{"b64": ...}` maps become `List<int>`,
/// `{"storageStats": ...}` maps become `StorageStats`, arrays become
/// `List<Object?>`.
Object? decodeValue(Object? value) {
  if (value == null) return null;
  if (value is Map) {
    final b64 = value[b64Tag];
    if (b64 is String) return base64Decode(b64);
    final stats = value['storageStats'];
    if (stats is Map) {
      return StorageStats(
        physicalBytes: BigInt.parse(stats['physicalBytes'] as String),
        logicalBytes: BigInt.parse(stats['logicalBytes'] as String),
        tableCount: BigInt.parse(stats['tableCount'] as String),
        openSnapshots: BigInt.parse(stats['openSnapshots'] as String),
        commitSequence: BigInt.parse(stats['commitSequence'] as String),
      );
    }
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): decodeValue(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) decodeValue(item)];
  }
  return value;
}

/// Encodes a worker request message to a JSON string.
String encodeRequest(Map<String, Object?> request) => jsonEncode(request);

/// Encodes a worker response message to a JSON string.
String encodeResponse(Map<String, Object?> response) => jsonEncode(response);

/// Decodes a JSON string message into a map (throws on malformed JSON).
Map<String, Object?> decodeMessage(String message) =>
    jsonDecode(message) as Map<String, Object?>;
