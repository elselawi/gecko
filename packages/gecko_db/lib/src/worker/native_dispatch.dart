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
import '../native/generated/api.dart' as generated;

/// Dispatches a single [operation] to [worker]. Returns a plain, sendable
/// value; throws a [GeckoError] (or a raw FRB error) on failure.
Future<Object?> dispatchNativeWorker(
  generated.NativeWorker worker,
  String operation,
  List<Object?> arguments,
) async {
  switch (operation) {
    case 'applyBatch':
      final result = await worker.applyBatch(
        encodedOps: _bytes(arguments[0]),
        indexDefinitions: [
          for (final definition
              in (arguments.length > 1
                  ? List<Object?>.from(arguments[1] as List)
                  : const <Object?>[]))
            _decodeIndexDefinition(definition),
        ],
        changeLogMaxEntries: _asBigInt(arguments.length > 2 ? arguments[2] : 0),
      );
      return _encodeApplyBatchResult(result);
    case 'applyPreparedBatch':
      final result = await worker.applyPreparedBatch(
        encodedOps: _bytes(arguments[0]),
        indexDefinitions: [
          for (final definition in arguments[1] as List)
            _decodeIndexDefinition(definition),
        ],
        changeLogMaxEntries: _asBigInt(arguments[2]),
        previousOperationIndexes: [
          for (final index in arguments[3] as List) index.toString(),
        ],
        putModes: [
          for (final entry in arguments[4] as List)
            (_asBigInt((entry as List)[0]), (entry[1] as int)),
        ],
        changes: [
          for (final change in arguments[5] as List)
            generated.PreparedChange(
              operationIndex: _asBigInt((change as Map)['operationIndex']),
              ordinal: _asBigInt(change['ordinal']),
              syncStateKey: Uint8List.fromList(
                List<int>.from(change['syncStateKey'] as List),
              ),
              recordTemplate: Uint8List.fromList(
                List<int>.from(change['recordTemplate'] as List),
              ),
              fillPreviousVersion: change['fillPreviousVersion'] as bool,
            ),
        ],
      );
      return _encodeApplyBatchResult(result);
    case 'registerLiveQuery':
      final result = await worker.registerLiveQuery(
        table: arguments[0] as String,
        predicateBytes: List<int>.from(arguments[1] as List),
        sortBytes: List<int>.from(arguments[2] as List),
        kind: arguments[3] as int,
      );
      return <String, Object?>{
        'id': result.id.toString(),
        'initial': [
          for (final pair in result.initial)
            <Object?>[pair.$1.toList(), pair.$2.toList()],
        ],
      };
    case 'unregisterLiveQuery':
      await worker.unregisterLiveQuery(id: _asBigInt(arguments[0]));
      return null;
    case 'liveQueryCount':
      return (await worker.liveQueryCount()).toString();
    case 'pendingChanges':
      final pairs = await worker.pendingChanges();
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'repairIndex':
      await worker.repairIndex(
        table: arguments[0] as String,
        fields: [for (final field in (arguments[1] as List)) field as String],
      );
      return null;
    case 'get':
      final value = await worker.get_(
        table: arguments[0] as String,
        key: _bytes(arguments[1]),
      );
      return value;
    case 'snapshotGetMany':
      final keys = [for (final k in arguments[2] as List) _bytes(k)];
      final pairs = await worker.snapshotGetMany(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        keys: keys,
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'getMany':
      final pairs = await worker.getMany(
        table: arguments[0] as String,
        keys: [for (final k in arguments[1] as List) _bytes(k)],
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'rangeScan':
      final pairs = await worker.rangeScan(
        table: arguments[0] as String,
        start: arguments[1] == null ? null : _bytes(arguments[1]),
        end: arguments[2] == null ? null : _bytes(arguments[2]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'tables':
      return await worker.tables();
    case 'createSnapshot':
      return (await worker.createSnapshot()).toString();
    case 'snapshotGet':
      final value = await worker.snapshotGet(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        key: _bytes(arguments[2]),
      );
      return value;
    case 'snapshotRangeScan':
      final pairs = await worker.snapshotRangeScan(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        start: arguments[2] == null ? null : _bytes(arguments[2]),
        end: arguments[3] == null ? null : _bytes(arguments[3]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryIndexed':
      final pairs = await worker.queryIndexed(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        start: _bytes(arguments[2]),
        end: _bytes(arguments[3]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'snapshotQueryIndexed':
      final pairs = await worker.snapshotQueryIndexed(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        start: _bytes(arguments[3]),
        end: _bytes(arguments[4]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryFiltered':
      final pairs = await worker.queryFiltered(
        table: arguments[0] as String,
        predicateBytes: _bytes(arguments[1]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'snapshotQueryFiltered':
      final pairs = await worker.snapshotQueryFiltered(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: _bytes(arguments[2]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryFilteredCount':
      final count = await worker.queryFilteredCount(
        table: arguments[0] as String,
        predicateBytes: _bytes(arguments[1]),
      );
      return count.toString();
    case 'queryFilteredLimited':
      final pairs = await worker.queryFilteredLimited(
        table: arguments[0] as String,
        predicateBytes: _bytes(arguments[1]),
        limit: arguments[2] == null ? null : _asBigInt(arguments[2]),
        offset: _asBigInt(arguments[3]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryIndexedLimited':
      final pairs = await worker.queryIndexedLimited(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        start: _bytes(arguments[2]),
        end: _bytes(arguments[3]),
        predicateBytes: _bytes(arguments[4]),
        covered: arguments[5] as bool,
        limit: arguments[6] == null ? null : _asBigInt(arguments[6]),
        offset: _asBigInt(arguments[7]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'querySorted':
      final pairs = await worker.querySorted(
        table: arguments[0] as String,
        predicateBytes: _bytes(arguments[1]),
        sortSpecBytes: _bytes(arguments[2]),
        limit: arguments[3] == null ? null : _asBigInt(arguments[3]),
        offset: _asBigInt(arguments[4]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryIndexedOrdered':
      final pairs = await worker.queryIndexedOrdered(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        start: _bytes(arguments[2]),
        end: _bytes(arguments[3]),
        predicateBytes: _bytes(arguments[4]),
        sortField: arguments[5] as String,
        eqBounded: arguments[6] as bool,
        descending: arguments[7] as bool,
        covered: arguments[8] as bool,
        limit: arguments[9] == null ? null : _asBigInt(arguments[9]),
        offset: _asBigInt(arguments[10]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'snapshotQueryFilteredCount':
      final count = await worker.snapshotQueryFilteredCount(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: _bytes(arguments[2]),
      );
      return count.toString();
    case 'queryFilteredDistinct':
      final fields = await worker.queryFilteredDistinct(
        table: arguments[0] as String,
        predicateBytes: _bytes(arguments[1]),
        field: arguments[2] as String,
      );
      return fields;
    case 'snapshotQueryFilteredDistinct':
      final fields = await worker.snapshotQueryFilteredDistinct(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: _bytes(arguments[2]),
        field: arguments[3] as String,
      );
      return fields;
    case 'dropSnapshot':
      await worker.dropSnapshot(snapshot: _asBigInt(arguments[0]));
      return null;
    case 'snapshotRelationshipParent':
      final pair = await worker.snapshotRelationshipParent(
        snapshot: _asBigInt(arguments[0]),
        childTable: arguments[1] as String,
        childKey: Uint8List.fromList(List<int>.from(arguments[2] as List)),
        parentTable: arguments[3] as String,
        foreignKeyField: arguments[4] as String,
      );
      return pair == null
          ? null
          : <Object?>[pair.$1.toList(), pair.$2.toList()];
    case 'snapshotRelationshipChildren':
      final groups = await worker.snapshotRelationshipChildren(
        snapshot: _asBigInt(arguments[0]),
        childTable: arguments[1] as String,
        foreignKeyField: arguments[2] as String,
        parentIds: [
          for (final id in (arguments[3] as List))
            Uint8List.fromList(List<int>.from(id as List)),
        ],
        indexTable: arguments[4] as String,
        indexRanges: [
          for (final range in (arguments[5] as List))
            (
              Uint8List.fromList(List<int>.from((range as List)[0] as List)),
              Uint8List.fromList(List<int>.from(range[1] as List)),
            ),
        ],
        predicateBytes: _bytes(arguments[6]),
      );
      return [
        for (final group in groups)
          <Object?>[
            group.parentId.toList(),
            [
              for (final pair in group.entries)
                <Object?>[pair.$1.toList(), pair.$2.toList()],
            ],
          ],
      ];
    case 'snapshotRelationshipJoinIds':
      final ids = await worker.snapshotRelationshipJoinIds(
        snapshot: _asBigInt(arguments[0]),
        joinTable: arguments[1] as String,
        field: arguments[2] as String,
        wantedId: Uint8List.fromList(List<int>.from(arguments[3] as List)),
      );
      return [for (final id in ids) id.toList()];
    case 'snapshotQueryFilteredLimited':
      final pairs = await worker.snapshotQueryFilteredLimited(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        predicateBytes: _bytes(arguments[2]),
        limit: arguments[3] == null ? null : _asBigInt(arguments[3]),
        offset: _asBigInt(arguments[4]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryIndexedMulti':
      final pairs = await worker.queryIndexedMulti(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        ranges: [
          for (final range in arguments[2] as List)
            (_bytes((range as List)[0]), _bytes(range[1])),
        ],
        predicateBytes: _bytes(arguments[3]),
        covered: arguments[4] as bool,
        limit: arguments[5] == null ? null : _asBigInt(arguments[5]),
        offset: _asBigInt(arguments[6]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1, pair.$2],
      ];
    case 'queryIndexedDistinct':
      final fields = await worker.queryIndexedDistinct(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        ranges: [
          for (final range in arguments[2] as List)
            (_bytes((range as List)[0]), _bytes(range[1])),
        ],
        predicateBytes: _bytes(arguments[3]),
        field: arguments[4] as String,
        covered: arguments[5] as bool,
      );
      return fields;
    case 'queryIndexedCount':
      final count = await worker.queryIndexedCount(
        table: arguments[0] as String,
        indexTable: arguments[1] as String,
        ranges: [
          for (final range in arguments[2] as List)
            (_bytes((range as List)[0]), _bytes(range[1])),
        ],
        predicateBytes: _bytes(arguments[3]),
        covered: arguments[4] as bool,
      );
      return count.toString();
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
        covered: arguments[5] as bool,
        limit: arguments[6] == null ? null : _asBigInt(arguments[6]),
        offset: _asBigInt(arguments[7]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'snapshotQueryIndexedCount':
      final count = await worker.snapshotQueryIndexedCount(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        ranges: [
          for (final range in (arguments[3] as List))
            (
              Uint8List.fromList(List<int>.from((range as List)[0] as List)),
              Uint8List.fromList(List<int>.from(range[1] as List)),
            ),
        ],
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[4] as List),
        ),
        covered: arguments[5] as bool,
      );
      return count.toString();
    case 'snapshotQueryIndexedDistinct':
      final fields = await worker.snapshotQueryIndexedDistinct(
        snapshot: _asBigInt(arguments[0]),
        table: arguments[1] as String,
        indexTable: arguments[2] as String,
        ranges: [
          for (final range in (arguments[3] as List))
            (
              Uint8List.fromList(List<int>.from((range as List)[0] as List)),
              Uint8List.fromList(List<int>.from(range[1] as List)),
            ),
        ],
        predicateBytes: Uint8List.fromList(
          List<int>.from(arguments[4] as List),
        ),
        field: arguments[5] as String,
        covered: arguments[6] as bool,
      );
      return [for (final bytes in fields) bytes.toList()];
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
        covered: arguments[6] as bool,
        limit: arguments[7] == null ? null : _asBigInt(arguments[7]),
        offset: _asBigInt(arguments[8]),
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
        descending: arguments[8] as bool,
        covered: arguments[9] as bool,
        limit: arguments[10] == null ? null : _asBigInt(arguments[10]),
        offset: _asBigInt(arguments[11]),
      );
      return [
        for (final pair in pairs) <Object?>[pair.$1.toList(), pair.$2.toList()],
      ];
    case 'setCompositeIndexes':
      await worker.setCompositeIndexes(
        table: arguments[0] as String,
        indexes: [
          for (final index in arguments[1] as List)
            [for (final field in index as List) field as String],
        ],
      );
      return null;
    case 'commitSequence':
      return (await worker.commitSequence()).toString();
    case 'compact':
      return await worker.compact();
    case 'storageStats':
      return await worker.storageStats();
    case 'enableCounters':
      await worker.enableCounters();
      return null;
    case 'disableCounters':
      await worker.disableCounters();
      return null;
    case 'takeCounters':
      return await worker.takeCounters();
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

(String, List<String>) _decodeIndexDefinition(Object? definition) {
  if (definition case (final String table, final List<String> fields)) {
    return (table, fields);
  }
  if (definition is List && definition.length == 2) {
    return (
      definition[0] as String,
      [for (final field in definition[1] as List) field as String],
    );
  }
  throw const GeckoError(
    GeckoErrorType.invalidOperation,
    'Malformed durable index declaration',
  );
}

BigInt _asBigInt(Object? value) {
  if (value is BigInt) return value;
  if (value is String) return BigInt.parse(value);
  return BigInt.from(value as int);
}

Uint8List _bytes(Object? value) => value is Uint8List
    ? value
    : Uint8List.fromList(List<int>.from(value as List));

/// Encodes a generated `QueryDelta` as a plain, JSON-encodable map so it can
/// travel over the isolate/web boundary unchanged.
Map<String, Object?> _encodeApplyBatchResult(
  generated.ApplyBatchResult result,
) => <String, Object?>{
  'sequence': result.sequence.toString(),
  'previousValues': [
    for (final value in result.previousValues) value?.toList(),
  ],
  'removedKeys': [
    for (final (table, key) in result.removedKeys)
      <Object?>[table, key.toList()],
  ],
  'deltas': [for (final delta in result.deltas) _encodeDelta(delta)],
};

Map<String, Object?> _encodeDelta(generated.QueryDelta delta) =>
    <String, Object?>{
      'id': delta.id.toString(),
      'added': [
        for (final pair in delta.added)
          <Object?>[pair.$1.toList(), pair.$2.toList()],
      ],
      'updated': [
        for (final pair in delta.updated)
          <Object?>[pair.$1.toList(), pair.$2.toList()],
      ],
      'removed': [
        for (final pair in delta.removed)
          <Object?>[pair.$1.toList(), pair.$2.toList()],
      ],
      'snapshot': [
        for (final pair in delta.snapshot)
          <Object?>[pair.$1.toList(), pair.$2.toList()],
      ],
      'unchanged': delta.unchanged,
    };
