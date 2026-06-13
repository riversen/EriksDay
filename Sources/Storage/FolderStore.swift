import Foundation

/// Reads and writes log entries as discrete JSON files inside a user-selected
/// folder (intended to be a shared iCloud Drive folder). iCloud syncs the
/// folder between participants; one file per entry keeps writers from
/// colliding on the same file.
///
/// IMPORTANT: never put a SwiftData/Core Data/SQLite store in this folder.
/// A single store file re-uploads in full on every change and corrupts under
/// iCloud's file-replacement sync. Discrete files only.
@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var folderName: String?
    @Published var lastError: String?

    private let bookmarkKey = "eriksDayFolderBookmark"
    private var folderURL: URL?

    init() {
        restoreFolder()
    }

    var hasFolder: Bool { folderURL != nil }

    /// Call with the URL returned by the folder importer.
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
            reload()
        } catch {
            lastError = "Couldn't save access to that folder: \(error.localizedDescription)"
        }
    }

    /// Resolve the saved bookmark on launch. Bookmarks are device-specific, so
    /// each device picks the folder once; this just re-opens that choice.
    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            folderURL = url
            folderName = url.lastPathComponent
            if stale { setFolder(url) } else { reload() }
        } catch {
            lastError = "Lost access to the folder. Please choose it again."
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            folderURL = nil
            folderName = nil
        }
    }

    private var entriesURL: URL? {
        folderURL?.appendingPathComponent("entries", isDirectory: true)
    }

    private func ensureSubfolders() throws {
        guard let entriesURL else { return }
        try FileManager.default.createDirectory(at: entriesURL, withIntermediateDirectories: true)
    }

    func add(_ entry: LogEntry) { save(entry) }

    /// Persist an edited entry. The file is keyed by `id`, so this overwrites
    /// the existing JSON in place.
    func update(_ entry: LogEntry) { save(entry) }

    private func save(_ entry: LogEntry) {
        guard let folderURL, let entriesURL else {
            lastError = "No folder selected yet."
            return
        }
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }

        let fileURL = entriesURL.appendingPathComponent("\(entry.id.uuidString).json")
        coordinatedWrite(to: fileURL) { url in
            let data = try JSONEncoder.eriksDay.encode(entry)
            try data.write(to: url, options: .atomic)
        }
        reload()
    }

    func delete(_ entry: LogEntry) {
        guard let folderURL, let entriesURL else { return }
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }

        let fileURL = entriesURL.appendingPathComponent("\(entry.id.uuidString).json")
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forDeleting, error: &coordError) { url in
            try? FileManager.default.removeItem(at: url)
        }
        if let coordError { lastError = coordError.localizedDescription }
        reload()
    }

    /// Reload everything from disk. Low volume in this first iteration, so a
    /// full re-read is fine; move off-main and diff if volume grows.
    func reload() {
        guard let folderURL, let entriesURL else { return }
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }

        var loaded: [LogEntry] = []
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: entriesURL, options: [], error: &coordError) { dir in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data)
                else { continue }
                loaded.append(entry)
            }
        }
        if let coordError { lastError = coordError.localizedDescription }
        entries = loaded.sorted { $0.timestamp > $1.timestamp }
    }

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
