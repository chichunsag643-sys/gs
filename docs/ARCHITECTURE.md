# Architecture

## Layout

```
lib/
  main.dart               opens the DB, loads settings + notes, starts the app
  app.dart                MaterialApp, Korean locale, lock overlay
  app_scope.dart          InheritedWidget holding the services below
  data/
    database.dart         SQLCipher DB; key generated once, kept in Keystore/Keychain
    schema.dart           tables + migrations (plugin-free, used by tests)
    models.dart           Note, Folder
    hlc.dart              Hybrid Logical Clock
    note_repository.dart  in-memory cache + write-through to the DB
    settings_store.dart   per-device settings in the `meta` table
  security/app_lock.dart  biometric lock (local_auth)
  ui/                     home (list + library drawer), editor, settings, lock
```

## Data model (designed for later sync)

| table     | purpose |
|-----------|---------|
| `notes`   | `id` (UUID), `folder_id`, `title`, `content` (Quill Delta JSON), `plain_text`, `ink` (S Pen strokes JSON, schema v2), `pinned`, timestamps, `hlc`, `device_id`, `deleted` |
| `folders` | `id` (UUID), `name`, `sort_order`, timestamps, `hlc`, `device_id`, `deleted` |
| `devices` | paired devices (empty until QR pairing exists): `id`, `name`, `public_key`, `last_seen_hlc` |
| `meta`    | local-only settings: device id/name, library on/off, lock on/off, last HLC |

Rules every write follows, so sync can be added without a migration:

1. **UUID ids** — any device can create records offline without collisions.
2. **HLC stamp per record** — each change gets `hlc` from this device's
   `HlcClock` and records `device_id`. HLC strings sort in causal order, so
   "everything changed since X" is `WHERE hlc > ?` (indexed).
3. **Tombstones** — deletes set `deleted = 1` instead of removing the row,
   so deletes propagate.
4. **Per-device settings are not synced** — library on/off and the lock live
   in `meta`, so a tablet can run notepad-only while the phone uses folders.

## Planned sync (later steps)

- Transport: devices find each other on the LAN (mDNS) or over Tailscale
  (MagicDNS / 100.x addresses); no server stores data.
- Pairing: QR code carries device id, address and a public key; stored in
  `devices`.
- Merge: exchange records with `hlc > last_seen_hlc`, keep the higher HLC
  per record (LWW), and call `HlcClock.receive()` on incoming stamps. If
  concurrent edits to the same note become a problem, the Delta content can
  be upgraded to a text CRDT for that field without changing the tables.

## S Pen handwriting

`notes.ink` holds the handwriting page as JSON (`data/ink.dart`): a list of
strokes, each with its own UUID, tool (pen/highlighter), colour, width and
flat `[x, y, pressure, ...]` points. Coordinates are in a fixed 1000-unit
page width, so the drawing scales to any screen. Strokes never change once
drawn (erasing removes whole strokes), so a later sync can merge two devices'
drawings as a set of stroke ids instead of last-writer-wins on the whole page.

On the handwriting page (`ui/ink_canvas.dart`) only the pen draws and
fingers scroll; holding the S Pen side button erases.
