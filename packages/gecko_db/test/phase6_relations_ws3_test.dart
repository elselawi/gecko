// Workstream 3 — relationship integration: index-wired FK lookups, the single
// transaction coordinator (atomic delete with change-feed events), and
// reactive relationship queries. Runs against both backends.
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

/// Waits until [condition] holds (reactive streams deliver asynchronously;
/// native round-trips need more than one microtask).
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

/// Declares an authors → posts one-to-many with the FK field indexed on the
/// child collection.
void _declareAuthorsPosts(DatabaseImpl db, {required Relationship rel}) {
  final r = db.relationships;
  r.registerAccessors(
    'posts',
    RowAccessors(
      childIdOf: (row) => row['id'],
      parentIdOf: (row) => row['authorId'],
    ),
  );
  r.declare(rel);
}

void main() {
  final nativePath = _nativeLibraryPath(_repoRoot());

  void runSuite(String label, Future<DatabaseImpl> Function(String tag) open) {
    group('WS3 relationship integration ($label)', () {
      test(
        'FK child lookup uses the index when the FK field is indexed',
        () async {
          final db = await open('fk-index');
          const rel = Relationship(
            name: 'author_posts',
            parentCollection: 'authors',
            childCollection: 'posts',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'authorId',
          );
          // Index the FK field on the child collection.
          db.collection<Map<String, Object?>>(
            'posts',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
            indexFields: ['authorId'],
          );
          _declareAuthorsPosts(db, rel: rel);
          final authors = db.collection<Map<String, Object?>>(
            'authors',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          final posts = db.collection<Map<String, Object?>>(
            'posts',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          await authors.put({'id': 'a1'});
          for (var i = 0; i < 50; i++) {
            await posts.put({'id': 'p$i', 'authorId': 'a${i % 5}'});
          }
          final before = db.engine.scannedRows;
          final kids = await db.relationships.children(rel, 'a1');
          expect(kids, hasLength(10));
          expect(
            db.engine.scannedRows,
            before,
            reason: 'indexed FK lookup must not full-scan the child table',
          );
          await db.close();
        },
      );

      test(
        'coordinator publishes delete events and advances the LSN',
        () async {
          final db = await open('coordinator');
          final rel = Relationship(
            name: 'author_posts',
            parentCollection: 'authors',
            childCollection: 'posts',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'authorId',
            deleteBehavior: DeleteBehavior.cascade,
          );
          _declareAuthorsPosts(db, rel: rel);
          final authors = db.collection<Map<String, Object?>>(
            'authors',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          final posts = db.collection<Map<String, Object?>>(
            'posts',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          await authors.put({'id': 'a1'});
          await authors.put({'id': 'a2'});
          await posts.put({'id': 'p1', 'authorId': 'a1'});
          await posts.put({'id': 'p2', 'authorId': 'a1'});
          await posts.put({'id': 'p3', 'authorId': 'a2'});

          final feed = <ChangeSet>[];
          final sub = db.watchAll().listen(feed.add);
          await db.relationships.deleteWithBehavior(rel, 'a1');
          await Future<void>.delayed(Duration.zero);

          // Parent + both children deleted in one atomic coordinator batch.
          expect(await authors.get('a1'), isNull);
          expect(await posts.get('p1'), isNull);
          expect(await posts.get('p2'), isNull);
          expect(await posts.get('p3'), isNotNull);
          // The batch was published to the feed with delete events.
          final events = feed.expand((s) => s.changes).toList();
          final deleted = {
            for (final c in events)
              if (c.kind == ChangeKind.delete) '${c.table}:${c.key}',
          };
          expect(deleted, containsAll(['authors:a1', 'posts:p1', 'posts:p2']));
          expect(feed.last.sequence, greaterThan(0));
          await sub.cancel();
          await db.close();
        },
      );

      test('watchChildren re-emits on child and parent changes', () async {
        final db = await open('watch-children');
        const rel = Relationship(
          name: 'author_posts',
          parentCollection: 'authors',
          childCollection: 'posts',
          type: RelationshipType.oneToMany,
          foreignKeyField: 'authorId',
          deleteBehavior: DeleteBehavior.cascade,
        );
        _declareAuthorsPosts(db, rel: rel);
        final authors = db.collection<Map<String, Object?>>(
          'authors',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        final posts = db.collection<Map<String, Object?>>(
          'posts',
          toRow: (m) => m,
          fromRow: (m) => Map<String, Object?>.from(m as Map),
          id: (m) => m['id'],
        );
        await authors.put({'id': 'a1'});
        await posts.put({'id': 'p1', 'authorId': 'a1'});

        final emissions = <int>[];
        final sub = db.relationships
            .watchChildren(rel, 'a1')
            .listen((rows) => emissions.add(rows.length));
        await _until(() => emissions.isNotEmpty);
        expect(emissions.first, 1); // initial emission

        await posts.put({'id': 'p2', 'authorId': 'a1'}); // child change
        await _until(() => emissions.length >= 2);
        expect(emissions.last, 2);

        await posts.delete('p1'); // child change
        await _until(() => emissions.length >= 3);
        expect(emissions.last, 1);

        await authors.put({'id': 'a1', 'name': 'Renamed'}); // parent change
        final countBeforeParent = emissions.length;
        await _until(() => emissions.length > countBeforeParent);
        expect(emissions.last, 1); // re-emitted (same children)

        await sub.cancel();
        await db.close();
      });

      test(
        'native parent and eager child reads preserve snapshot and parity',
        () async {
          final db = await open('native-relationship-primitives');
          const rel = Relationship(
            name: 'author_posts',
            parentCollection: 'authors',
            childCollection: 'posts',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'authorId',
          );
          _declareAuthorsPosts(db, rel: rel);
          final authors = db.collection<Map<String, Object?>>(
            'authors',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          final posts = db.collection<Map<String, Object?>>(
            'posts',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
            indexFields: ['authorId'],
          );
          await authors.put({'id': 'a1', 'name': 'A'});
          await authors.put({'id': 'a2', 'name': 'B'});
          await posts.put({'id': 'p1', 'authorId': 'a1'});
          await posts.put({'id': 'p2', 'authorId': 'a2'});
          final parent = await db.relationships.parent(rel, 'p1');
          expect(parent?['name'], 'A');
          final grouped = await db.relationships.loadAllChildren(rel, [
            'a1',
            'a2',
          ]);
          expect(grouped['a1']!.map((row) => row['id']), ['p1']);
          expect(grouped['a2']!.map((row) => row['id']), ['p2']);
          await authors.put({'id': 'a1', 'name': 'A2'});
          final parentAfter = await db.relationships.parent(rel, 'p1');
          expect(parentAfter?['name'], 'A2');
          expect(await db.relationships.parent(rel, 'missing'), isNull);
          await db.close();
        },
      );

      test(
        'watchParent and watchJoinIds re-emit on the relevant side',
        () async {
          final db = await open('watch-parent-join');
          const rel = Relationship(
            name: 'author_posts',
            parentCollection: 'authors',
            childCollection: 'posts',
            type: RelationshipType.oneToMany,
            foreignKeyField: 'authorId',
          );
          _declareAuthorsPosts(db, rel: rel);
          final authors = db.collection<Map<String, Object?>>(
            'authors',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          final posts = db.collection<Map<String, Object?>>(
            'posts',
            toRow: (m) => m,
            fromRow: (m) => Map<String, Object?>.from(m as Map),
            id: (m) => m['id'],
          );
          await authors.put({'id': 'a1', 'name': 'A'});
          await posts.put({'id': 'p1', 'authorId': 'a1'});

          final parentNames = <String?>[];
          final psub = db.relationships
              .watchParent(rel, 'p1')
              .listen((row) => parentNames.add(row?['name'] as String?));
          await _until(() => parentNames.isNotEmpty);
          expect(parentNames.first, 'A');
          await authors.put({'id': 'a1', 'name': 'B'});
          await _until(() => parentNames.length >= 2);
          expect(parentNames.last, 'B');
          await psub.cancel();

          // Many-to-many join ids.
          final join = Relationship(
            name: 'students_courses',
            parentCollection: 'students',
            childCollection: 'courses',
            type: RelationshipType.manyToMany,
            foreignKeyField: '__gecko_join_students_courses',
          );
          db.relationships.declare(join);
          await db.relationships.addJoin(join, 's1', 'c1');
          final ids = <List<Object?>>[];
          final jsub = db.relationships
              .watchJoinIds(join, 's1')
              .listen((right) => ids.add(right));
          await _until(() => ids.isNotEmpty);
          expect(ids.first, ['c1']);
          await db.relationships.addJoin(join, 's1', 'c2');
          await _until(() => ids.isNotEmpty && ids.last.length == 2);
          expect(ids.last.toSet(), {'c1', 'c2'});
          await jsub.cancel();
          await db.close();
        },
      );
    });
  }

  runSuite('native file', (tag) async {
    final dir = await Directory.systemTemp.createTemp('gecko-ws3r-$tag-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    return DatabaseImpl.open(
      '${dir.path}${Platform.pathSeparator}db.redb',
      useInMemory: false,
      config: DatabaseConfig(nativeLibraryPath: nativePath),
    );
  });
}
