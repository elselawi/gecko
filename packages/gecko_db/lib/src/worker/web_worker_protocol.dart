/// JSON-safe codec for the web Worker protocol
/// (`package:gecko_db/web/gecko_db_worker.dart` ↔ `WebWorkerClient`).
///
/// Messages cross a real `postMessage` boundary between two compiled JS
/// contexts, so everything must be JSON-encodable. Byte arrays are wrapped as
/// `{"b64": "<base64>"}` maps; everything else keeps its native JSON shape
/// (strings, ints, bools, nulls, nested lists). This file is platform-neutral
/// and unit-tested on the VM.
///
/// A binary variant of the same codec ([encodeValueBinary] /
/// [decodeValueBinary] / [encodeMessageBinary] / [decodeMessageBinary])
/// encodes byte arrays as `{"bytes": <Uint8List>}` instead of base64, so the
/// web transport can move them as transferable ArrayBuffers (no 33% base64
/// expansion, no JSON stringify/parse of payload bytes). The binary channel
/// is used only when the transport confirms a binary-capable `postMessage`;
/// otherwise both sides fall back to the JSON codec — the two shapes are
/// interoperable because both decoders accept the other's byte tags.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../native/generated/worker.dart' show StorageStats;

/// The wire key used to tag a base64-encoded byte array.
const String b64Tag = 'b64';

/// The wire key used to tag a binary-transfer byte array.
const String bytesTag = 'bytes';

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

/// Binary-transfer variant of [encodeValue]: byte arrays become
/// `{"bytes": <Uint8List>}` (a zero-copy view when the input is already
/// typed), which the transport converts to a transferable ArrayBuffer.
/// `StorageStats`/lists/maps recurse exactly like [encodeValue].
Object? encodeValueBinary(Object? value) {
  if (value == null) return null;
  if (value is List<int>) {
    return <String, Object?>{
      bytesTag: value is Uint8List ? value : Uint8List.fromList(value),
    };
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
    return <Object?>[for (final item in value) encodeValueBinary(item)];
  }
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): encodeValueBinary(entry.value),
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

/// Decodes a value received on a binary channel: `{"bytes": <Uint8List>}`
/// leaves return the `Uint8List` directly (zero copy); legacy `{"b64": ...}`
/// leaves still decode for mixed-version interop; everything else matches
/// [decodeValue].
Object? decodeValueBinary(Object? value) {
  if (value == null) return null;
  if (value is Map) {
    final bytes = value[bytesTag];
    // The transport may deliver the leaf as a Uint8List (js_interop
    // `dartify` of a JS typed array) or a plain List<int> — both decode.
    if (bytes is Uint8List) return bytes;
    if (bytes is List<int>) return Uint8List.fromList(bytes);
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
        entry.key.toString(): decodeValueBinary(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) decodeValueBinary(item)];
  }
  return value;
}

/// Encodes a worker request message to a JSON string.
String encodeRequest(Map<String, Object?> request) => jsonEncode(request);

/// Encodes a worker response message to a JSON string.
String encodeResponse(Map<String, Object?> response) => jsonEncode(response);

/// Encodes a worker request message to the binary channel shape (a plain
/// map with `{"bytes": ...}` leaves; the transport converts it to a JS
/// message with transferable buffers).
Map<String, Object?> encodeRequestBinary(Map<String, Object?> request) =>
    <String, Object?>{
      for (final entry in request.entries)
        entry.key: encodeValueBinary(entry.value),
    };

/// Encodes a worker response message to the binary channel shape.
Map<String, Object?> encodeResponseBinary(Map<String, Object?> response) =>
    <String, Object?>{
      for (final entry in response.entries)
        entry.key: encodeValueBinary(entry.value),
    };

/// Decodes a JSON string message into a map (throws on malformed JSON).
Map<String, Object?> decodeMessage(String message) =>
    jsonDecode(message) as Map<String, Object?>;

/// Decodes a message from either channel: a JSON string (fallback/legacy) or
/// a decoded object map with binary `{"bytes": ...}` leaves.
Map<String, Object?> decodeMessageBinary(Object? message) {
  if (message is String) return decodeMessage(message);
  final map = Map<Object?, Object?>.from(message as Map);
  return <String, Object?>{
    for (final entry in map.entries)
      entry.key.toString(): decodeValueBinary(entry.value),
  };
}
