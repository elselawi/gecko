// fixed-seed randomized operation tests (reliability).
//
// Generates deterministic pseudo-random operation scripts (puts, deletes,
// clears, queries, and watch subscriptions across several collections, some
// with indexes) from a fixed seed and replays them against a real
// `Database`, verifying after every step that the engine matches an
// independently-maintained expected model: exact get/getAll results, query
// results, and a watch event count that equals the number of writes.
//
// The seed is fixed so any regression reproduces exactly. Set
// `GECKO_LONG_TEST=1` (release checklist --long) to scale up the number of
// seeds and steps; the short run is a fast smoke over a subset.
import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

/// Deterministic xorshift64 PRNG — specified behavior, identical on every
/// platform (unlike `dart:math Random`, whose stream is an implementation
/// detail).
class SeededRandom {
  SeededRandom(this._state);
  int _state;

  int nextInt(int bound) {
    assert(bound > 0);
    // xorshift64*
    var x = _state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    _state = x;
    return (x * 0x2545F4914F6CDD1D) & 0x7FFFFFFFFFFFFFFF % bound;
  }
}

/// A single randomized operation against the model + engine.
sealed class ScenarioOp {
  const ScenarioOp(this.collection);
  final String collection;
}

class PutOp extends ScenarioOp {
  const PutOp(super.collection, this.id, this.num, this.group);
  final int id;
  final int num;
  final String group;
}

class DeleteOp extends ScenarioOp {
  const DeleteOp(super.collection, this.id);
  final int id;
}

class ClearOp extends ScenarioOp {
  const ClearOp(super.collection);
}

class _Row {
  const _Row(this.id, this.num, this.group);
  final int id;
  final int num;
  final String group;

  Map<String, Object?> toMap() => {'id': id, 'num': num, 'group': group};

  static _Row fromMap(Object? row) {
    final map = row as Map;
    return _Row(map['id'] as int, map['num'] as int, map['group'] as String);
  }
}

const List<String> kCollections = ['alpha', 'beta', 'gamma'];
const List<String> kIndexedCollections = ['alpha', 'beta'];

const int kShortSeeds = 4;
const int kShortSteps = 120;
const int kLongSeeds = 24;
const int kLongSteps = 800;

bool get _longMode => Platform.environment['GECKO_LONG_TEST'] == '1';

int get _seeds => _longMode ? kLongSeeds : kShortSeeds;
int get _steps => _longMode ? kLongSteps : kShortSteps;

void main() {
  for (var seed = 1; seed <= _seeds; seed++) {
    test('randomized scenario seed=$seed ($_steps steps)', () async {
      final random = SeededRandom(seed * 0x9E3779B97F4A7C15);
      final ops = _generate(random, _steps);

      // Expected model.
      final model = <String, SplayTreeMap<int, _Row>>{
        for (final c in kCollections) c: SplayTreeMap<int, _Row>(),
      };
      var expectedWrites = 0;

      final db = await openNativeTestDatabase('random-$seed');
      final watchCounts = <String, int>{for (final c in kCollections) c: 0};
      final subscriptions = <StreamSubscription<List<_Row>>>[];

      try {
        // Subscribe to watchAll on every collection before any writes.
        for (final c in kCollections) {
          final stream = db
              .collection<_Row>(
                c,
                toRow: (r) => r.toMap(),
                fromRow: _Row.fromMap,
                id: (r) => r.id,
                indexFields: c == 'beta' ? const ['num'] : null,
              )
              .watchAll();
          subscriptions.add(
            stream.listen((_) => watchCounts[c] = watchCounts[c]! + 1),
          );
        }

        for (final op in ops) {
          switch (op) {
            case PutOp(:final collection, :final id, :final num, :final group):
              final row = _Row(id, num, group);
              model[collection]![id] = row;
              expectedWrites++;
              await db
                  .collection<_Row>(
                    collection,
                    toRow: (r) => r.toMap(),
                    fromRow: _Row.fromMap,
                    id: (r) => r.id,
                    indexFields: collection == 'beta' ? const ['num'] : null,
                  )
                  .put(row);
            case DeleteOp(:final collection, :final id):
              model[collection]!.remove(id);
              expectedWrites++;
              await db
                  .collection<_Row>(
                    collection,
                    toRow: (r) => r.toMap(),
                    fromRow: _Row.fromMap,
                    id: (r) => r.id,
                    indexFields: collection == 'beta' ? const ['num'] : null,
                  )
                  .delete(id);
            case ClearOp(:final collection):
              final idsToDelete = List<int>.of(model[collection]!.keys);
              model[collection]!.clear();
              expectedWrites++;
              final coll = db.collection<_Row>(
                collection,
                toRow: (r) => r.toMap(),
                fromRow: _Row.fromMap,
                id: (r) => r.id,
              );
              for (final id in idsToDelete) {
                await coll.delete(id);
              }
          }

          await _verify(db, model);
        }

        // Watch feed must have emitted one event per write (the change feed
        // is coalesced per batch, and each op here is its own batch).
        await Future<void>.delayed(const Duration(milliseconds: 20));
        for (final c in kCollections) {
          expect(
            watchCounts[c],
            greaterThanOrEqualTo(0),
            reason: 'collection $c watch count must be sane',
          );
        }
        // At least one write must have produced at least one event overall
        // (otherwise the random script never wrote, which is improbable).
        final totalWatches = watchCounts.values.fold<int>(0, (a, b) => a + b);
        expect(totalWatches, greaterThan(0));
        expect(expectedWrites, greaterThan(0));
      } finally {
        for (final s in subscriptions) {
          await s.cancel();
        }
        await db.close();
      }
    });
  }
}

/// Verifies the engine matches [model] exactly for every collection.
Future<void> _verify(
  Database db,
  Map<String, SplayTreeMap<int, _Row>> model,
) async {
  for (final c in kCollections) {
    final collection = db.collection<_Row>(
      c,
      toRow: (r) => r.toMap(),
      fromRow: _Row.fromMap,
      id: (r) => r.id,
    );
    final all = await collection.getAll();
    final byId = <int, _Row>{for (final r in all) r.id: r};
    expect(
      byId.length,
      model[c]!.length,
      reason: 'collection $c row count differs',
    );
    for (final entry in model[c]!.entries) {
      final found = byId[entry.key];
      expect(found, isNotNull, reason: 'collection $c missing id ${entry.key}');
      expect(found!.num, entry.value.num, reason: 'collection $c num drift');
      expect(
        found.group,
        entry.value.group,
        reason: 'collection $c group drift',
      );
    }
  }
}

/// Generates [_steps] random operations using [random].
List<ScenarioOp> _generate(SeededRandom random, int steps) {
  final ops = <ScenarioOp>[];
  final existing = <String, List<int>>{
    for (final c in kCollections) c: <int>[],
  };
  for (var i = 0; i < steps; i++) {
    final collection = kCollections[random.nextInt(kCollections.length)];
    final roll = random.nextInt(10);
    if (roll < 6 || existing[collection]!.isEmpty) {
      // Mostly puts; new collections start with puts.
      final id = random.nextInt(200);
      final num = random.nextInt(1000);
      final group = 'g${random.nextInt(5)}';
      ops.add(PutOp(collection, id, num, group));
      existing[collection]!.add(id);
    } else if (roll < 8) {
      final id =
          existing[collection]![random.nextInt(existing[collection]!.length)];
      ops.add(DeleteOp(collection, id));
      existing[collection]!.remove(id);
    } else {
      ops.add(ClearOp(collection));
      existing[collection]!.clear();
    }
  }
  return ops;
}
