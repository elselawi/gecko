/// Phase 12 bulk-write contracts.
library;

import 'change.dart';

/// A single bulk mutation. Values are already decoded row values; the engine
/// serializes and commits all mutations in one atomic batch.
class BulkMutation {
  const BulkMutation.put({
    required this.table,
    required this.key,
    required this.value,
  }) : kind = ChangeKind.put;

  const BulkMutation.delete({required this.table, required this.key})
    : kind = ChangeKind.delete,
      value = null;

  final String table;
  final Object? key;
  final Object? value;
  final ChangeKind kind;
}

/// Result of a bulk write.
class BulkWriteResult {
  const BulkWriteResult({required this.sequence, required this.mutationCount});

  final int sequence;
  final int mutationCount;
}
