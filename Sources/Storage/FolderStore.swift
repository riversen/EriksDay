import Foundation
import UIKit

/// Reads and writes data as discrete files inside a user-selected folder
/// (intended to be a shared iCloud Drive folder). One file per entry keeps
/// writers from colliding; log entries are sharded into per-week subfolders so
/// not everything has to be loaded at once.
///
/// IMPORTANT: never put a SwiftData/Core Data/SQLite store in this folder.
/// Discrete files only.
@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var routines: [RoutineDoc] = []
    @Published private(set) var folderName: String?
    @Published var lastError: String?

    private let bookmarkKey = "eriksDayFolderBookmark"
    private var folderURL: URL?

    /// Per-week cache so weeks load independently and on demand.
    private var entriesByWeek: [String: [LogEntry]] = [:]
    private var loadedWeeks: Set<String> = []
    private var knownWeeks: Set<String> = []

    /// Label written into each edit record — "which device". iOS 16+ returns a
    /// generic model for `UIDevice.name`, so a vendor-id suffix disambiguates.
    let deviceName: String

    init() {
        deviceName = Self.resolveDeviceName()
        restoreFolder()
    }

    var hasFolder: Bool { folderURL != nil }

    private static func resolveDeviceName() -> String {
        let key = "deviceName"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let base = UIDevice.current.name
        let suffix = UIDevice.current.identifierForVendor?.uuidString.prefix(4) ?? "????"
        let name = "\(base) (\(suffix))"
        UserDefaults.standard.set(name, forKey: key)
        return name
    }

    // MARK: - Folder selection

    func setFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            folderURL = url
            folderName = url.lastPathComponent
            try ensureSubfolders()
            reloadAll()
        } catch {
            lastError = "Couldn't save access to that folder: \(error.localizedDescription)"
        }
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            folderURL = url
            folderName = url.lastPathComponent
            if stale { setFolder(url) } else { reloadAll() }
        } catch {
            lastError = "Lost access to the folder. Please choose it again."
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            folderURL = nil
            folderName = nil
        }
    }

    // MARK: - Folder layout

    private var entriesURL: URL? { folderURL?.appendingPathComponent("entries", isDirectory: true) }
    private var routinesURL: URL? { folderURL?.appendingPathComponent("routines", isDirectory: true) }
    private var mediaURL: URL? { routinesURL?.appendingPathComponent("media", isDirectory: true) }
    private var trashURL: URL? { folderURL?.appendingPathComponent(".trash", isDirectory: true) }

    private func ensureSubfolders() throws {
        let fm = FileManager.default
        if let entriesURL { try fm.createDirectory(at: entriesURL, withIntermediateDirectories: true) }
        if let routinesURL { try fm.createDirectory(at: routinesURL, withIntermediateDirectories: true) }
        if let mediaURL { try fm.createDirectory(at: mediaURL, withIntermediateDirectories: true) }
    }

    private func weekFolderURL(for date: Date) -> URL? {
        entriesURL?.appendingPathComponent(weekKey(for: date), isDirectory: true)
    }

    /// ISO-8601 week key like `2026-W24`.
    private func weekKey(for date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    private func startDate(forWeekKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[1].hasPrefix("W"),
              let year = Int(parts[0]), let week = Int(parts[1].dropFirst()) else { return nil }
        let cal = Calendar(identifier: .iso8601)
        var comps = DateComponents()
        comps.yearForWeekOfYear = year
        comps.weekOfYear = week
        comps.weekday = cal.firstWeekday
        return cal.date(from: comps)
    }

    private func withFolderAccess<T>(_ body: () -> T) -> T {
        let access = folderURL?.startAccessingSecurityScopedResource() ?? false
        defer { if access { folderURL?.stopAccessingSecurityScopedResource() } }
        return body()
    }

    /// The earliest day that has any entry, from the week folder names (cheap —
    /// no file contents read). Drives how far back the day browser reaches.
    var earliestEntryDate: Date? {
        knownWeeks.sorted().first.flatMap { startDate(forWeekKey: $0) }
    }

    // MARK: - Log entries

    func add(_ entry: LogEntry) { save(entry) }
    func update(_ entry: LogEntry) { save(entry) }

    private func save(_ entry: LogEntry) {
        guard hasFolder, entriesURL != nil else {
            lastError = "No folder selected yet."
            return
        }
        var e = entry
        e.edits.append(EditRecord(device: deviceName, date: .now))

        withFolderAccess {
            refreshKnownWeeksLocked()
            removeEntryFilesEverywhereLocked(id: e.id)       // drop any stale (e.g. week changed)
            guard let folder = weekFolderURL(for: e.timestamp) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent("\(e.id.uuidString).json")
            coordinatedWrite(to: fileURL) { url in
                try JSONEncoder.eriksDay.encode(e).write(to: url, options: .atomic)
            }
        }
        refreshKnownWeeks()
        let key = weekKey(for: e.timestamp)
        loadedWeeks.remove(key)
        loadWeek(key)
        rebuildEntries()
    }

    func delete(_ entry: LogEntry) {
        guard hasFolder else { return }
        withFolderAccess {
            guard let src = weekFolderURL(for: entry.timestamp)?
                .appendingPathComponent("\(entry.id.uuidString).json") else { return }
            moveToTrash(src, subfolder: "entries")
        }
        let key = weekKey(for: entry.timestamp)
        loadedWeeks.remove(key)
        loadWeek(key)
        rebuildEntries()
    }

    /// Ensure the week containing `date` is loaded (called as the day browser
    /// moves to older days).
    func ensureLoaded(weekOf date: Date) {
        let key = weekKey(for: date)
        guard !loadedWeeks.contains(key), knownWeeks.contains(key) else { return }
        loadWeek(key)
        rebuildEntries()
    }

    func reloadAll() {
        guard hasFolder else { return }
        // Folders picked by an earlier build won't have the routines/ subfolder
        // yet; create any missing subfolders before reading or writing.
        withFolderAccess { try? ensureSubfolders() }
        migrateLooseEntries()
        refreshKnownWeeks()
        let target = loadedWeeks.union(recentWeekKeys()).intersection(knownWeeks)
        entriesByWeek = [:]
        loadedWeeks = []
        for key in target { loadWeek(key) }
        rebuildEntries()
        reloadRoutines()
    }

    private func recentWeekKeys(daysBack: Int = 14) -> Set<String> {
        let cal = Calendar.current
        var keys: Set<String> = []
        for offset in 0...daysBack {
            if let d = cal.date(byAdding: .day, value: -offset, to: .now) {
                keys.insert(weekKey(for: d))
            }
        }
        return keys
    }

    private func loadWeek(_ key: String) {
        guard let dir = entriesURL?.appendingPathComponent(key, isDirectory: true) else { return }
        var loaded: [LogEntry] = []
        withFolderAccess {
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &coordError) { d in
                let urls = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
                for url in urls where url.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: url),
                          let e = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data) else { continue }
                    loaded.append(e)
                }
            }
            if let coordError { lastError = coordError.localizedDescription }
        }
        entriesByWeek[key] = loaded
        loadedWeeks.insert(key)
    }

    private func rebuildEntries() {
        entries = loadedWeeks.flatMap { entriesByWeek[$0] ?? [] }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private func refreshKnownWeeks() {
        knownWeeks = Set(withFolderAccess { availableWeekKeysLocked() })
    }

    /// Assumes folder access is already held.
    private func refreshKnownWeeksLocked() {
        knownWeeks = Set(availableWeekKeysLocked())
    }

    private func availableWeekKeysLocked() -> [String] {
        guard let entriesURL else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: entriesURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true }
            .map { $0.lastPathComponent }
    }

    /// Move any pre-sharding `entries/*.json` files into their week subfolder.
    private func migrateLooseEntries() {
        withFolderAccess {
            guard let entriesURL else { return }
            let urls = (try? FileManager.default.contentsOfDirectory(at: entriesURL, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data),
                      let folder = weekFolderURL(for: entry.timestamp) else { continue }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
        }
    }

    /// Assumes folder access is held. Removes any copy of an entry across weeks
    /// (used before rewriting, e.g. when an edit moved it to another week).
    private func removeEntryFilesEverywhereLocked(id: UUID) {
        guard let entriesURL else { return }
        for key in knownWeeks {
            let f = entriesURL.appendingPathComponent(key, isDirectory: true)
                .appendingPathComponent("\(id.uuidString).json")
            if FileManager.default.fileExists(atPath: f.path) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    // MARK: - Routines (markdown docs + media)

    func saveRoutine(_ doc: RoutineDoc) {
        guard hasFolder, let routinesURL else {
            lastError = "No folder selected yet."
            return
        }
        var d = doc
        d.edits.append(EditRecord(device: deviceName, date: .now))
        withFolderAccess {
            try? FileManager.default.createDirectory(at: routinesURL, withIntermediateDirectories: true)
            let mdURL = routinesURL.appendingPathComponent("\(d.id.uuidString).md")
            coordinatedWrite(to: mdURL) { url in
                try d.body.data(using: .utf8)?.write(to: url, options: .atomic)
            }
            let metaURL = routinesURL.appendingPathComponent("\(d.id.uuidString).json")
            coordinatedWrite(to: metaURL) { url in
                try JSONEncoder.eriksDay.encode(RoutineMeta(edits: d.edits)).write(to: url, options: .atomic)
            }
        }
        reloadRoutines()
    }

    func deleteRoutine(_ doc: RoutineDoc) {
        guard hasFolder, let routinesURL else { return }
        withFolderAccess {
            moveToTrash(routinesURL.appendingPathComponent("\(doc.id.uuidString).md"), subfolder: "routines")
            moveToTrash(routinesURL.appendingPathComponent("\(doc.id.uuidString).json"), subfolder: "routines")
        }
        reloadRoutines()
    }

    /// Copy attached media into `routines/media/` and return the routines-
    /// relative path (e.g. `media/<uuid>.jpg`). Copying means we never depend
    /// on the original device's photo library.
    func saveMedia(_ data: Data, ext: String) -> String? {
        guard hasFolder, let mediaURL else { return nil }
        let name = "\(UUID().uuidString).\(ext)"
        var ok = false
        withFolderAccess {
            try? FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
            coordinatedWrite(to: mediaURL.appendingPathComponent(name)) { url in
                try data.write(to: url, options: .atomic)
                ok = true
            }
        }
        return ok ? "media/\(name)" : nil
    }

    func mediaData(_ relativePath: String) -> Data? {
        guard hasFolder, let routinesURL else { return nil }
        return withFolderAccess {
            let fileURL = routinesURL.appendingPathComponent(relativePath)
            var data: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordError) { url in
                data = try? Data(contentsOf: url)
            }
            return data
        }
    }

    func reloadRoutines() {
        guard hasFolder, let routinesURL else { return }
        var loaded: [RoutineDoc] = []
        withFolderAccess {
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: routinesURL, options: [], error: &coordError) { dir in
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for url in urls where url.pathExtension == "md" {
                    guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                          let data = try? Data(contentsOf: url) else { continue }
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    let metaURL = dir.appendingPathComponent("\(id.uuidString).json")
                    let edits = (try? Data(contentsOf: metaURL))
                        .flatMap { try? JSONDecoder.eriksDay.decode(RoutineMeta.self, from: $0) }?.edits ?? []
                    loaded.append(RoutineDoc(id: id, body: body, updatedAt: modified, edits: edits))
                }
            }
            if let coordError { lastError = coordError.localizedDescription }
        }
        routines = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Trash & coordinated writes

    /// Move a file into the hidden `.trash/<subfolder>/` rather than deleting.
    /// Assumes folder access is held.
    private func moveToTrash(_ src: URL, subfolder: String) {
        guard let trashURL, FileManager.default.fileExists(atPath: src.path) else { return }
        let destDir = trashURL.appendingPathComponent(subfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(src.lastPathComponent)")
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving,
                                       writingItemAt: dest, options: .forReplacing,
                                       error: &coordError) { s, d in
            try? FileManager.default.moveItem(at: s, to: d)
        }
        if let coordError { lastError = coordError.localizedDescription }
    }

    /// Assumes folder access is held by the caller.
    private func coordinatedWrite(to url: URL, _ body: (URL) throws -> Void) {
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordinated in
            do { try body(coordinated) }
            catch { lastError = "Write failed: \(error.localizedDescription)" }
        }
        if let coordError { lastError = coordError.localizedDescription }
    }
}

extension JSONEncoder {
    static var eriksDay: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var eriksDay: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
