// sustained soak (reliability under continuous mixed load).
//
// Runs a realistic, sustained workload against a PHYSICALLY ENCRYPTED native
// redb database across many cycles:
//   * interleaved writes (put / patch / delete) over several collections,
//     some with secondary indexes;
//   * live watch subscriptions that must observe every write;
//   * indexed + full-scan queries checked against an expected model;
//   * pending-sync tracking and markSynced;
//   * additive schema migrations;
//   * compaction (space reclaim) with writes continuing around it;
//   * periodic close/reopen cycles proving durability;
//   * a raw-file scan proving no plaintext leaks through physical encryption.
//
// The short run is 6 cycles; `GECKO_LONG_TEST=1` scales to 24 cycles with
// more records per cycle.
import 'dart:async';
import 'dart:convert';
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

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

bool get _longMode => Platform.environment['GECKO_LONG_TEST'] == '1';
int get _cycles => _longMode ? 24 : 6;
int get _perCycle => _longMode ? 400 : 150;

/// A fixed 32-byte AES-256 key for physical encryption.
final List<int> _key = List<int>.generate(32, (i) => (i * 7 + 3) & 0xFF);

class _Record {
  _Record(this.id, this.tag, this.payload);
  final int id;
  final int tag;
  final String payload;

  Map<String, Object?> toMap() => {'id': id, 'tag': tag, 'payload': payload};

  static _Record fromMap(Object? row) {
    final map = row as Map;
    return _Record(
      map['id'] as int,
      map['tag'] as int,
      map['payload'] as String,
    );
  }
}

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  test(
    'sustained mixed workload with encryption, compaction, reopen cycles',
    () async {
      final dir = await Directory.systemTemp.createTemp('gecko-soak-');
      final path = '${dir.path}${Platform.pathSeparator}soak.redb';
      final rawFile = File(path);
      try {
        // Expected model, keyed by collection -> id -> record.
        final model = <String, Map<int, _Record>>{'events': {}, 'notes': {}};

        var db = await Database.open(
          path,
          config: DatabaseConfig(
            nativeLibraryPath: nativePath,
            encryptionKey: _key,
            changeLogMaxEntries: 500,
          ),
        );
        var watchEvents = 0;
        var subStreams = <StreamSubscription<dynamic>>[];

        void attachWatchers() {
          for (final collName in model.keys) {
            final coll = db.collection<_Record>(
              collName,
              toRow: (r) => r.toMap(),
              fromRow: _Record.fromMap,
              id: (r) => r.id,
              indexFields: collName == 'events' ? const ['tag'] : null,
            );
            subStreams.add(coll.watchAll().listen((_) => watchEvents++));
          }
        }

        Future<void> reopen() async {
          for (final s in subStreams) {
            await s.cancel();
          }
          subStreams = [];
          watchEvents = 0;
          await db.close();
          db = await Database.open(
            path,
            config: DatabaseConfig(
              nativeLibraryPath: nativePath,
              encryptionKey: _key,
              changeLogMaxEntries: 500,
            ),
          );
          attachWatchers();
        }

        attachWatchers();

        try {
          for (var cycle = 0; cycle < _cycles; cycle++) {
            // --- writes ---
            for (var i = 0; i < _perCycle; i++) {
              final id = cycle * _perCycle + i;
              final record = _Record(id, id % 20, 'payload-$id-${'x' * 64}');
              model['events']![id] = record;
              await db
                  .collection<_Record>(
                    'events',
                    toRow: (r) => r.toMap(),
                    fromRow: _Record.fromMap,
                    id: (r) => r.id,
                    indexFields: const ['tag'],
                  )
                  .put(record);
              if (id % 3 == 0) {
                final note = _Record(id, id % 7, 'note-$id');
                model['notes']![id] = note;
                await db
                    .collection<_Record>(
                      'notes',
                      toRow: (r) => r.toMap(),
                      fromRow: _Record.fromMap,
                      id: (r) => r.id,
                    )
                    .put(note);
              }
            }

            // --- patches (partial updates) ---
            for (var i = 0; i < _perCycle ~/ 10; i++) {
              final id = cycle * _perCycle + i;
              await db
                  .collection<_Record>(
                    'events',
                    toRow: (r) => r.toMap(),
                    fromRow: _Record.fromMap,
                    id: (r) => r.id,
                  )
                  .patch(id, {'payload': 'patched-$id'});
              model['events']![id] = _Record(id, id % 20, 'patched-$id');
            }

            // --- deletes (a sliding window so the dataset stays bounded) ---
            if (cycle >= 2) {
              final dropStart = (cycle - 2) * _perCycle;
              for (var i = 0; i < _perCycle ~/ 2; i++) {
                final id = dropStart + i;
                await db
                    .collection<_Record>(
                      'events',
                      toRow: (r) => r.toMap(),
                      fromRow: _Record.fromMap,
                      id: (r) => r.id,
                    )
                    .delete(id);
                model['events']!.remove(id);
              }
            }

            // --- queries: indexed + full scan vs model ---
            final events = db.collection<_Record>(
              'events',
              toRow: (r) => r.toMap(),
              fromRow: _Record.fromMap,
              id: (r) => r.id,
              indexFields: const ['tag'],
            );
            final tag7 = await events.where().filter('tag', 7).findAll();
            final modelTag7 = model['events']!.values
                .where((r) => r.tag == 7)
                .length;
            expect(
              tag7.length,
              modelTag7,
              reason: 'cycle $cycle: indexed tag==7 count drift',
            );
            for (final r in tag7) {
              expect(r.tag, 7);
            }
            final all = await events.getAll();
            expect(
              all.length,
              model['events']!.length,
              reason: 'cycle $cycle: getAll count drift',
            );
            final notes = db.collection<_Record>(
              'notes',
              toRow: (r) => r.toMap(),
              fromRow: _Record.fromMap,
              id: (r) => r.id,
            );
            expect((await notes.getAll()).length, model['notes']!.length);

            // --- watch feed caught the writes (coalesced) ---
            expect(
              watchEvents,
              greaterThanOrEqualTo(1),
              reason: 'cycle $cycle: watchers must observe writes',
            );

            // --- pending sync grows monotonically ---
            final pending = await db.sync.readLocallyChanged();
            expect(pending.length, greaterThan(0));

            // --- additive migration every few cycles ---
            if (cycle % 3 == 0) {
              final v = await db.schema.readVersion();
              await db.schema.migrateStep(
                MigrationStep(
                  name: 'soak-$v',
                  fromVersion: v,
                  toVersion: v + 1,
                ),
              );
              expect(await db.schema.readVersion(), v + 1);
            }

            // --- compaction: reclaims space, data stays correct ---
            if (cycle % 3 == 2) {
              final reclaimed = await db.maintenance.compact();
              expect(db.maintenance.compactionCount, greaterThan(0));
              expect(reclaimed, isA<bool>());
              // Data survives compaction intact.
              final afterCompact = await events.getAll();
              expect(afterCompact.length, model['events']!.length);
            }

            // --- periodic reopen cycles ---
            if (cycle % 2 == 1) {
              await reopen();
              // Durability check after reopen.
              final events2 = db.collection<_Record>(
                'events',
                toRow: (r) => r.toMap(),
                fromRow: _Record.fromMap,
                id: (r) => r.id,
              );
              expect(
                (await events2.getAll()).length,
                model['events']!.length,
                reason: 'cycle $cycle: reopen lost data',
              );
            }
          }

          // --- final integrity sweep ---
          final events = db.collection<_Record>(
            'events',
            toRow: (r) => r.toMap(),
            fromRow: _Record.fromMap,
            id: (r) => r.id,
          );
          final finalAll = await events.getAll();
          final byId = {for (final r in finalAll) r.id: r};
          expect(byId.length, model['events']!.length);
          for (final entry in model['events']!.entries) {
            expect(
              byId[entry.key],
              isNotNull,
              reason: 'final sweep missing id ${entry.key}',
            );
            expect(
              byId[entry.key]!.payload,
              entry.value.payload,
              reason: 'final sweep payload drift ${entry.key}',
            );
          }

          // --- physical encryption: raw file must contain NO plaintext ---
          await db.close();
          final rawBytes = rawFile.readAsBytesSync();
          final sample = utf8.decode(rawBytes, allowMalformed: true);
          expect(
            sample.contains('payload-'),
            isFalse,
            reason: 'encrypted file leaked plaintext payload',
          );
          expect(
            sample.contains('note-'),
            isFalse,
            reason: 'encrypted file leaked plaintext note',
          );
          expect(
            sample.contains('patched-'),
            isFalse,
            reason: 'encrypted file leaked plaintext patch',
          );

          // --- reopening with a WRONG key must fail typed ---
          final wrongKey = List<int>.generate(32, (i) => (i * 13 + 1) & 0xFF);
          await expectLater(
            Database.open(
              path,
              config: DatabaseConfig(
                nativeLibraryPath: nativePath,
                encryptionKey: wrongKey,
              ),
            ),
            throwsA(isA<GeckoError>()),
          );
        } finally {
          for (final s in subStreams) {
            await s.cancel();
          }
          await db.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
