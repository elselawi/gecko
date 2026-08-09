import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

Future<DatabaseImpl> _open(String name) =>
    DatabaseImpl.open('mem://rel6-$name', useInMemory: true);

void main() {
  group('Phase 6 many-to-many join table', () {
    test(
      'add/remove join entries atomically and query both directions',
      () async {
        final db = await _open('m2m');
        final r = db.relationships;
        r.declare(
          const Relationship(
            name: 'students_courses',
            parentCollection: 'students',
            childCollection: 'courses',
            type: RelationshipType.manyToMany,
            foreignKeyField: 'student_courses',
          ),
        );
        final rel = const Relationship(
          name: 'students_courses',
          parentCollection: 'students',
          childCollection: 'courses',
          type: RelationshipType.manyToMany,
          foreignKeyField: 'student_courses',
        );
        await r.addJoin(rel, 's1', 'c1');
        await r.addJoin(rel, 's1', 'c2');
        await r.addJoin(rel, 's2', 'c1');
        expect(await r.rightIds(rel, 's1'), containsAll(['c1', 'c2']));
        expect(await r.leftIds(rel, 'c1'), containsAll(['s1', 's2']));
        await r.removeJoin(rel, 's1', 'c2');
        expect(await r.rightIds(rel, 's1'), ['c1']);
        await db.close();
      },
    );

    test(
      'deleting a many-to-many side removes its join rows atomically',
      () async {
        final db = await _open('m2m-delete');
        final r = db.relationships;
        r.declare(
          const Relationship(
            name: 'students_courses',
            parentCollection: 'students',
            childCollection: 'courses',
            type: RelationshipType.manyToMany,
            foreignKeyField: 'student_courses',
          ),
        );
        final rel = const Relationship(
          name: 'students_courses',
          parentCollection: 'students',
          childCollection: 'courses',
          type: RelationshipType.manyToMany,
          foreignKeyField: 'student_courses',
        );
        await r.addJoin(rel, 's1', 'c1');
        await r.addJoin(rel, 's1', 'c2');
        const codec = DefaultWireCodec();
        await db.engine.rawPut(
          'students',
          ByteKey(codec.encode('s1')),
          codec.encode({'id': 's1'}),
        );
        await r.deleteWithBehavior(rel, 's1');
        expect(await r.rightIds(rel, 's1'), isEmpty);
        // The other side's join is untouched.
        expect(await r.leftIds(rel, 'c2'), isEmpty);
        await db.close();
      },
    );

    test(
      'non-many-to-many join operations are rejected with a typed error',
      () async {
        final db = await _open('m2m-reject');
        final r = db.relationships;
        r.declare(
          const Relationship(
            name: 'author_posts',
            parentCollection: 'authors',
            childCollection: 'posts',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'authorId',
          ),
        );
        final rel = const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'authorId',
        );
        expect(() => r.addJoin(rel, 'a1', 'p1'), throwsA(isA<GeckoError>()));
        await db.close();
      },
    );
  });

  group('Phase 6 restrict names the offending dependent', () {
    test(
      'a hybrid cascade->restrict delete names the restricting dependent',
      () async {
        final db = await _open('hybrid-name');
        const codec = DefaultWireCodec();
        final r = db.relationships;
        r.registerAccessors(
          'children',
          RowAccessors(
            childIdOf: (row) => row['id'],
            parentIdOf: (row) => row['parent'],
          ),
        );
        r.registerAccessors(
          'grandchildren',
          RowAccessors(
            childIdOf: (row) => row['id'],
            parentIdOf: (row) => row['parent'],
          ),
        );
        r.declare(
          const Relationship(
            name: 'parent_children',
            parentCollection: 'parents',
            childCollection: 'children',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'parent',
            deleteBehavior: DeleteBehavior.cascade,
          ),
        );
        r.declare(
          const Relationship(
            name: 'children_grandchildren',
            parentCollection: 'children',
            childCollection: 'grandchildren',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'parent',
            deleteBehavior: DeleteBehavior.restrict,
          ),
        );
        await db.engine.rawPut(
          'parents',
          ByteKey(codec.encode('p1')),
          codec.encode({'id': 'p1'}),
        );
        await db.engine.rawPut(
          'children',
          ByteKey(codec.encode('c1')),
          codec.encode({'id': 'c1', 'parent': 'p1'}),
        );
        await db.engine.rawPut(
          'grandchildren',
          ByteKey(codec.encode('gc1')),
          codec.encode({'id': 'gc1', 'parent': 'c1'}),
        );
        final parentChildren = const Relationship(
          name: 'parent_children',
          parentCollection: 'parents',
          childCollection: 'children',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'parent',
          deleteBehavior: DeleteBehavior.cascade,
        );
        await expectLater(
          r.deleteWithBehavior(parentChildren, 'p1'),
          throwsA(
            isA<GeckoError>()
                .having((e) => e.type, 'type', GeckoErrorType.invalidOperation)
                .having((e) => e.details, 'details', isNotEmpty),
          ),
        );
        // No partial cascade: parents and children remain.
        expect(
          await db.engine.rawGet('parents', ByteKey(codec.encode('p1'))),
          isNotNull,
        );
        expect(
          await db.engine.rawGet('children', ByteKey(codec.encode('c1'))),
          isNotNull,
        );
        await db.close();
      },
    );
  });

  group('Phase 6 application-controlled delete hook', () {
    test(
      'hook invoked exactly once per dependent, deterministic order',
      () async {
        final db = await _open('hook');
        const codec = DefaultWireCodec();
        final r = db.relationships;
        r.registerAccessors(
          'children',
          RowAccessors(
            childIdOf: (row) => row['id'],
            parentIdOf: (row) => row['parent'],
          ),
        );
        r.registerDeleteHook('children', (row, childId) async {
          final marker = row['marker'];
          return [
            RawPut(
              'children',
              ByteKey(codec.encode(childId)),
              codec.encode({'id': childId, 'parent': null, 'marker': marker}),
            ),
          ];
        });
        r.declare(
          const Relationship(
            name: 'parent_children',
            parentCollection: 'parents',
            childCollection: 'children',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'parent',
            deleteBehavior: DeleteBehavior.applicationControlled,
          ),
        );
        await db.engine.rawPut(
          'parents',
          ByteKey(codec.encode('p1')),
          codec.encode({'id': 'p1'}),
        );
        await db.engine.rawPut(
          'children',
          ByteKey(codec.encode('c1')),
          codec.encode({'id': 'c1', 'parent': 'p1', 'marker': 'x'}),
        );
        await db.engine.rawPut(
          'children',
          ByteKey(codec.encode('c2')),
          codec.encode({'id': 'c2', 'parent': 'p1', 'marker': 'y'}),
        );
        final rel = const Relationship(
          name: 'parent_children',
          parentCollection: 'parents',
          childCollection: 'children',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'parent',
          deleteBehavior: DeleteBehavior.applicationControlled,
        );
        await r.deleteWithBehavior(rel, 'p1');
        // Dependents survive with nulled FK (hook's decision, applied atomically).
        final c1 =
            codec.decode(
                  (await db.engine.rawGet(
                    'children',
                    ByteKey(codec.encode('c1')),
                  ))!,
                )
                as Map;
        expect(c1['parent'], isNull);
        expect(
          (await db.engine.rawGet('parents', ByteKey(codec.encode('p1')))),
          isNull,
        );
        await db.close();
      },
    );

    test('missing hook is a typed error', () async {
      final db = await _open('hook-missing');
      final r = db.relationships;
      r.registerAccessors(
        'children',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['parent'],
        ),
      );
      r.declare(
        const Relationship(
          name: 'parent_children',
          parentCollection: 'parents',
          childCollection: 'children',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'parent',
          deleteBehavior: DeleteBehavior.applicationControlled,
        ),
      );
      const codec = DefaultWireCodec();
      await db.engine.rawPut(
        'parents',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1'}),
      );
      await db.engine.rawPut(
        'children',
        ByteKey(codec.encode('c1')),
        codec.encode({'id': 'c1', 'parent': 'p1'}),
      );
      final rel = const Relationship(
        name: 'parent_children',
        parentCollection: 'parents',
        childCollection: 'children',
        type: RelationshipType.oneToMany,
        foreignKeyField: 'parent',
        deleteBehavior: DeleteBehavior.applicationControlled,
      );
      await expectLater(
        r.deleteWithBehavior(rel, 'p1'),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
      await db.close();
    });
  });

  group('Phase 6 cross-order batch integrity and orphan surfacing', () {
    test(
      'parent + children inserted in either order within one transaction',
      () async {
        final db = await _open('batch-orders');
        final r = db.relationships;
        r.registerAccessors(
          'children',
          RowAccessors(
            childIdOf: (row) => row['id'],
            parentIdOf: (row) => row['parent'],
          ),
        );
        r.declare(
          const Relationship(
            name: 'parent_children',
            parentCollection: 'parents',
            childCollection: 'children',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'parent',
            deleteBehavior: DeleteBehavior.cascade,
          ),
        );
        final rel = const Relationship(
          name: 'parent_children',
          parentCollection: 'parents',
          childCollection: 'children',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'parent',
          deleteBehavior: DeleteBehavior.cascade,
        );

        // children-first order: replacing a child whose parent appears later in
        // the same transaction must still be valid at commit (deferred FK check).
        await db.writeTxn((txn) async {
          await txn
              .collection<Map<String, Object?>>(
                'children',
                toRow: (m) => m,
                fromRow: (m) => Map<String, Object?>.from(m as Map),
                id: (m) => m['id'],
              )
              .put({'id': 'c1', 'parent': 'p1'});
          await txn
              .collection<Map<String, Object?>>(
                'parents',
                toRow: (m) => m,
                fromRow: (m) => Map<String, Object?>.from(m as Map),
                id: (m) => m['id'],
              )
              .put({'id': 'p1'});
        });
        final children = await r.children(rel, 'p1');
        expect(children.single['id'], 'c1');
        await db.close();
      },
    );

    test(
      'set-null deletion orphans the child, surfaced by orphan check',
      () async {
        final db = await _open('setnull-orphan');
        final r = db.relationships;
        r.registerAccessors(
          'children',
          RowAccessors(
            childIdOf: (row) => row['id'],
            parentIdOf: (row) => row['parent'],
          ),
        );
        r.declare(
          const Relationship(
            name: 'parent_children',
            parentCollection: 'parents',
            childCollection: 'children',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'parent',
            deleteBehavior: DeleteBehavior.setNull,
          ),
        );
        const codec = DefaultWireCodec();
        final rel = const Relationship(
          name: 'parent_children',
          parentCollection: 'parents',
          childCollection: 'children',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'parent',
          deleteBehavior: DeleteBehavior.setNull,
        );
        await db.engine.rawPut(
          'parents',
          ByteKey(codec.encode('p1')),
          codec.encode({'id': 'p1'}),
        );
        await db.engine.rawPut(
          'children',
          ByteKey(codec.encode('c1')),
          codec.encode({'id': 'c1', 'parent': 'p1'}),
        );
        await r.deleteWithBehavior(rel, 'p1');
        final child =
            codec.decode(
                  (await db.engine.rawGet(
                    'children',
                    ByteKey(codec.encode('c1')),
                  ))!,
                )
                as Map;
        expect(child['parent'], isNull, reason: 'setNull clears the FK');
        // The child now has no parent → orphaned per Phase 9 orphan semantics.
        final parentExists = await db.engine.rawGet(
          'parents',
          ByteKey(codec.encode('p1')),
        );
        expect(parentExists, isNull);
        await db.close();
      },
    );
  });
}
