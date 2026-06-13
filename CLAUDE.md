# EriksDay — project context for Claude Code

A private iOS app for logging daily care information for one person, with the
data stored in a shared iCloud Drive folder so several family members can log
from their own devices.

## Architecture

- SwiftUI, iOS 17+, iPhone + iPad. No external dependencies.
- Storage is a **user-selected folder** (intended to be a shared iCloud Drive
  folder), reached through the document picker (`.fileImporter`) and persisted
  with a **security-scoped bookmark** in `UserDefaults`.
- Each `LogEntry` is one JSON file at `<folder>/entries/<uuid>.json`. One file
  per entry means two people logging at once never write the same file, so
  there is nothing to merge for new entries.
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
  Models/LogEntry.swift    Codable structs + enums (LogKind, Amount)
  Storage/FolderStore.swift  bookmark mgmt + coordinated file-per-entry I/O
  Localization/Localization.swift  Language + AppLanguage + Strings table
  Views/ContentView.swift  router (folder picker vs log) + importer + alert + flag toggle
  Views/LogView.swift      one-tap buttons + today's timeline + entry editor
project.yml                XcodeGen spec
```

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

## Roadmap (build in this order)

1. Entry detail sheet: meal amount, sleep/nap quality, sleep spans
   (`endTimestamp`), and a note field. Long-press a quick button to open it.
2. History beyond today: group entries by day; simple daily summary.
3. Section 2, general info: a small set of editable docs
   (`<folder>/info/<topic>.md` or `.json`), rarely edited, last-write-wins.
4. Section 3, photos: image files under `<folder>/photos/`, with locally
   generated thumbnails.
5. Robustness: an `NSFilePresenter` on the entries folder for live updates,
   per-file coordination, and moving file I/O off the main actor as volume
   grows. Optional local-only cache (SwiftData, not synced) over the folder.

## Code style

- Concise, neutral, code-first. Pragmatic error handling, sparse comments.
- Match Apple's current SwiftUI conventions for iOS 17+.
- No placeholder tokens, no filler.
