import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _Rec {
  _Rec(this.id, this.name, [this.age]);
  final String id;
  final String name;
  final int? age;
}

Object? _toRow(_Rec r) => {
  'id': r.id,
  'name': r.name,
  if (r.age != null) 'age': r.age,
};
_Rec _fromRow(Object? row) {
  final m = row as Map;
  return _Rec(m['id'] as String? ?? '', m['name'] as String, m['age'] as int?);
}

Object? _recId(_Rec r) => r.id;

void main() {
  group('Phase 10 schema version stamping', () {
    test('new database starts unversioned; stamp is idempotent', () async {
      final db = await openNativeTestDatabase('p10a');
      expect(await db.schema.readVersion(), 0);
      await db.schema.stamp(3);
      await db.schema.stamp(3); // idempotent
      expect(await db.schema.readVersion(), 3);
      await db.close();
    });

    test('requiresUpgrade flags newer-than-known versions', () async {
      final db = await openNativeTestDatabase(
        'p10b',
        config: const DatabaseConfig(maxKnownSchemaVersion: 4),
      );
      expect(db.schema.requiresUpgrade(3, maxKnownVersion: 4), isFalse);
      expect(db.schema.requiresUpgrade(5, maxKnownVersion: 4), isTrue);
      await db.close();
    });
  });

  group('Phase 10 multi-step migration', () {
    test(
      'consecutive steps run in order to the final version and shape',
      () async {
        final db = await openNativeTestDatabase('p10c');
        final col = db.collection<_Rec>(
          'items',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _recId,
        );
        await col.put(_Rec('a', 'Alice', 30));
        await db.schema.stamp(1);

        final plan = MigrationPlan(
          targetVersion: 3,
          steps: const [
            MigrationStep(
              name: 'add-age',
              fromVersion: 1,
              toVersion: 2,
              rewritesRecords: false, // additive: no rewrite
            ),
            MigrationStep(
              name: 'rename-status',
              fromVersion: 2,
              toVersion: 3,
              rewritesRecords: true,
              collection: 'items',
              upgrade: _addStatusField,
            ),
          ],
        );
        final (applied, target) = await db.schema.migrate(plan);
        expect(applied, 2);
        expect(target, 3);
        expect(await db.schema.readVersion(), 3);
        // Records rewritten to the final shape.
        final raw = await db.rawGet(
          'items',
          ByteKey(DefaultWireCodec().encode('a')),
        );
        final row = DefaultWireCodec().decode(raw!) as Map;
        expect(row['status'], 'active');
        expect(row['name'], 'Alice');
        await db.close();
      },
    );

    test(
      'a failing step rolls back only itself; prior steps stay applied',
      () async {
        final db = await openNativeTestDatabase('p10d');
        final col = db.collection<_Rec>(
          'items',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _recId,
        );
        await col.put(_Rec('a', 'Alice', 30));
        await db.schema.stamp(1);
        final good = const MigrationStep(
          name: 'good-step',
          fromVersion: 1,
          toVersion: 2,
          rewritesRecords: false,
        );
        await db.schema.migrateStep(good);
        expect(await db.schema.readVersion(), 2);

        final failing = MigrationStep(
          name: 'failing-step',
          fromVersion: 2,
          toVersion: 3,
          rewritesRecords: true,
          collection: 'items',
          upgrade: (_) => throw StateError('boom'),
        );
        await expectLater(
          db.schema.migrateStep(failing),
          throwsA(
            isA<GeckoError>()
                .having((e) => e.type, 'type', GeckoErrorType.migration)
                .having((e) => e.message, 'message', contains('on record a')),
          ),
        );
        // Prior committed step still applied; the failing step did not advance.
        expect(await db.schema.readVersion(), 2);
        await db.close();
      },
    );

    test('wrong from-version is a typed migration error', () async {
      final db = await openNativeTestDatabase('p10e');
      await db.schema.stamp(1);
      final step = const MigrationStep(
        name: 'skip',
        fromVersion: 2,
        toVersion: 3,
      );
      await expectLater(
        db.schema.migrateStep(step),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.migration,
          ),
        ),
      );
      expect(await db.schema.readVersion(), 1);
      await db.close();
    });
  });

  group('Phase 10 chained migration and stable IDs', () {
    test('v1 to v3 chain keeps record IDs stable across a rewrite', () async {
      final db = await openNativeTestDatabase('p10i');
      final col = db.collection<_Rec>(
        'items',
        toRow: _toRow,
        fromRow: _fromRow,
        id: _recId,
      );
      final ids = <Object?>[];
      for (var i = 0; i < 20; i++) {
        ids.add(await col.put(_Rec('r$i', 'n$i')));
      }
      await db.schema.stamp(1);
      final chain = MigrationPlan(
        targetVersion: 3,
        steps: const [
          MigrationStep(
            name: 'add-nick',
            fromVersion: 1,
            toVersion: 2,
            rewritesRecords: false,
          ),
          MigrationStep(
            name: 'rename-status',
            fromVersion: 2,
            toVersion: 3,
            rewritesRecords: true,
            collection: 'items',
            upgrade: _addStatusField,
          ),
        ],
      );
      await db.schema.migrate(chain);
      expect(await db.schema.readVersion(), 3);
      // Every record keeps its original id after the chained migration.
      final all = await col.getAll();
      expect(all.length, 20);
      expect(all.map((r) => r.id).toSet(), ids.toSet());
      await db.close();
    });
  });

  group('Phase 10 additive fast path (no full rewrite)', () {
    test(
      'additive migration bumps version without rewriting any record',
      () async {
        final db = await openNativeTestDatabase('p10f');
        final col = db.collection<_Rec>(
          'items',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _recId,
        );
        await col.put(_Rec('a', 'Alice', 30));
        final beforeBytes = await db.rawGet(
          'items',
          ByteKey(DefaultWireCodec().encode('a')),
        );
        await db.schema.stamp(1);
        final additive = const MigrationStep(
          name: 'add-nick',
          fromVersion: 1,
          toVersion: 2,
          rewritesRecords: false,
        );
        await db.schema.migrateStep(additive);
        expect(await db.schema.readVersion(), 2);
        // Row is byte-identical: never rewritten by the additive path.
        final afterBytes = await db.rawGet(
          'items',
          ByteKey(DefaultWireCodec().encode('a')),
        );
        expect(afterBytes, beforeBytes);
        await db.close();
      },
    );

    test(
      'old-schema record stays readable and lazily interpreted (missing field)',
      () async {
        final db = await openNativeTestDatabase('p10g');
        final col = db.collection<_Rec>(
          'items',
          toRow: _toRow,
          fromRow: _fromRow,
          id: _recId,
        );
        // Put a record missing the new field entirely.
        await col.put(_Rec('a', 'Alice', 30));
        final raw = await db.rawGet(
          'items',
          ByteKey(DefaultWireCodec().encode('a')),
        );
        final row = DefaultWireCodec().decode(raw!) as Map;
        expect(row.containsKey('nick'), isFalse, reason: 'field is missing');
        expect(row['name'], 'Alice');
        await db.close();
      },
    );
  });

  group('Phase 10 open-time compatibility gate', () {
    test(
      'opening a newer-versioned file fails with typed upgradeRequired',
      () async {
        final root = await Directory.systemTemp.createTemp('gecko-p10-');
        final path = '${root.path}${Platform.pathSeparator}db.redb';
        final repositoryRoot = Directory.current.path.endsWith('gecko_db')
            ? Directory.current.parent.parent.path
            : Directory.current.path;
        final nativeLibraryName = Platform.isWindows
            ? 'gecko_db_rust.dll'
            : Platform.isMacOS
            ? 'libgecko_db_rust.dylib'
            : 'libgecko_db_rust.so';
        final nativePath =
            '$repositoryRoot${Platform.pathSeparator}rust${Platform.pathSeparator}'
            'target${Platform.pathSeparator}release${Platform.pathSeparator}'
            '$nativeLibraryName';
        final config = DatabaseConfig(
          nativeLibraryPath: nativePath,
          maxKnownSchemaVersion: 2,
        );

        try {
          final first = await DatabaseImpl.open(
            path,
            config: config,
          );
          await first.schema.stamp(5);
          await first.close();

          // Reopen with a build that only understands up to version 2.
          await expectLater(
            DatabaseImpl.open(path, config: config),
            throwsA(
              isA<GeckoError>().having(
                (e) => e.type,
                'type',
                GeckoErrorType.upgradeRequired,
              ),
            ),
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

Object? _addStatusField(Object? row) {
  if (row is! Map) return row;
  final out = Map<Object?, Object?>.from(row);
  if (!out.containsKey('status')) out['status'] = 'active';
  return out;
}
