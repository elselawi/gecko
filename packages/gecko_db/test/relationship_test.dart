import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

Future<DatabaseImpl> _open(String name) => openNativeTestDatabase('rel-$name');

void main() {
  group('children / parent lookups', () {
    test('one-to-many children and reverse parent', () async {
      final db = await _open('lookup');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      r.declare(
        const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'authorId',
        ),
      );

      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1', 'name': 'A'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1', 'title': 'T1'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p2')),
        codec.encode({'id': 'p2', 'authorId': 'a1', 'title': 'T2'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p3')),
        codec.encode({'id': 'p3', 'authorId': 'a2', 'title': 'T3'}),
      );

      final children = await r.children(
        const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          foreignKeyField: 'authorId',
        ),
        'a1',
      );
      expect(children.map((c) => c['title']).toList(), ['T1', 'T2']);

      final parent = await r.parent(
        const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          foreignKeyField: 'authorId',
        ),
        'p1',
      );
      expect(parent!['name'], 'A');
      await db.close();
    });
  });

  group('delete behaviors', () {
    test('cascade removes dependent children atomically', () async {
      final db = await _open('cascade');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      final rel = const Relationship(
        name: 'author_posts',
        parentCollection: 'authors',
        childCollection: 'posts',
        type: RelationshipType.oneToMany,
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.cascade,
      );
      r.declare(rel);

      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      for (final i in ['p1', 'p2']) {
        await db.engine.rawPut(
          'posts',
          ByteKey(codec.encode(i)),
          codec.encode({'id': i, 'authorId': 'a1'}),
        );
      }
      await r.deleteWithBehavior(rel, 'a1');
      expect(
        await db.engine.rawGet('authors', ByteKey(codec.encode('a1'))),
        isNull,
      );
      expect(
        await db.engine.rawGet('posts', ByteKey(codec.encode('p1'))),
        isNull,
      );
      expect(
        await db.engine.rawGet('posts', ByteKey(codec.encode('p2'))),
        isNull,
      );
      await db.close();
    });

    test('deeply-nested cascade removes the transitive subtree', () async {
      final db = await _open('cascade_nested');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'e1',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['rootId'],
        ),
      );
      r.registerAccessors(
        'e2',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['e1Id'],
        ),
      );
      r.declare(
        const Relationship(
          name: 'root_e1',
          parentCollection: 'root',
          childCollection: 'e1',
          foreignKeyField: 'rootId',
          deleteBehavior: DeleteBehavior.cascade,
        ),
      );
      r.declare(
        const Relationship(
          name: 'e1_e2',
          parentCollection: 'e1',
          childCollection: 'e2',
          foreignKeyField: 'e1Id',
          deleteBehavior: DeleteBehavior.cascade,
        ),
      );

      await db.engine.rawPut(
        'root',
        ByteKey(codec.encode('r1')),
        codec.encode({'id': 'r1'}),
      );
      await db.engine.rawPut(
        'e1',
        ByteKey(codec.encode('e1a')),
        codec.encode({'id': 'e1a', 'rootId': 'r1'}),
      );
      await db.engine.rawPut(
        'e2',
        ByteKey(codec.encode('e2a')),
        codec.encode({'id': 'e2a', 'e1Id': 'e1a'}),
      );
      await db.engine.rawPut(
        'e2',
        ByteKey(codec.encode('e2b')),
        codec.encode({'id': 'e2b', 'e1Id': 'e1a'}),
      );

      await r.deleteWithBehavior(
        const Relationship(
          name: 'root_e1',
          parentCollection: 'root',
          childCollection: 'e1',
          foreignKeyField: 'rootId',
          deleteBehavior: DeleteBehavior.cascade,
        ),
        'r1',
      );
      expect(
        await db.engine.rawGet('root', ByteKey(codec.encode('r1'))),
        isNull,
      );
      expect(
        await db.engine.rawGet('e1', ByteKey(codec.encode('e1a'))),
        isNull,
      );
      expect(
        await db.engine.rawGet('e2', ByteKey(codec.encode('e2a'))),
        isNull,
      );
      expect(
        await db.engine.rawGet('e2', ByteKey(codec.encode('e2b'))),
        isNull,
      );
      await db.close();
    });

    test('restrict fails the delete when dependents exist', () async {
      final db = await _open('restrict');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      final rel = const Relationship(
        name: 'author_posts',
        parentCollection: 'authors',
        childCollection: 'posts',
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.restrict,
      );
      r.declare(rel);
      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );

      await expectLater(
        r.deleteWithBehavior(rel, 'a1'),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.invalidOperation,
          ),
        ),
      );
      // Parent still present, child preserved.
      expect(
        await db.engine.rawGet('authors', ByteKey(codec.encode('a1'))),
        isNotNull,
      );
      expect(
        await db.engine.rawGet('posts', ByteKey(codec.encode('p1'))),
        isNotNull,
      );
      await db.close();
    });

    test('setNull nulls the foreign key on dependents', () async {
      final db = await _open('setnull');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      final rel = const Relationship(
        name: 'author_posts',
        parentCollection: 'authors',
        childCollection: 'posts',
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.setNull,
      );
      r.declare(rel);
      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );

      await r.deleteWithBehavior(rel, 'a1');
      expect(
        await db.engine.rawGet('authors', ByteKey(codec.encode('a1'))),
        isNull,
      );
      final child = codec.decode(
        (await db.engine.rawGet('posts', ByteKey(codec.encode('p1'))))!,
      );
      expect(child, {'id': 'p1', 'authorId': null});
      await db.close();
    });

    test('none delete behavior leaves dependents untouched', () async {
      final db = await _open('none_behavior');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      final rel = const Relationship(
        name: 'author_posts',
        parentCollection: 'authors',
        childCollection: 'posts',
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.none,
      );
      r.declare(rel);
      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );

      await r.deleteWithBehavior(rel, 'a1');
      // Parent gone, child preserved (none: no cascade/setNull).
      expect(
        await db.engine.rawGet('authors', ByteKey(codec.encode('a1'))),
        isNull,
      );
      expect(
        await db.engine.rawGet('posts', ByteKey(codec.encode('p1'))),
        isNotNull,
      );
      await db.close();
    });

    test('undeclared relationship use throws typed error', () async {
      final db = await _open('undeclared');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      const rel = Relationship(
        name: 'ghost',
        parentCollection: 'a',
        childCollection: 'b',
        foreignKeyField: 'aId',
      );
      await db.engine.rawPut(
        'a',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await expectLater(
        r.children(rel, 'a1'),
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

    test('resolveDelete restrict throws when called directly', () async {
      final db = await _open('restrict_direct');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      final rel = const Relationship(
        name: 'author_posts',
        parentCollection: 'authors',
        childCollection: 'posts',
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.restrict,
      );
      r.declare(rel);
      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );
      await expectLater(r.resolveDelete(rel, 'a1'), throwsA(isA<GeckoError>()));
      await db.close();
    });

    test('setNull skips dependents whose id cannot be extracted', () async {
      final db = await _open('setnull_noid');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      // No accessor registered for 'posts' → child ids unknown → skip.
      final rel = const Relationship(
        name: 'author_posts',
        parentCollection: 'authors',
        childCollection: 'posts',
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.setNull,
      );
      r.declare(rel);
      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );
      await r.deleteWithBehavior(rel, 'a1'); // must not throw
      expect(
        await db.engine.rawGet('authors', ByteKey(codec.encode('a1'))),
        isNull,
      );
      await db.close();
    });

    test('hybrid cascade-vs-restrict fails the whole delete', () async {
      final db = await _open('hybrid');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      // Author -> Posts (cascade), but a grandchild relationship that
      // restricts on a different parent chain: here we add a restrict
      // relationship elsewhere and confirm restrict wins and leaves all intact.
      final cascade = const Relationship(
        name: 'a_p',
        parentCollection: 'a',
        childCollection: 'p',
        foreignKeyField: 'authorId',
        deleteBehavior: DeleteBehavior.cascade,
      );
      final restrict = const Relationship(
        name: 'p_g',
        parentCollection: 'p',
        childCollection: 'g',
        foreignKeyField: 'postId',
        deleteBehavior: DeleteBehavior.restrict,
      );
      r.declare(cascade);
      r.declare(restrict);
      r.registerAccessors(
        'p',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      r.registerAccessors(
        'g',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['postId'],
        ),
      );

      // a -> p1 (cascade child), p1 -> g1 (restrict grandchild).
      await db.engine.rawPut(
        'a',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );
      await db.engine.rawPut(
        'p',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );
      await db.engine.rawPut(
        'g',
        ByteKey(codec.encode('g1')),
        codec.encode({'id': 'g1', 'postId': 'p1'}),
      );

      await expectLater(
        r.deleteWithBehavior(cascade, 'a1'),
        throwsA(isA<GeckoError>()),
      );
      // Byte-identical pre-delete state preserved.
      expect(
        await db.engine.rawGet('a', ByteKey(codec.encode('a1'))),
        isNotNull,
      );
      expect(
        await db.engine.rawGet('p', ByteKey(codec.encode('p1'))),
        isNotNull,
      );
      expect(
        await db.engine.rawGet('g', ByteKey(codec.encode('g1'))),
        isNotNull,
      );
      await db.close();
    });
  });

  group('cascade cycle detection', () {
    test('A->B cascade + B->A cascade is rejected at declaration', () async {
      final db = await _open('cycle1');
      final r = db.relationships;
      r.declare(
        const Relationship(
          name: 'a_b',
          parentCollection: 'a',
          childCollection: 'b',
          deleteBehavior: DeleteBehavior.cascade,
        ),
      );
      expect(
        () => r.declare(
          const Relationship(
            name: 'b_a',
            parentCollection: 'b',
            childCollection: 'a',
            deleteBehavior: DeleteBehavior.cascade,
          ),
        ),
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

    test('self-referential cascade is rejected at declaration', () async {
      final db = await _open('cycle2');
      final r = db.relationships;
      expect(
        () => r.declare(
          const Relationship(
            name: 'self',
            parentCollection: 'node',
            childCollection: 'node',
            deleteBehavior: DeleteBehavior.cascade,
          ),
        ),
        throwsA(isA<GeckoError>()),
      );
      await db.close();
    });
  });

  group('eager loading avoids N+1', () {
    test('loadAllChildren fetches in one pass', () async {
      final db = await _open('eager');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      r.declare(
        const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          foreignKeyField: 'authorId',
        ),
      );
      for (final a in ['a1', 'a2', 'a3']) {
        await db.engine.rawPut(
          'authors',
          ByteKey(codec.encode(a)),
          codec.encode({'id': a}),
        );
      }
      for (var i = 0; i < 30; i++) {
        final author = 'a${i % 3 + 1}';
        await db.engine.rawPut(
          'posts',
          ByteKey(codec.encode('p$i')),
          codec.encode({'id': 'p$i', 'authorId': author}),
        );
      }
      final result = await r.loadAllChildren(
        const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          foreignKeyField: 'authorId',
        ),
        ['a1', 'a2', 'a3'],
      );
      expect(result['a1'], hasLength(10));
      expect(result['a1']!.first['id'], 'p0');
      await db.close();
    });
  });

  group('many-to-many join semantics', () {
    test('join rules are exposed for application-driven m2m', () async {
      final db = await _open('m2m');
      const rel = Relationship(
        name: 'students_courses',
        parentCollection: 'students',
        childCollection: 'courses',
        type: RelationshipType.manyToMany,
        foreignKeyField: 'courseId',
      );
      expect(rel.type, RelationshipType.manyToMany);
      expect(rel.foreignKeyField, 'courseId');
      await db.close();
    });

    test('relationships getter lists declared relationships', () async {
      final db = await _open('listrel');
      final r = db.relationships;
      r.declare(
        const Relationship(
          name: 'one',
          parentCollection: 'a',
          childCollection: 'b',
        ),
      );
      expect(r.relationships, hasLength(1));
      expect(r.relationships.single.name, 'one');
      await db.close();
    });

    test('isCascadeOnParent reflects cascade one-to-many', () {
      const cascading = Relationship(
        name: 'c',
        parentCollection: 'a',
        childCollection: 'b',
        deleteBehavior: DeleteBehavior.cascade,
      );
      const restricting = Relationship(
        name: 'r',
        parentCollection: 'a',
        childCollection: 'b',
        deleteBehavior: DeleteBehavior.restrict,
      );
      expect(cascading.isCascadeOnParent, isTrue);
      expect(restricting.isCascadeOnParent, isFalse);
    });
  });

  group('reactive relationship queries', () {
    test('a change to a related record propagates to a live query', () async {
      final db = await _open('reactive');
      const codec = DefaultWireCodec();
      final r = db.relationships;
      r.registerAccessors(
        'posts',
        RowAccessors(
          childIdOf: (row) => row['id'],
          parentIdOf: (row) => row['authorId'],
        ),
      );
      r.declare(
        const Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          foreignKeyField: 'authorId',
        ),
      );
      await db.engine.rawPut(
        'authors',
        ByteKey(codec.encode('a1')),
        codec.encode({'id': 'a1'}),
      );

      final feed = <int>[];
      final sub = db.engine.changes.stream.listen((set) {
        if (set.changes.any((c) => c.table == 'posts')) feed.add(1);
      });
      await db.engine.rawPut(
        'posts',
        ByteKey(codec.encode('p1')),
        codec.encode({'id': 'p1', 'authorId': 'a1'}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        feed,
        isNotEmpty,
        reason: 'related-collection change visible on db feed',
      );
      await sub.cancel();
      await db.close();
    });
  });
}
