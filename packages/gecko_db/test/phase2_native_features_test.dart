// Native feature sweep (Workstream 2 / coverage qualification).
//
// Runs higher-level feature paths — transaction scans, sync deletions and
// remote application, conflict resolution kinds, attachments, schema
// stamping, diagnostics, and read-only guards — against the *native* file
// backend. This both proves the features work on the production storage path
// and deterministically exercises branches the phase suites only hit on the
// native backend.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

Collection<Map<String, Object?>> _collection(DatabaseImpl db, String name) =>
    db.collection<Map<String, Object?>>(
      name,
      toRow: (m) => m,
      fromRow: (m) => Map<String, Object?>.from(m as Map),
      id: (m) => m['id'],
    );

void main() {
  final nativePath = _nativeLibraryPath(_repoRoot());
  late Directory tempDir;
  late String path;
  late DatabaseImpl db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-sweep-');
    path = '${tempDir.path}${Platform.pathSeparator}db.redb';
    db = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  test(
    'transaction scans, staged overlay, and in-txn index definitions',
    () async {
      await db.writeTxn((txn) async {
        final c = txn.collection<Map<String, Object?>>(
          'txn',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
          indexFields: ['group'],
        );
        await c.put({'id': 'a', 'group': 'g1'});
        await c.put({'id': 'b', 'group': 'g2'});
        // getAll inside the transaction goes through the staged-overlay scan.
        final all = await c.getAll();
        expect(all.map((r) => r['id']).toList()..sort(), ['a', 'b']);
        // Overlay delete hides a staged row from the scan.
        await c.delete('a');
        final after = await c.getAll();
        expect(after.map((r) => r['id']).toList(), ['b']);
      });
      // Committed state reflects the overlay's final view.
      final committed = await _collection(db, 'txn').getAll();
      expect(committed.map((r) => r['id']).toList(), ['b']);
    },
  );

  test(
    'remote application, remote deletion, and dedupe on the native file',
    () async {
      final items = _collection(db, 'sync');
      await items.put({'id': 's1', 'v': 1});
      await db.sync.markSynced(['s1']);

      // Applying a remote record with an idempotency key registers the dedupe.
      final applied = await db.sync.applyRemoteTransactional([
        ChangeRecord(
          localMutationId: 42,
          recordId: 'remote',
          timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
          collection: 'sync',
          kind: ChangeKind.put,
          value: {'id': 'remote', 'v': 9},
          origin: ChangeOrigin.remoteSync,
          idempotencyKey: 'k-remote',
        ),
      ]);
      expect(applied, ['remote']);
      expect(await db.sync.isDuplicate('k-remote'), isTrue);
      expect((await items.get('remote'))!['v'], 9);

      // Remote deletion removes the record and its sync state.
      await db.sync.applyRemoteDeletion(const [RecordRef('sync', 'remote')]);
      expect(await items.get('remote'), isNull);
      // Deleting by raw id resolves the collection from sync state.
      await db.sync.applyRemoteDeletion(['s1']);
      expect(await items.get('s1'), isNull);
    },
  );

  test(
    'conflict resolution kinds and deferred review on the native file',
    () async {
      final items = _collection(db, 'conflict');
      await items.put({'id': 'one', 'value': 'local'});

      // Default strategy (last-write-wins) resolves with useRemote.
      final resolved = await db.conflicts.resolve(
        ConflictRequest(
          record: const RecordRef('conflict', 'one'),
          remote: const ConflictVersion(
            value: {'id': 'one', 'value': 'remote'},
          ),
        ),
      );
      expect(resolved.resolution.kind, ResolutionKind.useRemote);
      expect((await items.get('one'))!['value'], 'remote');

      // Deferred manual review preserves both versions.
      await items.put({'id': 'two', 'value': 'local'});
      final deferred = await db.conflicts.resolve(
        ConflictRequest(
          record: const RecordRef('conflict', 'two'),
          remote: const ConflictVersion(
            value: {'id': 'two', 'value': 'remote'},
            sequence: 7,
          ),
        ),
        strategy: ConflictStrategy.manualReview,
      );
      final pending = deferred.preservedConflict!;
      final preserved = await db.conflicts.read(pending.conflictId);
      expect(preserved!.remote.value, {'id': 'two', 'value': 'remote'});

      // Resolve the preserved conflict with a merged value.
      await db.conflicts.resolvePreserved(
        pending.conflictId,
        Resolution.mergedValue({'id': 'two', 'value': 'merged'}),
      );
      expect((await items.get('two'))!['value'], 'merged');
      expect(await db.conflicts.read(pending.conflictId), isNull);

      // Resolving an already-resolved conflict is a typed error.
      await expectLater(
        db.conflicts.resolvePreserved(
          pending.conflictId,
          const Resolution.delete(),
        ),
        throwsA(isA<GeckoError>()),
      );
    },
  );

  test('attachments: lifecycle, filters, and typed failure paths', () async {
    final parents = _collection(db, 'parents');
    await parents.put({'id': 'a'});
    final meta = await db.attachments.create(
      parentCollection: 'parents',
      parentId: 'a',
      filename: 'f.bin',
      fileType: 'bin',
      size: 10,
      contentHash: 'h1',
    );
    expect(await db.attachments.get(meta.id), isNotNull);

    // Upload state transitions.
    await db.attachments.setUploadState(
      meta.id,
      AttachmentUploadState.uploading,
    );
    await db.attachments.setUploadState(
      meta.id,
      AttachmentUploadState.failed,
      failedOperationDetail: 'network',
    );
    expect((await db.attachments.get(meta.id))!.retryCount, 1);
    await db.attachments.setUploadState(
      meta.id,
      AttachmentUploadState.completed,
    );

    // Query filters: parent + upload state.
    final filtered = await db.attachments.query(
      const AttachmentQuery(
        parentCollection: 'parents',
        parentId: 'a',
        uploadState: AttachmentUploadState.completed,
      ),
    );
    expect(filtered.single.id, meta.id);

    // Delete-state transition and filter.
    await db.attachments.setDeleteState(meta.id, AttachmentDeleteState.pending);
    final deleting = await db.attachments.query(
      const AttachmentQuery(deleteState: AttachmentDeleteState.pending),
    );
    expect(deleting.single.id, meta.id);

    // Deleting an unknown attachment is a no-op (delete is idempotent), but a
    // state transition on one is a typed error, as is creating under a
    // missing parent.
    await db.attachments.delete('nope');
    await expectLater(
      db.attachments.setUploadState('nope', AttachmentUploadState.uploading),
      throwsA(isA<GeckoError>()),
    );
    await expectLater(
      db.attachments.create(
        parentCollection: 'parents',
        parentId: 'missing-parent',
        filename: 'x',
        fileType: 'x',
        size: 1,
        contentHash: 'h2',
      ),
      throwsA(isA<GeckoError>()),
    );
  });

  test(
    'schema stamping and diagnostics lifecycle on the native file',
    () async {
      expect(await db.schema.readVersion(), 0);
      await db.schema.stamp(2);
      expect(await db.schema.readVersion(), 2);

      db.diagnostics.enable();
      await _collection(db, 'diag').put({'id': 'x'});
      final snapshot = db.diagnostics.snapshot();
      expect(snapshot.totalWrites, greaterThan(0));
      db.diagnostics.reset();
      expect(db.diagnostics.snapshot().totalWrites, 0);
      db.diagnostics.disable();
      expect(db.diagnostics.enabled, isFalse);
    },
  );

  test('raw engine diagnostics count writes and write failures', () async {
    final engine = RawEngine(_ThrowingBatchBackend());
    engine.setDiagnosticsEnabled(true);
    await expectLater(
      engine.rawPut('t', ByteKey([1]), [1]),
      throwsA(isA<GeckoError>()),
    );
    await expectLater(
      engine.rawDelete('t', ByteKey([1])),
      throwsA(isA<GeckoError>()),
    );
    await expectLater(engine.rawClear('t'), throwsA(isA<GeckoError>()));
    expect(engine.totalWrites, greaterThanOrEqualTo(3));
    expect(engine.failedWrites, 3);
    engine.resetDiagnosticsCounters();
    expect(engine.totalWrites, 0);
    expect(engine.failedWrites, 0);
  });
}

/// A backend whose writes always fail, to exercise the engine's write-failure
/// accounting paths deterministically.
class _ThrowingBatchBackend implements RawBackend {
  @override
  bool get isReadOnly => false;

  @override
  Future<Set<(String, ByteKey)>> applyBatch(RawBatch ops) async {
    throw const GeckoError(GeckoErrorType.invalidOperation, 'boom');
  }

  @override
  Future<RawSnapshot> snapshot() async {
    throw UnimplementedError();
  }

  @override
  Future<bool> tableExists(String table) async {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> tables() async {
    throw UnimplementedError();
  }

  @override
  Future<int> lastCommitSeq() async {
    throw UnimplementedError();
  }

  @override
  Future<void> close() async {}
}
