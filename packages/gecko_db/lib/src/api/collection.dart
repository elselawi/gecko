/// Collection contract — Tier 1 CRUD + reactivity hooks.
library;

import 'dart:async';

import 'query.dart';
import 'collection_diff.dart';

/// Maps a model instance `T` to its row representation (a plain Dart value
/// the wire codec understands). Hand-written — no annotations, no codegen.
typedef RowMapper<T> = Object? Function(T model);

/// Reconstructs a model `T` from a row representation.
typedef RowUnmapper<T> = T Function(Object? row);

/// Extracts a stable record identifier from a model instance.
typedef IdExtractor<T> = Object? Function(T model);

/// A typed collection bound to row mapping functions.
///
/// Tier 1 usage: `db.collection<User>('users', toRow: ..., fromRow: ...)` then
/// [`get`], [`put`], [`delete`], [`getAll`], [`watch`].
abstract class Collection<T> {
  /// The collection/table name.
  String get name;

  /// The database this collection belongs to.
  Object get database;

  /// Fetches the record with [id], or null if absent.
  Future<T?> get(Object? id);

  /// batched point-read — fetches the records for [ids] in ONE backend
  /// read (on the native backend, one Rust call in a single read
  /// transaction), returning rows in the same order as [ids]. Ids with no
  /// record are skipped, so the result may be shorter than [ids]. This is the
  /// batch equivalent of [`get`] and kills the N+1 that per-id reads pay
  /// (used internally for relationship eager-loading).
  Future<List<T>> getMany(List<Object?> ids);

  /// Inserts or updates [model]. Returns the assigned/stable id.
  Future<Object?> put(T model);

  /// Deletes the record with [id]. Deleting a non-existent record is a
  /// documented no-op.
  Future<void> delete(Object? id);

  /// Partial update of [fields] on the record with [id] (), without a
  /// full record rewrite. Missing/null/default are distinct states.
  Future<void> patch(Object? id, Map<String, Object?> fields);

  /// All records in the collection (empty list for an empty collection).
  Future<List<T>> getAll();

  /// Builds a query (Tier 2). Returns a fresh [`Query`] starting point.
  Query<T> where([Map<String, Object?>? predicates]);

  /// Watches a single record by [id] — a `Stream<T?>` emitting only on
  /// changes to that exact key. Emits `null` (not an error) on delete.
  Stream<T?> watch(Object? id);

  /// Watches the whole collection — a coarse `Stream<List<T>>` re-emitting
  /// the full list on any relevant change (per-row diffing is /12).
  Stream<List<T>> watchAll();

  /// Per-row diff mode for large watched collections. The initial emission
  /// reports the current rows as [CollectionDiff.added].
  Stream<CollectionDiff<T>> watchAllDiff();
}
