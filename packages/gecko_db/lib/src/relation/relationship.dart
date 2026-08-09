/// Phase 6 relationship model.
///
/// A relationship is declared between two typed collections. The engine uses
/// a foreign-key field in the child row to hold the parent record id (for
/// one-to-one / one-to-many), or a join collection for many-to-many. Delete
/// behavior (cascade / restrict / set-null / none) is enforced atomically.
library;

/// The cardinality of a relationship.
enum RelationshipType { oneToOne, oneToMany, manyToMany }

/// How deleting a parent affects its dependents.
enum DeleteBehavior {
  /// Delete the parent and all its dependent children, transitively.
  cascade,

  /// Refuse to delete the parent while dependents exist (typed error naming
  /// the offending dependent).
  restrict,

  /// Null out the foreign-key on dependents rather than deleting them.
  setNull,

  /// Leave dependents untouched (the application is responsible).
  none,

  /// Invoke the application-supplied callback for each affected dependent.
  /// The callback receives the dependent row and its before-state; the
  /// engine applies whatever operations the callback returns atomically.
  applicationControlled,
}

/// A foreign-key reference descriptor.
class Relationship {
  const Relationship({
    required this.name,
    required this.parentCollection,
    required this.childCollection,
    this.type = RelationshipType.oneToMany,
    this.deleteBehavior = DeleteBehavior.restrict,
    this.foreignKeyField,
  });

  /// Stable name used by diagnostics and cycle detection.
  final String name;

  /// The parent ("one") collection name.
  final String parentCollection;

  /// The child ("many"/"owning") collection name.
  final String childCollection;

  final RelationshipType type;

  final DeleteBehavior deleteBehavior;

  /// The field in the child row that holds the parent id. For many-to-many,
  /// this is the field holding the "other side" id in the join collection.
  final String? foreignKeyField;

  /// The reverse relationship's [foreignKeyField] must point back at the
  /// parent's id — for cycle detection the engine validates this pairing.
  bool get isCascadeOnParent =>
      type == RelationshipType.oneToMany &&
      deleteBehavior == DeleteBehavior.cascade;
}
