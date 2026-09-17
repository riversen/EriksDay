import Foundation
import CryptoKit
import os

/// ISO-8601 week keys (`2026-W24`) used to shard entries into subfolders.
enum WeekKey {
    /// ISO weeks in UTC, so every device — whatever its time zone — files the
    /// same instant in the same folder. A local day can straddle a UTC week
    /// boundary, so readers look at the neighbouring weeks of a day as well.
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    static func key(for date: Date) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    static func startDate(for key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[1].hasPrefix("W"),
              let year = Int(parts[0]), let week = Int(parts[1].dropFirst()) else { return nil }
        let cal = calendar
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
struct FileStamp: Equatable, Codable, Sendable {
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
struct WeekSnapshot: Codable, Sendable {
    var entries: [String: LogEntry] = [:]
    var stamps: [String: FileStamp] = [:]
}

/// Routine docs keyed by markdown file name. The sidecar can change on its own
/// (an offline translator writing into it), so both stamps are tracked.
struct RoutineSnapshot: Codable, Sendable {
    struct Item: Codable, Sendable {
        var doc: RoutineDoc
        var mdStamp: FileStamp
        var metaStamp: FileStamp?
    }
    var items: [String: Item] = [:]

    /// Just the file identities, for deciding whether anything changed.
    var stampsOnly: [String: [FileStamp?]] { items.mapValues { [$0.mdStamp, $0.metaStamp] } }
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
    private let key: String
    private var didMigrate = false
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EriksDay",
                                       category: "storage")

    init(root: URL) {
        self.root = root
        self.key = Self.cacheKey(for: root)
    }

    /// The folder whose cache may currently be written, process-wide. Set
    /// synchronously when a folder is attached and checked when each cache
    /// operation actually *executes*, so a call already queued on a previous
    /// folder's actor can never write or purge after that folder was replaced.
    private static let activeKey = OSAllocatedUnfairLock<String?>(initialState: nil)

    nonisolated static func activate(_ url: URL) { activeKey.withLock { $0 = cacheKey(for: url) } }
    nonisolated static func deactivate() { activeKey.withLock { $0 = nil } }
    private var isActive: Bool { Self.activeKey.withLock { $0 == key } }

    nonisolated static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - Local cache

    /// Decoded snapshots are mirrored under Library/Caches so a cold launch can
    /// paint at once and then read only files whose stamp changed — instead of
    /// re-reading (and possibly re-downloading from iCloud) every entry.
    ///
    /// Library/Caches is excluded from device and iCloud backups and may be
    /// purged by the OS; the cache is regenerable so both are fine. Files use
    /// the same protection class as the entries they copy. The directory is
    /// keyed by a hash of the folder path so switching folders never mixes
    /// data, and `prepare()` drops every other folder's cache.
    private static let cacheVersion = "v2"   // bump when a snapshot type changes shape (v2: sidecars decoded tolerantly)

    private static var cacheBase: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EriksDay", isDirectory: true)
    }

    private static var cacheRoot: URL? {
        cacheBase?.appendingPathComponent(cacheVersion, isDirectory: true)
    }

    private var cacheDir: URL? {
        Self.cacheRoot?.appendingPathComponent(key, isDirectory: true)
    }

    private func readCache<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard isActive, let dir = cacheDir,
              let data = try? Data(contentsOf: dir.appendingPathComponent(name))
        else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }

    private func writeCache<T: Encodable>(_ name: String, _ value: T) {
        guard isActive, let dir = cacheDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary       // dates stay binary: no ISO-8601 parsing on load
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadCachedWeek(_ key: String) -> WeekSnapshot? { readCache("week-\(key).plist", as: WeekSnapshot.self) }

    /// Only entries known to be on disk belong in the cache. An in-flight
    /// (unstamped) entry would otherwise be primed next launch as if saved.
    func saveCachedWeek(_ key: String, _ snapshot: WeekSnapshot) {
        var onDisk = WeekSnapshot()
        for (name, stamp) in snapshot.stamps {
            guard let entry = snapshot.entries[name] else { continue }
            onDisk.entries[name] = entry
            onDisk.stamps[name] = stamp
        }
        writeCache("week-\(key).plist", onDisk)
    }
    func loadCachedRoutines() -> RoutineSnapshot? { readCache("routines.plist", as: RoutineSnapshot.self) }

    /// Which days have at least one entry, per week, read from the local cache
    /// alone. The day browser marks days from this, so a week it hasn't loaded
    /// still shows its dots. Decoding only, no shared-folder access.
    func cachedDayIndex() -> [String: Set<Date>] {
        guard isActive, let dir = cacheDir else { return [:] }
        let cal = Calendar.current
        var out: [String: Set<Date>] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix("week-"), name.hasSuffix(".plist") else { continue }
            let key = String(name.dropFirst("week-".count).dropLast(".plist".count))
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? PropertyListDecoder().decode(WeekSnapshot.self, from: data)
            else { continue }
            out[key] = Set(snapshot.entries.values.flatMap { $0.spannedDays(cal) })
        }
        return out
    }
    func saveCachedRoutines(_ snapshot: RoutineSnapshot) { writeCache("routines.plist", snapshot) }

    /// Only the attached folder's data, at the current cache version, may live
    /// in the cache: drop any older version and any other folder's directory.
    private func purgeOtherCaches() {
        guard isActive else { return }
        let fm = FileManager.default
        if let base = Self.cacheBase {
            for url in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
                where url.lastPathComponent != Self.cacheVersion {
                try? fm.removeItem(at: url)
            }
        }
        guard let rootDir = Self.cacheRoot else { return }
        for url in (try? fm.contentsOfDirectory(at: rootDir, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent != key {
            try? fm.removeItem(at: url)
        }
    }

    /// Drop cached weeks that no longer match the shared folder: ones whose
    /// folder is gone, and ones that won't be reconciled this pass but whose
    /// files' stamps no longer match what was cached (entries erased or changed
    /// there while this device wasn't looking). Metadata only — no contents are
    /// read. A week whose folder can't be listed is left alone. Returns the
    /// keys removed.
    func pruneCachedWeeks(keeping keys: Set<String>, reconciled: Set<String>) -> [String] {
        guard isActive, let dir = cacheDir else { return [] }
        let fm = FileManager.default
        var removed: [String] = []
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            guard name.hasPrefix("week-"), name.hasSuffix(".plist") else { continue }
            let weekKey = String(name.dropFirst("week-".count).dropLast(".plist".count))
            if !keys.contains(weekKey) {
                try? fm.removeItem(at: url)
                removed.append(weekKey)
                continue
            }
            if reconciled.contains(weekKey) { continue }   // the stamp pass will refresh it
            guard let cached = try? PropertyListDecoder().decode(WeekSnapshot.self, from: Data(contentsOf: url))
            else {
                try? fm.removeItem(at: url)                 // unreadable: rebuild on demand
                removed.append(weekKey)
                continue
            }
            if let current = currentStamps(forWeek: weekKey), current != cached.stamps {
                try? fm.removeItem(at: url)
                removed.append(weekKey)
            }
        }
        return removed
    }

    /// Stamps of every entry file in one week folder — a directory listing,
    /// nothing read. nil when the folder can't be listed.
    private func currentStamps(forWeek weekKey: String) -> [String: FileStamp]? {
        withAccess {
            let dir = entriesURL.appendingPathComponent(weekKey, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            var out: [String: FileStamp] = [:]
            for url in urls where url.pathExtension == "json" {
                if let stamp = FileStamp(url) { out[url.lastPathComponent] = stamp }
            }
            return out
        }
    }

    /// Called when the folder is unlinked: nothing may remain cached, at any
    /// version.
    nonisolated static func purgeAllCaches() {
        guard let base = cacheBase else { return }
        try? FileManager.default.removeItem(at: base)
    }

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
    /// Returns an error when the shared folder itself can't be reached. Nothing
    /// is created then: a folder that vanished from its bookmarked path must
    /// never be rebuilt as an empty skeleton that later writes would fork into.
    func prepare() -> String? {
        purgeOtherCaches()
        var error: String?
        withAccess {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else {
                error = "Couldn't reach the shared folder."
                return
            }
            makeDirectory(entriesURL)
            makeDirectory(routinesURL)
            makeDirectory(mediaURL)

            guard !didMigrate else { return }
            didMigrate = true
            let urls = (try? fm.contentsOfDirectory(at: entriesURL, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let entry = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data) else { continue }
                let folder = entriesURL.appendingPathComponent(WeekKey.key(for: entry.timestamp),
                                                               isDirectory: true)
                makeDirectory(folder)
                try? fm.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
        }
        return error
    }

    /// Week folder names. Cheap — directory names only, no contents read.
    /// nil when the folder can't be listed (scope denied, iCloud unavailable),
    /// which callers must treat differently from "no weeks yet".
    func weekKeys() -> Set<String>? { withAccess { weekFoldersLocked() } }

    /// Week folder names as they are on disk right now, or nil if `entries/`
    /// can't be listed. Assumes folder access is held.
    private func weekFoldersLocked() -> Set<String>? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: entriesURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return Set(urls
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true }
            .map { $0.lastPathComponent })
    }

    // MARK: - Reading

    /// Load one week, reusing decoded entries from `prior` for every file whose
    /// stamp is unchanged. Files that vanished are simply absent from the result.
    func loadWeek(_ key: String, reusing prior: WeekSnapshot) -> IOResult<WeekSnapshot> {
        let dir = entriesURL.appendingPathComponent(key, isDirectory: true)
        var out = WeekSnapshot()
        var error: String?
        var reused = 0, read = 0
        withAccess {
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: dir, options: [], error: &coordError) { d in
                let urls: [URL]
                do {
                    urls = try FileManager.default.contentsOfDirectory(
                        at: d, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                } catch let listError {
                    // Only "this week's folder doesn't exist inside a reachable
                    // entries folder" is genuinely empty. Anything else — the
                    // shared folder gone, moved, or unreadable — is a failure,
                    // never an empty week.
                    let missing = (listError as? CocoaError)?.code == .fileReadNoSuchFile
                    if !(missing && FileManager.default.fileExists(atPath: entriesURL.path)) {
                        error = "Couldn't read \(key): \(listError.localizedDescription)"
                    }
                    return
                }
                for url in urls where url.pathExtension == "json" {
                    let name = url.lastPathComponent
                    let stamp = FileStamp(url)
                    if let stamp, prior.stamps[name] == stamp, let cached = prior.entries[name] {
                        out.entries[name] = cached          // unchanged: no read, no decode
                        out.stamps[name] = stamp
                        reused += 1
                        continue
                    }
                    guard let data = try? Data(contentsOf: url),
                          let entry = try? JSONDecoder.eriksDay.decode(LogEntry.self, from: data)
                    else { continue }
                    out.entries[name] = entry
                    if let stamp { out.stamps[name] = stamp }
                    read += 1
                }
            }
            if let coordError { error = coordError.localizedDescription }
        }
        Self.logger.notice("week \(key, privacy: .public): reused \(reused) read \(read)")
        return IOResult(value: out, error: error)
    }

    func loadRoutines(reusing prior: RoutineSnapshot) -> IOResult<RoutineSnapshot> {
        var out = RoutineSnapshot()
        var error: String?
        var reused = 0, read = 0
        withAccess {
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: routinesURL, options: [], error: &coordError) { dir in
                let urls: [URL]
                do {
                    urls = try FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
                } catch let listError {
                    let missing = (listError as? CocoaError)?.code == .fileReadNoSuchFile
                    if !(missing && FileManager.default.fileExists(atPath: root.path)) {
                        error = "Couldn't read routines: \(listError.localizedDescription)"
                    }
                    return
                }
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
                        reused += 1
                        continue
                    }
                    guard let mdStamp, let data = try? Data(contentsOf: url) else { continue }
                    let meta = (try? Data(contentsOf: metaURL))
                        .flatMap { try? JSONDecoder.eriksDay.decode(RoutineMeta.self, from: $0) }
                    // A sidecar that exists but couldn't be read or decoded is
                    // left unstamped, so the next reconcile tries it again
                    // instead of caching the routine as untranslated — and the
                    // doc records that its metadata is unknown, so a save
                    // merges into the sidecar instead of replacing it.
                    let trusted = meta?.undecodedKeys.isEmpty ?? (metaStamp == nil)
                    if !trusted { Self.logger.error("routine \(name, privacy: .public): sidecar unreadable") }
                    let doc = RoutineDoc(id: id,
                                         body: String(data: data, encoding: .utf8) ?? "",
                                         updatedAt: mdStamp.modified,
                                         edits: meta?.edits ?? [],
                                         sourceLanguage: meta?.sourceLanguage,
                                         translations: meta?.translations ?? [:],
                                         metaLoaded: trusted)
                    out.items[name] = .init(doc: doc, mdStamp: mdStamp, metaStamp: trusted ? metaStamp : nil)
                    read += 1
                }
            }
            if let coordError { error = coordError.localizedDescription }
        }
        Self.logger.notice("routines: reused \(reused) read \(read)")
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
            guard fm.fileExists(atPath: root.path) else {
                error = "Couldn't reach the shared folder."
                return
            }
            let folder = entriesURL.appendingPathComponent(targetKey, isDirectory: true)
            makeDirectory(folder)
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
            // Only once the new copy is safely on disk remove any copy an
            // edited timestamp left in another week — a failed write must
            // never lose the entry. Sweep what is actually on disk, not only
            // what the caller knew about: another device may have moved it.
            guard stamp != nil else { return }
            var sweep = weeks
            if let onDisk = weekFoldersLocked() {
                sweep.formUnion(onDisk)
            } else {
                error = "Saved, but couldn't check other weeks for an older copy."
            }
            // Into the trash, never erased: should the copy left behind ever be
            // the one a device edited, nothing is lost for good.
            for key in sweep where key != targetKey {
                let f = entriesURL.appendingPathComponent(key, isDirectory: true)
                    .appendingPathComponent(name)
                if let trashError = moveToTrash(f, subfolder: "entries") {
                    error = "Saved, but an older copy remains: \(trashError)"
                }
            }
        }
        return IOResult(value: stamp, error: error)
    }

    /// Entry files present in more than one week folder — a move whose sweep
    /// never finished, on this device or another. Names only, one listing per
    /// week; run by the daily deep pass. nil when the folder can't be listed.
    func duplicatedEntryIDs() -> Set<UUID>? {
        withAccess {
            guard let weeks = weekFoldersLocked() else { return nil }
            var seen: [String: Int] = [:]
            for key in weeks {
                let dir = entriesURL.appendingPathComponent(key, isDirectory: true)
                let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for url in urls where url.pathExtension == "json" {
                    seen[url.deletingPathExtension().lastPathComponent, default: 0] += 1
                }
            }
            return Set(seen.filter { $0.value > 1 }.keys.compactMap(UUID.init(uuidString:)))
        }
    }

    /// When an entry's file exists in more than one week folder, keep the most
    /// recently edited copy (every save appends an audit record; on a tie the
    /// copy in the week of its own timestamp, then the later week key, so
    /// every device picks the same one) and move the rest to the trash.
    /// Returns the weeks whose copy must stay hidden until the next try:
    /// empty once at most one copy remains, the leftovers when a move failed,
    /// every copy while one can't be read (nothing can be judged), and nil
    /// when the folder couldn't be listed at all.
    func resolveCopies(id: UUID) -> Set<String>? {
        let name = "\(id.uuidString).json"
        var copies: [(key: String, url: URL, entry: LogEntry?)] = []
        var listed = false
        withAccess {
            guard FileManager.default.fileExists(atPath: root.path),
                  let weeks = weekFoldersLocked() else { return }
            listed = true
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: entriesURL, options: [], error: &coordError) { _ in
                for key in weeks.sorted() {
                    let url = entriesURL.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let entry = (try? Data(contentsOf: url))
                        .flatMap { try? JSONDecoder.eriksDay.decode(LogEntry.self, from: $0) }
                    copies.append((key, url, entry))
                }
            }
            if coordError != nil { listed = false }
        }
        guard listed else { return nil }
        guard copies.count > 1 else { return [] }
        // One copy unreadable (not downloaded yet, say): nothing can be judged,
        // so hide nothing and try again next refresh. A hide only ever names
        // the weeks a losing copy stayed in, so the keeper is always shown —
        // an entry that silently vanishes from a care log invites logging the
        // same care twice.
        guard copies.allSatisfy({ $0.entry != nil }) else { return [] }
        func rank(_ c: (key: String, url: URL, entry: LogEntry?)) -> (Date, Int, String) {
            guard let entry = c.entry else { return (.distantPast, 0, "") }
            return (entry.edits.last?.date ?? .distantPast,
                    WeekKey.key(for: entry.timestamp) == c.key ? 1 : 0,
                    c.key)
        }
        guard let keep = copies.max(by: { rank($0) < rank($1) }) else { return [] }
        var remaining: Set<String> = []
        withAccess {
            for c in copies where c.url != keep.url {
                if moveToTrash(c.url, subfolder: "entries") != nil { remaining.insert(c.key) }
            }
        }
        if remaining.isEmpty {
            Self.logger.notice("resolved \(copies.count, privacy: .public) copies of \(name, privacy: .public): kept \(keep.key, privacy: .public)")
        }
        return remaining
    }

    // MARK: - Unswept copies (per device, in the cache directory)

    /// Entries whose superseded copy a save couldn't clear from the weeks it
    /// moved out of, with those weeks. Remembered per device — never in the
    /// shared folder — so the sweep is retried on every refresh until done.
    func loadUnswept() -> [String: Set<String>] {
        readCache("unswept.plist", as: [String: Set<String>].self) ?? [:]
    }

    func saveUnswept(_ unswept: [String: Set<String>]) {
        writeCache("unswept.plist", unswept)
    }

    /// Move every copy of an entry into the trash — while a timestamp edit is
    /// in flight the file can be in a different week than the entry implies.
    func trashEntry(id: UUID, in weeks: Set<String>) -> String? {
        var error: String?
        let name = "\(id.uuidString).json"
        withAccess {
            guard FileManager.default.fileExists(atPath: root.path) else {
                error = "Couldn't reach the shared folder."
                return
            }
            // Sweep every week on disk, not only the caller's view: another
            // device may have moved the entry since this device last listed.
            guard let onDisk = weekFoldersLocked() else {
                error = "Couldn't read the shared folder to confirm the deletion."
                return
            }
            for key in weeks.union(onDisk) {
                let src = entriesURL.appendingPathComponent(key, isDirectory: true)
                    .appendingPathComponent(name)
                if let e = moveToTrash(src, subfolder: "entries") { error = e }
            }
        }
        return error
    }

    func writeRoutine(_ doc: RoutineDoc, mergingSidecar: Bool = false) -> String? {
        var error: String?
        withAccess {
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path) else {
                error = "Couldn't reach the shared folder."
                return
            }
            makeDirectory(routinesURL)
            var coordError: NSError?

            // The sidecar is named after the body file that is actually on
            // disk — the same pairing loadRoutines uses — so an externally
            // written lowercase name never ends up with a second sidecar.
            let mdURL = routineFileURL(id: doc.id, ext: "md")
            let metaURL = mdURL.deletingPathExtension().appendingPathExtension("json")

            // Remember the sidecar as it was, to put back if the body can't be
            // written: the audit log and language label must describe the body
            // that is on disk, and a new routine must not leave an orphan.
            let hadSidecar = fm.fileExists(atPath: metaURL.path)
            var previousMeta: Data?
            NSFileCoordinator().coordinate(readingItemAt: metaURL, options: [], error: &coordError) { url in
                previousMeta = try? Data(contentsOf: url)
            }
            if hadSidecar, previousMeta == nil {
                // Can't tell what a restore would need: change nothing.
                error = "Couldn't read the routine's sidecar: \(coordError?.localizedDescription ?? "unreadable file")"
                return
            }
            coordError = nil

            // Sidecar first. If it fails the body is left untouched, so a reader
            // can never see a new body paired with the previous body's
            // translations (an old body with cleared translations is merely
            // untranslated, never wrong).
            var carryOver: Set<String> = []
            var meta = RoutineMeta(edits: doc.edits,
                                   sourceLanguage: doc.sourceLanguage,
                                   translations: doc.translations)
            if mergingSidecar, let previousMeta {
                // The doc was loaded while its sidecar couldn't be read, so it
                // carries none of the audit log. Keep what is on disk, and the
                // translations too if the body is unchanged — and if it still
                // can't be decoded, write nothing: an audit log and offline
                // translations can't be reproduced.
                guard let prev = try? JSONDecoder.eriksDay.decode(RoutineMeta.self, from: previousMeta) else {
                    error = "Couldn't read the routine's saved history, so it wasn't overwritten."
                    return
                }
                meta.edits = prev.edits + doc.edits.filter { !prev.edits.contains($0) }
                meta.sourceLanguage = doc.sourceLanguage ?? prev.sourceLanguage
                if (try? String(contentsOf: mdURL, encoding: .utf8)) == doc.body {
                    meta.translations = prev.translations
                }
                carryOver = prev.undecodedKeys
            }
            var metaData: Data
            do { metaData = try JSONEncoder.eriksDay.encode(meta) }
            catch let encodeError {
                error = "Write failed: \(encodeError.localizedDescription)"
                return
            }
            if let previousMeta, !carryOver.isEmpty,
               let preserved = Self.carryingOver(carryOver, from: previousMeta,
                                                 into: metaData, adding: doc.edits) {
                metaData = preserved
            }
            NSFileCoordinator().coordinate(writingItemAt: metaURL, options: .forReplacing,
                                           error: &coordError) { url in
                do {
                    try metaData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch let writeError {
                    error = "Write failed: \(writeError.localizedDescription)"
                }
            }
            if let coordError { error = coordError.localizedDescription }
            guard error == nil else { return }

            NSFileCoordinator().coordinate(writingItemAt: mdURL, options: .forReplacing,
                                           error: &coordError) { url in
                do {
                    try doc.body.data(using: .utf8)?.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch let writeError {
                    error = "Write failed: \(writeError.localizedDescription)"
                }
            }
            if let coordError { error = coordError.localizedDescription }
            guard error != nil else { return }

            // The body didn't land: restore the sidecar that matches the body
            // still on disk, or remove the one a brand-new routine just made.
            var restoreError: NSError?
            var restored = false
            NSFileCoordinator().coordinate(writingItemAt: metaURL, options: .forReplacing,
                                           error: &restoreError) { url in
                if let previousMeta {
                    restored = (try? previousMeta.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
                } else {
                    restored = (try? fm.removeItem(at: url)) != nil
                }
            }
            if !restored || restoreError != nil {
                error = "\(error ?? "Write failed."). The routine's sidecar couldn't be put back either."
            }
        }
        return error
    }

    func trashRoutine(id: UUID) -> String? {
        var error: String?
        withAccess {
            guard FileManager.default.fileExists(atPath: root.path) else {
                error = "Couldn't reach the shared folder."
                return
            }
            // Every spelling of the name, body first: an externally written
            // lowercase body may have picked up an uppercase sidecar.
            for url in routineFileURLs(id: id, ext: "md") + routineFileURLs(id: id, ext: "json") {
                error = moveToTrash(url, subfolder: "routines")
                if error != nil { return }
            }
        }
        return error
    }

    /// Copy attached media into `routines/media/` and return the routines-
    /// relative path, so playback never depends on the original device's
    /// photo library.
    func saveMedia(_ data: Data, ext: String) -> IOResult<String?> {
        let name = "\(UUID().uuidString).\(ext)"
        var path: String?
        var error: String?
        withAccess {
            guard FileManager.default.fileExists(atPath: root.path) else {
                error = "Couldn't reach the shared folder."
                return
            }
            makeDirectory(mediaURL)
            var coordError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: mediaURL.appendingPathComponent(name),
                                           options: .forReplacing, error: &coordError) { url in
                do {
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    path = "media/\(name)"
                } catch let writeError {
                    error = "Couldn't save the attachment: \(writeError.localizedDescription)"
                }
            }
            if let coordError { error = coordError.localizedDescription }
        }
        return IOResult(value: path, error: error)
    }

    // MARK: - Helpers (folder access already held)

    /// Put back the sidecar fields this build couldn't parse, exactly as they
    /// were on disk, so writing the file never turns "couldn't read this" into
    /// "this was empty". An unreadable audit log still gains this save's own
    /// record, appended to the raw array.
    private static func carryingOver(_ keys: Set<String>, from previous: Data,
                                     into encoded: Data, adding newEdits: [EditRecord]) -> Data? {
        guard var out = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any],
              let old = (try? JSONSerialization.jsonObject(with: previous)) as? [String: Any]
        else { return nil }
        for key in keys {
            guard let raw = old[key] else { out.removeValue(forKey: key); continue }
            if key == "edits", var records = raw as? [Any] {
                if let added = try? JSONEncoder.eriksDay.encode(newEdits),
                   let list = (try? JSONSerialization.jsonObject(with: added)) as? [Any] {
                    records.append(contentsOf: list)
                }
                out[key] = records
            } else {
                out[key] = raw
            }
        }
        return try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    }

    /// Create a folder inside the shared folder one level at a time, never
    /// with intermediates: if the shared folder vanished after the caller's
    /// guard, this fails instead of resurrecting it as an empty shell that
    /// every device would then read as "emptied".
    private func makeDirectory(_ url: URL) {
        var current = root
        for part in url.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(part, isDirectory: true)
            try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
        }
    }

    /// Every on-disk file for a routine with this extension, matched
    /// case-insensitively: externally-generated names use lowercase UUIDs and
    /// iOS filesystems are case-sensitive.
    private func routineFileURLs(id: UUID, ext: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: routinesURL, includingPropertiesForKeys: nil)) ?? []
        return urls.filter {
            $0.pathExtension == ext &&
            $0.deletingPathExtension().lastPathComponent
                .caseInsensitiveCompare(id.uuidString) == .orderedSame
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The file a write goes to: the existing one if any, else the canonical
    /// name for a new doc.
    private func routineFileURL(id: UUID, ext: String) -> URL {
        routineFileURLs(id: id, ext: ext).first
            ?? routinesURL.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// Move a file into the hidden `.trash/<subfolder>/` rather than deleting.
    private func moveToTrash(_ src: URL, subfolder: String) -> String? {
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let destDir = trashURL.appendingPathComponent(subfolder, isDirectory: true)
        makeDirectory(destDir)
        let dest = destDir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(src.lastPathComponent)")
        var coordError: NSError?
        var moveError: String?
        NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving,
                                       writingItemAt: dest, options: .forReplacing,
                                       error: &coordError) { s, d in
            do { try FileManager.default.moveItem(at: s, to: d) }
            catch let e { moveError = "Couldn't move to trash: \(e.localizedDescription)" }
        }
        return coordError?.localizedDescription ?? moveError
    }
}
