# ADR-0013: Web Runtime (FRB wasm glue + OPFS persistence)

- Status: accepted
- Date: 2026-08-09
- Deciders: gecko_db maintainers
- Technical Story: Workstream 7 — make the native (Rust/redb) engine run on the
  web, with durable persistence via the Origin Private File System (OPFS).

## Context

The engine's public API is Dart; the file backend is the `gecko_db_rust` crate
(redb) exposed through flutter_rust_bridge (FRB) 2.12.0. Prior to this ADR the
web was explicitly "CI-pending": a wasm32 artifact was built, but the FRB web
glue (`frb_generated.web.dart` + wasm-bindgen glue) did not exist, so the
engine could not run in a browser at all.

The web target has two distinct needs:

1. **Run the redb engine on wasm** (in-memory databases at minimum).
2. **Persist file-backed databases** in the browser. The only durable storage
   with synchronous semantics suitable for redb is OPFS
   `FileSystemSyncAccessHandle`, which is **worker-only**.

## Decision

### 1. FRB web glue is enabled and shipped

`frb.yaml` sets `web: true`. `flutter_rust_bridge_codegen` emits
`frb_generated.web.dart`; the wasm build is post-processed with
`wasm-bindgen --target no-modules`, producing `gecko_db_rust.js` +
`gecko_db_rust_bg.wasm`, bundled under `packages/gecko_db/lib/native/web/wasm32/`
with a manifest (glue files recorded as `glueJs`/`glueWasm`).

### 2. The FRB API is async-only

All 16 FRB-facing methods in `rust/src/api.rs` are `async fn`. FRB's web
runtime dispatches **sync** functions through its WorkerPool, which spawns Web
Workers and transfers the (non-shared) wasm `WebAssembly.Memory` — the transfer
fails with `DataCloneError` in environments without a shared memory. Async
functions are dispatched through the async runtime (wasm-bindgen-futures on the
web, tokio natively) and never touch the worker pool. The generated Dart API is
identical either way (already `Future`-based).

### 3. flutter_rust_bridge is vendored with one minimal patch

`rust/vendor/flutter_rust_bridge` (via `[patch.crates-io]`) is identical to
crates.io 2.12.0 except that `WorkerPool::default()` no longer panics when a
Web Worker cannot be created — it falls back to an empty pool. gecko_db never
dispatches `spawn_blocking` work on the web (see decision 2), so the empty pool
is never exercised. The `thread-pool` feature must remain enabled because the
generated glue references `wrap_normal`.

### 4. OPFS persistence runs inside a Web Worker

A `FileSystemSyncAccessHandle` is worker-only and synchronous; redb needs
synchronous storage. The acquisition is asynchronous, and a single-threaded
wasm module cannot block on a JS promise. The division of labor:

- **Dart (in the Worker)** acquires the handle asynchronously
  (`navigator.storage.getDirectory()` → `getFileHandle(name, {create:true})` →
  `createSyncAccessHandle()`), then hands the raw JS handle to Rust through the
  plain wasm-bindgen export `wasm_bindgen.wasm_opfs_register(path, handle)`.
- **Rust** (`rust/src/opfs.rs`, wasm32-only) stores the handle keyed by path and
  exposes `WasmOpfsBackend: redb::StorageBackend` using only the synchronous
  handle methods. `RedbWorker::open` on wasm uses it for any path other than
  `:memory:` (which opens redb's in-memory backend).
- The Dart web open path (`NativeWorkerClient._openWeb`) registers the OPFS
  handle before opening, producing a typed error when running on the main
  thread or outside a secure context.

`Send`/`Sync` are unsafely implemented for the handle wrapper; this is
documented as sound only on single-threaded `wasm32-unknown-unknown`, the sole
target where the module compiles.

### 5. The web worker bootstrap is a documented reference pattern

The FRB web loader appends a `<script>` to `document.head` — main-thread only.
Inside a Worker the glue is loaded with `importScripts`, then:

- `jsEval('self.wasm_bindgen = wasm_bindgen')` — the no-modules glue declares
  `let wasm_bindgen` (a lexical binding, not a global property).
- `jsEval('self.window = self')` — FRB's Dart web runtime reads the glue
  through `web.window`, which does not exist in a Worker.
- `wasm_bindgen('<wasm url>')` — the string form fetches and instantiates the
  module (the `{module_or_path}` object form does not work in this glue).
- `RustLib.init(externalLibrary: ExternalLibrary(...))` — skips the
  document-based loader entirely.

The validated reference implementation is `tool/web_smoke/opfs_worker.dart`;
consumers embed this pattern in their own worker entry.

### 6. The web smoke tests are driven by a CDP harness

`--dump-dom --virtual-time-budget` does not pump async Web-Worker
continuations. `tool/web_smoke/cdp_drive.mjs` drives a headless Chrome
(`--remote-debugging-port=9222`) via the DevTools Protocol in real time and
asserts the DOM/title markers. Two live-validated suites:

- `web_smoke.dart` → **`WEB-SMOKE-OK`**: `Database.open(':memory:')`,
  put/get/getAll/writeTxn against the redb-on-wasm engine on the main thread.
- `opfs_worker.dart` → **`OPFS-SMOKE-OK`**: OPFS handle acquisition,
  `NativeWorker.open`, applyBatch/get round-trip, and deterministic close, in a
  real Worker. Reopening the same file succeeds (the close released the handle).

## Consequences

### Positive

- The engine now runs in a browser: `Database.open` works on the web with the
  native redb engine (`:memory:` on the main thread; any path in a Worker over
  OPFS).
- Web portability fixes shipped: `ByteData.getInt64` (unsupported on dart2js)
  replaced by manual big-endian assembly in the wire codec and sort rules;
  web-incompatible 64-bit integer literals removed; `dart:ffi` `Abi` isolated
  behind a conditional import; `Isolate.spawn`-based worker client replaced by
  a same-isolate direct mode on the web.
- Artifacts are reproducible: `tool/build_artifacts.dart build wasm32` runs
  cargo + wasm-bindgen and bundles the glue pair + manifest.

### Negative / caveats

- OPFS persistence requires the app to host the engine inside a Web Worker
  (the reference pattern is documented, not an in-package entry yet).
- OPFS allows only one sync access handle per file at a time; the engine must
  be closed deterministically or the next open fails with
  `NoModificationAllowedError`.
- Physical encryption (`physicalEncryptionKey`) is not supported on the web
  (the wasm OPFS path is opened unencrypted; the API rejects keyed opens on the
  web with a typed error).
- A vendored FRB copy must be kept in sync when upgrading FRB.
