// Live smoke for the reusable in-package worker + WebWorkerClient.
//
// Main-thread Dart entry that spawns `gecko_db_worker.js` as a Dedicated
// Worker, opens a file-backed database over OPFS through the JSON protocol,
// round-trips an applyBatch/get, and closes. Prints `GECKO-WORKER-OK` on
// success and writes the marker to the DOM for the CDP driver.
library;

import 'dart:html' as html;
import 'dart:typed_data';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/wire/op.dart';

const String kDbPath = 'worker-smoke.db';

Future<void> main() async {
  final results = <String>[];
  void report(String line) {
    results.add(line);
    // ignore: avoid_print
    print(line);
  }

  try {
    final client = await WebWorkerClient.open(
      workerUrl: 'gecko_db_worker.js',
      path: kDbPath,
    );
    final ops = Op.encodeBatch(<Op>[
      Op(
        op: OpKind.put,
        table: 'smoke',
        key: Uint8List.fromList(<int>[1]),
        value: Uint8List.fromList(<int>[42]),
      ),
    ]);
    final seq = (await client.applyBatch(ops)).sequence;
    final readBack = await client.get(table: 'smoke', key: <int>[1]);
    final tables = await client.tables();
    if (seq < 1 ||
        readBack?.length != 1 ||
        readBack![0] != 42 ||
        !tables.contains('smoke')) {
      throw StateError(
        'round-trip mismatch: seq=$seq value=$readBack tables=$tables',
      );
    }
    await client.close();
    report('GECKO-WORKER-OK');
  } catch (error, stackTrace) {
    report('GECKO-WORKER-FAIL: $error');
    report(stackTrace.toString());
  }

  final out = html.document.getElementById('out');
  out?.text = results.join('\n');
  html.document.title = results.contains('GECKO-WORKER-OK')
      ? 'GECKO-WORKER-OK'
      : 'GECKO-WORKER-FAIL';
}
