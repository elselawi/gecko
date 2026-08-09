/// Phase 12 per-row collection watch differences.
library;

/// A row-level delta between consecutive collection snapshots.
class CollectionDiff<T> {
  const CollectionDiff({
    required this.added,
    required this.updated,
    required this.removed,
    required this.snapshot,
  });

  final List<T> added;
  final List<T> updated;
  final List<T> removed;
  final List<T> snapshot;
}
