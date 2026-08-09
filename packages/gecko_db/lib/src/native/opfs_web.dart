/// Web implementation of OPFS handle registration.
///
/// Runs inside a Web Worker. Steps:
/// 1. `navigator.storage.getDirectory()` → the OPFS root directory.
/// 2. `dir.getFileHandle(path, {create: true})` → the database file handle.
/// 3. `fileHandle.createSyncAccessHandle()` → the synchronous handle.
/// 4. `wasm_bindgen.wasm_opfs_register(path, handle)` → hand the JS handle to
///    the Rust engine (registered keyed by path for `RedbWorker::open`).
///
/// Requires the FRB glue to be loaded first (so the global `wasm_bindgen` is
/// initialized), and a secure context (OPFS is only available on https or
/// localhost).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Registers an OPFS sync-access handle for [path] with the Rust engine.
/// Returns null on success, or a human-readable error message on failure
/// (e.g. running on the main thread, non-secure context, or OPFS unsupported).
Future<String?> registerOpfsHandle(String path) async {
  try {
    final global = globalContext;
    final navigator = global.getProperty('navigator'.toJS);
    if (navigator.isUndefinedOrNull) {
      return 'OPFS unavailable: no navigator (not running in a Worker?)';
    }
    final navigatorObj = navigator as JSObject;
    final storage = navigatorObj.getProperty('storage'.toJS);
    if (storage.isUndefinedOrNull) {
      return 'OPFS unavailable: navigator.storage is undefined '
          '(requires a secure context: https or localhost)';
    }
    final storageObj = storage as JSObject;
    final root = await _awaitObject(storageObj.callMethod('getDirectory'.toJS));
    if (root == null) {
      return 'OPFS unavailable: navigator.storage.getDirectory() returned null';
    }
    final options = JSObject()..setProperty('create'.toJS, true.toJS);
    final fileHandle = await _awaitObject(
      root.callMethod('getFileHandle'.toJS, path.toJS, options),
    );
    if (fileHandle == null) {
      return 'OPFS unavailable: getFileHandle("$path") returned null';
    }
    final handle = await _awaitObject(
      fileHandle.callMethod('createSyncAccessHandle'.toJS),
    );
    if (handle == null) {
      return 'OPFS unavailable: createSyncAccessHandle() returned null '
          '(sync access handles are only available inside a Web Worker)';
    }
    final wasmBindgen = global.getProperty('wasm_bindgen'.toJS);
    if (wasmBindgen.isUndefinedOrNull) {
      return 'OPFS unavailable: wasm_bindgen glue not initialized';
    }
    (wasmBindgen as JSObject).callMethod(
      'wasm_opfs_register'.toJS,
      path.toJS,
      handle,
    );
    return null;
  } catch (error) {
    return 'OPFS registration failed for "$path": $error';
  }
}

/// Awaits a JS promise and returns the resolved JS object, or null.
Future<JSObject?> _awaitObject(JSAny? promise) async {
  if (promise.isUndefinedOrNull) return null;
  final result = await (promise as JSPromise).toDart;
  if (result.isUndefinedOrNull) return null;
  return result as JSObject;
}
