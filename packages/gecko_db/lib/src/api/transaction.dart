/// Transaction contract ().
library;

import 'collection.dart';
import '../model/row_schema.dart';

/// A read/write transaction handle. Within a write transaction, reads see the
/// transaction's own uncommitted writes and nothing from concurrent
/// transactions.
abstract class Transaction {
  /// Opens a collection view bound to this transaction.
  Collection<T> collection<T>(
    String name, {
    required Object? Function(T) toRow,
    required T Function(Object? row) fromRow,
    Object? Function(T)? id,
    RowSchema? schema,
    List<String>? indexFields,
    Iterable<String>? prefixFields,
  });

  /// Reads a record within the transaction, or null.
  Future<T?> get<T>(
    String collection,
    Object? id, {
    required Object? Function(T) toRow,
    required T Function(Object? row) fromRow,
  });

  /// Whether this transaction can perform writes.
  bool get isReadOnly;

  /// Commits the transaction explicitly (default: commit on block exit).
  Future<void> commit();

  /// Rolls back the transaction, discarding all writes.
  Future<void> rollback();
}
