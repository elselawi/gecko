# Web smoke tests (FRB wasm glue + OPFS)

Live browser validation of the web target (ADR-0013). Two suites:

| Suite | Entry | Marker | What it proves |
|---|---|---|---|
| Main-thread engine | `web_smoke.dart` | `WEB-SMOKE-OK` | `Database.open(':memory:')` runs the **redb engine on wasm** on the main thread: put/get/getAll/writeTxn through the public API. |
| OPFS worker | `opfs_worker.dart` | `OPFS-SMOKE-OK` | In a real **Web Worker**: glue loaded via `importScripts`, FRB initialized, OPFS `FileSystemSyncAccessHandle` acquired + registered, `NativeWorker.open` over OPFS, applyBatch/get round-trip, deterministic close, reopen. |

## Prerequisites

- Rust wasm target + wasm-bindgen CLI (pinned version must match
  `rust/Cargo.toml`):
  ```powershell
  rustup target add wasm32-unknown-unknown
  cargo install wasm-bindgen-cli --version 0.2.92 --locked
  ```
- Google Chrome (for the headless run).
- Node.js ≥ 22 (for the CDP driver; built-in `fetch` + `WebSocket`, no deps).

## Building the glue

The glue is produced by the artifact tool (runs cargo + wasm-bindgen):

```powershell
dart run tool/build_artifacts.dart build wasm32 --out=build/native
```

This emits `build/native/gecko_db_rust.js` + `gecko_db_rust_bg.wasm`
(+ `wasm32.json`). `bundle` copies them into
`packages/gecko_db/lib/native/web/wasm32/`.

## Compiling the suites

```powershell
dart compile js tool/web_smoke/web_smoke.dart -o build/web_smoke/app.js
dart compile js tool/web_smoke/opfs_worker.dart -o build/web_smoke/opfs_worker.js
```

## Serving

`serve.dart` serves the compiled app at `/`, the glue at
`/packages/gecko_db/native/web/wasm32/` (the URL the FRB loader resolves), with
correct JS/WASM MIME types:

```powershell
dart run tool/web_smoke/serve.dart 8080
```

`opfs_test.html` is the harness page that spawns `opfs_worker.js` as a
Dedicated Worker and surfaces its `postMessage` lines in the DOM.

## Running (headless Chrome)

`--dump-dom --virtual-time-budget` does **not** pump async Web-Worker
continuations, so the suites are driven through the DevTools Protocol in real
time.

```powershell
# 1. Headless Chrome with CDP (fresh profile so OPFS state is clean):
Remove-Item build/cdp_profile -Recurse -ErrorAction SilentlyContinue
& "C:\Program Files\Google\Chrome\Application\chrome.exe" --headless=new `
  --disable-gpu --no-sandbox --remote-debugging-port=9222 `
  --user-data-dir=C:\Users\alias\Coding\gecko\build\cdp_profile about:blank

# 2. Drive each suite (exit 0 on the marker):
node tool/web_smoke/cdp_drive.mjs http://localhost:8080/ WEB-SMOKE-OK WEB-SMOKE-FAIL
node tool/web_smoke/cdp_drive.mjs http://localhost:8080/opfs_test.html OPFS-SMOKE-OK OPFS-SMOKE-FAIL
```

> Note: OPFS allows only one sync-access handle per file at a time. The worker
> closes the engine deterministically in `finally`, but a crashed prior run can
> leave a handle open — restart with a fresh `--user-data-dir` to reset.

## Notes / gotchas (all documented in ADR-0013)

- FRB dispatches **sync** API functions through a Web-Worker pool on the web
  (which fails to transfer the non-shared wasm memory); gecko's FRB API is
  therefore **async-only**.
- The no-modules glue declares `let wasm_bindgen` (lexical, not a global
  property) — copy it onto `self` in a Worker; FRB's Dart runtime reads it via
  `web.window`, so a Worker also needs `self.window = self`.
- Initialize the module with the **string** wasm URL, not the
  `{module_or_path}` object form.
