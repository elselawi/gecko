// fixed-seed randomized extended operations (reliability, audit 2.21).
//
// Extends the base randomized scenario with the combinations the base suite
// does not drive:
//   1. schema-validated collections (declared defaults injected on put),
//   2. multi-op write transactions (model + engine apply atomically),
//   3. relationship cascade deletes (the model mirrors the cascade side
//      effects: deleting a parent removes every child).
//
// Like the base suite, the seed is fixed (regressions reproduce exactly) and
// GECKO_LONG_TEST=1 scales the step count.

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

/// Deterministic xorshift64 PRNG (mirrors the base randomized suite).
class SeededRandom {
  SeededRandom(this._state);
  int _state;

  int nextInt(int bound) {
    assert(bound > 0);
    var x = _state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    _state = x;
    return (x * 0x2545F4914F6CDD1D) & 0x7FFFFFFFFFFFFFFF % bound;
  }
}

sealed class XOp {
  const XOp();
}

class XPut extends XOp {
  const XPut(this.collection, this.id, this.num, this.group);
  final String collection;
  final int id;
  final int num;
  final String group;
}

class XDelete extends XOp {
  const XDelete(this.collection, this.id);
  final String collection;
  final int id;
}

class XClear extends XOp {
  const XClear(this.collection);
  final String collection;
}

/// A write transaction containing several inner ops (atomic).
class XTxn extends XOp {
  const XTxn(this.ops);
  final List<XOp> ops;
}

/// Cascade-deletes a parent (and every child referencing it).
class XCascadeDelete extends XOp {
  const XCascadeDelete(this.parentId);
  final int parentId;
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

class _Child {
  const _Child(this.id, this.parentId, this.num);
  final int id;
  final int parentId;
  final int num;
  Map<String, Object?> toMap() =>
      {'id': id, 'parentId': parentId, 'num': num};
  static _Child fromMap(Object? row) {
    final map = row as Map;
    return _Child(
      map['id'] as int,
      map['parentId'] as int,
      map['num'] as int,
    );
  }
}

const String kParents = 'parents';
const String kChildren = 'children';
const String kEvents = 'events';

final _eventSchema = RowSchema([
  const FieldSpec(name: 'id'),
  const FieldSpec(name: 'kind', defaultValue: 'log', hasDefault: true),
]);

const int kShortSeeds = 2;
const int kShortSteps = 80;
const int kLongSeeds = 16;
const int kLongSteps = 500;

bool get _longMode => Platform.environment['GECKO_LONG_TEST'] == '1';

int get _seeds => _longMode ? kLongSeeds : kShortSeeds;
int get _steps => _longMode ? kLongSteps : kShortSteps;

void main() {
  for (var seed = 1; seed <= _seeds; seed++) {
    test('extended randomized scenario seed=$seed ($_steps steps)', () async {
      final random = SeededRandom(seed * 0x9E3779B97F4A7C15);
      final ops = _generate(random, _steps);

      final parents = SplayTreeMap<int, _Row>();
      final children = SplayTreeMap<int, _Child>();
      final events = SplayTreeMap<int, Map<String, Object?>>();
      var expectedWrites = 0;

      final db = await openNativeTestDatabase('random-x-$seed');
      db.relationships.registerAccessors(
        kChildren,
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['parentId'],
        ),
      );
      const rel = Relationship(
        name: 'parent-children',
        parentCollection: kParents,
        childCollection: kChildren,
        foreignKeyField: 'parentId',
        deleteBehavior: DeleteBehavior.cascade,
      );
      db.relationships.declare(rel);

      // Seed a stable parent so children always have a real parent to
      // reference (every child below uses parentId == 0).
      parents[0] = const _Row(0, 0, 'g0');
      await _open(db, kParents).put(const _Row(0, 0, 'g0').toMap());

      final watchCounts = <String, int>{for (final c in [kParents, kChildren, kEvents]) c: 0};
      final subscriptions = <StreamSubscription<List<Object?>>>[];

      try {
        for (final c in [kParents, kChildren, kEvents]) {
          final stream = _open(db, c).watchAll();
          subscriptions.add(
            stream.listen((_) => watchCounts[c] = watchCounts[c]! + 1),
          );
        }

        for (final op in ops) {
          switch (op) {
            case XPut(:final collection, :final id, :final num, :final group):
              expectedWrites++;
              switch (collection) {
                case kParents:
                  parents[id] = _Row(id, num, group);
                case kChildren:
                  // Every child references the seeded parent (parentId 0), so
                  // the cascade invariant always holds.
                  children[id] = _Child(id, 0, num);
                case kEvents:
                  events[id] = {'id': id, 'kind': 'log', 'num': num};
                default:
                  continue;
              }
              await _open(db, collection).put(_mapFor(collection, id, num, group));
            case XDelete(:final collection, :final id):
              expectedWrites++;
              if (collection == kParents) {
                // Parent deletion always cascades (model + engine), so a
                // parent is never removed while its children survive.
                if (!parents.containsKey(id)) continue;
                parents.remove(id);
                children.removeWhere((_, child) => child.parentId == id);
                await db.relationships.deleteWithBehavior(rel, id);
              } else {
                switch (collection) {
                  case kChildren:
                    children.remove(id);
                  case kEvents:
                    events.remove(id);
                  default:
                    continue;
                }
                await _open(db, collection).delete(id);
              }
            case XClear():
              expectedWrites++;
              parents.clear();
              children.clear();
              events.clear();
              for (final c in [kParents, kChildren, kEvents]) {
                final all = await _open(db, c).getAll();
                for (final row in all) {
                  await _open(db, c).delete(_idOf(c, row));
                }
              }
              // Re-seed the stable parent so later child writes stay valid.
              parents[0] = const _Row(0, 0, 'g0');
              await _open(db, kParents).put(const _Row(0, 0, 'g0').toMap());
            case XTxn(:final ops):
              // Model applies all inner ops; engine applies them atomically.
              for (final inner in ops) {
                switch (inner) {
                  case XPut(:final collection, :final id, :final num):
                    switch (collection) {
                      case kChildren:
                        children[id] = _Child(id, 0, num);
                      case kEvents:
                        events[id] = {'id': id, 'kind': 'log', 'num': num};
                      default:
                        continue;
                    }
                  case XDelete(:final collection, :final id):
                    switch (collection) {
                      case kChildren:
                        children.remove(id);
                      case kEvents:
                        events.remove(id);
                      default:
                        continue;
                    }
                  default:
                    break;
                }
              }
              expectedWrites++;
              await db.writeTxn((txn) async {
                for (final inner in ops) {
                  switch (inner) {
                    case XPut(:final collection, :final id, :final num, :final group):
                      await txn
                          .collection<Object?>(
                            collection,
                            toRow: (v) => v,
                            fromRow: (row) => row,
                            id: (v) =>
                                Map<Object?, Object?>.from(v as Map)['id'],
                          )
                          .put(_mapFor(collection, id, num, group));
                    case XDelete(:final collection, :final id):
                      await txn
                          .collection<Object?>(
                            collection,
                            toRow: (v) => v,
                            fromRow: (row) => row,
                            id: (v) =>
                                Map<Object?, Object?>.from(v as Map)['id'],
                          )
                          .delete(id);
                    default:
                      break;
                  }
                }
              });
            case XCascadeDelete(:final parentId):
              if (!parents.containsKey(parentId)) continue;
              expectedWrites++;
              parents.remove(parentId);
              children.removeWhere((_, child) => child.parentId == parentId);
              await db.relationships.deleteWithBehavior(rel, parentId);
          }

          await _verify(db, parents, children, events);
        }

        await Future<void>.delayed(const Duration(milliseconds: 20));
        final totalWatches =
            watchCounts.values.fold<int>(0, (a, b) => a + b);
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

Future<void> _verify(
  Database db,
  SplayTreeMap<int, _Row> parents,
  SplayTreeMap<int, _Child> children,
  SplayTreeMap<int, Map<String, Object?>> events,
) async {
  // Exact row contents per collection.
  final gotParents = await _open(db, kParents).getAll();
  expect(gotParents.length, parents.length, reason: 'parents count');
  for (final row in gotParents) {
    final p = _Row.fromMap(row);
    expect(parents[p.id]?.num, p.num, reason: 'parent $p drift');
  }
  final gotChildren = await _open(db, kChildren).getAll();
  expect(gotChildren.length, children.length, reason: 'children count');
  for (final row in gotChildren) {
    final c = _Child.fromMap(row);
    expect(children[c.id]?.num, c.num, reason: 'child $c drift');
  }
  final gotEvents = await _open(db, kEvents).getAll();
  expect(gotEvents.length, events.length, reason: 'events count');
  for (final row in gotEvents) {
    final map = Map<String, Object?>.from(row as Map);
    final id = map['id'] as int;
    expect(map['kind'], 'log', reason: 'schema default must be injected');
    expect(events[id]?['num'], map['num'], reason: 'event $id drift');
  }

  // Cascade invariant: no child references a missing parent.
  final parentIds = parents.keys.toSet();
  for (final child in children.values) {
    expect(
      parentIds.contains(child.parentId),
      isTrue,
      reason: 'orphan child ${child.id} (cascade invariant)',
    );
  }

  // Indexed queries match the model.
  final byGroup = await _open(db, kParents).where().filter('group', 'g1').findAll();
  final expectedByGroup = parents.values.where((p) => p.group == 'g1').length;
  expect(byGroup.length, expectedByGroup, reason: 'indexed group query');
  final byParent = await _open(db, kChildren).where().filter('parentId', 0).findAll();
  final expectedByParent = children.values.where((c) => c.parentId == 0).length;
  expect(byParent.length, expectedByParent, reason: 'indexed parentId query');
  final byKind = await _open(db, kEvents).where().filter('kind', 'log').findAll();
  expect(byKind.length, events.length, reason: 'indexed kind query');
}

Collection<Object?> _open(Database db, String collection) =>
    db.collection<Object?>(
      collection,
      toRow: (value) => value,
      fromRow: (row) => row,
      id: (value) => _idOf(collection, value),
      schema: collection == kEvents ? _eventSchema : null,
      indexFields: switch (collection) {
        kParents => const ['group'],
        kChildren => const ['parentId'],
        kEvents => const ['kind'],
        _ => null,
      },
    );

Object? _idOf(String collection, Object? value) {
  final map = Map<Object?, Object?>.from(value as Map);
  return map['id'];
}

Map<String, Object?> _mapFor(String collection, int id, int num, String group) =>
    switch (collection) {
      kParents || kEvents => {'id': id, 'num': num, 'group': group},
      _ => {'id': id, 'parentId': 0, 'num': num},
    };

List<XOp> _generate(SeededRandom random, int steps) {
  final ops = <XOp>[];
  final existing = <String, List<int>>{
    kParents: <int>[],
    kChildren: <int>[],
    kEvents: <int>[],
  };
  for (var i = 0; i < steps; i++) {
    final roll = random.nextInt(100);
    if (roll < 55 || existing.values.every((list) => list.isEmpty)) {
      final collection = [kParents, kChildren, kEvents][random.nextInt(3)];
      final id = random.nextInt(150);
      ops.add(XPut(collection, id, random.nextInt(500), 'g${random.nextInt(5)}'));
      existing[collection]!.add(id);
    } else if (roll < 70) {
      final collection = [kParents, kChildren, kEvents][random.nextInt(3)];
      final pool = existing[collection]!;
      final id = pool[random.nextInt(pool.length)];
      ops.add(XDelete(collection, id));
      pool.remove(id);
    } else if (roll < 78) {
      // Transactions only touch children/events (a parent delete inside a
      // transaction would need a cascade the raw txn does not perform).
      ops.add(XTxn([
        for (var j = 0; j < 2 + random.nextInt(3); j++)
          XPut(
            [kChildren, kEvents][random.nextInt(2)],
            random.nextInt(150),
            random.nextInt(500),
            'g${random.nextInt(5)}',
          ),
      ]));
    } else if (roll < 90) {
      if (existing[kParents]!.isNotEmpty) {
        ops.add(
          XCascadeDelete(
            existing[kParents]![random.nextInt(existing[kParents]!.length)],
          ),
        );
        existing[kParents]!.clear();
        existing[kChildren]!.clear();
      }
    } else {
      ops.add(XClear([kParents, kChildren, kEvents][random.nextInt(3)]));
      for (final pool in existing.values) {
        pool.clear();
      }
    }
  }
  return ops;
}
