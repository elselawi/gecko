# Native, Web, and in-memory route matrix

M7.1 records the current execution boundary without introducing a persistent
Rust query registry. Public API/model mapping, migration callbacks, reactive
lifecycle, and relationship policy remain Dart-owned.

| Operation | Native file / Web-Wasm OPFS | Transitional in-memory | Snapshot boundary | Rows transferred to Dart |
|---|---|---|---|---|
| Raw put/delete/batch | Dart `RawEngine` → native worker → Rust/redb | Dart `RawEngine` → `InMemoryBackend` | One write transaction | None; affected keys only |
| Indexed equality query | Rust durable index join | Dart `SecondaryIndex` + point reads | One native/in-memory snapshot | Matching rows |
| Indexed range/prefix/multi-eq | Rust durable-index intersection + predicate recheck | Dart reference index + Dart predicate | One snapshot | Matching rows |
| Unindexed query | Rust predicate pushdown | Dart full scan/predicate | One snapshot | Matching rows |
| Sorted/limited query | Rust index-ordered or top-K route | Dart materialization/sort | One snapshot | Window rows |
| Unindexed `count()` | Rust predicate count | Dart scan/count | One snapshot | Scalar only |
| Indexed `count()` | Rust durable-index candidate count + predicate recheck | Dart scan/count | One snapshot | Scalar only |
| Unindexed `distinct()` | Rust field-byte extraction; Dart decode/dedup | Dart scan/dedup | One snapshot | Matching field bytes |
| Indexed `distinct()` | Rust durable-index candidate field extraction; Dart decode/dedup | Dart scan/dedup | One snapshot | Matching field bytes |
| Relationship `parent()` | Rust child FK extraction + parent point read | Dart snapshot point reads | One snapshot | Parent row only |
| Relationship `children()` | Rust durable-index lookup or FK predicate push | Dart index lookup or full scan | One snapshot | Matching child rows |
| `loadAllChildren()` | Rust union of indexed FK ranges or Rust FK matching | Dart full child scan | One snapshot | Matching child rows |
| Many-to-many IDs | Rust snapshot join scan/filter | Dart join scan/filter | One snapshot | Matching encoded IDs |
| Relationship delete policy | Dart policy, callbacks, change-feed events; Rust atomic batch | Dart policy and atomic batch | One write transaction | No query rows beyond policy inputs |
| Raw inclusive scan | Worker snapshot range scan | In-memory snapshot scan | Caller snapshot | Requested rows |
| Raw exclusive scan | Dart compatibility filtering over snapshot result | Dart snapshot filtering | Caller snapshot | Requested rows |
| Web worker protocol | Shared native dispatch; JSON-safe byte/list conversion | Not applicable | Worker-owned snapshot ID | Same as native route |

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
Missing tables/rows use the established empty/missing contracts. Native and
in-memory relationship tests cover missing parent/child behavior, indexed and
unindexed child retrieval, join IDs, delete policies, and reactive behavior.
