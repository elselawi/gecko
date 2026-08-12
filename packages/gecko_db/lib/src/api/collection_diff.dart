/// per-row collection watch differences.
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

/// A snapshot-less row delta for consumers with their own state store.
///
/// [Collection.watchAllDeltas] emits only added/updated/removed rows — no
/// full snapshot is ever built, so a large collection never pays to
/// materialize or transfer the whole list per emission. This is an additive
/// shape; [`CollectionDiff`] (and its `snapshot`) is unchanged.
class CollectionDelta<T> {
  const CollectionDelta({
    required this.added,
    required this.updated,
    required this.removed,
  });

  final List<T> added;
  final List<T> updated;
  final List<T> removed;
}
