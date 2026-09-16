# EriksDay — project context for Claude Code

A private iOS app for logging daily care information for one person, with the
data stored in a shared iCloud Drive folder so several family members can log
from their own devices.

## Architecture

- SwiftUI, iOS 17+, iPhone + iPad. No external dependencies.
- Storage is a **user-selected folder** (intended to be a shared iCloud Drive
  folder), reached through the document picker (`.fileImporter`) and persisted
  with a **security-scoped bookmark** in `UserDefaults`.
- Each `LogEntry` is one JSON file at `<folder>/entries/<ISO-week>/<uuid>.json`.
  One file per entry means two people logging at once never write the same
  file, so there is nothing to merge for new entries.
- iCloud syncs the folder between participants. The app does not use CloudKit
  or CKShare.

## Hard rules (do not break)

- **Never** place a SwiftData/Core Data/SQLite store inside the folder. A single
  store file re-uploads in full on every change and corrupts under iCloud's
  file-replacement sync. Discrete files only.
- All folder access is bracketed by `startAccessingSecurityScopedResource()` /
  `stopAccessingSecurityScopedResource()`, and reads/writes go through
  `NSFileCoordinator`.
- Security-scoped bookmarks are device-specific. Do not try to sync the bookmark
  between devices; each device picks the folder once.
- No force-unwraps in the storage layer. Surface failures via
  `FolderStore.lastError`.

## Layout

```
Sources/
  EriksDayApp.swift        app entry, injects FolderStore + AppLanguage
  Models/LogEntry.swift    LogKind, Amount, Mood, EditRecord, LogEntry (+ day-span helpers)
  Models/RoutineDoc.swift  RoutineDoc + RoutineMeta sidecar
  Models/LocalizedText.swift  free text + source language + translations
  Storage/FolderIO.swift   actor: all file access, off the main thread
  Storage/FolderStore.swift  @MainActor cache the UI reads; optimistic writes
  Localization/Localization.swift  Language (en/nb/nn) + AppLanguage + Strings
  Views/ContentView.swift  tabs, folder picker, flag toggle, app-icon badge
  Views/LogView.swift      quick buttons + day strip + timeline + entry editor
  Views/RoutinesView.swift routine list, markdown editor + preview, media
project.yml                XcodeGen spec
```

On disk, inside the shared folder:

```
entries/<ISO-week>/<uuid>.json   one file per event, sharded by ISO week in UTC
routines/<uuid>.md               markdown body (the source text)
routines/<uuid>.json             sidecar: edits, sourceLanguage, translations
routines/media/<uuid>.<ext>      copied photos/videos referenced by markdown
.trash/<entries|routines>/…      deletes and superseded copies move here; nothing is erased
```

Free text (entry notes, routine bodies) records the language it was written
in and carries a `translations` map an offline process can fill; the UI falls
back to the closest available language. A routine loaded while its sidecar
couldn't be read is marked `metaLoaded: false`, and saving it merges into the
sidecar instead of replacing it — an audit log and offline translations are
not reproducible.

Two devices editing the same entry within one iCloud sync window still resolve
last-writer-wins per file, and a superseded copy can end up in `.trash/`
rather than in `entries/`. Nothing is erased, but until there is a restore UI
(roadmap item 2) recovering it means reaching into the folder by hand. Every entry keeps an `edits` audit
log of which device changed it and when.

Separately, in the app container (never the shared folder), `FolderIO` keeps
a **local cache** of decoded snapshots under
`Library/Caches/EriksDay/v1/<hash-of-folder-path>/` — one binary plist per
week plus `routines.plist`. A cold launch paints from it immediately, then the
stamp-based reconcile reads only files that are new or changed. It is
regenerable (the OS may purge it), excluded from backups, written with the
same protection class as the entries, keyed per folder so switching folders
never mixes data, and wiped when the folder is unlinked. Bump `cacheVersion`
whenever a snapshot type changes shape. `unswept.plist` there lists entries
whose superseded copy a save couldn't clear from another week; `refresh()`
retries them, hides what it can't settle yet, and lists (names only) every
week folder for an entry filed twice — left by any device — keeping the
newest copy. The `storage` os_log category reports
`primed N`, per-week `reused/read` counts, the `entries: N rows` the UI sees,
and every `lastError`, for diagnosing it with `log show`.

The DEBUG-only launch arguments `-demoData` (attach a local seeded folder),
`-tabRoutines` and `-demoEditRoutine` (save an edit to the routine with the
lowest id) exist so a shell script can drive storage without the UI.

## Build

```
brew install xcodegen      # once
xcodegen generate          # regenerates EriksDay.xcodeproj from project.yml
open EriksDay.xcodeproj
```

Set the signing team in Xcode (Signing & Capabilities, automatic), or set
`DEVELOPMENT_TEAM` in `project.yml` so it survives regeneration. No iCloud
capability is needed: folder access comes from the user's pick, not an
entitlement.

## Roadmap

Done: entry detail sheet, history by day, routines (markdown docs with inline
media), three languages, weekly sharding, trash, per-entry audit log, moving
file I/O off the main actor with stamp-based incremental reloads, and a local
cache so cold launch no longer re-reads every file.

Next, roughly in order:

1. `NSFilePresenter` on the folder for live updates, so another device's
   change appears without a foreground refresh. The stamp diffing in
   `FolderIO` is what this would drive.
2. A way to see and restore what's in `.trash/` from inside the app.
3. The offline translation pass that fills `translations` in entry notes and
   routine sidecars.
4. A digest of the body in the routine sidecar, so a reader can tell when a
   sidecar and body were not written together (a kill between the two writes
   can still pair an old body with a new sidecar).
5. Errors as a non-modal banner. The root alert on `lastError` tears down any
   sheet that is open — a refresh error while the routine editor is up
   discards the unsaved text. Media errors already stay inside the editor.

## Code style

- Concise, neutral, code-first. Pragmatic error handling, sparse comments.
- Match Apple's current SwiftUI conventions for iOS 17+.
- No placeholder tokens, no filler.
