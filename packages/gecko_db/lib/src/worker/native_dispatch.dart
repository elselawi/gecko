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
    case 'repairIndex':
      await worker.repairIndex(
        table: arguments[0] as String,
        fields: [for (final field in (arguments[1] as List)) field as String],
      );
      return null;
    case 'get':
      final value = await worker.get_(
        table: arguments[0] as String,
        key: List<int>.from(arguments[1] as List),
      );
      return value?.toList();
    case 'snapshotGetMany':
      final keys = [
        for (final k in (arguments[2] as List))
          Uint8List.fromList(List<int>.from(k as List)),
      ];
      final pairs = await worker.snapshotGetMany(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        keys: keys,
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
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
    case 'snapshotQueryFilteredCount':
      final count = await worker.snapshotQueryFilteredCount(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[2] as List),
        ),
      );
      return count.toString();
    case 'snapshotQueryFilteredDistinct':
      final fields = await worker.snapshotQueryFilteredDistinct(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[2] as List),
        ),
        field: arguments[3] as String,
      );
      return [for (final b in fields) b.toList()];
    case 'dropSnapshot':
      await worker.dropSnapshot(snapshot: _asBigInt(arguments[0]));
      return null;
    case 'snapshotQueryFilteredLimited':
      final pairs = await worker.snapshotQueryFilteredLimited(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[2] as List),
        ),
        limit: arguments[3] == null ? null : _asBigInt(arguments[3]),
        offset: _asBigInt(arguments[4]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQueryIndexedMulti':
      final ranges = [
        for (final range in (arguments[3] as List))
          (
            Uint8List.fromList(List<int>.from((range as List)[0] as List)),
            Uint8List.fromList(List<int>.from(range[1] as List)),
          ),
      ];
      final pairs = await worker.snapshotQueryIndexedMulti(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        ranges: ranges,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[4] as List),
        ),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQueryIndexedLimited':
      final pairs = await worker.snapshotQueryIndexedLimited(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        start: Uint8List.fromList(List<int>.from(arguments[3] as List)),
        end: Uint8List.fromList(List<int>.from(arguments[4] as List)),
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[5] as List),
        ),
        limit: arguments[6] == null ? null : _asBigInt(arguments[6]),
        offset: _asBigInt(arguments[7]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQuerySorted':
      final pairs = await worker.snapshotQuerySorted(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[2] as List),
        ),
        sortSpecBytes: Uint8List.fromList(List<int>.from(arguments[3] as List)),
        limit: arguments[4] == null ? null : _asBigInt(arguments[4]),
        offset: _asBigInt(arguments[5]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQueryIndexedOrdered':
      final pairs = await worker.snapshotQueryIndexedOrdered(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        start: Uint8List.fromList(List<int>.from(arguments[3] as List)),
        end: Uint8List.fromList(List<int>.from(arguments[4] as List)),
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[5] as List),
        ),
        sortField: arguments[6] as String,
        eqBounded: arguments[7] as bool,
        limit: arguments[8] == null ? null : _asBigInt(arguments[8]),
        offset: _asBigInt(arguments[9]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
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
