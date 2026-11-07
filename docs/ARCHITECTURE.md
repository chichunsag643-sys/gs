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
| `attachments` | voice memos (schema v3; synced, files separately): `id`, `note_id`, `kind` (`audio`), `mime`, `duration_ms`, `size_bytes`, `sha256`, timestamps, `hlc`, `device_id`, `deleted` |
| `devices` | paired devices (synced): `id`, `name`, `addresses`, `port`, `platform`, `hlc`, `device_id`, `deleted` |
| `peer_state` | local-only sync progress per peer: cursors, last address, manual address, last error |
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

## Sync (lib/sync/)

```
sync/
  sync_service.dart   server, client, pairing, LAN beacon, scheduling
  sync_store.dart     change feed (seq), LWW merge, device list, peer cursors
  transport.dart      length-prefixed TCP frames, local/Tailscale addresses
  crypto.dart         AES-256-GCM (package:cryptography)
  pairing.dart        QR invite format, one-time pairing window
  blob_store.dart     interface for attachment files (voice memos)
ui/sync_screen.dart   설정 → 기기 동기화, QR show/scan
```

- **Transport**: every device listens on TCP 47800 while the app is open.
  One request frame, one reply frame per connection:
  `[key id: 1 byte][length: 4 bytes][AES-GCM sealed JSON]`. Peers are
  reached at the addresses they publish (LAN first, Tailscale 100.64/10
  last), the last address that worked, or one the user typed in. On the
  same Wi-Fi an encrypted UDP broadcast beacon (47801) finds changed IPs.
- **Change feed**: schema v4 adds a local `seq` column to every synced table,
  stamped by SQLite triggers from `sync_counter` on every insert/update,
  including merged rows. A peer asks for "rows with seq > N". HLC alone
  can't do this, because merged rows keep their original, possibly older,
  HLC. New synced tables call `addSyncTracking(db, table)` in their
  migration and need nothing else.
- **Exchange**: the caller sends its rows since the peer's last ack plus its
  cursor into the peer's feed; the reply carries the peer's rows past that
  cursor and an ack. Batches of 300 repeat until both sides are done.
  Cursors live in the local-only `peer_state` table.
- **Merge**: per record, higher HLC wins; equal or older is ignored, so
  repeats are no-ops and echoes stop after one hop. Merged stamps go
  through `HlcClock.receive()`. Unknown columns from newer app versions are
  dropped.
- **When**: local edits push to all peers after 0.7 s; merges are relayed
  to the other peers the same way; every 30 s and on app resume a full
  round runs, which also pulls what was missed while offline.
- **Pairing**: the QR code has the host's id, addresses, port and a one-time
  32-byte key valid while the QR screen is open (max 10 min). The joining
  device sends its device row sealed with that key; the host replies with
  the group key and the device list. `devices` is a synced table, so every
  device learns about every other one. The group key never appears in the
  QR code.
- **Removal**: tombstones the device row; devices refuse its requests and
  tell it, and it leaves the group. (It keeps the notes it already had.)
- **Attachments**: the `attachments` rows sync like notes. Files move
  separately (`type: blob`, checked by sha256) and only to devices whose
  `audio_sync` setting is `all`. The voice memo feature implements
  `SyncBlobStore`.

## Voice memos

Recording (`ui/voice_recorder_sheet.dart`, `record` package): AAC-LC mono
64 kbps .m4a, about 0.5 MB per minute. While recording, a microphone
foreground service (`RecordingService.kt`) keeps the mic open with the screen
off.

Storage (`data/attachment_repository.dart`): the `attachments` row is the
synced metadata; the audio is a file `<app support>/attachments/<id>.m4a`,
outside the database. Rows follow the same rules as notes (UUID, HLC from
the shared clock, tombstones).

Sync contract (implemented by the sync step): sync the `attachments` rows
like any other table, then copy audio files separately by id, verified by
`sha256`. Each device decides in its own `meta.audio_sync`:
`text_only` (default) never downloads other devices' audio, `all` does
(`AttachmentRepository.wantsBlobs / hasBlob / blobFile / importBlob`).
Recordings made on a device always stay on it.

Transcription (`audio/transcriber.dart` → `Transcriber.kt`): Android's
`SpeechRecognizer.createOnDeviceSpeechRecognizer` only (no network
fallback). The .m4a is decoded with MediaCodec to 16 kHz mono PCM and fed
through a pipe (`EXTRA_AUDIO_SOURCE`, segmented session), so it needs
Android 13+. If the Korean model is missing the system is asked to download
it. The text is appended to the note itself, so it syncs with the note.

## S Pen handwriting

`notes.ink` holds the handwriting page as JSON (`data/ink.dart`): a list of
strokes, each with its own UUID, tool (pen/highlighter), colour, width and
flat `[x, y, pressure, ...]` points. Coordinates are in a fixed 1000-unit
page width, so the drawing scales to any screen. Strokes never change once
drawn (erasing removes whole strokes), so a later sync can merge two devices'
drawings as a set of stroke ids instead of last-writer-wins on the whole page.

On the handwriting page (`ui/ink_canvas.dart`) only the pen draws and
fingers scroll; holding the S Pen side button erases.
