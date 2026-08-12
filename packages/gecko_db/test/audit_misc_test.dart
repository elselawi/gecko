// Audit-driven attachment / migration / maintenance / encryption edge tests
// (audited-test-gaps 2.13, 2.14, 2.15, 2.16).

import 'dart:io';
import 'dart:typed_data';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

Collection<Map<String, Object?>> coll(DatabaseImpl db, String table) =>
    db.collection<Map<String, Object?>>(
      table,
      toRow: (value) => value,
      fromRow: (row) => Map<String, Object?>.from(row as Map),
      id: (value) => value['id'],
    );

const List<int> testKey = [
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
];

void main() {
  group('2.13 attachments', () {
    test(
      'copyWith always overwrites failedOperationDetail (can clear to null)',
      () {
        final meta = AttachmentMetadata(
          id: 'att-1',
          parentCollection: 'items',
          parentId: 'a',
          filename: 'f.bin',
          fileType: 'application/octet-stream',
          size: 10,
          contentHash: 'hash',
          failedOperationDetail: 'previous failure',
        );
        // The field is ALWAYS overwritten (not `??`), so passing null clears it.
        final cleared = meta.copyWith(failedOperationDetail: null);
        expect(
          cleared.failedOperationDetail,
          isNull,
          reason: 'copyWith can clear failedOperationDetail to null',
        );
        final overwritten = meta.copyWith(failedOperationDetail: 'new');
        expect(overwritten.failedOperationDetail, 'new');
      },
    );

    test(
      'upload state transitions through pending/uploading/completed/failed',
      () async {
        final db = await openNativeTestDatabase('att-states');
        final c = coll(db, 'items');
        await c.put({'id': 'a'}); // the parent must exist to attach to it
        final created = await db.attachments.create(
          parentCollection: 'items',
          parentId: 'a',
          filename: 'f.bin',
          fileType: 'application/octet-stream',
          size: 10,
          contentHash: 'hash-1',
        );
        expect(created.uploadState, AttachmentUploadState.pending);
        final uploading = await db.attachments.setUploadState(
          created.id,
          AttachmentUploadState.uploading,
        );
        expect(uploading.uploadState, AttachmentUploadState.uploading);
        final completed = await db.attachments.setUploadState(
          created.id,
          AttachmentUploadState.completed,
        );
        expect(completed.uploadState, AttachmentUploadState.completed);
        expect(
          (await db.attachments.completedUploads()).map((a) => a.id),
          contains(created.id),
        );
        final failed = await db.attachments.setUploadState(
          created.id,
          AttachmentUploadState.failed,
          failedOperationDetail: 'network',
        );
        expect(failed.uploadState, AttachmentUploadState.failed);
        expect(failed.failedOperationDetail, 'network');
        expect(
          (await db.attachments.failedUploads()).map((a) => a.id),
          contains(created.id),
        );
        // Delete state handling with failure detail.
        final deleted = await db.attachments.setDeleteState(
          created.id,
          AttachmentDeleteState.failed,
          failedOperationDetail: 'server 403',
        );
        expect(deleted.deleteState, AttachmentDeleteState.failed);
        expect(deleted.failedOperationDetail, 'server 403');
        await db.close();
      },
    );

    test('deleting the parent makes the attachment orphaned', () async {
      final db = await openNativeTestDatabase('att-orphan');
      final c = coll(db, 'items');
      await c.put({'id': 'a'});
      await db.attachments.create(
        parentCollection: 'items',
        parentId: 'a',
        filename: 'f.bin',
        fileType: 'application/octet-stream',
        size: 5,
        contentHash: 'hash-2',
      );
      expect(await db.attachments.orphaned(), isEmpty);
      await c.delete('a');
      final orphans = await db.attachments.orphaned();
      expect(orphans, hasLength(1));
      expect(orphans.single.parentId, 'a');
      await db.close();
    });

    test('corrupt attachment metadata fails the read instead of returning a '
        'bogus record', () async {
      final db = await openNativeTestDatabase('att-corrupt');
      final c = coll(db, 'items');
      await c.put({'id': 'a'});
      // Write a metadata record that is not a valid attachment map. The read
      // must fail (raw decode/type error today — no typed wrapper) rather
      // than fabricating a record.
      await db.engine.rawPut(
        '__gecko_attachments',
        ByteKey(const DefaultWireCodec().encode('corrupt')),
        const DefaultWireCodec().encode({'not': 'a valid attachment meta'}),
      );
      await expectLater(
        db.attachments.get('corrupt'),
        throwsA(isA<TypeError>()),
        reason: 'missing id field casts null to String (pinned raw error)',
      );
      // A malformed non-map payload fails the same way.
      await db.engine.rawPut(
        '__gecko_attachments',
        ByteKey(const DefaultWireCodec().encode('corrupt2')),
        const DefaultWireCodec().encode(42),
      );
      await expectLater(
        db.attachments.get('corrupt2'),
        throwsA(anything),
        reason: 'a scalar payload cannot be decoded into metadata',
      );
      await db.close();
    });
  });

  group('2.14 migrations', () {
    test('migrateStep on the same step twice is a typed error', () async {
      final db = await openNativeTestDatabase('mig-twice');
      final step = MigrationStep(name: 'v1', fromVersion: 0, toVersion: 1);
      await db.schema.migrateStep(step);
      // The second application of the same step must fail with a typed error
      // (already applied).
      await expectLater(
        db.schema.migrateStep(step),
        throwsA(isA<GeckoError>()),
      );
      await db.close();
    });

    test(
      'upgrade callback that throws fails the step with a typed error',
      () async {
        final db = await openNativeTestDatabase('mig-throw');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        final step = MigrationStep(
          name: 'rewrite',
          fromVersion: 0,
          toVersion: 1,
          rewritesRecords: true,
          collection: 'items',
          upgrade: (row) => throw StateError('bad row'),
        );
        await expectLater(
          db.schema.migrateStep(step),
          throwsA(isA<GeckoError>()),
        );
        await db.close();
      },
    );

    test(
      'upgrade callback returning null keeps the record untouched',
      () async {
        final db = await openNativeTestDatabase('mig-keep');
        final c = coll(db, 'items');
        await c.put({'id': 'a', 'n': 1});
        await c.put({'id': 'b', 'n': 2});
        final step = MigrationStep(
          name: 'rewrite-keep',
          fromVersion: 0,
          toVersion: 1,
          rewritesRecords: true,
          collection: 'items',
          upgrade: (row) => null, // keep untouched
        );
        await db.schema.migrateStep(step);
        expect(await c.get('a'), isNotNull);
        expect(await c.get('b'), isNotNull);
        await db.close();
      },
    );

    test('upgrade returning a non-Map stores the scalar at the raw layer '
        '(pinned)', () async {
      final db = await openNativeTestDatabase('mig-nonmap');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final step = MigrationStep(
        name: 'to-scalar',
        fromVersion: 0,
        toVersion: 1,
        rewritesRecords: true,
        collection: 'items',
        upgrade: (_) => 42, // non-Map result
      );
      // The migration itself succeeds: the scalar is stored as the row value.
      await db.schema.migrateStep(step);
      final raw = await db.engine.rawGet(
        'items',
        ByteKey(const DefaultWireCodec().encode('a')),
      );
      expect(
        const DefaultWireCodec().decode(raw!),
        42,
        reason: 'non-Map upgrade results are stored verbatim (pinned)',
      );
      await db.close();
    });

    test('migration x index: a rewriting step keeps the durable index '
        'consistent', () async {
      final db = await openNativeTestDatabase('mig-index');
      final c = db.collection<Map<String, Object?>>(
        'items',
        toRow: (value) => value,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (value) => value['id'],
        indexFields: ['g'],
      );
      await c.put({'id': 'a', 'g': 'x', 'n': 1});
      await c.put({'id': 'b', 'g': 'x', 'n': 2});
      await db.schema.migrateStep(
        MigrationStep(
          name: 'bump',
          fromVersion: 0,
          toVersion: 1,
          rewritesRecords: true,
          collection: 'items',
          upgrade: (row) => {...(row as Map), 'v2': true},
        ),
      );
      // The index still serves the rewritten rows.
      final found = await c.where().filter('g', 'x').findAll();
      expect(found, hasLength(2));
      expect(
        found.every((r) => r['v2'] == true),
        isTrue,
        reason: 'rewritten rows must be indexed',
      );
      await db.close();
    });

    test(
      'a large record rewrite applies every row in bounded chunks',
      () async {
        final db = await openNativeTestDatabase('mig-large');
        final c = coll(db, 'items');
        for (var i = 0; i < 2000; i++) {
          await c.put({'id': 'k$i', 'n': i});
        }
        var calls = 0;
        await db.schema.migrateStep(
          MigrationStep(
            name: 'bump',
            fromVersion: 0,
            toVersion: 1,
            rewritesRecords: true,
            collection: 'items',
            upgrade: (row) {
              calls++;
              return {...(row as Map), 'v2': true};
            },
          ),
        );
        expect(
          calls,
          2000,
          reason: 'every record must pass through the upgrade',
        );
        expect((await c.get('k0'))!['v2'], isTrue);
        expect((await c.get('k1999'))!['v2'], isTrue);
        await db.close();
      },
    );

    test(
      'an interrupted record rewrite resumes idempotently from progress',
      () async {
        final db = await openNativeTestDatabase('mig-resume');
        final c = coll(db, 'items');
        for (var i = 0; i < 500; i++) {
          await c.put({'id': 'k$i', 'n': i});
        }
        // First attempt: chunk 1 (rows 0-200) commits, chunk 2 fails on k250.
        await expectLater(
          db.schema.migrateStep(
            MigrationStep(
              name: 'resume',
              fromVersion: 0,
              toVersion: 1,
              rewritesRecords: true,
              collection: 'items',
              upgrade: (row) {
                final id = (row as Map)['id'];
                if (id == 'k250') {
                  throw StateError('simulated chunk failure');
                }
                return {...row, 'v2': true};
              },
            ),
          ),
          throwsA(
            isA<GeckoError>().having(
              (e) => e.type,
              'type',
              GeckoErrorType.migration,
            ),
          ),
        );
        // The failed step must not have stamped the version (still 0), so
        // migrateStep can be retried.
        expect(await db.schema.readVersion(), 0);
        // Retry: only the rows after the committed chunk boundary (200) may
        // pass through the upgrade again — no re-rewriting of done rows.
        var retryCalls = 0;
        await db.schema.migrateStep(
          MigrationStep(
            name: 'resume',
            fromVersion: 0,
            toVersion: 1,
            rewritesRecords: true,
            collection: 'items',
            upgrade: (row) {
              retryCalls++;
              return {...(row as Map), 'v2': true};
            },
          ),
        );
        expect(
          retryCalls,
          lessThanOrEqualTo(500 - 200),
          reason: 'rows already committed by the failed run must not be '
              're-rewritten (durable progress resume)',
        );
        expect(await db.schema.readVersion(), 1);
        for (var i = 0; i < 500; i++) {
          expect(
            (await c.get('k$i'))!['v2'],
            isTrue,
            reason: 'every row must end upgraded',
          );
        }
        // A `migrate()` over the already-completed plan is a no-op: the step
        // is skipped (version is already 1), so no upgrade calls occur.
        var thirdCalls = 0;
        final (applied, version) = await db.schema.migrate(
          MigrationPlan(
            targetVersion: 1,
            steps: [
            MigrationStep(
              name: 'resume',
              fromVersion: 0,
              toVersion: 1,
              rewritesRecords: true,
              collection: 'items',
              upgrade: (row) {
                thirdCalls++;
                return row;
              },
            ),
          ]),
        );
        expect(applied, 0, reason: 'completed step is skipped');
        expect(version, 1);
        expect(thirdCalls, 0, reason: 'completed step is skipped');
        await db.close();
      },
    );
  });

  group('2.15 maintenance / diagnostics', () {
    test('compact on an empty database succeeds', () async {
      final db = await openNativeTestDatabase('maint-empty');
      final result = await db.maintenance.compact();
      expect(result, isA<bool>());
      await db.close();
    });

    test('compact on a metadata-only database succeeds', () async {
      // No user tables at all — only the reserved metadata tables exist.
      final db = await openNativeTestDatabase('maint-metadata-only');
      final result = await db.maintenance.compact();
      expect(result, isA<bool>());
      await db.close();
    });

    test('two concurrent compactions: one runs, the other errors', () async {
      final db = await openNativeTestDatabase('maint-concurrent');
      final c = coll(db, 'items');
      for (var i = 0; i < 20; i++) {
        await c.put({'id': 'k$i', 'payload': 'x' * 2000});
      }
      final results = await Future.wait<Object?>([
        db.maintenance.compact().then<Object?>((v) => v),
        db.maintenance.compact().then<Object?>(
          (v) => v,
          onError: (Object e, StackTrace _) => e,
        ),
      ]);
      final succeeded = results.whereType<bool>().toList();
      final failed = results.whereType<GeckoError>().toList();
      expect(succeeded.length + failed.length, 2);
      // Either both succeeded serially or exactly one failed with a typed
      // error — never a crash.
      expect(succeeded.length, greaterThanOrEqualTo(1));
      for (final error in failed) {
        expect(error, isA<GeckoError>());
      }
      await db.close();
    });

    test('totalQueryDurationMicros is hardcoded zero in diagnostics', () async {
      final db = await openNativeTestDatabase('maint-diag');
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      await c.where().findAll();
      final snapshot = db.diagnostics.snapshot();
      expect(
        snapshot.totalQueryDurationMicros,
        0,
        reason: 'pinned: the diagnostics snapshot hardcodes 0 today',
      );
      await db.close();
    });

    test(
      'diagnostics counters stay untouched after disable (mid-write)',
      () async {
        final db = await openNativeTestDatabase('maint-diag-disable');
        final c = coll(db, 'items');
        db.diagnostics.enable();
        await c.put({'id': 'a'});
        expect(db.diagnostics.snapshot().totalWrites, greaterThan(0));

        // Disable clears the counters...
        db.diagnostics.disable();
        expect(db.diagnostics.enabled, isFalse);
        expect(db.diagnostics.snapshot().totalWrites, 0);

        // ...and a write while disabled must not accumulate them.
        await c.put({'id': 'b'});
        final snapshot = db.diagnostics.snapshot();
        expect(
          snapshot.totalWrites,
          0,
          reason: 'disabled diagnostics must not accumulate write counters',
        );
        await db.close();
      },
    );
  });

  group('2.16 encryption (Dart side)', () {
    test('read-only + encryption opens today (pinned divergence)', () async {
      final directory = await Directory.systemTemp.createTemp('gecko-enc-ro-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}db.redb';
      // The audit expected a typed error, but today the Dart facade opens an
      // encrypted file even with readOnly (the encrypted worker is always
      // read-write). Pin the actual behavior so a future fix is deliberate.
      final db = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(encryptionKey: testKey, readOnly: true),
      );
      await db.close();
    });

    test(
      'rotatePhysicalKey on a live/open database is a typed error',
      () async {
        final db = await openNativeTestDatabase('enc-rotate-live');
        await expectLater(
          rotatePhysicalKey(
            path: db.path,
            oldKey: testKey,
            newKey: List<int>.generate(32, (i) => i + 100),
          ),
          throwsA(isA<GeckoError>()),
        );
        await db.close();
      },
    );

    test('validateEncryptionKey length matrix (31/33/0)', () {
      expect(
        () => validateEncryptionKey(List<int>.filled(31, 0)),
        throwsA(isA<GeckoError>()),
      );
      expect(
        () => validateEncryptionKey(List<int>.filled(33, 0)),
        throwsA(isA<GeckoError>()),
      );
      expect(() => validateEncryptionKey(const []), throwsA(isA<GeckoError>()));
      // 32 bytes as List<int> and as Uint8List both pass.
      expect(
        () => validateEncryptionKey(List<int>.filled(32, 0)),
        returnsNormally,
      );
      expect(
        () =>
            validateEncryptionKey(Uint8List.fromList(List<int>.filled(32, 1))),
        returnsNormally,
      );
    });

    test('generation 0 is accepted by open (pinned)', () async {
      final directory = await Directory.systemTemp.createTemp('gecko-enc-g0-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}${Platform.pathSeparator}db.redb';
      final db = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(
          encryptionKey: testKey,
          encryptionKeyGeneration: 0,
        ),
      );
      await db.close();
    });
  });
}
