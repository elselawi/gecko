// Index preparation coalescing (perf plan Item 4, Stage A): many concurrent
// `collection()` declarations for one table must share a single Rust repair
// (never queue several full repairs), a failed repair must leave the index in
// the failed state (queries fall back to the full-scan path, never a
// potentially incomplete durable index), and a later declaration may retry.
import 'dart:async';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/query/query_impl.dart'
    show CollectionIndex, CollectionIndexState;
import 'package:test/test.dart';

import 'support/native_database.dart';

/// The freshly-built release native artifact. The public `DatabaseImpl.open`
/// without an explicit [DatabaseConfig.nativeLibraryPath] resolves a bundled
/// artifact which may lag the freshly-built engine (and its WorkCounters wire
/// format), so tests that exercise counters must pin the release library.
String _nativeLibraryPath() {
  final root = Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )
      ? Directory.current.parent.parent.path
      : Directory.current.path;
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

void main() {
  group('CollectionIndex.prepare coalescing (unit)', () {
    test('concurrent same-fingerprint preparations run the work once', () async {
      final index = CollectionIndex(fields: const ['a']);
      var workRuns = 0;
      final futures = <Future<void>>[
        for (var i = 0; i < 100; i++)
          index.prepare(
            fingerprint: 'f:a',
            work: () async {
              workRuns++;
              await Future<void>.delayed(const Duration(milliseconds: 5));
            },
          ),
      ];
      await Future.wait(futures);
      expect(workRuns, 1, reason: 'one repair, never N');
      expect(index.state, CollectionIndexState.ready);
      expect(index.isReady, isTrue);
    });

    test('a failed preparation completes waiters and allows a later retry',
        () async {
      final index = CollectionIndex(fields: const ['a']);
      var workRuns = 0;
      final failing = index.prepare(
        fingerprint: 'f:a',
        work: () async {
          workRuns++;
          throw StateError('repair failed');
        },
      );
      // The shared future never throws: failure is observable via state.
      await failing;
      expect(index.state, CollectionIndexState.failed);
      expect(index.isReady, isFalse);
      expect(index.lastError, isA<StateError>());

      // A later declaration retries and succeeds.
      await index.prepare(
        fingerprint: 'f:a',
        work: () async {
          workRuns++;
        },
      );
      expect(workRuns, 2);
      expect(index.state, CollectionIndexState.ready);
      expect(index.isReady, isTrue);
    });

    test('a different fingerprint replaces the plan and re-runs the work',
        () async {
      final index = CollectionIndex(fields: const ['a']);
      var workRuns = 0;
      await index.prepare(
        fingerprint: 'f:a',
        work: () async {
          workRuns++;
        },
      );
      expect(index.state, CollectionIndexState.ready);
      // Incompatible declaration: never silently treated as equivalent.
      index.replaceFields(const ['a', 'b'], const []);
      await index.prepare(
        fingerprint: 'f:a\u0001b',
        work: () async {
          workRuns++;
        },
      );
      expect(workRuns, 2, reason: 'changed definition re-prepares');
      expect(index.state, CollectionIndexState.ready);
      expect(index.fields, ['a', 'b']);
    });
  });

  group('Index preparation end-to-end (native)', () {
    test(
      'many concurrent collection handles for one table trigger one repair',
      () async {
        final db = await openNativeTestDatabase('idx-prep-coalesce');
        addTearDown(db.close);
        final backend = db.engine.backend as NativeRawBackend;

        // Seed 100k rows before declaring any index.
        const chunk = 5000;
        for (var start = 0; start < 100000; start += chunk) {
          final end = (start + chunk > 100000) ? 100000 : start + chunk;
          await db.bulkWrite([
            for (var i = start; i < end; i++)
              BulkMutation.put(
                table: 'items',
                key: 'r$i',
                value: {'id': 'r$i', 'g': 'g${i % 100}'},
              ),
          ]);
        }
        await backend.enableCounters();
        await backend.takeCounters(); // drain seeding counters

        // Declare the same indexed collection many times concurrently.
        final handles = <Collection<Map<String, Object?>>>[];
        for (var i = 0; i < 50; i++) {
          handles.add(
            db.collection<Map<String, Object?>>(
              'items',
              toRow: (m) => m,
              fromRow: (m) => Map<String, Object?>.from(m as Map),
              id: (m) => m['id'],
              indexFields: const ['g'],
            ),
          );
        }
        // Let the coalesced repair settle.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final counters = await backend.takeCounters();
        expect(counters.indexRepairs, BigInt.one,
            reason: '50 concurrent declarations must trigger exactly one repair');
        expect(counters.indexMaintenanceOps, BigInt.zero);

        // The shared index serves every handle with correct results.
        final results = await Future.wait([
          for (final h in handles) h.where({'g': 'g1'}).findAll(),
        ]);
        for (final rows in results) {
          expect(rows, hasLength(1000));
        }
      },
    );

    test(
      'a failed repair (read-only) leaves the index unusable and queries fall back to the full scan',
      () async {
        final root = await Directory.systemTemp.createTemp('idx-prep-ro-');
        addTearDown(() => root.delete(recursive: true));
        final path = '${root.path}${Platform.pathSeparator}db.redb';

        // Seed + index in a writable database, then reopen read-only.
        final first = await DatabaseImpl.open(
          path,
          config: DatabaseConfig(nativeLibraryPath: _nativeLibraryPath()),
        );
        final col = first.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['g'],
        );
        await col.put({'id': 'a', 'g': 'g1'});
        await col.put({'id': 'b', 'g': 'g1'});
        await col.put({'id': 'c', 'g': 'g2'});
        await first.close();

        final ro = await DatabaseImpl.open(
          path,
          config: DatabaseConfig(
            readOnly: true,
            nativeLibraryPath: _nativeLibraryPath(),
          ),
        );
        addTearDown(ro.close);
        final roCol = ro.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['g'],
        );
        // The repair cannot run on a read-only worker (the worker rejects it),
        // so the index must stay failed/preparing and queries must fall back
        // to the pushed-predicate full scan — never the incomplete durable
        // index.
        final q = roCol.where({'g': 'g1'}) as QueryImpl<Map<String, Object?>>;
        final rows = await q.findAll();
        expect(q.lastPlan, IndexPlan.nativeFilteredScan,
            reason: 'failed index must not route through the durable index');
        expect(rows.map((r) => r['id']).toSet(), {'a', 'b'});
      },
    );

    test(
      'reopening a consistent indexed database skips the full repair',
      () async {
        final root = await Directory.systemTemp.createTemp('idx-prep-reopen-');
        addTearDown(() => root.delete(recursive: true));
        final path = '${root.path}${Platform.pathSeparator}db.redb';
        final nativeLibraryPath = _nativeLibraryPath();

        final first = await DatabaseImpl.open(
          path,
          config: DatabaseConfig(nativeLibraryPath: nativeLibraryPath),
        );
        final firstBackend = first.engine.backend as NativeRawBackend;
        await firstBackend.enableCounters();
        await firstBackend.takeCounters();
        first.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['g'],
        );
        // Let the initial repair settle, then seed rows (the write path keeps
        // the durable index atomic with the primary rows).
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await first.bulkWrite([
          for (var i = 0; i < 1000; i++)
            BulkMutation.put(
              table: 'items',
              key: 'r$i',
              value: {'id': 'r$i', 'g': 'g${i % 10}'},
            ),
        ]);
        // Drain the session-1 counters (which include the one-time repair).
        await firstBackend.takeCounters();
        await first.close();

        // Reopen: the persisted manifest matches the declaration, so the
        // repair must be skipped entirely — no full rebuild.
        final second = await DatabaseImpl.open(
          path,
          config: DatabaseConfig(nativeLibraryPath: nativeLibraryPath),
        );
        addTearDown(second.close);
        final secondBackend = second.engine.backend as NativeRawBackend;
        await secondBackend.enableCounters();
        final col2 = second.collection<Map<String, Object?>>(
          'items',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: const ['g'],
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Correctness: the skipped-but-valid durable index still serves
        // queries.
        final q = col2.where({'g': 'g1'}) as QueryImpl<Map<String, Object?>>;
        final rows = await q.findAll();
        expect(rows, hasLength(100));
        expect(q.lastPlan, IndexPlan.secondaryIndex,
            reason: 'the skipped durable index still serves queries');
        final counters = await secondBackend.takeCounters();
        expect(counters.indexRepairs, BigInt.zero,
            reason: 'a matching manifest skips the full rebuild on reopen');
      },
    );
  });
}
