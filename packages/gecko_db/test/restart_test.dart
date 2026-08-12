import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

/// A backend that fails a batch exactly once to simulate a crash/abort at the
/// commit boundary — nothing before or after the failed batch is applied.
class _FailingBackend implements RawBackend {
  _FailingBackend(this._inner);
  final RawBackend _inner;

  @override
  Future<ApplyBatchResult> applyBatch(RawBatch ops) async {
    final hasPut = ops.any(
      (op) => op is RawPut && op.table != '__gecko_sync_meta',
    );
    if (hasPut && !_failedOnce) {
      _failedOnce = true;
      throw const GeckoError(
        GeckoErrorType.transactionAborted,
        'simulated crash at commit boundary',
      );
    }
    return _inner.applyBatch(ops);
  }

  @override
  Future<void> registerCompositeIndexes(
    String table,
    List<List<String>> indexes,
  ) =>
      _inner.registerCompositeIndexes(table, indexes);

  bool _failedOnce = false;

  @override
  Future<LiveQueryRegistration> registerLiveQuery({
    required String table,
    required List<int> predicateBytes,
    required List<int> sortBytes,
    required int kind,
    int? limit,
    int offset = 0,
  }) =>
      _inner.registerLiveQuery(
        table: table,
        predicateBytes: predicateBytes,
        sortBytes: sortBytes,
        kind: kind,
        limit: limit,
        offset: offset,
      );

  @override
  Future<void> unregisterLiveQuery(int id) => _inner.unregisterLiveQuery(id);
  @override
  Future<int> liveQueryCount() => _inner.liveQueryCount();
  @override
  Future<List<RawEntry>> pendingChanges() => _inner.pendingChanges();

  @override
  bool get isReadOnly => _inner.isReadOnly;

  @override
  Future<RawSnapshot> snapshot() => _inner.snapshot();
  @override
  Future<List<RawEntry>> getMany(String table, List<ByteKey> keys) =>
      _inner.getMany(table, keys);
  @override
  Future<bool> tableExists(String table) => _inner.tableExists(table);
  @override
  Future<List<String>> tables() => _inner.tables();
  @override
  Future<int> lastCommitSeq() => _inner.lastCommitSeq();
  @override
  Future<void> close() => _inner.close();
}

void main() {
  group('restart persistence and atomicity', () {
    test(
      'idempotency dedupe persists across a file-backed close/reopen',
      () async {
        final root = await Directory.systemTemp.createTemp('gecko-restart-');
        final path = '${root.path}${Platform.pathSeparator}db.redb';
        final repositoryRoot = Directory.current.path.endsWith('gecko_db')
            ? Directory.current.parent.parent.path
            : Directory.current.path;
        final nativeLibraryName = Platform.isWindows
            ? 'gecko_db_rust.dll'
            : Platform.isMacOS
            ? 'libgecko_db_rust.dylib'
            : 'libgecko_db_rust.so';
        final nativePath =
            '$repositoryRoot${Platform.pathSeparator}rust${Platform.pathSeparator}'
            'target${Platform.pathSeparator}release${Platform.pathSeparator}'
            '$nativeLibraryName';
        final config = DatabaseConfig(nativeLibraryPath: nativePath);

        DatabaseImpl? db;
        try {
          db = await DatabaseImpl.open(path, config: config);
          final item = ChangeRecord(
            localMutationId: 0,
            recordId: 'r1',
            timestamp: DateTime.utc(2026),
            collection: 'items',
            kind: ChangeKind.put,
            value: {'value': 'v'},
            idempotencyKey: 'key-abc',
            origin: ChangeOrigin.remoteSync,
          );
          expect(await db.sync.isDuplicate('key-abc'), isFalse);
          expect(await db.sync.applyRemoteTransactional([item]), ['r1']);
          expect(await db.sync.isDuplicate('key-abc'), isTrue);
          await db.close();
          db = null;

          final reopened = await DatabaseImpl.open(path, config: config);
          // The seen-key lives in the file, not just memory.
          expect(await reopened.sync.isDuplicate('key-abc'), isTrue);
          expect(await reopened.sync.applyRemoteTransactional([item]), isEmpty);
          await reopened.close();
        } finally {
          await db?.close();
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test('a failed commit leaves neither data nor its change record', () async {
      final db = await openNativeTestDatabase('restart-fail');
      final failing = _FailingBackend(db.engine.backend);
      final engine = RawEngine(failing);
      // The commitBatch seam is exactly where the data row and its
      // change-tracking record are written in one batch.
      await expectLater(
        engine.commitBatch(
          (lsn, _) async => [
            RawPut('items', ByteKey([1]), [9]),
            RawPut('__gecko_change_log', ByteKey([lsn, 0]), [1]),
          ],
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.transactionAborted,
          ),
        ),
      );
      final snap = await db.engine.backend.snapshot();
      expect(await snap.read('items', ByteKey([1])), isNull);
      expect(await snap.scanAll('__gecko_change_log'), isEmpty);

      // A subsequent commit succeeds.
      final lsn = await engine.commitBatch(
        (lsn, _) async => [
          RawPut('items', ByteKey([2]), [7]),
          RawPut('__gecko_change_log', ByteKey([lsn, 0]), [1]),
        ],
      );
      expect(lsn, greaterThan(0));
      final fresh = await db.engine.backend.snapshot();
      expect(await fresh.read('items', ByteKey([2])), [7]);
      await db.close();
    });
  });
}
