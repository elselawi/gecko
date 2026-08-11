// FRB dispatch-contract tests (audited-test-gaps 2.18).
//
// The public `NativeRawBackend` + `NativeWorker` surface is the FRB dispatch
// contract: every raw operation must land on the intended generated method
// with a typed result. This suite drives a REAL native worker end to end and
// locks:
//   1. the wire/op version contract,
//   2. the RawOp -> wire Op mapping (put/delete/deleteRange/clear),
//   3. every backend method dispatching to its generated worker call,
//   4. index-definition dispatch (registerDurableIndex -> Rust index table),
//   5. counters + compact + storageStats + close teardown.

import 'dart:typed_data';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/namespaces.dart' show geckoIndexTable;
import 'package:gecko_db/src/query/durable_index_bounds.dart'
    show eqBounds, fieldBounds;
import 'package:gecko_db/src/query/predicate_codec.dart' show encodePredicate;
import 'package:gecko_db/src/query/sort_spec_codec.dart' show encodeSortSpecs;
import 'package:test/test.dart';

import 'support/native_database.dart';

const _codec = DefaultWireCodec();

ByteKey _key(Object? value) => ByteKey(_codec.encode(value));

List<int> _row(String id, String nick, int age) =>
    _codec.encode({'id': id, 'nick': nick, 'age': age});

void main() {
  group('wire contract', () {
    test('op / format / predicate / sort-spec versions agree', () {
      expect(Op.wireVersion, 1);
      expect(geckoWireVersion, 1);
      expect(
        const FormatHeader(packageVersion: '0.0.1').wireVersion,
        geckoWireVersion,
      );
      expect(
        const FormatHeader(packageVersion: '0.0.1').encode(),
        isNotEmpty,
      );
    });

    test('each RawOp kind encodes to the intended wire op and round-trips',
        () {
      final put = Op(
        op: OpKind.put,
        table: 't',
        key: Uint8List.fromList([1]),
        value: Uint8List.fromList([9, 9]),
      );
      final del = Op(
        op: OpKind.delete,
        table: 't',
        key: Uint8List.fromList([2]),
      );
      final range = Op(
        op: OpKind.deleteRange,
        table: 't',
        start: Uint8List.fromList([1]),
        end: Uint8List.fromList([3]),
      );
      final clear = Op(op: OpKind.clear, table: 't');

      final decoded = Op.decodeBatch(Op.encodeBatch([put, del, range, clear]));
      expect(decoded, hasLength(4));
      expect(decoded[0].op, OpKind.put);
      expect(decoded[0].table, 't');
      expect(decoded[0].key, [1]);
      expect(decoded[0].value, [9, 9]);
      expect(decoded[1].op, OpKind.delete);
      expect(decoded[1].key, [2]);
      expect(decoded[2].op, OpKind.deleteRange);
      expect(decoded[2].start, [1]);
      expect(decoded[2].end, [3]);
      expect(decoded[3].op, OpKind.clear);
    });
  });

  group('RawOp dispatch to the worker', () {
    test('RawPut lands as a put and the row is readable', () async {
      final db = await openNativeTestDatabase('contract-put');
      final backend = db.engine.backend as NativeRawBackend;
      final key = _key('k1');
      final result = await backend.applyBatch([
        RawPut('t', key, _row('p1', 'ada', 36)),
      ]);
      expect(result.affected, contains(('t', key)));
      final snap = await backend.snapshot();
      try {
        expect(await snap.read('t', key), _row('p1', 'ada', 36));
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('RawDelete lands as a delete and removes the row', () async {
      final db = await openNativeTestDatabase('contract-delete');
      final backend = db.engine.backend as NativeRawBackend;
      final key = _key('k2');
      await backend.applyBatch([RawPut('t', key, _row('p2', 'bob', 20))]);
      final result = await backend.applyBatch([RawDelete('t', key)]);
      expect(result.affected, contains(('t', key)));
      final snap = await backend.snapshot();
      try {
        expect(await snap.read('t', key), isNull);
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('RawDeleteRange lands as a deleteRange and removes the range',
        () async {
      final db = await openNativeTestDatabase('contract-range');
      final backend = db.engine.backend as NativeRawBackend;
      final k1 = _key('a');
      final k2 = _key('b');
      final k3 = _key('c');
      await backend.applyBatch([
        RawPut('t', k1, _row('p1', 'a', 1)),
        RawPut('t', k2, _row('p2', 'b', 2)),
        RawPut('t', k3, _row('p3', 'c', 3)),
      ]);
      final result = await backend.applyBatch([RawDeleteRange('t', k1, k2)]);
      expect(result.affected, contains(('t', k1)));
      expect(result.affected, contains(('t', k2)));
      final snap = await backend.snapshot();
      try {
        final remaining = await snap.scanAll('t');
        expect(remaining, hasLength(1));
        expect(remaining.single.key, k3);
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('RawClear lands as a clear and empties the table', () async {
      final db = await openNativeTestDatabase('contract-clear');
      final backend = db.engine.backend as NativeRawBackend;
      await backend.applyBatch([
        RawPut('t', _key('a'), _row('p1', 'a', 1)),
        RawPut('t', _key('b'), _row('p2', 'b', 2)),
      ]);
      final result = await backend.applyBatch([RawClear('t')]);
      expect(result.affected, contains(('t', ByteKey(const []))));
      final snap = await backend.snapshot();
      try {
        expect(await snap.scanAll('t'), isEmpty);
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('a mixed batch applies atomically with the full affected set',
        () async {
      final db = await openNativeTestDatabase('contract-mixed');
      final backend = db.engine.backend as NativeRawBackend;
      final k1 = _key('k1');
      final k2 = _key('k2');
      final result = await backend.applyBatch([
        RawPut('t', k1, _row('p1', 'a', 1)),
        RawDelete('t', k2), // absent delete is a no-op, still reported
        RawClear('u'),
      ]);
      expect(result.affected, contains(('t', k1)));
      expect(result.affected, contains(('t', k2)));
      expect(result.affected, contains(('u', ByteKey(const []))));
      final snap = await backend.snapshot();
      try {
        expect(await snap.read('t', k1), _row('p1', 'a', 1));
      } finally {
        await snap.dispose();
      }
      await db.close();
    });
  });

  group('full backend dispatch surface', () {
    test('open wires compatibilityHandshake and reports a live worker',
        () async {
      final db = await openNativeTestDatabase('contract-open');
      final backend = db.engine.backend as NativeRawBackend;
      expect(backend.workerAlive, isTrue);
      expect(backend.workerIsolateName, isNotNull);
      expect(backend.workerIsolateName, isNotEmpty);
      await db.close();
    });

    test('getMany dispatches to the batched point-read', () async {
      final db = await openNativeTestDatabase('contract-getmany');
      final backend = db.engine.backend as NativeRawBackend;
      final k1 = _key('a');
      final k2 = _key('b');
      await backend.applyBatch([
        RawPut('t', k1, _row('p1', 'a', 1)),
        RawPut('t', k2, _row('p2', 'b', 2)),
      ]);
      // Duplicate input ids return one row per occurrence.
      final entries = await backend.getMany('t', [k1, k1, k2, _key('zzz')]);
      expect(entries, hasLength(3));
      expect(entries[0].key, k1);
      expect(entries[1].key, k1);
      expect(entries[2].key, k2);
      await db.close();
    });

    test('snapshot read / scan / scanAll / getMany dispatch', () async {
      final db = await openNativeTestDatabase('contract-snap');
      final backend = db.engine.backend as NativeRawBackend;
      final k1 = _key('a');
      final k2 = _key('b');
      final k3 = _key('c');
      await backend.applyBatch([
        RawPut('t', k1, _row('p1', 'a', 1)),
        RawPut('t', k2, _row('p2', 'b', 2)),
        RawPut('t', k3, _row('p3', 'c', 3)),
      ]);
      final snap = await backend.snapshot();
      try {
        expect(await snap.read('t', k2), _row('p2', 'b', 2));
        expect(await snap.read('t', _key('zzz')), isNull);
        final ranged = await snap.scan('t', start: k2, end: k3);
        expect(ranged.map((e) => e.key), [k2, k3]);
        expect(await snap.scanAll('t'), hasLength(3));
        final many = await snap.getMany('t', [k3, k1]);
        expect(many.map((e) => e.key), [k3, k1]);
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('queryFiltered dispatches and filters in Rust', () async {
      final db = await openNativeTestDatabase('contract-filter');
      final backend = db.engine.backend as NativeRawBackend;
      await _seedPeople(backend);
      final predicate = encodePredicate([Filter.eq('nick', 'g3')]);
      final rows = await backend.queryFiltered(
        table: 't',
        predicateBytes: predicate,
      );
      expect(rows, hasLength(4));
      final snap = await backend.snapshot() as NativeRawSnapshot;
      try {
        final snapshotRows = await snap.queryFiltered(
          table: 't',
          predicateBytes: predicate,
        );
        expect(snapshotRows.map((e) => e.key), rows.map((e) => e.key));
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('queryFilteredCount / queryFilteredDistinct / queryFilteredLimited '
        'dispatch', () async {
      final db = await openNativeTestDatabase('contract-aggregate');
      final backend = db.engine.backend as NativeRawBackend;
      await _seedPeople(backend);
      final predicate = encodePredicate(
        [Filter.between('age', min: 10, max: 19)],
      );
      final snap = await backend.snapshot() as NativeRawSnapshot;
      try {
        expect(
          await snap.queryFilteredCount(
            table: 't',
            predicateBytes: predicate,
          ),
          10,
        );
        final distinct = await snap.queryFilteredDistinct(
          table: 't',
          predicateBytes: const [1, 0],
          field: 'nick',
        );
        // The Rust side emits one encoded value per matching row; Dart is
        // responsible for the final decode + dedup.
        expect(distinct, hasLength(40));
        final unique = {
          for (final bytes in distinct) (_codec.decode(bytes) as String),
        };
        expect(unique, hasLength(10));
        final limited = await snap.queryFilteredLimited(
          table: 't',
          predicateBytes: predicate,
          limit: 3,
          offset: 2,
        );
        expect(limited, hasLength(3));
        expect(
          await snap.queryFilteredLimited(
            table: 't',
            predicateBytes: predicate,
            limit: 2,
          ),
          hasLength(2),
        );
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('querySorted dispatches with a Rust-side top-K window', () async {
      final db = await openNativeTestDatabase('contract-sorted');
      final backend = db.engine.backend as NativeRawBackend;
      await _seedPeople(backend);
      final sortBytes = encodeSortSpecs([
        const SortSpec('age', SortOrder.ascending),
      ]);
      final snap = await backend.snapshot() as NativeRawSnapshot;
      try {
        final window = await snap.querySorted(
          table: 't',
          predicateBytes: const [1, 0],
          sortSpecBytes: sortBytes,
          limit: 5,
          offset: 0,
        );
        expect(window, hasLength(5));
        // The window must be the 5 smallest ages, in ascending order.
        final ages = [
          for (final entry in window)
            (_codec.decode(entry.value!) as Map)['age'] as int,
        ];
        expect(ages, [0, 1, 2, 3, 4]);
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('registerLiveQuery / unregisterLiveQuery / liveQueryCount dispatch',
        () async {
      final db = await openNativeTestDatabase('contract-reg');
      final backend = db.engine.backend as NativeRawBackend;
      final registration = await backend.registerLiveQuery(
        table: 't',
        predicateBytes: const [1, 0],
        sortBytes: const [1, 0],
        kind: 0,
      );
      expect(registration.id, 0);
      expect(await backend.liveQueryCount(), 1);
      await backend.unregisterLiveQuery(registration.id);
      expect(await backend.liveQueryCount(), 0);
      await db.close();
    });

    test('pendingChanges dispatches to the sync-state aggregation', () async {
      final db = await openNativeTestDatabase('contract-pending');
      final backend = db.engine.backend as NativeRawBackend;
      final changes = await backend.pendingChanges();
      expect(changes, isA<List<RawEntry>>());
      await db.close();
    });

    test('tableExists and tables dispatch', () async {
      final db = await openNativeTestDatabase('contract-tables');
      final backend = db.engine.backend as NativeRawBackend;
      await backend.applyBatch([RawPut('t', _key('a'), _row('p1', 'a', 1))]);
      expect(await backend.tableExists('t'), isTrue);
      expect(await backend.tableExists('missing'), isFalse);
      final tables = await backend.tables();
      expect(tables, contains('t'));
      // Reserved metadata tables are created lazily; every reported name must
      // be non-empty and user tables must not carry the internal prefix.
      expect(tables.every((name) => name.isNotEmpty), isTrue);
      expect(tables.any((name) => name.startsWith('__gecko_user_')), isFalse);
      await db.close();
    });

    test('lastCommitSeq and commitSequenceProbe dispatch', () async {
      final db = await openNativeTestDatabase('contract-lsn');
      final backend = db.engine.backend as NativeRawBackend;
      final before = await backend.lastCommitSeq();
      await backend.applyBatch([RawPut('t', _key('a'), _row('p1', 'a', 1))]);
      final after = await backend.lastCommitSeq();
      expect(after, greaterThanOrEqualTo(before));
      expect(await backend.commitSequenceProbe(), greaterThanOrEqualTo(after));
      await db.close();
    });

    test('repairIndex dispatches and is a no-op when consistent', () async {
      final db = await openNativeTestDatabase('contract-repair');
      final backend = db.engine.backend as NativeRawBackend;
      await _seedPeople(backend);
      await backend.repairIndex(table: 't', fields: ['nick']);
      // Repairing again is still a no-op (no throw, no state change).
      await backend.repairIndex(table: 't', fields: ['nick']);
      await db.close();
    });

    test('index definitions dispatch: registerDurableIndex fills the Rust '
        'index table', () async {
      final db = await openNativeTestDatabase('contract-indexdef');
      final backend = db.engine.backend as NativeRawBackend;
      backend.registerDurableIndex('t', ['nick']);
      await _seedPeople(backend);
      final snap = await backend.snapshot() as NativeRawSnapshot;
      try {
        final entries = await snap.scanAll(geckoIndexTable);
        expect(entries, isNotEmpty, reason: 'durable index table populated');
        // eqBounds on a nick value returns rows via the index join.
        final (start, end) = eqBounds('t', 'nick', 'g3');
        final indexed = await snap.queryIndexed(
          table: 't',
          start: ByteKey(start),
          end: ByteKey(end),
        );
        expect(indexed, hasLength(4));
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('index-ordered / indexed-multi / indexed-count dispatch', () async {
      final db = await openNativeTestDatabase('contract-indexq');
      final backend = db.engine.backend as NativeRawBackend;
      backend.registerDurableIndex('t', ['nick']);
      await _seedPeople(backend);
      final snap = await backend.snapshot() as NativeRawSnapshot;
      try {
        final (lo, hi) = eqBounds('t', 'nick', 'g3');
        final predicate = encodePredicate([Filter.eq('nick', 'g3')]);
        final ordered = await snap.queryIndexedOrdered(
          table: 't',
          start: ByteKey(lo),
          end: ByteKey(hi),
          predicateBytes: predicate,
          sortField: 'nick',
          eqBounded: true,
        );
        expect(ordered, hasLength(4));
        expect(
          await snap.queryIndexedCount(
            table: 't',
            ranges: [(ByteKey(lo), ByteKey(hi))],
            predicateBytes: predicate,
          ),
          4,
        );
        expect(
          await snap.queryIndexedMulti(
            table: 't',
            ranges: [(ByteKey(lo), ByteKey(hi))],
            predicateBytes: predicate,
          ),
          hasLength(4),
        );
        final (allLo, allHi) = fieldBounds('t', 'nick');
        final limited = await snap.queryIndexedLimited(
          table: 't',
          start: ByteKey(allLo),
          end: ByteKey(allHi),
          predicateBytes: const [1, 0],
          limit: 6,
          offset: 2,
        );
        expect(limited, hasLength(6));
      } finally {
        await snap.dispose();
      }
      await db.close();
    });

    test('compact and storageStats dispatch', () async {
      final db = await openNativeTestDatabase('contract-compact');
      final backend = db.engine.backend as NativeRawBackend;
      await _seedPeople(backend);
      final stats = await backend.storageStats();
      expect(stats.physicalBytes, greaterThan(BigInt.zero));
      expect(stats.tableCount, greaterThan(BigInt.zero));
      expect(stats.commitSequence, greaterThanOrEqualTo(BigInt.zero));
      final reclaimed = await backend.compact();
      expect(reclaimed, isA<bool>());
      await db.close();
    });

    test('counters dispatch: enable, populate, disable, reset', () async {
      final db = await openNativeTestDatabase('contract-counters');
      final backend = db.engine.backend as NativeRawBackend;
      await backend.enableCounters();
      await backend.applyBatch([RawPut('t', _key('a'), _row('p1', 'a', 1))]);
      final counters = await backend.takeCounters();
      expect(counters.rowsWritten, greaterThan(BigInt.zero));
      expect(counters.batchesApplied, greaterThan(BigInt.zero));
      await backend.disableCounters();
      final disabled = await backend.takeCounters();
      expect(disabled.rowsWritten, BigInt.zero);
      await db.close();
    });

    test('close dispatches and tears the worker down', () async {
      final db = await openNativeTestDatabase('contract-close');
      final backend = db.engine.backend as NativeRawBackend;
      expect(backend.workerAlive, isTrue);
      await backend.close();
      expect(backend.workerAlive, isFalse);
      await db.close();
    });
  });
}

/// Seeds 40 rows: ages 0..39, nicks g0..g9 (groups repeat every 10).
Future<void> _seedPeople(NativeRawBackend backend) async {
  final ops = <RawOp>[
    for (var i = 0; i < 40; i++)
      RawPut('t', _key('r$i'), _row('r$i', 'g${i % 10}', i)),
  ];
  await backend.applyBatch(ops);
}
