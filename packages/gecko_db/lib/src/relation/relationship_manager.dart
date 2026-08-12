/// relationship manager.
///
/// Declares and enforces relationships between collections at the row level,
/// built on the raw engine (`RawEngine`) so all constraint enforcement and
/// cascades are applied in atomic batches (same-transaction discipline as the
/// rest of the engine). Foreign keys are plain fields holding the parent id in
/// the child row; many-to-many uses an explicit join collection.
library;

import 'dart:async';

import '../api/change.dart';
import '../backend/byte_key.dart';
import '../backend/native_raw_backend.dart' show NativeRawSnapshot;
import '../backend/raw_backend.dart';
import '../errors/errors.dart';
import '../query/durable_index_bounds.dart';
import '../query/filter.dart';
import '../query/predicate_codec.dart';
import '../query/query_impl.dart';
import '../raw/raw_engine.dart';
import '../wire/wire_codec.dart';
import 'relationship.dart';

/// A callback that decides how an application-controlled delete affects a
/// dependent row. Returns the raw operations to apply atomically.
typedef DependentDeleteHook =
    FutureOr<List<RawOp>> Function(
      Map<Object?, Object?> dependentRow,
      Object? childId,
    );

/// Row accessor functions the manager needs for a collection.
class RowAccessors {
  const RowAccessors({required this.childIdOf, required this.parentIdOf});

  /// Extracts a child row's own id from its row map.
  final Object? Function(Map<Object?, Object?> row) childIdOf;

  /// In a child row, extracts the stored parent id (FK field value).
  final Object? Function(Map<Object?, Object?> row) parentIdOf;
}

/// Enforces referential integrity and provides relationship helpers.
class RelationshipManager {
  RelationshipManager(
    this._engine, {
    DefaultWireCodec codec = const DefaultWireCodec(),
    CollectionIndex? Function(String table)? indexLookup,
  }) : _codec = codec,
       _indexLookup = indexLookup;

  final RawEngine _engine;
  final DefaultWireCodec _codec;
  final CollectionIndex? Function(String table)? _indexLookup;

  final List<Relationship> _relationships = [];
  final Map<String, RowAccessors> _accessors = {};
  final Map<String, DependentDeleteHook> _deleteHooks = {};

  /// All declared relationships (diagnostics/inspection).
  List<Relationship> get relationships => List.unmodifiable(_relationships);

  void registerAccessors(String collection, RowAccessors accessors) {
    _accessors[collection] = accessors;
  }

  /// Registers the hook used for [`DeleteBehavior.applicationControlled`]
  /// relationships on [collection]. Exactly one hook per collection.
  void registerDeleteHook(String collection, DependentDeleteHook hook) {
    _deleteHooks[collection] = hook;
  }

  /// Declares a relationship and performs cycle detection (cascade cycles are
  /// rejected at declaration time, not at delete time).
  void declare(Relationship relationship) {
    _relationships.add(relationship);
    // Cascade cycle detection: after adding, DFS the full cascade graph for
    // any cycle (A→B cascade + B→A cascade, or a self-referential cascade).
    for (final r in _relationships.where(
      (r) => r.deleteBehavior == DeleteBehavior.cascade,
    )) {
      final path = <String>[];
      _walk(r.parentCollection, path);
    }
  }

  void _walk(String collection, List<String> path) {
    if (path.contains(collection)) {
      throw GeckoError(
        GeckoErrorType.invalidOperation,
        'Cascade cycle detected: ${path.join(' -> ')} -> $collection',
        details: <String, Object?>{
          'path': [...path, collection],
        },
      );
    }
    path.add(collection);
    for (final r in _relationships) {
      if (r.deleteBehavior == DeleteBehavior.cascade &&
          r.parentCollection == collection) {
        _walk(r.childCollection, path);
      }
    }
    path.removeLast();
  }

  /// Loads the children of [parentId] for a one-to-many relationship whose
  /// child rows reference the parent via [relationship]. Uses the child
  /// collection's index on the foreign-key field when one is declared
  /// ( FK helpers wired to indexes).
  Future<List<Map<Object?, Object?>>> children(
    Relationship relationship,
    Object? parentId,
  ) async {
    _checkChild(relationship);
    final fk = _fkField(relationship);
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      return await _childRowsFrom(snap, relationship, parentId, fk);
    } finally {
      await snap.dispose();
    }
  }

  /// Resolves child rows for [parentId] against [snap], using the child
  /// collection's secondary index when the FK field is indexed.
  Future<List<Map<Object?, Object?>>> _childRowsFrom(
    NativeRawSnapshot snap,
    Relationship r,
    Object? parentId,
    String fk,
  ) async {
    final index = _indexLookup?.call(r.childCollection);
    if (index != null && index.fields.contains(fk)) {
      // Native indexed relationship lookup: the durable index narrows the
      // candidate set and Rust applies the FK predicate on those candidates
      // (the same primitive query execution uses). Dart decodes only the rows
      // the predicate accepted — no Dart-side re-verification remains.
      final (start, end) = eqBounds(
        r.childCollection,
        fk,
        parentId,
        codec: _codec,
      );
      final entries = await snap.queryIndexedLimited(
        table: r.childCollection,
        start: ByteKey(start),
        end: ByteKey(end),
        predicateBytes: encodePredicate([
          Filter.eq(fk, parentId),
        ], codec: _codec),
      );
      return [
        for (final entry in entries)
          _mapOf(_codec.decode(entry.value ?? const [])),
      ];
    }
    // Native unindexed relationship lookup evaluates the predicate in Rust,
    // transferring only matching child rows to Dart.
    final entries = await snap.queryFiltered(
      table: r.childCollection,
      predicateBytes: encodePredicate([Filter.eq(fk, parentId)], codec: _codec),
    );
    return [
      for (final entry in entries)
        _mapOf(_codec.decode(entry.value ?? const [])),
    ];
  }

  /// Loads the parent of [childId] for a relationship (reverse lookup).
  Future<Map<Object?, Object?>?> parent(
    Relationship relationship,
    Object? childId,
  ) async {
    _checkChild(relationship);
    final fk = _fkField(relationship);
    final childKey = _byteOf(childId);
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      final entry = await snap.relationshipParent(
        childTable: relationship.childCollection,
        childKey: childKey,
        parentTable: relationship.parentCollection,
        foreignKeyField: fk,
      );
      return entry == null
          ? null
          : _mapOf(_codec.decode(entry.value ?? const []));
    } finally {
      await snap.dispose();
    }
  }

  /// Eager-loads children for a list of parents in one pass (avoids N+1).
  Future<Map<Object?, List<Map<Object?, Object?>>>> loadAllChildren(
    Relationship relationship,
    List<Object?> parentIds,
  ) async {
    _checkChild(relationship);
    final fk = _fkField(relationship);
    final wanted = parentIds.toSet();
    final out = <Object?, List<Map<Object?, Object?>>>{
      for (final id in parentIds) id: <Map<Object?, Object?>>[],
    };
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      final index = _indexLookup?.call(relationship.childCollection);
      final ranges = <(ByteKey, ByteKey)>[];
      if (index != null && index.fields.contains(fk)) {
        for (final parentId in parentIds) {
          final (start, end) = eqBounds(
            relationship.childCollection,
            fk,
            parentId,
            codec: _codec,
          );
          ranges.add((ByteKey(start), ByteKey(end)));
        }
      }
      final groups = await snap.relationshipChildren(
        childTable: relationship.childCollection,
        foreignKeyField: fk,
        parentIds: [for (final id in parentIds) _byteOf(id)],
        indexRanges: ranges,
        predicateBytes: encodePredicate(const [], codec: _codec),
      );
      // Rust already classified every returned row by FK; Dart only routes
      // each group's entries to the matching parent bucket (model mapping).
      for (final group in groups) {
        final pid = _codec.decode(group.parentId.bytes);
        if (pid != null && wanted.contains(pid)) {
          out[pid]!.addAll([
            for (final entry in group.entries)
              _mapOf(_codec.decode(entry.value ?? const [])),
          ]);
        }
      }
      return out;
    } finally {
      await snap.dispose();
    }
  }

  /// For a many-to-many relationship, adds a join row linking [leftId]
  /// (the parent side) to [rightId] (the child side).
  Future<void> addJoin(
    Relationship relationship,
    Object? leftId,
    Object? rightId,
  ) async {
    _checkJoinable(relationship);
    final table = _joinTable(relationship);
    final joinKey = _byteOf([leftId, rightId]);
    // Join rows live in a reserved table that the public change feed filters
    // out, so the coordinator publishes an event on the parent collection to
    // keep reactive N:M queries live.
    await _engine.commitBatchNoSnapshot(
      (_) async => [
        RawPut(
          table,
          joinKey,
          _codec.encode({'left': leftId, 'right': rightId}),
        ),
      ],
      buildChanges: (lsn) => [
        Change(
          table: relationship.parentCollection,
          key: leftId,
          kind: ChangeKind.put,
        ),
      ],
    );
  }

  /// Removes a join row linking [leftId] to [rightId] (no-op if absent).
  Future<void> removeJoin(
    Relationship relationship,
    Object? leftId,
    Object? rightId,
  ) async {
    _checkJoinable(relationship);
    final table = _joinTable(relationship);
    final joinKey = _byteOf([leftId, rightId]);
    await _engine.commitBatchNoSnapshot(
      (_) async => [RawDelete(table, joinKey)],
      buildChanges: (lsn) => [
        Change(
          table: relationship.parentCollection,
          key: leftId,
          kind: ChangeKind.delete,
        ),
      ],
    );
  }

  /// Loads the ids on the right side of a many-to-many relationship for
  /// [leftId].
  Future<List<Object?>> rightIds(
    Relationship relationship,
    Object? leftId,
  ) async {
    _checkJoinable(relationship);
    final table = _joinTable(relationship);
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      final encodedIds = await snap.relationshipJoinIds(
        joinTable: table,
        field: 'left',
        wantedId: _byteOf(leftId),
      );
      return [for (final bytes in encodedIds) _codec.decode(bytes)];
    } finally {
      await snap.dispose();
    }
  }

  /// Loads the ids on the left side of a many-to-many relationship for
  /// [rightId].
  Future<List<Object?>> leftIds(
    Relationship relationship,
    Object? rightId,
  ) async {
    _checkJoinable(relationship);
    final table = _joinTable(relationship);
    final snap = await _engine.backend.snapshot() as NativeRawSnapshot;
    try {
      final encodedIds = await snap.relationshipJoinIds(
        joinTable: table,
        field: 'right',
        wantedId: _byteOf(rightId),
      );
      return [for (final bytes in encodedIds) _codec.decode(bytes)];
    } finally {
      await snap.dispose();
    }
  }

  /// Many-to-many bookkeeping: removes every join row touching [id] on the
  /// given side. Called when a record is deleted so the join table cannot
  /// retain dangling references.
  Future<List<RawOp>> joinCleanupOps(
    Relationship relationship,
    Object? id, {
    required bool isLeft,
    RawSnapshot? snapshot,
  }) async {
    _checkJoinable(relationship);
    final table = _joinTable(relationship);
    final snap = snapshot ?? await _engine.backend.snapshot();
    final owned = snapshot == null;
    try {
      // The engine is always native; the commitBatch/engine snapshot is a
      // NativeRawSnapshot at runtime. Rust evaluates the side+id predicate,
      // transferring only the matching join rows (Dart no longer scans and
      // decodes the whole join table to find dangling references).
      final field = isLeft ? 'left' : 'right';
      final entries = await (snap as NativeRawSnapshot).queryFiltered(
        table: table,
        predicateBytes: encodePredicate([Filter.eq(field, id)], codec: _codec),
      );
      return [for (final entry in entries) RawDelete(table, entry.key)];
    } finally {
      if (owned) await snap.dispose();
    }
  }

  /// Reactive one-to-many relationship query emits the children of
  /// [parentId] immediately, then re-emits whenever a change touches either
  /// the child collection or the parent collection (so writes on either side
  /// are observed).
  Stream<List<Map<Object?, Object?>>> watchChildren(
    Relationship relationship,
    Object? parentId,
  ) {
    _checkChild(relationship);
    late StreamController<List<Map<Object?, Object?>>> controller;
    late StreamSubscription<ChangeSet> sub;
    controller = StreamController<List<Map<Object?, Object?>>>(
      onListen: () {
        unawaited(children(relationship, parentId).then(controller.add));
        sub = _engine.changes.stream.listen((set) {
          if (set.changes.any(
            (c) =>
                c.table == relationship.childCollection ||
                c.table == relationship.parentCollection,
          )) {
            unawaited(children(relationship, parentId).then(controller.add));
          }
        });
      },
      onCancel: () => sub.cancel(),
    );
    return controller.stream;
  }

  /// Reactive reverse lookup emits the parent row of [childId]
  /// immediately, then re-emits when the parent or child row changes.
  Stream<Map<Object?, Object?>?> watchParent(
    Relationship relationship,
    Object? childId,
  ) {
    _checkChild(relationship);
    late StreamController<Map<Object?, Object?>?> controller;
    late StreamSubscription<ChangeSet> sub;
    controller = StreamController<Map<Object?, Object?>?>(
      onListen: () {
        unawaited(parent(relationship, childId).then(controller.add));
        sub = _engine.changes.stream.listen((set) {
          if (set.changes.any(
            (c) =>
                c.table == relationship.childCollection ||
                c.table == relationship.parentCollection,
          )) {
            unawaited(parent(relationship, childId).then(controller.add));
          }
        });
      },
      onCancel: () => sub.cancel(),
    );
    return controller.stream;
  }

  /// Reactive many-to-many emits the right-side ids of [leftId]
  /// immediately, then re-emits when the join table changes.
  ///
  /// Join rows live in a reserved `__gecko_join_*` table that the public
  /// change feed filters out, so `addJoin`/`removeJoin` publish a synthetic
  /// event on the parent collection; this watch reacts to parent and child
  /// collection changes.
  Stream<List<Object?>> watchJoinIds(
    Relationship relationship,
    Object? leftId,
  ) {
    _checkJoinable(relationship);
    late StreamController<List<Object?>> controller;
    late StreamSubscription<ChangeSet> sub;
    controller = StreamController<List<Object?>>(
      onListen: () {
        unawaited(rightIds(relationship, leftId).then(controller.add));
        sub = _engine.changes.stream.listen((set) {
          if (set.changes.any(
            (c) =>
                c.table == relationship.parentCollection ||
                c.table == relationship.childCollection,
          )) {
            unawaited(rightIds(relationship, leftId).then(controller.add));
          }
        });
      },
      onCancel: () => sub.cancel(),
    );
    return controller.stream;
  }

  /// Enforces delete behavior: returns a batch of ops to apply atomically when
  /// the parent at [parentId] is deleted. `restrict` throws if dependents exist.
  Future<List<RawOp>> resolveDelete(
    Relationship relationship,
    Object? parentId, {
    RawSnapshot? snapshot,
  }) async {
    _checkChild(relationship);
    final fk = _fkField(relationship);
    final dependentRows = await _childRows(
      relationship,
      parentId,
      fk,
      snapshot: snapshot,
    );
    return _resolveDeleteFromRows(relationship, parentId, dependentRows);
  }

  /// The delete-behavior decision over already-read dependent [rows] — shared
  /// by [resolveDelete] and the cascade planner so dependent rows are fetched
  /// exactly once per parent (no double read in `_collectDeleteOps`).
  Future<List<RawOp>> _resolveDeleteFromRows(
    Relationship relationship,
    Object? parentId,
    List<Map<Object?, Object?>> dependentRows,
  ) async {
    final fk = _fkField(relationship);
    switch (relationship.deleteBehavior) {
      case DeleteBehavior.none:
        return const [];
      case DeleteBehavior.restrict:
        if (dependentRows.isNotEmpty) {
          final offender = _accessors[relationship.childCollection]?.childIdOf(
            dependentRows.first,
          );
          throw GeckoError(
            GeckoErrorType.invalidOperation,
            'Cannot delete parent id $parentId: dependents exist in '
            '"${relationship.childCollection}" (dependent id="$offender")',
            details: <String, Object?>{
              'childCollection': relationship.childCollection,
              'dependentId': offender,
            },
          );
        }
        return const [];
      case DeleteBehavior.setNull:
        final ops = <RawOp>[];
        for (final row in dependentRows) {
          final childId = _accessors[relationship.childCollection]?.childIdOf(
            row,
          );
          if (childId == null) continue;
          final newRow = Map<Object?, Object?>.from(row)..[fk] = null;
          ops.add(
            RawPut(
              relationship.childCollection,
              _byteOf(childId),
              _codec.encode(newRow),
            ),
          );
        }
        return ops;
      case DeleteBehavior.cascade:
        final ops = <RawOp>[];
        for (final row in dependentRows) {
          final childId = _accessors[relationship.childCollection]?.childIdOf(
            row,
          );
          if (childId != null) {
            ops.add(RawDelete(relationship.childCollection, _byteOf(childId)));
          }
        }
        return ops;
      case DeleteBehavior.applicationControlled:
        final hook = _deleteHooks[relationship.childCollection];
        if (hook == null) {
          throw GeckoError(
            GeckoErrorType.invalidOperation,
            'Delete-behavior applicationControlled on '
            '"${relationship.childCollection}" has no registered hook',
          );
        }
        final ops = <RawOp>[];
        for (final row in dependentRows) {
          final childId = _accessors[relationship.childCollection]?.childIdOf(
            row,
          );
          if (childId == null) continue;
          final sub = await hook(row, childId);
          ops.addAll(sub);
        }
        return ops;
    }
  }

  /// Atomically deletes [parentId] along with its cascade/restrict/setNull
  /// effects, including transitive cascades for one-to-many cascade chains.
  ///
  /// this is the single transaction coordinator — constraint
  /// enforcement, cascades, set-null rewrites, application hooks, and
  /// many-to-many join cleanup are collected and committed in ONE redb write
  /// transaction (with the LSN and change-feed events), under the engine's
  /// write gate and one MVCC snapshot.
  Future<void> deleteWithBehavior(
    Relationship relationship,
    Object? parentId,
  ) async {
    final ops = <RawOp>[];
    await _engine.commitBatch(
      (lsn, snapshot) async {
        ops.clear();
        await _collectDeleteOps(
          relationship,
          parentId,
          ops,
          <String>{},
          snapshot: snapshot,
        );
        // Many-to-many: remove the owning side's join rows atomically.
        if (relationship.type == RelationshipType.manyToMany) {
          ops.addAll(
            await joinCleanupOps(
              relationship,
              parentId,
              isLeft: true,
              snapshot: snapshot,
            ),
          );
        }
        return ops;
      },
      buildChanges: (lsn) => [
        for (final op in ops)
          if (op is RawDelete && !_engine.isReservedTable(op.table))
            Change(
              table: op.table,
              key: _codec.decode(op.key.bytes),
              kind: ChangeKind.delete,
            ),
      ],
    );
  }

  Future<void> _collectDeleteOps(
    Relationship relationship,
    Object? parentId,
    List<RawOp> ops,
    Set<String> visited, {
    RawSnapshot? snapshot,
  }) async {
    final guard = '${relationship.parentCollection}:$parentId';
    if (!visited.add(guard)) return; // cycle guard
    if (relationship.type == RelationshipType.manyToMany) {
      ops.add(RawDelete(relationship.parentCollection, _byteOf(parentId)));
      return;
    }
    final ownDelete = relationship.deleteBehavior;
    final fk = _fkField(relationship);
    // Read the dependent rows ONCE; the same rows feed the restrict check,
    // the delete-behavior decision, and the cascade recursion (they were
    // previously read up to three times per parent).
    final dependentRows = await _childRows(
      relationship,
      parentId,
      fk,
      snapshot: snapshot,
    );
    // Check restrict entirely first (restrict wins over cascade).
    if (ownDelete == DeleteBehavior.restrict) {
      if (dependentRows.isNotEmpty) {
        final offender = _accessors[relationship.childCollection]?.childIdOf(
          dependentRows.first,
        );
        throw GeckoError(
          GeckoErrorType.invalidOperation,
          'Cannot delete parent id $parentId: restricting dependents exist in '
          '"${relationship.childCollection}" (dependent id="$offender")',
          details: <String, Object?>{
            'childCollection': relationship.childCollection,
            'dependentId': offender,
          },
        );
      }
    }
    final subOps = await _resolveDeleteFromRows(
      relationship,
      parentId,
      dependentRows,
    );
    ops.addAll(subOps);
    // Recurse into child rows for cascade chains.
    if (ownDelete == DeleteBehavior.cascade) {
      final childIds = _idsOfRows(relationship, dependentRows);
      for (final childId in childIds) {
        for (final next in _relationships) {
          if (next.parentCollection == relationship.childCollection) {
            await _collectDeleteOps(
              next,
              childId,
              ops,
              visited,
              snapshot: snapshot,
            );
          }
        }
      }
    }
    ops.add(RawDelete(relationship.parentCollection, _byteOf(parentId)));
  }

  Future<List<Map<Object?, Object?>>> _childRows(
    Relationship r,
    Object? parentId,
    String fk, {
    RawSnapshot? snapshot,
  }) async {
    final snap = snapshot ?? await _engine.backend.snapshot();
    final owned = snapshot == null;
    try {
      // The engine is always native; the commitBatch/engine snapshot is a
      // NativeRawSnapshot at runtime.
      return await _childRowsFrom(snap as NativeRawSnapshot, r, parentId, fk);
    } finally {
      if (owned) await snap.dispose();
    }
  }

  /// Derives the child record ids from already-decoded dependent [rows] —
  /// shared by the cascade planner so ids never require a second fetch of the
  /// rows they are derived from.
  List<Object?> _idsOfRows(Relationship r, List<Map<Object?, Object?>> rows) {
    final accessor = _accessors[r.childCollection];
    return [
      for (final row in rows)
        if (accessor?.childIdOf(row) != null) accessor!.childIdOf(row),
    ];
  }

  String _fkField(Relationship r) =>
      r.foreignKeyField ?? '${r.parentCollection}Id';

  String _joinTable(Relationship r) =>
      r.foreignKeyField ?? '__gecko_join_${r.name}';

  void _checkJoinable(Relationship r) {
    if (r.type != RelationshipType.manyToMany) {
      throw GeckoError(
        GeckoErrorType.invalidOperation,
        'Relationship "${r.name}" is not many-to-many',
      );
    }
    _checkChild(r);
  }

  ByteKey _byteOf(Object? value) => ByteKey(_codec.encode(value));

  Map<Object?, Object?> _mapOf(Object? value) =>
      value is Map ? Map<Object?, Object?>.from(value) : <Object?, Object?>{};

  void _checkChild(Relationship r) {
    if (!_relationships.any((declared) => declared.name == r.name)) {
      throw GeckoError(
        GeckoErrorType.invalidOperation,
        'Relationship "${r.name}" is not declared',
      );
    }
  }
}

extension ApplyRawBatch on RawEngine {
  /// Applies a batch without publishing individual watch events (atomic).
  Future<void> applyBatchRaw(List<RawOp> ops) async {
    if (ops.isEmpty) return;
    await backend.applyBatch(ops);
  }
}
