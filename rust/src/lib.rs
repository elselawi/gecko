//! gecko_db_rust — the native engine crate.
//!
//! scope: establish the crate skeleton and the `Op` wire format that
//! mirrors the Dart contract (`gecko_db`'s `Op`/`OpKind`), so the cross-language
//! golden-bytes verification has a foundation. Later phases add the redb-backed
//! worker, indexing, change tracking, and encryption backend here.

pub mod api;
pub mod compatibility;
pub mod crypto_storage;
pub mod error;
pub mod format_header;
mod frb_generated;
#[cfg(target_arch = "wasm32")]
pub mod opfs;
pub mod predicate;
pub mod registry;
pub mod sort_spec;
pub mod value_codec;
pub mod wire;
pub mod worker;
