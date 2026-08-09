// Web smoke test for the gecko_db FRB wasm engine.
//
// Compiled with `dart compile js` and run in headless Chrome. Exercises the
// full public API against the *native* (Rust, redb) engine running on wasm —
// the Dart in-memory engine is deliberately NOT used. On success it prints
// `WEB-SMOKE-OK` to the console and writes the marker to the DOM so both
// `--dump-dom` and `--enable-logging=stderr` capture it.
//
// Usage (see tool/web_smoke/README.md):
//   dart compile js tool/web_smoke/web_smoke.dart -o build/web_smoke/app.js
//   (serve build/web_smoke/ + glue, then headless Chrome)
library;

import 'dart:html' as html;

import 'package:gecko_db/gecko_db.dart';

Future<void> main() async {
  final results = <String>[];
  void report(String line) {
    results.add(line);
    // ignore: avoid_print
    print(line);
  }

  try {
    // `:memory:` selects the native redb in-memory backend on wasm (no OPFS
    // handle needed on the main thread).
    final db = await Database.open(':memory:', config: const DatabaseConfig());

    Collection<String> notes() => db.collection<String>(
      'notes',
      toRow: (value) => value,
      fromRow: (row) => row as String,
      id: (value) => value,
    );

    await notes().put('hello from wasm');
    await notes().put('second row');
    final readBack = await notes().get('hello from wasm');
    if (readBack != 'hello from wasm') {
      throw StateError('read-back mismatch: $readBack');
    }

    final all = await notes().getAll();
    if (all.length != 2) {
      throw StateError('expected 2 rows, got ${all.length}');
    }

    // Exercise a transaction + a query against the wasm engine too.
    await db.writeTxn((txn) async {
      await txn
          .collection<String>(
            'notes',
            toRow: (value) => value,
            fromRow: (row) => row as String,
            id: (value) => value,
          )
          .put('txn row');
    });
    final txnRead = await notes().get('txn row');
    if (txnRead != 'txn row') {
      throw StateError('txn read-back mismatch: $txnRead');
    }

    await db.close();
    report('WEB-SMOKE-OK');
  } catch (error, stackTrace) {
    report('WEB-SMOKE-FAIL: $error');
    report(stackTrace.toString());
  }

  html.document.body!.text = results.join('\n');
  html.document.title = results.contains('WEB-SMOKE-OK')
      ? 'WEB-SMOKE-OK'
      : 'WEB-SMOKE-FAIL';
}
