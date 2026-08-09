//! OPFS-backed storage for the web (wasm32) build.
//!
//! The browser's Origin Private File System (OPFS) offers
//! [`FileSystemSyncAccessHandle`], a *synchronous* read/write handle that is
//! only available inside Web Workers. Acquiring the handle is asynchronous
//! (`navigator.storage.getDirectory()` -> `getFileHandle` ->
//! `createSyncAccessHandle`), and a single-threaded wasm module cannot block on
//! a JS promise. We therefore split the work:
//!
//! 1. The Dart side (running inside a Worker) performs the asynchronous
//!    acquisition and hands the raw JS handle to Rust via
//!    [`wasm_opfs_register`] (a plain `wasm-bindgen` export, not an FRB call),
//!    keyed by the database path.
//! 2. Rust stores the handle in a process-wide registry and
//!    [`take_handle_for_path`] hands it to [`WasmOpfsBackend`], which
//!    implements `redb::StorageBackend` using only the synchronous handle
//!    methods.
//!
//! This module only compiles for `target_arch = "wasm32"`.

#![cfg(target_arch = "wasm32")]

use redb::StorageBackend;
use std::io;
use std::sync::Mutex;
use wasm_bindgen::prelude::*;
use web_sys::{FileSystemReadWriteOptions, FileSystemSyncAccessHandle};

/// `JsValue` (and thus `FileSystemSyncAccessHandle`) is `!Send + !Sync` in
/// wasm-bindgen 0.2.x, while `redb::StorageBackend` requires `Send + Sync`.
/// On `wasm32-unknown-unknown` there is exactly one thread (no `std::thread`
/// spawn, no shared memory), so these bounds are trivially satisfied. This
/// wrapper is therefore *de facto* sound on the only target where this module
/// compiles; it is never instantiated on threaded targets.
struct SendSyncWrapper<T>(T);

// SAFETY: `wasm32-unknown-unknown` is single-threaded. The `Send`/`Sync`
// bounds demanded by redb are vacuous here (no other thread can ever observe
// or mutate this value). This module is cfg-gated to wasm32, so the wrapper is
// never used on multi-threaded targets where these impls would be unsound.
unsafe impl<T> Send for SendSyncWrapper<T> {}
// SAFETY: see above; single-threaded wasm32 only.
unsafe impl<T> Sync for SendSyncWrapper<T> {}

/// Registry of acquired OPFS sync-access handles, keyed by the database path
/// they belong to (gecko opens at most one worker per path).
///
/// A `Mutex` guards the map; the inner handle is wrapped in
/// [`SendSyncWrapper`] so the static itself can be `Sync`.
static HANDLES: Mutex<SendSyncWrapper<Vec<(String, Option<FileSystemSyncAccessHandle>)>>> =
    Mutex::new(SendSyncWrapper(Vec::new()));

/// Registers a JS `FileSystemSyncAccessHandle` (passed from Dart) under
/// [path] and returns a numeric id. This is a plain `wasm-bindgen` export so
/// the Dart web code can call it through the generated glue
/// (`wasm_bindgen.wasm_opfs_register`).
#[wasm_bindgen]
pub fn wasm_opfs_register(path: String, handle: JsValue) -> u32 {
    let handle: FileSystemSyncAccessHandle = handle.unchecked_into();
    let mut registry = HANDLES.lock().unwrap();
    for (stored_path, slot) in registry.0.iter_mut() {
        if *stored_path == path && slot.is_none() {
            *slot = Some(handle);
            return 0;
        }
    }
    registry.0.push((path, Some(handle)));
    (registry.0.len() - 1) as u32
}

/// Removes (and closes) a previously registered handle by id.
#[wasm_bindgen]
pub fn wasm_opfs_unregister(id: u32) {
    let mut registry = HANDLES.lock().unwrap();
    if let Some((_, Some(handle))) = registry.0.get_mut(id as usize) {
        handle.close();
        *handle = FileSystemSyncAccessHandle::from(JsValue::undefined());
        registry.0[id as usize].1 = None;
    }
}

/// Takes the handle registered for [path] out of the registry, transferring
/// ownership. Returns `None` when no handle was registered for the path (or it
/// was already taken).
pub fn take_handle_for_path(path: &str) -> Option<FileSystemSyncAccessHandle> {
    let mut registry = HANDLES.lock().unwrap();
    for (stored_path, slot) in registry.0.iter_mut() {
        if stored_path == path {
            return slot.take();
        }
    }
    None
}

/// Maps a JS error to a Rust `io::Error` with context.
fn js_err(context: &str, value: JsValue) -> io::Error {
    io::Error::new(
        io::ErrorKind::Other,
        format!("{context}: {:?}", value.as_string().unwrap_or_default()),
    )
}

/// A `redb::StorageBackend` backed by a single OPFS sync-access handle.
pub struct WasmOpfsBackend {
    handle: SendSyncWrapper<FileSystemSyncAccessHandle>,
    /// Short human-readable label for error messages (e.g. the db file name).
    label: String,
}

impl std::fmt::Debug for WasmOpfsBackend {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WasmOpfsBackend")
            .field("label", &self.label)
            .finish_non_exhaustive()
    }
}

impl WasmOpfsBackend {
    /// Wraps an acquired handle. [label] names the database file for errors.
    pub fn new(handle: FileSystemSyncAccessHandle, label: String) -> Self {
        Self {
            handle: SendSyncWrapper(handle),
            label,
        }
    }
}

impl StorageBackend for WasmOpfsBackend {
    fn len(&self) -> Result<u64, io::Error> {
        self.handle
            .0
            .get_size()
            .map(|size| size as u64)
            .map_err(|error| js_err(&self.label, error))
    }

    fn read(&self, offset: u64, out: &mut [u8]) -> Result<(), io::Error> {
        let mut options = FileSystemReadWriteOptions::new();
        options.at(offset as f64);
        let bytes_read = self
            .handle
            .0
            .read_with_u8_array_and_options(out, &options)
            .map_err(|error| js_err(&self.label, error))? as usize;
        if bytes_read != out.len() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                format!(
                    "{}: short read at offset {offset}: got {bytes_read}, wanted {}",
                    self.label,
                    out.len()
                ),
            ));
        }
        Ok(())
    }

    fn set_len(&self, len: u64) -> Result<(), io::Error> {
        self.handle
            .0
            .truncate_with_f64(len as f64)
            .map_err(|error| js_err(&self.label, error))
    }

    fn sync_data(&self) -> Result<(), io::Error> {
        self.handle
            .0
            .flush()
            .map_err(|error| js_err(&self.label, error))
    }

    fn write(&self, offset: u64, data: &[u8]) -> Result<(), io::Error> {
        let mut options = FileSystemReadWriteOptions::new();
        options.at(offset as f64);
        let bytes_written = self
            .handle
            .0
            .write_with_u8_array_and_options(data, &options)
            .map_err(|error| js_err(&self.label, error))? as usize;
        if bytes_written != data.len() {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                format!(
                    "{}: short write at offset {offset}: got {bytes_written}, wanted {}",
                    self.label,
                    data.len()
                ),
            ));
        }
        Ok(())
    }

    fn close(&self) -> Result<(), io::Error> {
        self.handle.0.close();
        Ok(())
    }
}
