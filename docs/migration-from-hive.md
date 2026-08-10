# Migrating from Hive / SharedPreferences

`gecko_db` is designed as a drop-in replacement for Hive boxes and
SharedPreferences-style key-value stores, with the important difference that
you no longer hand-roll an observable layer: widgets consume live, typed
queries and `Stream`s directly.

This guide covers the mapping, the explicit limitations, and a concrete data
import.

## Conceptual mapping

| Hive | gecko_db |
|---|---|
| `Box<Map>` / `Box<T>` | `Database.collection<T>` (typed) |
| `box.put(key, value)` | `collection.put(model)` |
| `box.get(key)` | `collection.get(id)` |
| `box.delete(key)` | `collection.delete(id)` |
| `box.watch(key)` | `collection.watch(id)` (a `Stream<T?>`) |
| `box.watch()` | `collection.watchAll()` (a `Stream<List<T>>`) |
| `Box.open(...)` | `Database.open(path, config: ...)` |
| manual observable lists / `ValueListenable` | `StreamBuilder` over `watch` streams |
| — | `collection.where(...).watch()` (reactive queries) |

## The five-minute path

```dart
import 'package:gecko_db/gecko_db.dart';

// The public entry point (native file backend; there is no in-memory mode).
final db = await Database.open('app_data/app.db');

final users = db.collection<User>(
  'users',
  toRow: (u) => {'name': u.name, 'age': u.age},   // hand-written, no codegen
  fromRow: (r) => User((r as Map)['name'] as String, (r)['age'] as int),
  id: (u) => u.id,
);

await users.put(User('u1', 'Alice', 30));          // upsert
final alice = await users.get('u1');               // User?
await users.delete('u1');
```

## Importing existing Hive data

Because `gecko_db` is plain Dart with a transactional write path, importing is
a straightforward read-Hive → write-gecko loop. This example is **runnable**
(see `examples/`); it reads a Hive box's entries and writes them into a
`gecko_db` collection in one `writeTxn`:

```dart
import 'package:gecko_db/gecko_db.dart';
import 'package:hive/hive.dart';

Future<void> importHiveBox({
  required Database db,
  required Box<dynamic> box,
  required String collectionName,
}) async {
  final col = db.collection<Map<String, Object?>>(
    collectionName,
    toRow: (m) => m,
    fromRow: (m) => Map<String, Object?>.from(m as Map),
    id: (m) => m['_hiveKey'],
  );
  // One atomic transaction: the import is all-or-nothing.
  await db.writeTxn((txn) async {
    for (final entry in box.toMap().entries) {
      await txn.put(
        collectionName,
        entry.key.toString(),
        {'_hiveKey': entry.key, ...?entry.value as Map?},
      );
    }
  });
}
```

Notes:
- Hive keys may be non-String; convert to a stable String id or keep the raw
  value under a dedicated field (`_hiveKey` above).
- Nested `Map`/`List` values map directly (the wire codec supports them).
- Run imports at most once (guard on a `_imported` flag or check
  `col.get('marker')`).

## SharedPreferences

For small settings that fit in a `Map<String, Object?>`, keep the same shape:

```dart
final settings = db.collection<Map<String, Object?>>(
  'settings',
  toRow: (m) => m,
  fromRow: (m) => Map<String, Object?>.from(m as Map),
  id: (m) => m['key'],
);
await settings.put({'key': 'theme', 'value': 'dark'});
final theme = (await settings.get('theme'))?['value'];
```

## Explicit limitations

- **`gecko_db` is asynchronous** — every call returns a `Future`; Hive's
  synchronous `box.get` has no direct equivalent (use `await`).
- **No type adapter registry** — models map through hand-written
  `toRow`/`fromRow` pairs (no codegen; ADR-0001). There is no Hive-ecosystem
  type adapter compatibility.
- **Keys are record ids** — unlike Hive's arbitrary keys, a collection's key
  comes from the `id:` extractor; for a flat key-value migration use
  `id: (v) => v['key']`-style models.
- **Physical encryption / security** — see `SECURITY.md` for what is and is
  not claimed.
- **Reactivity is stream-based** — migrate UI code from `ValueListenable` /
  manual observer lists to `StreamBuilder` over `watch`/`watchAll`/`where()`.

## Next steps

- Tier 2 queries: `collection.where().range('age', min: 18).findAll()`
- Tier 3 relationships, transactions, sync, attachments, migrations
- See `docs/api.md` for the full API surface and `examples/` for runnable code.
