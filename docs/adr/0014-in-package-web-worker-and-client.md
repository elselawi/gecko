---
status: accepted
date: 2026-08-09
deciders: gecko_db maintainers
---

# ADR-0014: In-Package Reusable Web Worker Entry and WebWorkerClient

## Context

ADR-0013 shipped the FRB wasm glue and OPFS persistence, but the worker
bootstrap was a *documented reference pattern* (`tool/web_smoke/opfs_worker.dart`)
that every consumer had to copy into their own project and adapt. That meant:

- The subtle worker bootstrap (glue loaded via `importScripts`, `self.wasm_bindgen`
  hoisting, `self.window = self`, string-form wasm URL, `RustLib.init` with an
  external library) was re-derived by hand each time, inviting the exact bugs
  ADR-0013's decision 5 documents.
- There was no first-class, protocol-stable way for application code to talk to
  the worker: consumers had to write their own `onmessage` JSON handling and
  their own error/boot sequencing.

The goal of this workstream was to make "run gecko_db in a Web Worker over OPFS"
a one-line, supported operation — the web analog of `NativeWorkerClient` on the
VM — with a documented wire protocol and deterministic boot/close semantics.

## Decision

### 1. The reusable worker entry ships inside the package

`packages/gecko_db/web/gecko_db_worker.dart` is a self-contained `DedicatedWorker`
global script that:

- loads the FRB glue with `importScripts` (absolute or relative URL),
- performs the ADR-0013 bootstrap (hoist `wasm_bindgen`, alias `self.window`,
  instantiate via the string-form wasm URL, `RustLib.init(ExternalLibrary(...))`),
- installs `onmessage` **before** posting `{'type':'booted'}` (closing the
  race where a client's first request is dropped because the handler was not yet
  installed),
- serves a stable JSON protocol (below),
- rejects `physicalKey` requests on the web (there is no key-management surface
  for physical encryption in a Worker today; a typed error is returned instead
  of silently ignoring the key).

It is excluded from VM analysis (`packages/gecko_db/web/**` in
`analysis_options.yaml`) because it references web-only FRB symbols.

### 2. A JSON wire protocol is defined once

`packages/gecko_db/lib/src/worker/web_worker_protocol.dart` defines
`encodeValue`/`decodeValue` (bytes → `{"b64": ...}`, `StorageStats` → a plain
map, lists recurse), `encodeRequest`, `encodeResponse`, and `decodeMessage`.
Messages:

- worker → client: `booted`, `startupError`, `ready` (with handshake),
  `response` (ok/error), `closed`
- client → worker: `open` (path/readOnly), `request` (op + args), `close`

Big integers cross the wire as strings (identical to the VM native dispatch).

### 3. A first-class `WebWorkerClient` mirrors `NativeWorkerClient`

`packages/gecko_db/lib/src/worker/web_worker_client.dart` is exported
conditionally (`io` → throwing stubs, `web` → the real client), so the barrel
compiles on both platforms. `WebWorkerClient.open(...)`:

- creates the `Worker` from `workerUrl`,
- wires `onmessage`/`onerror` through `dart:js_interop` (`setProperty` +
  `toJS`, decoding with `dartify()`),
- **awaits `booted` before sending `open`** (the race fix), then awaits `ready`,
- returns the **same instance** whose stream is already wired (creating a
  second instance on `ready` breaks message routing),
- dispatches the same 16 operations as the VM native dispatch
  (`dispatchNativeWorker`), so the web client is behaviorally aligned with the
  VM worker client.

## Consequences

### Positive

- Consumers now write `WebWorkerClient.open(workerUrl: 'gecko_db_worker.js',
  path: 'app.db')` and get a booted, handshaken client with typed errors — the
  web equivalent of the VM path.
- The wire protocol is testable on the VM (`web_worker_protocol_test.dart`)
  without a browser.
- The worker entry is covered by a live headless-Chrome CDP smoke
  (`GECKO-WORKER-OK`) and survives open → close → reopen of the same OPFS file
  (the sync-access-handle leak that previously caused
  `NoModificationAllowedError` is fixed by deterministic `close`).

### Negative / caveats

- The worker entry and client are `dart2js`/`dart:js_interop` code that cannot
  be analyzed or unit-tested on the VM; their live validation depends on the
  CDP-driven browser harness and the protocol-level unit tests.
- `physicalKey` (physical encryption) is unsupported on the web worker and
  returns a typed error; consumers must keep encryption keys out of browser
  worker contexts.
- `dart:js_interop` on this SDK has no `asString()`; message decoding relies on
  `dartify()`, which is documented in the client source.

## Supersedes

None — extends ADR-0013 (the worker bootstrap reference pattern is now a
supported, in-package entry rather than a copy-paste example).
