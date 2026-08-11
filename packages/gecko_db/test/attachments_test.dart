import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _Parent {
  _Parent(this.id, this.name);
  final String id;
  final String name;
}

Object? _toRow(_Parent p) => {'name': p.name};
_Parent _fromRow(Object? row) => _Parent('', (row as Map)['name'] as String);
Object? _parentId(_Parent p) => p.id;

Future<DatabaseImpl> _open(String name) =>
    openNativeTestDatabase('attachments-$name');
void main() {
  group('attachment metadata', () {
    test('create, read, and duplicate-hash dedupe share a blob', () async {
      final db = await _open('dedupe');
      final parents = db.collection<_Parent>(
        'parents',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _parentId,
      );
      await parents.put(_Parent('a', 'A'));
      await parents.put(_Parent('b', 'B'));
      final first = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'a',
        filename: 'f.bin',
        fileType: 'bin',
        size: 10,
        contentHash: 'abc',
      );
      final second = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'b',
        filename: 'g.bin',
        fileType: 'bin',
        size: 10,
        contentHash: 'abc',
      );
      expect(await db.attachments.hasBlob('abc'), isTrue);
      expect(await db.attachments.blobRefCount('abc'), 2);
      expect(first.id, isNot(second.id));
      expect(first.contentHash, second.contentHash);
      await db.close();
    });

    test('deleting the last reference frees the blob', () async {
      final db = await _open('refcount');
      final parents = db.collection<_Parent>(
        'parents',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _parentId,
      );
      await parents.put(_Parent('a', 'A'));
      await parents.put(_Parent('b', 'B'));
      final first = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'a',
        filename: 'f',
        fileType: 'x',
        size: 1,
        contentHash: 'h1',
      );
      await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'b',
        filename: 'g',
        fileType: 'x',
        size: 1,
        contentHash: 'h1',
      );
      await db.attachments.delete(first.id);
      expect(await db.attachments.blobRefCount('h1'), 1);
      await db.attachments.delete('parents:b:g');
      expect(await db.attachments.hasBlob('h1'), isFalse);
      await db.close();
    });

    test('upload transitions are atomic and queryable', () async {
      final db = await _open('states');
      final parents = db.collection<_Parent>(
        'parents',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _parentId,
      );
      await parents.put(_Parent('a', 'A'));
      final meta = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'a',
        filename: 'f',
        fileType: 'x',
        size: 5,
        contentHash: 'h2',
      );
      final uploading = await db.attachments.setUploadState(
        meta.id,
        AttachmentUploadState.uploading,
      );
      expect(uploading.uploadState, AttachmentUploadState.uploading);
      final failed = await db.attachments.setUploadState(
        meta.id,
        AttachmentUploadState.failed,
        failedOperationDetail: 'network',
      );
      expect(failed.retryCount, 1);
      expect(failed.failedOperationDetail, 'network');
      final retried = await db.attachments.setUploadState(
        meta.id,
        AttachmentUploadState.pending,
        resetRetry: true,
      );
      expect(retried.retryCount, 0);
      await db.attachments.setUploadState(
        meta.id,
        AttachmentUploadState.completed,
      );
      expect(await db.attachments.completedUploads(), hasLength(1));
      expect(await db.attachments.pendingUploads(), isEmpty);
      expect(await db.attachments.failedUploads(), isEmpty);
      await db.close();
    });

    test(
      'orphan query surfaces attachments whose parent was removed',
      () async {
        final db = await _open('orphan');
        final parents = db.collection<_Parent>(
          'parents',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _parentId,
        );
        await parents.put(_Parent('a', 'A'));
        final meta = await db.attachments.create(
          parentCollection: 'parents',
          parentId: 'a',
          filename: 'f',
          fileType: 'x',
          size: 1,
          contentHash: 'h3',
        );
        expect(await db.attachments.orphaned(), isEmpty);
        await parents.delete('a');
        expect((await db.attachments.orphaned()).single.id, meta.id);
        await db.close();
      },
    );

    test('queries are mutually exclusive and exhaustive', () async {
      final db = await _open('exhaustive');
      final parents = db.collection<_Parent>(
        'parents',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _parentId,
      );
      await parents.put(_Parent('a', 'A'));
      await parents.put(_Parent('b', 'B'));
      await parents.put(_Parent('c', 'C'));
      final pending = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'a',
        filename: 'p',
        fileType: 'x',
        size: 1,
        contentHash: 'c1',
      );
      final completed = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'b',
        filename: 'c',
        fileType: 'x',
        size: 1,
        contentHash: 'c2',
      );
      final failed = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'c',
        filename: 'f',
        fileType: 'x',
        size: 1,
        contentHash: 'c3',
      );
      await db.attachments.setUploadState(
        pending.id,
        AttachmentUploadState.pending,
      );
      await db.attachments.setUploadState(
        completed.id,
        AttachmentUploadState.completed,
      );
      await db.attachments.setUploadState(
        failed.id,
        AttachmentUploadState.failed,
      );
      final all = [
        ...await db.attachments.pendingUploads(),
        ...await db.attachments.completedUploads(),
        ...await db.attachments.failedUploads(),
      ];
      expect(all.length, 3);
      expect(all.map((a) => a.id).toSet().length, 3);
      await db.close();
    });

    test('parent deletion transactionally integrates with metadata', () async {
      final db = await _open('parent-delete');
      final parents = db.collection<_Parent>(
        'parents',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _parentId,
      );
      await parents.put(_Parent('a', 'A'));
      final meta = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'a',
        filename: 'f',
        fileType: 'x',
        size: 1,
        contentHash: 'h4',
      );
      await db.attachments.setDeleteState(
        meta.id,
        AttachmentDeleteState.completed,
      );
      expect(
        (await db.attachments.get(meta.id))!.deleteState,
        AttachmentDeleteState.completed,
      );
      await db.close();
    });

    test(
      'deleting a parent marks dependent attachments deletable and orphans them',
      () async {
        final db = await _open('parent-delete-integ');
        final parents = db.collection<_Parent>(
          'parents',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _parentId,
        );
        await parents.put(_Parent('a', 'A'));
        final meta = await db.attachments.create(
          parentCollection: 'parents',
          parentId: 'a',
          filename: 'f',
          fileType: 'x',
          size: 1,
          contentHash: 'h5',
        );
        await db.attachments.setUploadState(
          meta.id,
          AttachmentUploadState.completed,
        );
        // Deleting the parent through the typed collection leaves the
        // attachment metadata intact but surfaces it as an orphan.
        await parents.delete('a');
        expect((await db.attachments.orphaned()).single.id, meta.id);
        // The upload state is unaffected by parent deletion (metadata and the
        // parent remain independent).
        expect(
          (await db.attachments.get(meta.id))!.uploadState,
          AttachmentUploadState.completed,
        );
        await db.close();
      },
    );
  });
}
