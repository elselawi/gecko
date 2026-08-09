/// Phase 9 attachment metadata contracts.
///
/// Attachment metadata tracks binary files that live outside the database.
/// Every metadata state change is transactional with its own persistence; the
/// actual binary transfer is external and slower, so the metadata records can
/// be advanced independently (a failed transfer only mutates metadata).
library;

import '../model/row_schema.dart';

/// Upload lifecycle of an attachment's binary.
enum AttachmentUploadState { pending, uploading, completed, failed }

/// Deletion lifecycle of an attachment's remote/local binary.
enum AttachmentDeleteState { none, pending, completed, failed }

/// Whether an attachment is a primary file or a generated preview.
enum AttachmentKind { original, preview }

/// The full Phase 9 attachment-metadata record.
class AttachmentMetadata {
  const AttachmentMetadata({
    required this.id,
    required this.parentCollection,
    required this.parentId,
    required this.filename,
    required this.fileType,
    required this.size,
    required this.contentHash,
    this.remoteFileId,
    this.localPath,
    this.cacheId,
    this.kind = AttachmentKind.original,
    this.uploadState = AttachmentUploadState.pending,
    this.deleteState = AttachmentDeleteState.none,
    this.retryCount = 0,
    this.failedOperationDetail,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String parentCollection;
  final Object? parentId;
  final String filename;
  final String fileType;
  final int size;
  final String contentHash;
  final String? remoteFileId;
  final String? localPath;
  final String? cacheId;
  final AttachmentKind kind;
  final AttachmentUploadState uploadState;
  final AttachmentDeleteState deleteState;
  final int retryCount;
  final String? failedOperationDetail;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  AttachmentMetadata copyWith({
    String? remoteFileId,
    String? localPath,
    String? cacheId,
    AttachmentUploadState? uploadState,
    AttachmentDeleteState? deleteState,
    int? retryCount,
    String? failedOperationDetail,
    DateTime? updatedAt,
  }) => AttachmentMetadata(
    id: id,
    parentCollection: parentCollection,
    parentId: parentId,
    filename: filename,
    fileType: fileType,
    size: size,
    contentHash: contentHash,
    remoteFileId: remoteFileId ?? this.remoteFileId,
    localPath: localPath ?? this.localPath,
    cacheId: cacheId ?? this.cacheId,
    kind: kind,
    uploadState: uploadState ?? this.uploadState,
    deleteState: deleteState ?? this.deleteState,
    retryCount: retryCount ?? this.retryCount,
    failedOperationDetail: failedOperationDetail,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// Optional filter for attachment queries.
class AttachmentQuery {
  const AttachmentQuery({
    this.uploadState,
    this.deleteState,
    this.parentCollection,
    this.parentId,
  });

  final AttachmentUploadState? uploadState;
  final AttachmentDeleteState? deleteState;
  final String? parentCollection;
  final Object? parentId;
}

/// Database-backed Phase 9 attachment-metadata surface.
abstract class AttachmentApi {
  /// Registers a new attachment, persisting its metadata. If a blob with
  /// [contentHash] already exists, no second copy is persisted and the new
  /// record references the shared blob.
  Future<AttachmentMetadata> create({
    required String parentCollection,
    required Object? parentId,
    required String filename,
    required String fileType,
    required int size,
    required String contentHash,
    String? remoteFileId,
    String? localPath,
    String? cacheId,
    AttachmentKind kind = AttachmentKind.original,
    RowSchema? schema,
  });

  /// Advances the upload state transactionally and atomically.
  Future<AttachmentMetadata> setUploadState(
    String id,
    AttachmentUploadState state, {
    String? failedOperationDetail,
    bool resetRetry = false,
  });

  /// Advances the delete state transactionally and atomically.
  Future<AttachmentMetadata> setDeleteState(
    String id,
    AttachmentDeleteState state, {
    String? failedOperationDetail,
  });

  /// Reads one attachment by id, or null.
  Future<AttachmentMetadata?> get(String id);

  /// Lists attachments matching [query].
  Future<List<AttachmentMetadata>> query([AttachmentQuery? query]);

  /// Attachments whose upload is still actionable (pending, uploading, failed).
  Future<List<AttachmentMetadata>> pendingUploads();

  /// Attachments whose upload failed, sorted by retry count descending.
  Future<List<AttachmentMetadata>> failedUploads();

  /// Attachments whose upload completed.
  Future<List<AttachmentMetadata>> completedUploads();

  /// Attachments whose parent record no longer exists.
  Future<List<AttachmentMetadata>> orphaned();

  /// True when a blob with [contentHash] already exists.
  Future<bool> hasBlob(String contentHash);

  /// Ouputs the current reference count for a shared blob.
  Future<int> blobRefCount(String contentHash);

  /// Removes attachment metadata; releases the shared blob reference and makes
  /// the blob eligible for physical removal when the last reference is freed.
  Future<void> delete(String id);
}
