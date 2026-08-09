/// Change feed contract (Phase 4).
library;

/// The kind of change applied to a key.
enum ChangeKind { put, delete }

/// A single change to a single (table, key).
class Change {
  const Change({
    required this.table,
    required this.key,
    required this.kind,
    this.sequence,
  });

  final String table;
  final Object? key;
  final ChangeKind kind;

  /// Monotonically increasing sequence number (LSN) aligned with Phase 7's
  /// ordering clock when available.
  final int? sequence;

  @override
  String toString() => 'Change($table, $key, ${kind.name}, seq=$sequence)';
}

/// A set of changes emitted after a committed batch. Per the phase contract,
/// one coalesced emission per committed batch (per key), not one per op.
class ChangeSet {
  const ChangeSet(this.changes, {this.sequence});

  final List<Change> changes;

  /// The LSN of the committing batch, if assigned.
  final int? sequence;

  int get length => changes.length;
  bool get isEmpty => changes.isEmpty;
}
