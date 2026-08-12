// Live smoke for the PUBLIC web open path (terry-perf Item 20).
//
// Main-thread Dart that calls the public `Database.open` API. On the main
// thread OPFS sync access handles are worker-only, so the public open path
// provisions the in-package dedicated worker (`gecko_db_worker.js`) and
// proxies every request to it over the transferable protocol. This suite
// proves the full Tier-1 cycle end-to-end:
//
//   open (provisions the worker) → put → get → query → watch → close → reopen
//
// plus worker-startup-failure handling (opening with a bogus worker URL must
// fail with a typed error, not hang). Prints `GECKO-PUBLIC-OPEN-OK` on success
// and writes the marker to the DOM for the CDP driver.
library;

import 'dart:html' as html;
import 'dart:async';

import 'package:gecko_db/gecko_db.dart';

const String kDbPath = 'public-open.db';

Future<void> main() async {
  final results = <String>[];
  void report(String line) {
    results.add(line);
    // ignore: avoid_print
    print(line);
  }

  try {
    // Worker URL override: the compiled worker is served at /gecko_db_worker.js
    // by serve.dart. This is the documented web meaning of nativeLibraryPath
    // on the main-thread open path.
    final config = DatabaseConfig(nativeLibraryPath: 'gecko_db_worker.js');

    // 1. Open (main thread → provisions the dedicated worker).
    final db = await DatabaseImpl.open(kDbPath, config: config);
    final c = db.collection<Map<String, Object?>>(
      'items',
      toRow: (value) => value,
      fromRow: (row) => Map<String, Object?>.from(row as Map),
      id: (value) => value['id'],
    );

    // 2. Write + read back.
    await c.put({'id': 'a', 'n': 1});
    await c.put({'id': 'b', 'n': 2});
    final readBack = await c.get('a');
    if (readBack?['n'] != 1) throw StateError('put/get round-trip failed: $readBack');

    // 3. Query (Tier 2).
    final found = await c.where({'n': 2}).findAll();
    if (found.length != 1 || found.single['id'] != 'b') {
      throw StateError('query failed: $found');
    }

    // 4. Watch: a change after listen must be delivered.
    final watchValues = <int>[];
    final watchSub = c.watch('a').listen((row) {
      watchValues.add(row?['n'] as int? ?? -1);
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await c.put({'id': 'a', 'n': 9});
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await watchSub.cancel();
    if (!watchValues.contains(9)) {
      throw StateError('watch did not deliver the update: $watchValues');
    }

    // 5. Close.
    await db.close();

    // 6. Reopen and verify persistence.
    final reopened = await DatabaseImpl.open(kDbPath, config: config);
    final after = await reopened
        .collection<Map<String, Object?>>(
          'items',
          toRow: (value) => value,
          fromRow: (row) => Map<String, Object?>.from(row as Map),
          id: (value) => value['id'],
        )
        .getAll();
    await reopened.close();
    if (after.length != 2) throw StateError('reopen lost rows: $after');

    // 7. Worker startup failure must surface as a typed error, not a hang.
    final bad = DatabaseImpl.open(
      kDbPath,
      config: DatabaseConfig(nativeLibraryPath: 'definitely-missing-worker.js'),
    );
    final badError = await bad.then<Object?>((_) => null).catchError(
      (Object error) => error,
    );
    if (badError == null) {
      throw StateError('missing worker URL did not fail open');
    }

    report('GECKO-PUBLIC-OPEN-OK');
  } catch (error, stackTrace) {
    report('GECKO-PUBLIC-OPEN-FAIL: $error');
    report(stackTrace.toString());
  }

  final out = html.document.getElementById('out');
  out?.text = results.join('\n');
  html.document.title = results.contains('GECKO-PUBLIC-OPEN-OK')
      ? 'GECKO-PUBLIC-OPEN-OK'
      : 'GECKO-PUBLIC-OPEN-FAIL';
}
