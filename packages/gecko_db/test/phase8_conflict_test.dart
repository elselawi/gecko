import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

ConflictVersion _v(Map<String, Object?> value, {int? sequence}) =>
    ConflictVersion(value: value, sequence: sequence);

void main() {
  setUp(ConflictStrategy.restoreDefaults);

  group('Phase 8 pure strategies', () {
    test('last-write-wins, field merge, and manual review differ', () {
      final local = _v({'local': 1, 'same': 'l'}, sequence: 2);
      final remote = _v({'remote': 1, 'same': 'r'}, sequence: 3);
      expect(
        ConflictStrategy.resolve(ConflictStrategy.lastWriteWins, local, remote),
        const TypeMatcher<Resolution>(),
      );
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.lastWriteWins,
          local,
          remote,
        ).kind,
        ResolutionKind.useRemote,
      );
      final merged = ConflictStrategy.resolve(
        ConflictStrategy.fieldLevelMerge,
        local,
        remote,
      );
      expect(merged.kind, ResolutionKind.mergedValue);
      expect(merged.value, {'local': 1, 'remote': 1, 'same': 'r'});
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.manualReview,
          local,
          remote,
        ).kind,
        ResolutionKind.manualReview,
      );
    });

    test(
      'three-way merge preserves one-sided changes and remote-wins conflict',
      () {
        final base = _v({'a': 0, 'b': 0, 'c': 0});
        final local = _v({'a': 1, 'b': 2, 'c': 0});
        final remote = _v({'a': 3, 'b': 0, 'c': 4});
        final result = ConflictStrategy.resolve(
          ConflictStrategy.threeWayMerge,
          local,
          remote,
          base,
        );
        expect(result.value, {'a': 3, 'b': 2, 'c': 4});
      },
    );

    test('unknown names and empty registrations are typed errors', () {
      expect(
        () => ConflictStrategy.resolve('missing', _v({}), _v({})),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.conflict,
          ),
        ),
      );
      expect(
        () => ConflictStrategy.register(
          ' ',
          (_, __, ___) => const Resolution.useLocal(),
        ),
        throwsA(isA<GeckoError>()),
      );
    });

    test(
      'plugin registration uses the same path and last registration wins',
      () {
        ConflictStrategy.register('plugin', (local, remote, base) {
          expect(local.value, {'x': 1});
          expect(remote.value, {'x': 2});
          expect(base!.value, {'x': 0});
          return const Resolution.useLocal();
        });
        expect(
          ConflictStrategy.resolve(
            'plugin',
            _v({'x': 1}),
            _v({'x': 2}),
            _v({'x': 0}),
          ).kind,
          ResolutionKind.useLocal,
        );
        ConflictStrategy.register(
          'plugin',
          (_, __, ___) => const Resolution.useRemote(),
        );
        expect(
          ConflictStrategy.resolve('plugin', _v({}), _v({})).kind,
          ResolutionKind.useRemote,
        );
      },
    );

    test('strategies are deterministic and delete-wins for field merge', () {
      final deleted = const ConflictVersion.deleted(sequence: 2);
      final edited = _v({'x': 1}, sequence: 3);
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.fieldLevelMerge,
          deleted,
          edited,
        ).kind,
        ResolutionKind.delete,
      );
      final first = ConflictStrategy.resolve(
        ConflictStrategy.threeWayMerge,
        _v({'x': 1}),
        _v({'x': 2}),
      );
      final second = ConflictStrategy.resolve(
        ConflictStrategy.threeWayMerge,
        _v({'x': 1}),
        _v({'x': 2}),
      );
      expect(first.toString(), second.toString());
    });

    test('value objects expose copy and deferred state', () {
      const original = ConflictVersion(
        value: {'x': 1},
        sequence: 1,
        version: 1,
      );
      final copied = original.copyWith(
        value: {'x': 2},
        deleted: true,
        sequence: 2,
        version: 2,
      );
      expect(copied.value, {'x': 2});
      expect(copied.deleted, isTrue);
      expect(copied.sequence, 2);
      expect(copied.version, 2);
      expect(copied.toString(), contains('sequence=2'));
      const deferred = Resolution.manualReview();
      expect(deferred.isDeferred, isTrue);
      expect(const Resolution.useLocal().isDeferred, isFalse);
      final result = ConflictResolutionResult(
        record: const RecordRef('items', 'x'),
        local: original,
        remote: original,
        base: null,
        resolution: deferred,
      );
      expect(result.deferred, isTrue);
      expect(
        ConflictStrategy.isRegistered(ConflictStrategy.lastWriteWins),
        isTrue,
      );
    });

    test('last-write-wins supports ordered tokens and non-map fallback', () {
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.lastWriteWins,
          const ConflictVersion(version: 3),
          const ConflictVersion(version: 2),
        ).kind,
        ResolutionKind.useLocal,
      );
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.lastWriteWins,
          ConflictVersion(version: DateTime.utc(2026, 2)),
          ConflictVersion(version: DateTime.utc(2026, 1)),
        ).kind,
        ResolutionKind.useLocal,
      );
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.fieldLevelMerge,
          const ConflictVersion(value: 'local'),
          const ConflictVersion(value: 'remote'),
        ).kind,
        ResolutionKind.useRemote,
      );
    });

    test('three-way deletion and nested values remain deterministic', () {
      const base = ConflictVersion(value: {'x': 0});
      expect(
        ConflictStrategy.resolve(
          ConflictStrategy.threeWayMerge,
          const ConflictVersion.deleted(),
          base,
          base,
        ).kind,
        ResolutionKind.delete,
      );
      final nested = ConflictStrategy.resolve(
        ConflictStrategy.threeWayMerge,
        const ConflictVersion(
          value: {
            'x': [
              1,
              {'a': 2},
            ],
          },
        ),
        const ConflictVersion(
          value: {
            'x': [
              1,
              {'a': 2},
            ],
          },
        ),
        const ConflictVersion(
          value: {
            'x': [
              1,
              {'a': 2},
            ],
          },
        ),
      );
      expect(nested.value, {
        'x': [
          1,
          {'a': 2},
        ],
      });
    });
  });

  group('Phase 8 database resolution', () {
    Future<DatabaseImpl> open(String name) =>
        DatabaseImpl.open('mem://phase8-$name', useInMemory: true);

    test(
      'reads both versions and atomically applies remote resolution',
      () async {
        final db = await open('apply');
        final items = db.collection<Map<String, Object?>>(
          'items',
          toRow: (row) => row,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (row) => row['id'],
        );
        await items.put({'id': 'one', 'value': 'local'});
        final result = await db.conflicts.resolve(
          ConflictRequest(
            record: const RecordRef('items', 'one'),
            remote: const ConflictVersion(
              value: {'id': 'one', 'value': 'remote'},
              sequence: 5,
            ),
          ),
        );
        expect(result.resolution.kind, ResolutionKind.useRemote);
        expect((await items.get('one'))!['value'], 'remote');
        expect(await db.conflicts.readPending(), isEmpty);
        await db.close();
      },
    );

    test('manual conflicts preserve both versions and resolve later', () async {
      final db = await open('manual');
      final items = db.collection<Map<String, Object?>>(
        'items',
        toRow: (row) => row,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (row) => row['id'],
      );
      await items.put({'id': 'one', 'value': 'local'});
      final deferred = await db.conflicts.resolve(
        ConflictRequest(
          record: const RecordRef('items', 'one'),
          remote: const ConflictVersion(
            value: {'id': 'one', 'value': 'remote'},
          ),
        ),
        strategy: ConflictStrategy.manualReview,
      );
      final pending = deferred.preservedConflict!;
      expect((await db.conflicts.read(pending.conflictId))!.remote.value, {
        'id': 'one',
        'value': 'remote',
      });
      await db.conflicts.resolvePreserved(
        pending.conflictId,
        const Resolution.useRemote(),
      );
      expect((await items.get('one'))!['value'], 'remote');
      expect(await db.conflicts.read(pending.conflictId), isNull);
      await db.close();
    });

    test('schema-invalid resolution fails before any write', () async {
      final db = await open('schema');
      final schema = RowSchema.of({
        'required': const FieldSpec(name: 'required', required: true),
      });
      final items = db.collection<Map<String, Object?>>(
        'items',
        toRow: (row) => row,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (row) => row['id'],
        schema: schema,
      );
      await items.put({'id': 'one', 'required': 'local'});
      await expectLater(
        db.conflicts.resolve(
          ConflictRequest(
            record: const RecordRef('items', 'one'),
            remote: const ConflictVersion(value: {'id': 'one'}),
            schema: schema,
          ),
        ),
        throwsA(
          isA<GeckoError>().having(
            (e) => e.type,
            'type',
            GeckoErrorType.schemaValidation,
          ),
        ),
      );
      expect((await items.get('one'))!['required'], 'local');
      await db.close();
    });

    test('delete resolution is deterministic', () async {
      final db = await open('delete');
      final items = db.collection<Map<String, Object?>>(
        'items',
        toRow: (row) => row,
        fromRow: (row) => Map<String, Object?>.from(row as Map),
        id: (row) => row['id'],
      );
      await items.put({'id': 'one', 'value': 'local'});
      await db.conflicts.resolve(
        ConflictRequest(
          record: const RecordRef('items', 'one'),
          remote: const ConflictVersion.deleted(),
        ),
        strategy: ConflictStrategy.fieldLevelMerge,
      );
      expect(await items.get('one'), isNull);
      await db.close();
    });
  });
}
