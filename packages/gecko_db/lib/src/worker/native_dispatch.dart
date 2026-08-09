/// Shared native-worker operation dispatch, used by both the isolate worker
/// client ([`NativeWorkerClient`]) and the reusable web Worker entry
/// (`package:gecko_db/web/gecko_db_worker.dart`).
///
/// Every operation maps to a generated FRB `NativeWorker` method. Results are
/// plain, JSON-encodable values (big ints as strings) so they can travel over
/// either an isolate port or a `postMessage` boundary unchanged.
library;

import 'dart:typed_data';

import '../errors/errors.dart';
import '../native/generated/api.dart';

/// Dispatches a single [operation] to [worker]. Returns a plain, sendable
/// value; throws a [GeckoError] (or a raw FRB error) on failure.
Future<Object?> dispatchNativeWorker(
  NativeWorker worker,
  String operation,
  List<Object?> arguments,
) async {
  switch (operation) {
    case 'applyBatch':
      return (await worker.applyBatch(
        encodedOps: List<int>.from(arguments[0] as List),
      )).toString();
    case 'get':
      final value = await worker.get_(
        table: arguments[0] as String,
        key: List<int>.from(arguments[1] as List),
      );
      return value?.toList();
    case 'rangeScan':
      final pairs = await worker.rangeScan(
        table: arguments[0] as String,
        start: arguments[1] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[1] as List)),
        end: arguments[2] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[2] as List)),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'tables':
      return await worker.tables();
    case 'createSnapshot':
      return (await worker.createSnapshot()).toString();
    case 'snapshotGet':
      final value = await worker.snapshotGet(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        key: Uint8List.fromList(List<int>.from(arguments[2] as List)),
      );
      return value?.toList();
    case 'snapshotRangeScan':
      final pairs = await worker.snapshotRangeScan(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        start: arguments[2] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[2] as List)),
        end: arguments[3] == null
            ? null
            : Uint8List.fromList(List<int>.from(arguments[3] as List)),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'queryIndexed':
      final pairs = await worker.queryIndexed(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        start: Uint8List.fromList(List<int>.from(arguments[2] as List)),
        end: Uint8List.fromList(List<int>.from(arguments[3] as List)),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQueryIndexed':
      final pairs = await worker.snapshotQueryIndexed(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        start: Uint8List.fromList(List<int>.from(arguments[3] as List)),
        end: Uint8List.fromList(List<int>.from(arguments[4] as List)),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'queryFiltered':
      final pairs = await worker.queryFiltered(
        table: arguments[0] as String,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[1] as List),
        ),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQueryFiltered':
      final pairs = await worker.snapshotQueryFiltered(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[2] as List),
        ),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'dropSnapshot':
      await worker.dropSnapshot(snapshot: _asBigInt(arguments[0]));
      return null;
    case 'commitSequence':
      return (await worker.commitSequence()).toString();
    case 'compact':
      return await worker.compact();
    case 'storageStats':
      return await worker.storageStats();
    case 'compatibilityHandshake':
      return await worker.compatibilityHandshake();
    case 'close':
      await worker.close();
      return null;
    default:
      throw const GeckoError(
        GeckoErrorType.invalidOperation,
        'Unknown native worker operation',
      );
  }
}

BigInt _asBigInt(Object? value) {
  if (value is BigInt) return value;
  if (value is String) return BigInt.parse(value);
  return BigInt.from(value as int);
}
