/// OPFS (Origin Private File System) handle registration for the web build.
///
/// OPFS `FileSystemSyncAccessHandle`s are worker-only, so on the web a
/// `Database.open(path)` requires the engine to run inside a Web Worker. The
/// async acquisition of the handle is done from Dart (a single-threaded wasm
/// module cannot block on a promise); the raw JS handle is then handed to
/// Rust via the plain wasm-bindgen export `wasm_bindgen.wasm_opfs_register(
/// path, handle)` (see `rust/src/opfs.rs`).
library;

export 'opfs_io.dart' if (dart.library.js_interop) 'opfs_web.dart';
