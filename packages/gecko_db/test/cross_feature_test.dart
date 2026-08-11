// Audit-driven cross-feature combination tests (audited-test-gaps 2.20).

import 'dart:async';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

Collection<Map<String, Object?>> coll(
  DatabaseImpl db,
  String table, {
  List<String>? indexFields,
}) => db.collection<Map<String, Object?>>(
  table,
  toRow: (value) => value,
  fromRow: (row) => Map<String, Object?>.from(row as Map),
  id: (value) => value['id'],
  indexFields: indexFields,
);

const List<int> _testKey = [
  1,
  2,
  3,
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
];

void main() {
  test('encryption x index: indexed query works after reopen', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-x-enc-idx-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}db.redb';
    final db1 = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(encryptionKey: _testKey),
    );
    final c1 = coll(db1, 'items', indexFields: ['g']);
    await c1.put({'id': 'a', 'g': 'x'});
    await db1.close();

    final db2 = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(encryptionKey: _testKey),
    );
    final c2 = coll(db2, 'items', indexFields: ['g']);
    expect((await c2.where().filter('g', 'x').findAll()).map((r) => r['id']), [
      'a',
    ]);
    await db2.close();
  });

  test(
    'encryption x migration: migrateStep on an encrypted database',
    () async {
      final dir = await Directory.systemTemp.createTemp('gecko-x-enc-mig-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}db.redb';
      final db1 = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(encryptionKey: _testKey),
      );
      final c = coll(db1, 'items');
      await c.put({'id': 'a', 'n': 1});
      await db1.schema.migrateStep(
        const MigrationStep(name: 'v1', fromVersion: 0, toVersion: 1),
      );
      expect(await db1.schema.readVersion(), 1);
      await db1.close();

      final db2 = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(encryptionKey: _testKey),
      );
      expect(await db2.schema.readVersion(), 1);
      expect(await coll(db2, 'items').get('a'), isNotNull);
      await db2.close();
    },
  );

  test(
    'encryption x sync: change tracking works on an encrypted database',
    () async {
      final dir = await Directory.systemTemp.createTemp('gecko-x-enc-sync-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}${Platform.pathSeparator}db.redb';
      final db = await DatabaseImpl.open(
        path,
        config: DatabaseConfig(encryptionKey: _testKey),
      );
      final c = coll(db, 'items');
      await c.put({'id': 'a', 'n': 1});
      final pending = await db.sync.readLocallyChanged();
      expect(pending.map((p) => p.recordId), contains('a'));
      await db.sync.markSynced(['a']);
      expect(
        (await db.sync.readLocallyChanged()).map((p) => p.recordId),
        isNot(contains('a')),
      );
      await db.close();
    },
  );

  test('relationship cascade is one atomic batch (all-or-nothing)', () async {
    final db = await openNativeTestDatabase('x-rel-txn');
    final parents = coll(db, 'parents');
    final children = coll(db, 'children', indexFields: ['parentId']);
    db.relationships.registerAccessors(
      'children',
      RowAccessors(
        childIdOf: (row) => row['id'],
        parentIdOf: (row) => row['parentId'],
      ),
    );
    db.relationships.declare(
      const Relationship(
        name: 'parent-children',
        parentCollection: 'parents',
        childCollection: 'children',
        foreignKeyField: 'parentId',
        deleteBehavior: DeleteBehavior.cascade,
      ),
    );
    await parents.put({'id': 'p1'});
    await children.put({'id': 'c1', 'parentId': 'p1'});
    await children.put({'id': 'c2', 'parentId': 'p1'});
    // deleteWithBehavior collects the parent + all children deletes into one
    // write transaction.
    await db.relationships.deleteWithBehavior(
      const Relationship(
        name: 'parent-children',
        parentCollection: 'parents',
        childCollection: 'children',
        foreignKeyField: 'parentId',
        deleteBehavior: DeleteBehavior.cascade,
      ),
      'p1',
    );
    expect(await parents.get('p1'), isNull);
    expect(await children.get('c1'), isNull, reason: 'cascade');
    expect(await children.get('c2'), isNull, reason: 'cascade');
    await db.close();
  });

  test(
    'watch x compaction: compaction emits no spurious watch events',
    () async {
      final db = await openNativeTestDatabase('x-watch-compact');
      final c = coll(db, 'items');
      for (var i = 0; i < 50; i++) {
        await c.put({'id': 'k$i', 'payload': 'x' * 2000});
      }
      final emissions = <List<Map<String, Object?>>>[];
      final sub = c.watchAll().listen(emissions.add);
      // Let the initial snapshot arrive.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final before = emissions.length;
      await db.maintenance.compact();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // Compaction alone must not trigger re-emissions.
      expect(
        emissions.length,
        before,
        reason: 'compaction must not emit spurious watch events',
      );
      await sub.cancel();
      await db.close();
    },
  );

  test(
    'one bulk across two indexed tables stays atomic with correct indexes',
    () async {
      final db = await openNativeTestDatabase('x-bulk-two');
      final a = coll(db, 'tableA', indexFields: ['g']);
      final b = coll(db, 'tableB', indexFields: ['g']);
      final result = await db.bulkWrite([
        for (var i = 0; i < 10; i++)
          BulkMutation.put(
            table: 'tableA',
            key: 'a$i',
            value: {'id': 'a$i', 'g': 'ga'},
          ),
        for (var i = 0; i < 10; i++)
          BulkMutation.put(
            table: 'tableB',
            key: 'b$i',
            value: {'id': 'b$i', 'g': 'gb'},
          ),
      ]);
      expect(result.mutationCount, 20);
      // Both tables have all rows.
      expect(await a.getAll(), hasLength(10));
      expect(await b.getAll(), hasLength(10));
      // Both durable indexes are maintained.
      expect((await a.where().filter('g', 'ga').findAll()), hasLength(10));
      expect((await b.where().filter('g', 'gb').findAll()), hasLength(10));
      await db.close();
    },
  );

  test(
    'attachments x conflict: a parent resolved away orphans the attachment',
    () async {
      final db = await openNativeTestDatabase('x-att-conflict');
      final parents = coll(db, 'parents');
      await parents.put({'id': 'p1'});
      final meta = await db.attachments.create(
        parentCollection: 'parents',
        parentId: 'p1',
        filename: 'f.txt',
        fileType: 'text/plain',
        size: 3,
        contentHash: 'abc123',
      );
      // fieldLevelMerge is delete-wins: a deleted remote removes the parent.
      await db.conflicts.resolve(
        ConflictRequest(
          record: const RecordRef('parents', 'p1'),
          remote: const ConflictVersion.deleted(sequence: 5),
        ),
        strategy: ConflictStrategy.fieldLevelMerge,
      );
      expect(await parents.get('p1'), isNull);
      expect(
        (await db.attachments.orphaned()).map((m) => m.id),
        contains(meta.id),
        reason: 'parent removal via conflict must orphan the attachment',
      );
      await db.close();
    },
  );

  test('compaction x sync: the change log survives compaction', () async {
    final db = await openNativeTestDatabase('x-compact-sync');
    final c = coll(db, 'items');
    for (var i = 0; i < 20; i++) {
      await c.put({'id': 'k$i', 'payload': 'x' * 2000});
    }
    expect(await db.sync.readLocallyChanged(), hasLength(20));
    await db.maintenance.compact();
    final pending = await db.sync.readLocallyChanged();
    expect(
      pending,
      hasLength(20),
      reason: 'change log must survive compaction',
    );
    await db.sync.markSynced([for (var i = 0; i < 20; i++) 'k$i']);
    expect(await db.sync.readLocallyChanged(), isEmpty);
    await db.close();
  });

  test(
    'relationships x sync: cascade delete then remote-apply of a child',
    () async {
      final db = await openNativeTestDatabase('x-rel-sync');
      final parents = coll(db, 'parents');
      final children = coll(db, 'children', indexFields: ['parentId']);
      db.relationships.registerAccessors(
        'children',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['parentId'],
        ),
      );
      const rel = Relationship(
        name: 'parent-children',
        parentCollection: 'parents',
        childCollection: 'children',
        foreignKeyField: 'parentId',
        deleteBehavior: DeleteBehavior.cascade,
      );
      db.relationships.declare(rel);
      await parents.put({'id': 'p1'});
      await children.put({'id': 'c1', 'parentId': 'p1'});
      await children.put({'id': 'c2', 'parentId': 'p1'});

      // A remote delete lands through sync and removes the child normally.
      await db.sync.applyRemoteDeletion(['c1']);
      expect(await children.get('c1'), isNull, reason: 'remote delete');
      expect(await children.get('c2'), isNotNull);

      // Cascade delete of the parent now removes only the remaining child.
      await db.relationships.deleteWithBehavior(rel, 'p1');
      expect(await parents.get('p1'), isNull);
      expect(await children.get('c2'), isNull, reason: 'cascade');
      await db.close();
    },
  );

  test('encryption x relationships: cascade works across a reopen', () async {
    final dir = await Directory.systemTemp.createTemp('gecko-x-enc-rel-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}${Platform.pathSeparator}db.redb';

    final db1 = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(encryptionKey: _testKey),
    );
    final parents = coll(db1, 'parents');
    final children = coll(db1, 'children', indexFields: ['parentId']);
    db1.relationships.registerAccessors(
      'children',
      RowAccessors(
        childIdOf: (row) => row['id'],
        parentIdOf: (row) => row['parentId'],
      ),
    );
    const rel = Relationship(
      name: 'parent-children',
      parentCollection: 'parents',
      childCollection: 'children',
      foreignKeyField: 'parentId',
      deleteBehavior: DeleteBehavior.cascade,
    );
    db1.relationships.declare(rel);
    await parents.put({'id': 'p1'});
    await children.put({'id': 'c1', 'parentId': 'p1'});
    await db1.close();

    final db2 = await DatabaseImpl.open(
      path,
      config: DatabaseConfig(encryptionKey: _testKey),
    );
    final parents2 = coll(db2, 'parents');
    final children2 = coll(db2, 'children', indexFields: ['parentId']);
    db2.relationships.registerAccessors(
      'children',
      RowAccessors(
        childIdOf: (row) => row['id'],
        parentIdOf: (row) => row['parentId'],
      ),
    );
    db2.relationships.declare(rel);
    expect(await parents2.get('p1'), isNotNull, reason: 'data survives reopen');
    expect(await children2.get('c1'), isNotNull);
    await db2.relationships.deleteWithBehavior(rel, 'p1');
    expect(await parents2.get('p1'), isNull);
    expect(await children2.get('c1'), isNull, reason: 'cascade across reopen');
    await db2.close();
  });
}
