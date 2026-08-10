import 'dart:async';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

Future<DatabaseImpl> _open(String name) => openNativeTestDatabase('phase8b-$name');

void main() {
  setUp(ConflictStrategy.restoreDefaults);

  group('Phase 8 concurrent resolution & commit-boundary', () {
    test(
      'two racing resolves of the same record leave one committed and one aborted',
      () async {
        final db = await _open('race');
        final items = db.collection<Map<String, Object?>>(
          'items',
          toRow: (row) => row,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (row) => row['id'],
        );
        await items.put({'id': 'one', 'value': 'local'});
        final request = ConflictRequest(
          record: const RecordRef('items', 'one'),
          remote: const ConflictVersion(
            value: {'id': 'one', 'value': 'remote'},
          ),
        );
        final outcomes = await Future.wait<Object?>([
          db.conflicts
              .resolve(request, strategy: ConflictStrategy.manualReview)
              .then<Object?>((r) => r),
          db.conflicts
              .resolve(request, strategy: ConflictStrategy.manualReview)
              .then<Object?>((r) => r)
              .catchError((Object e) {
                if (e is GeckoError) return e;
                throw e;
              }),
        ]);
        final committed = outcomes
            .whereType<ConflictResolutionResult>()
            .toList();
        final aborted = outcomes.whereType<GeckoError>().toList();
        expect(
          committed,
          hasLength(1),
          reason: 'exactly one resolution proceeds',
        );
        expect(
          aborted,
          hasLength(1),
          reason: 'the other aborts deterministically',
        );
        expect(aborted.single.type, GeckoErrorType.transactionAborted);
        // Exactly one preserved conflict exists.
        expect(await db.conflicts.readPending(), hasLength(1));
        await db.close();
      },
    );

    test(
      'a crash between compute and commit leaves the conflict unresolved',
      () async {
        final db = await _open('crash-boundary');
        final items = db.collection<Map<String, Object?>>(
          'items',
          toRow: (row) => row,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (row) => row['id'],
        );
        await items.put({'id': 'one', 'value': 'local'});
        // Defer to manual so the resolution is "computed" but not committed.
        final deferred = await db.conflicts.resolve(
          ConflictRequest(
            record: const RecordRef('items', 'one'),
            remote: const ConflictVersion(
              value: {'id': 'one', 'value': 'remote'},
            ),
          ),
          strategy: ConflictStrategy.manualReview,
        );
        expect(deferred.deferred, isTrue);
        // The conflict exists unresolved with both versions intact.
        final pending = await db.conflicts.readPending();
        expect(pending, hasLength(1));
        expect(pending.single.isResolved, isFalse);
        expect(pending.single.local.value, {'id': 'one', 'value': 'local'});
        expect(pending.single.remote.value, {'id': 'one', 'value': 'remote'});
        // Applying a manual resolution later clears it atomically.
        await db.conflicts.resolvePreserved(
          pending.single.conflictId,
          const Resolution.useRemote(),
        );
        expect((await items.get('one'))!['value'], 'remote');
        expect(await db.conflicts.readPending(), isEmpty);
        await db.close();
      },
    );

    test(
      'resolving an already-resolved preserved conflict fails with a typed error',
      () async {
        final db = await _open('double-resolve');
        final items = db.collection<Map<String, Object?>>(
          'items',
          toRow: (row) => row,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (row) => row['id'],
        );
        await items.put({'id': 'one', 'value': 'local'});
        await db.conflicts.resolve(
          ConflictRequest(
            record: const RecordRef('items', 'one'),
            remote: const ConflictVersion(
              value: {'id': 'one', 'value': 'remote'},
            ),
          ),
          strategy: ConflictStrategy.manualReview,
        );
        final pending = (await db.conflicts.readPending()).single;
        await db.conflicts.resolvePreserved(
          pending.conflictId,
          const Resolution.useRemote(),
        );
        // Second resolution of the same (now-deleted) conflict: typed error.
        await expectLater(
          db.conflicts.resolvePreserved(
            pending.conflictId,
            const Resolution.useRemote(),
          ),
          throwsA(
            isA<GeckoError>().having(
              (e) => e.type,
              'type',
              GeckoErrorType.conflict,
            ),
          ),
        );
        await db.close();
      },
    );
  });
}
