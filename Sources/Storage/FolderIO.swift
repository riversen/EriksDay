import Foundation

/// ISO-8601 week keys (`2026-W24`) used to shard entries into subfolders.
enum WeekKey {
    static func key(for date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    static func startDate(for key: String) -> Date? {
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
}

/// Identity of a file version. Comparing stamps lets a reload skip files that
/// haven't changed — which matters most under iCloud, where reading contents
/// can block while the file is downloaded back from the cloud.
struct FileStamp: Equatable, Sendable {
    var modified: Date
    var size: Int

    init?(_ url: URL) {
        guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = v.contentModificationDate else { return nil }
        self.modified = modified
        self.size = v.fileSize ?? 0
    }
}

/// One week's decoded entries keyed by file name, with the stamps they were
/// decoded from.
struct WeekSnapshot: Sendable {
    var entries: [String: LogEntry] = [:]
    var stamps: [String: FileStamp] = [:]
}

/// Routine docs keyed by markdown file name. The sidecar can change on its own
/// (an offline translator writing into it), so both stamps are tracked.
struct RoutineSnapshot: Sendable {
    struct Item: Sendable {
        var doc: RoutineDoc
        var mdStamp: FileStamp
        var metaStamp: FileStamp?
    }
    var items: [String: Item] = [:]
}

struct IOResult<T: Sendable>: Sendable {
    var value: T
    var error: String?
}

/// All file access for the shared folder. Files are written with the
/// `completeUntilFirstUserAuthentication` protection class: it keeps data
/// unreadable on a powered-off device without blocking the background sync
/// that stricter classes can stall while the device is locked.
///
/// This is an `actor` on purpose: the
/// work runs off the main thread (coordinated iCloud reads can block for
/// seconds while a file is downloaded) and is serialized, so concurrent
/// reloads and writes never race on the same folder.
actor FolderIO {
    private let root: URL
    private var didMigrate = false

    init(root: URL) { self.root = root }

    private var entriesURL: URL { root.appendingPathComponent("entries", isDirectory: true) }
    private var routinesURL: URL { root.appendingPathComponent("routines", isDirectory: true) }
    private var mediaURL: URL { routinesURL.appendingPathComponent("media", isDirectory: true) }
    private var trashURL: URL { root.appendingPathComponent(".trash", isDirectory: true) }

    private func withAccess<T>(_ body: () -> T) -> T {
        let ok = root.startAccessingSecurityScopedResource()
        defer { if ok { root.stopAccessingSecurityScopedResource() } }
        return body()
    }

    // MARK: - Setup

    /// Create missing subfolders and (once per launch) move any pre-sharding
    /// `entries/*.json` into its week subfolder.
    func prepare() {
        withAccess {
            let fm = FileManager.default
            try? fm.createDirectory(at: entriesURL, withIntermediateDirectories: true)
            try? fm.createDirectory(at: routinesURL, withIntermediateDirectories: true)
            try? fm.createDirectory(at: mediaURL, withIntermediateDirectories: true)

            guard !didMigrate else { return }
            didMigrate = true
            let urls = (try? fm.contentsOfDirectory(at: entriesURL, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data) else { continue }
                let folder = entriesURL.appendingPathComponent(WeekKey.key(for: entry.timestamp),
                                                               isDirectory: true)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? fm.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
        }
    }

    /// Week folder names. Cheap — directory names only, no contents read.
    func weekKeys() -> Set<String> {
        withAccess {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: entriesURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return Set(urls
                .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true }
                .map { $0.lastPathComponent })
        }
    }

    // MARK: - Reading

    /// Load one week, reusing decoded entries from `prior` for every file whose
    /// stamp is unchanged. Files that vanished are simply absent from the result.
    func loadWeek(_ key: String, reusing prior: WeekSnapshot) -> IOResult<WeekSnapshot> {
        let dir = entriesURL.appendingPathComponent(key, isDirectory: true)
        var out = WeekSnapshot()
        var error: String?
        withAccess {
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &coordError) { d in
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: d, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                for url in urls where url.pathExtension == "json" {
                    let name = url.lastPathComponent
                    let stamp = FileStamp(url)
                    if let stamp, prior.stamps[name] == stamp, let cached = prior.entries[name] {
                        out.entries[name] = cached          // unchanged: no read, no decode
                        out.stamps[name] = stamp
                        continue
                    }
                    guard let data = try? Data(contentsOf: url),
                          let entry = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data)
                    else { continue }
                    out.entries[name] = entry
                    if let stamp { out.stamps[name] = stamp }
                }
            }
            if let coordError { error = coordError.localizedDescription }
        }
        return IOResult(value: out, error: error)
    }

    func loadRoutines(reusing prior: RoutineSnapshot) -> IOResult<RoutineSnapshot> {
        var out = RoutineSnapshot()
        var error: String?
        withAccess {
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: routinesURL, options: [], error: &coordError) { dir in
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                for url in urls where url.pathExtension == "md" {
                    guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                    else { continue }
                    let name = url.lastPathComponent
                    // Derive the sidecar from the md file's actual name, not
                    // id.uuidString: externally generated files use lowercase
                    // UUIDs and iOS filesystems are case-sensitive.
                    let metaURL = url.deletingPathExtension().appendingPathExtension("json")
                    let mdStamp = FileStamp(url)
                    let metaStamp = FileStamp(metaURL)
                    if let mdStamp, let old = prior.items[name],
                       old.mdStamp == mdStamp, old.metaStamp == metaStamp {
                        out.items[name] = old               // unchanged: reuse
                        continue
                    }
                    guard let mdStamp, let data = try? Data(contentsOf: url) else { continue }
                    let meta = (try? Data(contentsOf: metaURL))
                        .flatMap { try? JSONDecoder.eriksDay.decode(RoutineMeta.self, from: $0) }
                    let doc = RoutineDoc(id: id,
                                         body: String(data: data, encoding: .utf8) ?? "",
                                         updatedAt: mdStamp.modified,
                                         edits: meta?.edits ?? [],
                                         sourceLanguage: meta?.sourceLanguage,
                                         translations: meta?.translations ?? [:])
                    out.items[name] = .init(doc: doc, mdStamp: mdStamp, metaStamp: metaStamp)
                }
            }
            if let coordError { error = coordError.localizedDescription }
        }
        return IOResult(value: out, error: error)
    }

    func mediaData(_ relativePath: String) -> Data? {
        withAccess {
            let fileURL = routinesURL.appendingPathComponent(relativePath)
            var data: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &coordError) { url in
                data = try? Data(contentsOf: url)
            }
            return data
        }
    }

    // MARK: - Writing

    /// Write one entry, first clearing any copy in another week (an edited time
    /// can move it). Returns the new stamp so the caller's cache stays warm.
    func write(_ entry: LogEntry, clearingFrom weeks: Set<String>) -> IOResult<FileStamp?> {
        var stamp: FileStamp?
        var error: String?
        let name = "\(entry.id.uuidString).json"
        let targetKey = WeekKey.key(for: entry.timestamp)
        withAccess {
            let fm = FileManager.default
            for key in weeks where key != targetKey {
                let f = entriesURL.appendingPathComponent(key, isDirectory: true)
                    .appendingPathComponent(name)
                if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
            }
            let folder = entriesURL.appendingPathComponent(targetKey, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var coordError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: folder.appendingPathComponent(name),
                                           options: .forReplacing, error: &coordError) { url in
                do {
                    try JSONEncoder.eriksDay.encode(entry).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    stamp = FileStamp(url)
                } catch let writeError {
                    error = "Write failed: \(writeError.localizedDescription)"
                }
            }
            if let coordError { error = coordError.localizedDescription }
        }
        return IOResult(value: stamp, error: error)
    }

    func trashEntry(id: UUID, weekKey: String) -> String? {
        var error: String?
        withAccess {
            let src = entriesURL.appendingPathComponent(weekKey, isDirectory: true)
                .appendingPathComponent("\(id.uuidString).json")
            error = moveToTrash(src, subfolder: "entries")
        }
        return error
    }

    func writeRoutine(_ doc: RoutineDoc) -> String? {
        var error: String?
        withAccess {
            try? FileManager.default.createDirectory(at: routinesURL, withIntermediateDirectories: true)
            let mdURL = routineFileURL(id: doc.id, ext: "md")
            var coordError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: mdURL, options: .forReplacing,
                                           error: &coordError) { url in
                try? doc.body.data(using: .utf8)?.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if let coordError { error = coordError.localizedDescription }

            let meta = RoutineMeta(edits: doc.edits,
                                   sourceLanguage: doc.sourceLanguage,
                                   translations: doc.translations)
            let metaURL = routineFileURL(id: doc.id, ext: "json")
            NSFileCoordinator().coordinate(writingItemAt: metaURL, options: .forReplacing,
                                           error: &coordError) { url in
                try? JSONEncoder.eriksDay.encode(meta).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if let coordError { error = coordError.localizedDescription }
        }
        return error
    }

    func trashRoutine(id: UUID) -> String? {
        var error: String?
        withAccess {
            error = moveToTrash(routineFileURL(id: id, ext: "md"), subfolder: "routines")
                ?? moveToTrash(routineFileURL(id: id, ext: "json"), subfolder: "routines")
        }
        return error
    }

    /// Copy attached media into `routines/media/` and return the routines-
    /// relative path, so playback never depends on the original device's
    /// photo library.
    func saveMedia(_ data: Data, ext: String) -> String? {
        let name = "\(UUID().uuidString).\(ext)"
        var ok = false
        withAccess {
            try? FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
            var coordError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: mediaURL.appendingPathComponent(name),
                                           options: .forReplacing, error: &coordError) { url in
                ok = (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
            }
        }
        return ok ? "media/\(name)" : nil
    }

    // MARK: - Helpers (folder access already held)

    /// On-disk URL for a routine file, matched case-insensitively so
    /// externally-generated lowercase UUID names resolve on case-sensitive
    /// filesystems. Falls back to the canonical name for new docs.
    private func routineFileURL(id: UUID, ext: String) -> URL {
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: routinesURL, includingPropertiesForKeys: nil),
           let match = urls.first(where: {
               $0.pathExtension == ext &&
               $0.deletingPathExtension().lastPathComponent
                   .caseInsensitiveCompare(id.uuidString) == .orderedSame
           }) {
            return match
        }
        return routinesURL.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// Move a file into the hidden `.trash/<subfolder>/` rather than deleting.
    private func moveToTrash(_ src: URL, subfolder: String) -> String? {
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let destDir = trashURL.appendingPathComponent(subfolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(src.lastPathComponent)")
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving,
                                       writingItemAt: dest, options: .forReplacing,
                                       error: &coordError) { s, d in
            try? FileManager.default.moveItem(at: s, to: d)
        }
        return coordError?.localizedDescription
    }
}
