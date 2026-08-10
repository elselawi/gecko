# Native and Web route matrix

M7.1 records the current execution boundary without introducing a persistent
Rust query registry. Public API/model mapping, migration callbacks, reactive
lifecycle, and relationship policy remain Dart-owned. M7.5 removed the
transitional in-memory backend; every route below is the native file / Web-Wasm
OPFS route.

| Operation | Native file / Web-Wasm OPFS | Snapshot boundary | Rows transferred to Dart |
|---|---|---|---|
| Raw put/delete/batch | Dart `RawEngine` → native worker → Rust/redb | One write transaction | None; affected keys only |
| Indexed equality query | Rust durable index join | One native snapshot | Matching rows |
| Indexed range/prefix/multi-eq | Rust durable-index intersection + predicate recheck | One snapshot | Matching rows |
| Unindexed query | Rust predicate pushdown | One snapshot | Matching rows |
| Sorted/limited query | Rust index-ordered or top-K route | One snapshot | Window rows |
| Unindexed `count()` | Rust predicate count | One snapshot | Scalar only |
| Indexed `count()` | Rust durable-index candidate count + predicate recheck | One snapshot | Scalar only |
| Unindexed `distinct()` | Rust field-byte extraction; Dart decode/dedup | One snapshot | Matching field bytes |
| Indexed `distinct()` | Rust durable-index candidate field extraction; Dart decode/dedup | One snapshot | Matching field bytes |
| Relationship `parent()` | Rust child FK extraction + parent point read | One snapshot | Parent row only |
| Relationship `children()` | Rust durable-index lookup or FK predicate push | One snapshot | Matching child rows |
| `loadAllChildren()` | Rust union of indexed FK ranges or Rust FK matching | One snapshot | Matching child rows |
| Many-to-many IDs | Rust snapshot join scan/filter | One snapshot | Matching encoded IDs |
| Relationship delete policy | Dart policy, callbacks, change-feed events; Rust atomic batch | One write transaction | No query rows beyond policy inputs |
| Raw inclusive scan | Worker snapshot range scan | Caller snapshot | Requested rows |
| Raw exclusive scan | Dart compatibility filtering over snapshot result | Caller snapshot | Requested rows |
| Web worker protocol | Shared native dispatch; JSON-safe byte/list conversion | Worker-owned snapshot ID | Same as native route |

## Diagnostics and M8 handoff

- `lastPlan` remains Dart-visible and distinguishes `secondaryIndex`,
  `nativeFilteredScan`, and `fullScan`.
- Query stage timings measure boundary work and Dart decoding/mapping; Rust
  predicate/index work is represented by backend-read duration and transferred
  row counts.
- Snapshot IDs are owned and released by the native worker; finalizers remain
  a safety net in addition to deterministic disposal.
- Change-feed ordering and LSN assignment remain in `RawEngine`/Dart. Native
  write batches already carry indexed declarations for Rust maintenance.
- The M8 handoff is limited to changed row keys, indexed-field declarations,
  and batch metadata. No query registration, persistent query state, or Rust
  reactive lifecycle is added here.

## Typed errors and parity

Native worker errors are mapped through the existing `GeckoErrorEnvelope`.
Missing tables/rows use the established empty/missing contracts. Native
relationship tests cover missing parent/child behavior, indexed and unindexed
child retrieval, join IDs, delete policies, and reactive behavior.
