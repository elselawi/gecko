// Web/OPFS benchmark entry (browser, in a Dedicated Worker).
//
// Qualifies the web target SEPARATELY from native Windows numbers (the plan's
// rule: never extrapolate native plaintext numbers to Web/OPFS). Measures, on
// a real OPFS file inside a Web Worker: bulk seeding, point reads, single
// writes, and a full scan at 1k and 10k rows. Timings include the whole
// path (Dart messaging → JS/WASM glue → Rust execution → OPFS sync I/O);
// they are a baseline for the web target, not a substitute for the native
// benchmark.
//
// Compile with:
//   dart compile js tool/web_smoke/web_opfs_bench.dart \
//     -o build/web_smoke/web_opfs_bench.js
// Serve with `dart run tool/web_smoke/serve.dart 8080`, then drive:
//   node tool/web_smoke/cdp_drive.mjs \
//     http://localhost:8080/web_opfs_bench_test.html \
//     WEB-OPFS-BENCH-OK WEB-OPFS-BENCH-FAIL
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'package:gecko_db/src/native/generated/api.dart';
import 'package:gecko_db/src/native/generated/frb_generated.dart';
import 'package:gecko_db/src/native/native_resolver.dart'
    show bundledWebGluePrefix, bundledWebStem;
import 'package:gecko_db/src/native/opfs.dart' show registerOpfsHandle;
import 'package:gecko_db/src/wire/op.dart';

const String kDbPath = 'opfs-bench.db';

/// Seeds [count] rows through one batched write per [chunkSize] rows and
/// returns µs/row.
Future<double> _seed(
  NativeWorker worker,
  int count,
  int chunkSize,
) async {
  final sw = Stopwatch()..start();
  for (var start = 0; start < count; start += chunkSize) {
    final end = start + chunkSize > count ? count : start + chunkSize;
    final ops = Op.encodeBatch(<Op>[
      for (var i = start; i < end; i++)
        Op(
          op: OpKind.put,
          table: 'bench',
          key: Uint8List.fromList(_key(i)),
          value: Uint8List.fromList(_value(i)),
        ),
    ]);
    await worker.applyBatch(
      encodedOps: Uint8List.fromList(ops),
      indexDefinitions: const <(String, List<String>)>[],
      changeLogMaxEntries: BigInt.zero,
    );
  }
  sw.stop();
  return sw.elapsedMicroseconds / count;
}

/// Measures [fn] over [ops] iterations, returning the average µs/op.
Future<double> _measure(
  Future<void> Function() fn,
  int ops,
) async {
  final sw = Stopwatch()..start();
  for (var i = 0; i < ops; i++) {
    await fn();
  }
  sw.stop();
  return sw.elapsedMicroseconds / ops;
}

List<int> _key(int i) => Uint8List(8)
  ..[7] = i & 0xFF
  ..[6] = (i >> 8) & 0xFF
  ..[5] = (i >> 16) & 0xFF
  ..[4] = (i >> 24) & 0xFF
  ..[3] = (i >> 32) & 0xFF
  ..[2] = (i >> 40) & 0xFF
  ..[1] = (i >> 48) & 0xFF
  ..[0] = (i >> 56) & 0xFF;

List<int> _value(int i) => Uint8List.fromList(
  utf8.encode('{"id":$i,"num":$i,"group":"g${i % 100}"}'),
);

Future<void> main() async {
  final global = globalContext;
  void post(String line) {
    // ignore: avoid_print
    print(line);
    global.callMethod('postMessage'.toJS, line.toJS);
  }

  void fail(String error) {
    post('WEB-OPFS-BENCH-FAIL: $error');
  }

  try {
    final prefix =
        (await bundledWebGluePrefix()) ?? 'packages/gecko_db/native/web/wasm32/';
    global.callMethod('importScripts'.toJS, '$prefix$bundledWebStem.js'.toJS);
    jsEval('self.wasm_bindgen = wasm_bindgen');
    jsEval('self.window = self');
    final wasmBindgen = global.getProperty('wasm_bindgen'.toJS);
    if (wasmBindgen.isUndefinedOrNull) {
      throw StateError('wasm_bindgen not defined after importScripts');
    }
    final initPromise =
        (wasmBindgen as JSFunction).callAsFunction(
              null,
              '$prefix${bundledWebStem}_bg.wasm'.toJS,
            )
            as JSPromise;
    await initPromise.toDart;
    await RustLib.init(
      externalLibrary: ExternalLibrary(
        debugInfo: 'gecko_db web worker (bench)',
        wasmBindgenName: 'wasm_bindgen',
      ),
    );
    final opfsError = await registerOpfsHandle(kDbPath);
    if (opfsError != null) throw StateError(opfsError);

    NativeWorker? worker;
    try {
      worker = await NativeWorker.open(path: kDbPath, readOnly: false);
      final w = worker;
      final rows = [
        (1, 1000),
        (2, 10000),
      ];
      final lines = <String>[];
      for (final (round, count) in rows) {
        final seedUsPerRow = await _seed(w, count, 500);
        final getUs = await _measure(() async {
          await w.get_(table: 'bench', key: _key(0));
        }, 200);
        final sw = Stopwatch()..start();
        final all = await w.rangeScan(
          table: 'bench',
          start: null,
          end: null,
        );
        sw.stop();
        final scanMs = sw.elapsedMicroseconds / 1000;
        if (all.length != count) {
          throw StateError('scan returned ${all.length} rows, expected $count');
        }
        final putUs = await _measure(() async {
          final ops = Op.encodeBatch(<Op>[
            Op(
              op: OpKind.put,
              table: 'bench',
              key: Uint8List.fromList(_key(count + 1)),
              value: Uint8List.fromList(_value(count + 1)),
            ),
          ]);
          await w.applyBatch(
            encodedOps: Uint8List.fromList(ops),
            indexDefinitions: const <(String, List<String>)>[],
            changeLogMaxEntries: BigInt.zero,
          );
        }, 100);
        final line =
            'round $round: rows=$count seed=${seedUsPerRow.toStringAsFixed(1)}'
            'µs/row get=${getUs.toStringAsFixed(1)}µs '
            'put=${putUs.toStringAsFixed(1)}µs scan=${scanMs.toStringAsFixed(1)}ms';
        post(line);
        lines.add(line);
      }
      post('WEB-OPFS-BENCH-OK');
      post(lines.join('\n'));
      await w.close();
    } finally {
      if (worker != null) {
        try {
          await worker.close();
        } catch (_) {}
      }
    }
  } catch (error) {
    fail('$error');
  }
}
