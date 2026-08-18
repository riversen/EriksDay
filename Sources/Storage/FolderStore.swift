import Foundation
import UIKit

/// In-memory model over the user-selected shared folder (intended to be a
/// shared iCloud Drive folder). All file access happens in `FolderIO`, off the
/// main actor; this type holds the cache the UI reads.
///
/// Reloads diff by file stamp and reuse everything unchanged, so returning to
/// the app doesn't re-read (and possibly re-download) files it already has.
/// Writes update memory first and persist in the background, so tapping a
/// button never waits on iCloud.
///
/// IMPORTANT: never put a SwiftData/Core Data/SQLite store in the shared
/// folder. Discrete files only.
@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var routines: [RoutineDoc] = []
    @Published private(set) var folderName: String?
    @Published var lastError: String?

    private let bookmarkKey = "eriksDayFolderBookmark"
    private var folderURL: URL?
    private var io: FolderIO?

    /// Per-week cache so weeks load independently and on demand.
    private var weeks: [String: WeekSnapshot] = [:]
    private var loadedWeeks: Set<String> = []
    private var knownWeeks: Set<String> = []
    private var routineSnapshot = RoutineSnapshot()

    /// Local changes not yet confirmed on disk. A reload that was already in
    /// flight must not revert them, so they're re-applied over its result.
    private var pendingEntries: [UUID: LogEntry] = [:]
    private var pendingEntryDeletes: Set<UUID> = []
    private var pendingRoutines: [UUID: RoutineDoc] = [:]
    private var pendingRoutineDeletes: Set<UUID> = []

    /// Label written into each edit record — "which device". iOS 16+ returns a
    /// generic model for `UIDevice.name`, so a vendor-id suffix disambiguates.
    let deviceName: String

    init() {
        deviceName = Self.resolveDeviceName()
        restoreFolder()
        #if DEBUG
        loadDemoDataIfRequested()
        #endif
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

    private func attach(_ url: URL, name: String) {
        folderURL = url
        folderName = name
        io = FolderIO(root: url)
        weeks = [:]
        loadedWeeks = []
        knownWeeks = []
        routineSnapshot = RoutineSnapshot()
    }

    func setFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            attach(url, name: url.lastPathComponent)
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
            if stale {
                setFolder(url)
            } else {
                attach(url, name: url.lastPathComponent)
                reloadAll()
            }
        } catch {
            lastError = "Lost access to the folder. Please choose it again."
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            folderURL = nil
            folderName = nil
            io = nil
        }
    }

    /// The earliest day that has any entry, from week folder names alone.
    /// Drives how far back the day browser reaches without loading contents.
    var earliestEntryDate: Date? {
        knownWeeks.sorted().first.flatMap { WeekKey.startDate(for: $0) }
    }

    // MARK: - Reloading

    func reloadAll() {
        Task { await refresh() }
    }

    /// Reload the weeks currently in play plus the recent ones, reusing
    /// everything whose file stamp is unchanged.
    func refresh() async {
        guard let io else { return }
        await io.prepare()
        let keys = await io.weekKeys()
        knownWeeks = keys

        let targets = loadedWeeks.union(recentWeekKeys()).intersection(keys)
        for key in targets {
            let result = await io.loadWeek(key, reusing: weeks[key] ?? WeekSnapshot())
            applyWeek(key, result.value)
            if let error = result.error { lastError = error }
        }

        let routineResult = await io.loadRoutines(reusing: routineSnapshot)
        applyRoutines(routineResult.value)
        if let error = routineResult.error { lastError = error }

        rebuildEntries()
    }

    /// Ensure the week containing `date` is loaded — called as the day browser
    /// moves to days that aren't in memory yet.
    func ensureLoaded(weekOf date: Date) {
        guard let io else { return }
        let key = WeekKey.key(for: date)
        guard !loadedWeeks.contains(key), knownWeeks.contains(key) else { return }
        loadedWeeks.insert(key)     // claim it now so we don't queue it twice
        Task {
            let result = await io.loadWeek(key, reusing: WeekSnapshot())
            applyWeek(key, result.value)
            if let error = result.error { lastError = error }
            rebuildEntries()
        }
    }

    private func recentWeekKeys(daysBack: Int = 14) -> Set<String> {
        let cal = Calendar.current
        var keys: Set<String> = []
        for offset in 0...daysBack {
            if let d = cal.date(byAdding: .day, value: -offset, to: .now) {
                keys.insert(WeekKey.key(for: d))
            }
        }
        return keys
    }

    /// Store a freshly loaded week, keeping any local change still in flight.
    private func applyWeek(_ key: String, _ snapshot: WeekSnapshot) {
        var snapshot = snapshot
        for (id, entry) in pendingEntries where WeekKey.key(for: entry.timestamp) == key {
            snapshot.entries["\(id.uuidString).json"] = entry
        }
        for id in pendingEntryDeletes {
            snapshot.entries.removeValue(forKey: "\(id.uuidString).json")
        }
        weeks[key] = snapshot
        loadedWeeks.insert(key)
    }

    private func applyRoutines(_ snapshot: RoutineSnapshot) {
        routineSnapshot = snapshot
        var docs = snapshot.items.values.map(\.doc)
        for (id, doc) in pendingRoutines where !docs.contains(where: { $0.id == id }) {
            docs.append(doc)
        }
        docs = docs.map { pendingRoutines[$0.id] ?? $0 }
            .filter { !pendingRoutineDeletes.contains($0.id) }
        routines = docs.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func rebuildEntries() {
        entries = loadedWeeks
            .flatMap { weeks[$0]?.entries.values.map { $0 } ?? [] }
            .sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Log entries

    func add(_ entry: LogEntry) { save(entry) }
    func update(_ entry: LogEntry) { save(entry) }

    private func save(_ entry: LogEntry) {
        guard let io else {
            lastError = "No folder selected yet."
            return
        }
        var e = entry
        e.edits.append(EditRecord(device: deviceName, date: .now))

        // Reflect it immediately; the disk write happens in the background.
        let key = WeekKey.key(for: e.timestamp)
        let name = "\(e.id.uuidString).json"
        removeFromMemory(id: e.id)
        var snapshot = weeks[key] ?? WeekSnapshot()
        snapshot.entries[name] = e
        weeks[key] = snapshot
        loadedWeeks.insert(key)
        knownWeeks.insert(key)
        pendingEntries[e.id] = e
        pendingEntryDeletes.remove(e.id)
        rebuildEntries()

        let sweep = knownWeeks
        Task {
            let result = await io.write(e, clearingFrom: sweep)
            if let stamp = result.value {
                // Record the stamp so the next reload treats it as unchanged.
                weeks[key]?.stamps[name] = stamp
            }
            if let error = result.error { lastError = error }
            if pendingEntries[e.id]?.edits.count == e.edits.count { pendingEntries[e.id] = nil }
        }
    }

    func delete(_ entry: LogEntry) {
        guard let io else { return }
        let key = WeekKey.key(for: entry.timestamp)
        removeFromMemory(id: entry.id)
        pendingEntries[entry.id] = nil
        pendingEntryDeletes.insert(entry.id)
        rebuildEntries()

        Task {
            if let error = await io.trashEntry(id: entry.id, weekKey: key) { lastError = error }
            pendingEntryDeletes.remove(entry.id)
        }
    }

    /// Drop an entry from every week it might be cached under (an edited time
    /// can move it between weeks).
    private func removeFromMemory(id: UUID) {
        let name = "\(id.uuidString).json"
        for key in weeks.keys {
            weeks[key]?.entries.removeValue(forKey: name)
            weeks[key]?.stamps.removeValue(forKey: name)
        }
    }

    // MARK: - Routines

    func saveRoutine(_ doc: RoutineDoc) {
        guard let io else {
            lastError = "No folder selected yet."
            return
        }
        var d = doc
        d.edits.append(EditRecord(device: deviceName, date: .now))
        d.updatedAt = .now

        pendingRoutines[d.id] = d
        pendingRoutineDeletes.remove(d.id)
        applyRoutines(routineSnapshot)

        Task {
            if let error = await io.writeRoutine(d) { lastError = error }
            let result = await io.loadRoutines(reusing: RoutineSnapshot())
            if pendingRoutines[d.id]?.edits.count == d.edits.count { pendingRoutines[d.id] = nil }
            applyRoutines(result.value)
        }
    }

    func deleteRoutine(_ doc: RoutineDoc) {
        guard let io else { return }
        pendingRoutines[doc.id] = nil
        pendingRoutineDeletes.insert(doc.id)
        applyRoutines(routineSnapshot)

        Task {
            if let error = await io.trashRoutine(id: doc.id) { lastError = error }
            let result = await io.loadRoutines(reusing: RoutineSnapshot())
            pendingRoutineDeletes.remove(doc.id)
            applyRoutines(result.value)
        }
    }

    func saveMedia(_ data: Data, ext: String) async -> String? {
        guard let io else { return nil }
        return await io.saveMedia(data, ext: ext)
    }

    func mediaData(_ relativePath: String) async -> Data? {
        guard let io else { return nil }
        return await io.mediaData(relativePath)
    }
}

#if DEBUG
extension FolderStore {
    /// Launch with `-demoData` to point at a local, non-synced folder seeded
    /// with neutral sample content for App Store screenshots. DEBUG only.
    func loadDemoDataIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-demoData") else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        attach(docs.appendingPathComponent("DemoFolder", isDirectory: true), name: "Family")

        Task {
            await refresh()
            guard entries.isEmpty, routines.isEmpty else { return }

            func at(_ h: Int, _ m: Int) -> Date {
                Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? .now
            }
            add(LogEntry(kind: .wake, timestamp: at(7, 30)))
            add(LogEntry(kind: .meal, timestamp: at(8, 0), amount: .normal,
                         note: "Oatmeal and banana", noteLanguage: .en))
            add(LogEntry(kind: .urine, timestamp: at(9, 10)))
            add(LogEntry(kind: .mood, timestamp: at(9, 30), moods: [.happy, .energetic]))
            add(LogEntry(kind: .nap, timestamp: at(12, 30), endTimestamp: at(13, 15)))
            add(LogEntry(kind: .meal, timestamp: at(15, 0), amount: .little,
                         note: "Apple slices", noteLanguage: .en))
            add(LogEntry(kind: .note, timestamp: at(16, 20),
                         note: "Great afternoon at the park.", noteLanguage: .en))

            saveRoutine(RoutineDoc(id: UUID(), body: """
            # Sign Language

            Signs we use every day:

            - **More** — tap fingertips together
            - **All done** — twist hands outward
            - **Eat** — fingertips to mouth
            - **Help** — fist on flat palm, lift up
            """, updatedAt: .now, sourceLanguage: .en))

            saveRoutine(RoutineDoc(id: UUID(), body: """
            # Likes

            - Splashing in water
            - Trampolines
            - The number 7 bus
            - Soft blankets
            """, updatedAt: .now, sourceLanguage: .en))

            saveRoutine(RoutineDoc(id: UUID(), body: """
            # Dislikes

            - Loud hand dryers
            - Sudden changes in plan
            - Scratchy clothing labels
            """, updatedAt: .now, sourceLanguage: .en))
        }
    }
}
#endif

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
