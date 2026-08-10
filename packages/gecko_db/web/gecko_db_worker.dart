// gecko_db reusable OPFS Web-Worker entry.
//
// Compile this file with `dart compile js` and spawn the result as a
// Dedicated Worker from your app:
//
//   dart compile js packages/gecko_db/web/gecko_db_worker.dart \
//     -o build/gecko_db_worker.js
//
// Then `new Worker('gecko_db_worker.js')` and speak the protocol documented
// in `lib/src/worker/web_worker_protocol.dart` (see `WebWorkerClient`).
//
// What this worker does (ADR-0013):
//   1. Loads the wasm-bindgen glue with `importScripts` (the FRB default
//      loader needs document.head, which a worker lacks).
//   2. Aliases `self.wasm_bindgen` (the glue declares a lexical `let`) and
//      `self.window` (FRB's Dart runtime reads the glue via `web.window`).
//   3. Initializes the wasm module by calling `wasm_bindgen(<wasm url>)`
//      with the string form (the `{module_or_path}` object form does not
//      work in this glue).
//   4. Initializes FRB with an explicit `ExternalLibrary` (skips the
//      document-based loader).
//   5. On `open`: acquires + registers an OPFS `FileSystemSyncAccessHandle`
//      (unless the path is `:memory:`), opens the redb engine over it.
//   6. Services `request` (the `dispatchNativeWorker` operation set) and
//      `close` over `postMessage` using the JSON protocol.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary, jsEval;

import 'package:gecko_db/src/native/generated/api.dart' show NativeWorker;
import 'package:gecko_db/src/native/generated/frb_generated.dart' show RustLib;
import 'package:gecko_db/src/native/native_resolver.dart'
    show bundledWebGluePrefix, bundledWebStem;
import 'package:gecko_db/src/native/opfs.dart' show registerOpfsHandle;
import 'package:gecko_db/src/worker/native_dispatch.dart'
    show dispatchNativeWorker;
import 'package:gecko_db/src/worker/web_worker_protocol.dart';

/// The opened FRB worker, or null before `open` / after `close`. Mutable
/// top-level state so the `onmessage` handler can reach the worker opened by
/// [_handleOpen].
NativeWorker? _currentWorker;

Future<void> main() async {
  final global = globalContext;

  void post(Map<String, Object?> message) {
    global.callMethod('postMessage'.toJS, encodeResponse(message).toJS);
  }

  void postStartupError(String error) =>
      post(<String, Object?>{'type': 'startupError', 'error': error});

  try {
    // 1–4. Load + initialize the glue and FRB in this worker context.
    final prefix =
        (await bundledWebGluePrefix()) ??
        'packages/gecko_db/native/web/wasm32/';
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
        debugInfo: 'gecko_db web worker',
        wasmBindgenName: 'wasm_bindgen',
      ),
    );

    // 5–6. Service the protocol. Signal boot only after the onmessage
    // handler is installed so the main thread never sends `open` into a
    // worker that is not yet listening (early messages would be dropped).
    global.setProperty(
      'onmessage'.toJS,
      ((JSAny? event) {
        final data = (event as JSObject).getProperty('data'.toJS);
        final text = data.dartify();
        if (text is! String) return;
        final message = decodeMessage(text);
        final cmd = message['cmd'] as String?;
        final id = message['id'];

        if (cmd == 'open') {
          unawaited(_handleOpen(message, post));
          return;
        }

        final worker = _currentWorker;
        if (cmd == 'close' && worker != null) {
          _currentWorker = null;
          dispatchNativeWorker(worker, 'close', const [])
              .then((_) => post(<String, Object?>{'type': 'closed'}))
              .catchError(
                (Object error) => post(<String, Object?>{
                  'type': 'closed',
                  'error': '$error',
                }),
              );
          return;
        }

        if (cmd == 'request' && worker != null) {
          final op = message['op'] as String;
          final rawArgs = message['args'] as List? ?? const <Object?>[];
          final args = <Object?>[for (final arg in rawArgs) decodeValue(arg)];
          dispatchNativeWorker(worker, op, args)
              .then((result) {
                post(<String, Object?>{
                  'type': 'response',
                  'id': id,
                  'ok': true,
                  'value': encodeValue(result),
                });
              })
              .catchError((Object error) {
                post(<String, Object?>{
                  'type': 'response',
                  'id': id,
                  'ok': false,
                  'error': '$error',
                });
              });
          return;
        }

        post(<String, Object?>{
          'type': 'response',
          'id': id,
          'ok': false,
          'error': cmd == null ? 'malformed command' : 'unknown command: $cmd',
        });
      }).toJS,
    );
    post(<String, Object?>{'type': 'booted'});
  } catch (error) {
    postStartupError('$error');
  }
}

/// Handles an `open` request: registers the OPFS handle (unless `:memory:` or
/// a physical key is supplied) and opens the redb engine, replying `ready`.
Future<void> _handleOpen(
  Map<String, Object?> message,
  void Function(Map<String, Object?> response) post,
) async {
  final path = message['path'] as String;
  final readOnly = message['readOnly'] as bool? ?? false;
  final encryptionKey = message['encryptionKey'];
  final id = message['id'];

  void fail(String error) => post(<String, Object?>{
    'type': 'response',
    'id': id,
    'ok': false,
    'error': error,
  });

  try {
    if (encryptionKey != null) {
      fail(
        'physical encryption is not supported on the web; '
        'use OPFS (no key) or :memory:',
      );
      return;
    }
    if (path != ':memory:') {
      final opfsError = await registerOpfsHandle(path);
      if (opfsError != null) {
        fail(opfsError);
        return;
      }
    }
    final worker = await NativeWorker.open(path: path, readOnly: readOnly);
    final handshake = await worker.compatibilityHandshake();
    _currentWorker = worker;
    post(<String, Object?>{'type': 'ready', 'id': id, 'handshake': handshake});
  } catch (error) {
    fail('$error');
  }
}
