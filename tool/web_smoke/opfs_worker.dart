// OPFS web-worker smoke entry.
//
// Compiled with `dart compile js` and loaded into a Dedicated Worker by the
// main page. It loads the wasm-bindgen glue itself (the FRB default loader
// needs document.head, which a worker lacks), registers an OPFS
// FileSystemSyncAccessHandle with the Rust engine, opens a file-backed
// database over OPFS, and round-trips a record. The result is posted back to
// the main thread via `postMessage`.
//
// This proves the OPFS persistence path end-to-end: OPFS handle → Rust
// `WasmOpfsBackend` → redb on wasm.
library;

import 'dart:async';
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

const String kDbPath = 'opfs-smoke.db';

Future<void> main() async {
  final global = globalContext;
  void post(String line) {
    // ignore: avoid_print
    print(line);
    global.callMethod('postMessage'.toJS, line.toJS);
  }

  try {
    // 1. Load the wasm-bindgen glue in the worker (importScripts defines the
    //    global `wasm_bindgen`), then initialize the module by calling it with
    //    the module_or_path option.
    final prefix =
        (await bundledWebGluePrefix()) ??
        'packages/gecko_db/native/web/wasm32/';
    global.callMethod('importScripts'.toJS, '$prefix$bundledWebStem.js'.toJS);
    // The glue declares `let wasm_bindgen` — a lexical binding, not a global
    // property. FRB's main-thread loader copies it onto `window`; here we copy
    // it onto the worker global (`self`) so both the module init below and
    // FRB's `@JS('wasm_bindgen')` lookups resolve it.
    jsEval('self.wasm_bindgen = wasm_bindgen');
    // FRB's Dart web runtime reads the glue through `web.window`. Workers have
    // no `window`; alias it to the worker global so the same code works.
    jsEval('self.window = self');
    final wasmBindgen = global.getProperty('wasm_bindgen'.toJS);
    if (wasmBindgen.isUndefinedOrNull) {
      throw StateError('wasm_bindgen not defined after importScripts');
    }
    // Initialize the module by calling `wasm_bindgen` with the wasm URL as a
    // plain string (the glue's `__wbg_init` fetches string inputs; the
    // `{module_or_path}` object form does not work here).
    final initPromise =
        (wasmBindgen as JSFunction).callAsFunction(
              null,
              '$prefix${bundledWebStem}_bg.wasm'.toJS,
            )
            as JSPromise;
    await initPromise.toDart;

    // 2. Initialize FRB with the already-loaded glue (skip the document-based
    //    loader by passing an ExternalLibrary explicitly).
    await RustLib.init(
      externalLibrary: ExternalLibrary(
        debugInfo: 'gecko_db web worker',
        wasmBindgenName: 'wasm_bindgen',
      ),
    );
    // 3. Acquire + register the OPFS handle, then open over it.
    final opfsError = await registerOpfsHandle(kDbPath);
    if (opfsError != null) throw StateError(opfsError);

    NativeWorker? worker;
    try {
      worker = await NativeWorker.open(path: kDbPath, readOnly: false);

      // 4. Round-trip a record through the OPFS-backed engine.
      final ops = Op.encodeBatch(<Op>[
        Op(
          op: OpKind.put,
          table: 'smoke',
          key: Uint8List.fromList(<int>[1]),
          value: Uint8List.fromList(<int>[42]),
        ),
      ]);
      final seq = (await worker.applyBatch(
        encodedOps: Uint8List.fromList(ops),
        indexDefinitions: const <(String, List<String>)>[],
        changeLogMaxEntries: BigInt.zero,
      )).sequence;
      final value = await worker.get_(
        table: 'smoke',
        key: Uint8List.fromList(<int>[1]),
      );
      final readBack = value?.toList();
      if (readBack == null ||
          readBack.length != 1 ||
          readBack[0] != 42 ||
          seq < BigInt.one) {
        throw StateError('OPFS round-trip mismatch: seq=$seq value=$readBack');
      }
      post('OPFS-SMOKE-OK');
    } finally {
      // OPFS forbids a second sync-access handle on a file while one is open,
      // so the engine must always be closed deterministically (even on error)
      // or the next open fails with NoModificationAllowedError.
      if (worker != null) {
        try {
          await worker.close();
        } catch (_) {
          // Best-effort teardown.
        }
      }
    }
  } catch (error, stackTrace) {
    post('OPFS-SMOKE-FAIL: $error');
    post(stackTrace.toString());
  }
}
