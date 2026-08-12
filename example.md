# Gecko Studio — Implementation Plan

## 1. Vision

Build **Gecko Studio**, a small, polished, responsive database playground that demonstrates Gecko DB's capabilities without becoming a full game.

The visual concept is:

> **A database manager with a subtle fantasy/game aesthetic.**

The application should feel closer to **TablePlus / SQLite Browser** than to an actual game.

The demo should make these Gecko capabilities immediately visible:

* Persistent storage
* CRUD
* Secondary indexes
* Filtering and sorting
* Reactive/live queries
* Transactions
* Relationships
* Fast reads/writes
* Bulk operations
* Query performance
* Database statistics
* Responsive UI

The **game-like aspect is only the data presentation**: characters, items, guilds, etc. should have attractive icons/avatars and small animations.

---

# 2. Core Concept

Use a fictional database containing four primary collections:

```text
characters
items
guilds
quests
```

Example character:

```dart
Character(
  id: '...',
  name: 'Aria',
  level: 42,
  gold: 12400,
  guildId: 'phoenix',
  className: 'Mage',
)
```

The user should be able to interact with these records exactly as they would with a database manager.

---

# 3. Main Application Layout

## Desktop / Large Tablet

Use a three-region layout:

```text
┌─────────────────────────────────────────────────────────────┐
│ Gecko Studio                              ● Database Online │
├──────────────┬──────────────────────────────────────────────┤
│              │                                              │
│ Collections  │               Main Content                   │
│              │                                              │
│ 🧙 Characters│                                              │
│ ⚔ Items      │                                              │
│ 🏰 Guilds    │                                              │
│ 📜 Quests    │                                              │
│              │                                              │
│              │                                              │
├──────────────┴──────────────────────────────────────────────┤
│ Status / query performance / database statistics            │
└─────────────────────────────────────────────────────────────┘
```

Desktop should use a persistent sidebar.

The sidebar should **not** consume excessive width.

Suggested width:

```text
220–280 px
```

---

# 4. Tablet Layout

For medium-width screens:

```text
┌─────────────────────────────────────────────┐
│ Gecko Studio                    ☰           │
├─────────────────────────────────────────────┤
│ 🧙 Characters                               │
├─────────────────────────────────────────────┤
│                                             │
│ Main content                                │
│                                             │
└─────────────────────────────────────────────┘
```

Collapse the collection sidebar into a navigation drawer.

The main content should retain comfortable margins and avoid creating excessively narrow cards.

---

# 5. Mobile Layout

Mobile should **not** attempt to squeeze the desktop database manager into a tiny screen.

Use:

```text
┌───────────────────────────┐
│ 🦎 Gecko Studio       ☰  │
├───────────────────────────┤
│ Characters                │
│                           │
│ ┌───────────────────────┐ │
│ │ 🧙 Aria               │ │
│ │ Level 42              │ │
│ │ 12,400 gold           │ │
│ │ Phoenix               │ │
│ └───────────────────────┘ │
│                           │
│ ┌───────────────────────┐ │
│ │ 🧝 Omar               │ │
│ │ Level 31              │ │
│ │  8,200 gold           │ │
│ │ Wolves                │ │
│ └───────────────────────┘ │
└───────────────────────────┘
```

Use a bottom navigation or compact menu for:

* Collections
* Query
* Live
* Database

Avoid horizontal scrolling for the primary UI.

---

# 6. Responsive Breakpoints

Use layout behavior rather than hardcoded device assumptions.

Suggested breakpoints:

```text
< 600 px
    Mobile

600–1000 px
    Tablet

> 1000 px
    Desktop
```

However, components should also respond to **available width**, not just device type.

For example:

```text
Character cards:
Desktop → 3–4 columns
Tablet  → 2 columns
Mobile  → 1 column
```

Tables should transform into cards on narrow screens rather than forcing horizontal scrolling wherever practical.

---

# 7. Screen 1 — Collections

This is the primary screen.

Sidebar:

```text
COLLECTIONS

🧙 Characters
⚔ Items
🏰 Guilds
📜 Quests
```

Selecting a collection opens its records.

Header:

```text
Characters                         + Add Character

12,482 records
```

Toolbar:

```text
🔍 Search...

Filter
Sort
Refresh
```

---

# 8. Character Presentation

Use compact cards rather than a conventional spreadsheet as the default presentation.

Example:

```text
┌────────────────────────────┐
│ 🧙                         │
│ Aria                       │
│ Mage · Level 42            │
│                            │
│ 💰 12,400                  │
│ 🏰 Phoenix                 │
│                            │
│                       →    │
└────────────────────────────┘
```

Cards should remain primarily **database records**, not game objects.

No combat stats, inventories, animations, maps, etc.

---

# 9. Optional Table View

Provide:

```text
[ Cards ] [ Table ]
```

Table mode:

```text
Name      Class    Level    Gold      Guild
────────────────────────────────────────────
Aria      Mage      42      12,400    Phoenix
Omar      Rogue     31       8,200    Wolves
Sara      Knight    27       6,800    Phoenix
```

On mobile, automatically switch to cards.

---

# 10. CRUD

Every collection must support:

### Create

```text
+ Add Character
```

Use a compact form.

### Read

Clicking a record opens its inspector.

### Update

Edit fields directly.

### Delete

Use confirmation only when appropriate.

After every operation show a subtle status message:

```text
✓ Character updated
1.37 ms
```

---

# 11. Record Inspector

Desktop:

```text
┌───────────────────────────────┐
│ Character                     │
│                               │
│ 🧙 Aria                       │
│                               │
│ ID       9f82...              │
│ Name     Aria                 │
│ Class    Mage                 │
│ Level    42                   │
│ Gold     12,400               │
│ Guild    Phoenix              │
│                               │
│ [ Edit ]       [ Delete ]     │
└───────────────────────────────┘
```

Mobile:

Use a full-screen page or modal bottom sheet.

---

# 12. Query Lab

Create a simple visual query builder.

Do **not** build a full SQL editor.

Example:

```text
Characters

WHERE
[ Level ] [ > ] [ 30 ]

AND
[ Gold ] [ > ] [ 5000 ]

SORT BY
[ Gold ] [ Descending ]

LIMIT
[ 20 ]

             [ Run Query ]
```

Result:

```text
7 results

⚡ 0.42 ms
Index: characters.level
```

This should demonstrate Gecko's query system without requiring users to understand SQL.

---

# 13. Query Presets

Provide predefined examples:

```text
High-level characters
Richest characters
Phoenix guild members
Low-level characters
Recent quests
Rare items
```

Selecting one should populate the query builder.

This lets someone understand Gecko within seconds of opening the demo.

---

# 14. Query Performance

Every query result should optionally expose:

```text
7 results
0.42 ms

Index used:
characters.level
```

Add a small expandable:

```text
Execution details
────────────────────
Planning       0.03 ms
Index lookup   0.08 ms
Read           0.14 ms
Decode         0.12 ms
Total          0.42 ms
```

If these timings aren't available from Gecko itself, don't fabricate them. Only show measurements actually provided by the implementation.

---

# 15. Live Query

Create a dedicated **Live** mode.

Example:

```text
LIVE QUERY

Characters where:

Level > 30

● Watching
```

Show:

```text
7 matching characters
```

Now edit Aria:

```text
Level: 29 → 42
```

The result should update automatically.

A subtle highlight animation should indicate:

```text
+ Aria
```

This is one of the most important demonstrations in the entire application.

---

# 16. Reactive Leaderboard

Have one tiny built-in example:

```text
RICHEST CHARACTERS
────────────────────

🥇 Aria       12,400
🥈 Omar        8,200
🥉 Sara        6,800
```

This should be backed by a Gecko reactive query.

Changing gold should immediately update the ranking.

No game mechanics required.

This demonstrates:

**data → query → watcher → UI**

beautifully.

---

# 17. Transactions

Add a simple transaction playground.

Example:

```text
TRANSACTION

3 pending operations

+ Aria      +500 gold
+ Omar      -200 gold
+ Sara      +100 gold

[ Commit ]    [ Rollback ]
```

When committed:

```text
✓ Transaction committed
```

When rolled back:

```text
↶ Transaction rolled back
```

The UI should make it obvious that the three operations form one atomic operation.

---

# 18. Index Explorer

A simple database section:

```text
INDEXES

characters
  ├─ level
  ├─ gold
  └─ guildId

items
  ├─ rarity
  └─ ownerId

quests
  └─ characterId
```

Selecting an index shows basic information:

```text
characters.level

Indexed records: 12,482

Used by:
• Level > 30
• Level = 42
• Level BETWEEN 20 AND 50
```

Do not build a complicated index visualization.

The goal is to communicate:

> Gecko doesn't just scan everything.

---

# 19. Database Dashboard

A compact dashboard accessible from the main navigation:

```text
DATABASE

Records          12,482
Collections           4
Indexes               7
Active watchers       3

Recent operation
─────────────────────
UPDATE characters/4821
1.21 ms
✓ committed
```

If Gecko exposes reliable runtime metrics, show them:

```text
Reads/sec
Writes/sec
Cache hit rate
Database size
```

Otherwise leave them out.

**Never use fake benchmark numbers in the live UI.**

---

# 20. Stress Playground

Keep this very simple.

Buttons:

```text
Generate:

[ 100 records ]
[ 1,000 records ]
[ 10,000 records ]

[ Bulk Insert ]
[ Bulk Update ]
[ Delete All ]
```

During the operation:

```text
Generating 10,000 records...

██████████████████░░  8,421 / 10,000
```

Then:

```text
✓ Complete

10,000 records
73 ms
```

Use Gecko's real measured operation duration.

This gives developers an easy way to experiment with the database.

---

# 21. Subtle Game Aesthetic

Keep this deliberately restrained.

### Use:

* Small character/item icons
* Friendly names
* Slightly playful empty states
* Tiny success animations
* Subtle record highlighting
* A Gecko mascot
* Fantasy-themed sample data

### Do NOT use:

* Maps
* Combat
* XP
* Quests as gameplay
* Player movement
* Game economy
* Inventory gameplay
* Game menus
* Character progression
* Complex animations

The application is still a **database manager**.

---

# 22. Visual Design

Use a clean developer-tool aesthetic.

Suggested visual hierarchy:

```text
Application shell
    ↓
Collection
    ↓
Records
    ↓
Record details
    ↓
Database operation
    ↓
Performance information
```

Avoid making every element colorful.

Use the Gecko branding primarily for:

* logo
* accent color
* icons
* subtle highlights

The data itself should remain easy to read.

---

# 23. Empty States

Every collection should have a useful empty state.

Example:

```text
             🧙

       No characters yet

Create your first record to
start exploring Gecko DB.

       [ + Add Character ]
```

For query results:

```text
🔍

No matching records

Try changing the filter.
```

---

# 24. Responsive Interaction Rules

### Desktop

Use:

* Sidebar
* Multi-column cards
* Split record inspector
* Persistent query toolbar

### Tablet

Use:

* Collapsible sidebar
* Two-column cards
* Inspector as modal/sheet

### Mobile

Use:

* Single-column cards
* Drawer navigation
* Full-screen record editor
* Bottom sheets for filters
* Compact performance indicators

All functionality must remain available at every size.

---

# 25. Accessibility

Implement:

* Keyboard navigation
* Focus indicators
* Semantic buttons
* Tooltips for unfamiliar icons
* Adequate touch targets
* Screen-reader-friendly labels
* No information conveyed solely through color
* Responsive text/layout
* Respect system text scaling where practical

---

# 26. Seed Dataset

On first launch create a deterministic dataset.

Suggested initial size:

```text
Characters    1,000
Items         2,000
Guilds           50
Quests        2,000
```

Use deterministic seed data so performance and behavior are reproducible.

Allow:

```text
Reset Demo Data
```

---

# 27. Database Relationships

Keep relationships simple:

```text
Character
   │
   ├── guildId ──────→ Guild
   │
   └── quests ───────→ Quest

Item
   └── ownerId ──────→ Character
```

This is enough to demonstrate Gecko's modelling and indexed relationship capabilities.

---

# 28. Demo Flow

The application should have an obvious 2-minute demonstration path.

### Step 1

Open **Characters**.

### Step 2

Edit Aria's level.

### Step 3

Open **Live Query**.

Show the result automatically updating.

### Step 4

Run:

```text
Level > 30
```

Show:

```text
7 results
0.42 ms
Index: level
```

### Step 5

Open **Transaction**.

Modify three characters.

Commit.

### Step 6

Open **Indexes**.

Show the `level` and `guildId` indexes.

### Step 7

Generate 10,000 records.

Show Gecko handling the bulk operation.

That's enough to communicate the product.

---

# 29. Architecture

Keep the demo architecture intentionally thin:

```text
Flutter UI
    │
    ▼
Gecko DB
    │
    ├── Collections
    ├── Queries
    ├── Indexes
    ├── Transactions
    └── Watchers
```

Avoid introducing another backend or networking layer.

The point of the application is to demonstrate **local Gecko DB**.

---

# 30. Important Implementation Principle

The demo should **not implement fake versions of Gecko features**.

For example:

❌ Don't fake a "live query" by periodically polling.

❌ Don't fake index performance.

❌ Don't fabricate query execution times.

❌ Don't maintain a second in-memory database just for the UI.

Instead:

```text
UI
 ↓
actual Gecko API
 ↓
actual Gecko query
 ↓
actual Gecko watcher
 ↓
actual Gecko transaction
```

The demo should effectively be a **living integration test and showcase for Gecko DB**.

---

# 31. Suggested Project Structure

```text
lib/
├── app/
│   ├── app.dart
│   ├── theme.dart
│   └── responsive.dart
│
├── database/
│   ├── database.dart
│   ├── seed.dart
│   └── schema.dart
│
├── models/
│   ├── character.dart
│   ├── item.dart
│   ├── guild.dart
│   └── quest.dart
│
├── screens/
│   ├── dashboard/
│   ├── collection/
│   ├── query/
│   ├── live/
│   ├── indexes/
│   ├── transactions/
│   └── stress/
│
├── widgets/
│   ├── record_card.dart
│   ├── record_table.dart
│   ├── record_inspector.dart
│   ├── query_builder.dart
│   ├── performance_badge.dart
│   ├── collection_sidebar.dart
│   └── responsive_shell.dart
│
└── demo/
    ├── presets.dart
    └── generators.dart
```

---

# 32. Definition of Done

The demo is complete when a developer can launch it and, without reading documentation:

* Create a record
* Edit a record
* Delete a record
* Browse records
* Search/filter records
* Sort records
* See an indexed query execute
* See a live query react to changes
* Perform a transaction
* Commit/rollback a transaction
* Inspect indexes
* Generate thousands of records
* See real operation timings
* Use the application comfortably on desktop, tablet, and phone

And most importantly:

> **The application should make Gecko DB's capabilities understandable within 2–3 minutes.**

---

# Final Product Direction

The final visual identity should be:

**Database manager:** 90%
**Playful/game aesthetic:** 10%
**Developer tool:** 100%

The key idea is **not to make Gecko DB look like a game**.

It's to make **database operations feel tangible and enjoyable**.

A developer should look at Gecko Studio and think:

> *"This is basically a really nice database browser... wait, I changed that record and the live query updated instantly."*

That's the moment the demo has done its job.
