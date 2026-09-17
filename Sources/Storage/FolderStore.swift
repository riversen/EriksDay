import Foundation
import UIKit
import os

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
    /// Days that have at least one entry, covering every week the local cache
    /// knows — not just the weeks loaded into `entries`. The day browser marks
    /// days from this, so scrolling back doesn't reach a stretch of blank days
    /// that turn out to have entries once tapped.
    @Published private(set) var daysWithEntries: Set<Date> = []
    private var dayIndex: [String: Set<Date>] = [:]
    @Published private(set) var routines: [RoutineDoc] = []
    @Published private(set) var folderName: String?
    @Published var lastError: String? {
        didSet { if let lastError { Self.logger.error("\(lastError, privacy: .public)") } }
    }

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
    /// Weeks an in-flight entry was moved out of, accumulated across chained
    /// edits, so a failed write can restore the copy that is really on disk.
    private var pendingVacated: [UUID: Set<String>] = [:]
    private var pendingEntryDeletes: Set<UUID> = []
    private var pendingRoutines: [UUID: RoutineDoc] = [:]
    private var pendingRoutineDeletes: Set<UUID> = []

    /// Bumped whenever a different folder is attached. Work already in flight
    /// for the previous folder re-checks it after each await and stops, so it
    /// can neither touch the new folder's state nor recreate the old folder's
    /// cache after it was purged.
    private var generation = 0

    /// When cached-but-unloaded weeks were last checked against disk stamps.
    private var lastFullPrune: Date?

    /// Label written into each edit record — "which device". iOS 16+ returns a
    /// generic model for `UIDevice.name`, so a vendor-id suffix disambiguates.
    let deviceName: String

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "EriksDay",
                                       category: "storage")

    init() {
        deviceName = Self.resolveDeviceName()
        restoreFolder()
        #if DEBUG
        loadDemoDataIfRequested()
        #endif
    }

    var hasFolder: Bool { folderURL != nil }

    /// True until the saved folder has been resolved, so the first frame isn't
    /// a "choose a folder" prompt for someone who chose one long ago.
    @Published private(set) var isRestoring = false

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
        generation += 1
        FolderIO.activate(url)
        folderURL = url
        folderName = name
        io = FolderIO(root: url)
        weeks = [:]
        loadedWeeks = []
        knownWeeks = []
        dayIndex = [:]
        daysWithEntries = []
        routineSnapshot = RoutineSnapshot()
        entries = []                // the previous folder's data leaves the screen now,
        routines = []               // not when the first refresh happens to finish
        lastFullPrune = nil
        // Nothing still in flight for the previous folder may be overlaid onto
        // this one.
        pendingEntries = [:]
        pendingVacated = [:]
        pendingEntryDeletes = []
        pendingRoutines = [:]
        pendingRoutineDeletes = []
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

    /// Resolving a security-scoped bookmark can touch the file system, and for
    /// an iCloud folder that can take seconds — on the main thread at launch
    /// that is a watchdog kill. Resolve it off the main actor and attach when
    /// it comes back.
    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        isRestoring = true
        Task {
            let resolved = await Task.detached(priority: .userInitiated) {
                var stale = false
                let url = try? URL(resolvingBookmarkData: data, options: [],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
                return url.map { ($0, stale) }
            }.value
            isRestoring = false
            guard let (url, stale) = resolved else {
                unlinkFolder()
                return
            }
            if stale {
                setFolder(url)
                if io == nil { unlinkFolder() }      // couldn't re-save the bookmark
            } else {
                attach(url, name: url.lastPathComponent)
                reloadAll()
            }
        }
    }

    /// No folder is attached any more: forget the bookmark and leave nothing
    /// cached on this device.
    private func unlinkFolder() {
        lastError = "Lost access to the folder. Please choose it again."
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        folderURL = nil
        folderName = nil
        io = nil
        FolderIO.deactivate()
        FolderIO.purgeAllCaches()
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
    ///
    /// Weeks not yet in memory (a cold launch) are painted from the local cache
    /// first so the timeline appears immediately; the stamp pass that follows
    /// then reads only files that are new or changed.
    func refresh() async {
        guard let io else { return }
        let gen = generation
        let unreachable = await io.prepare()
        let listed = unreachable == nil ? await io.weekKeys() : nil
        guard gen == generation else { return }
        // Before anything is painted: superseded copies a save couldn't clear
        // stay hidden, on this path and the unreachable one below.
        for (idString, gone) in await io.loadUnswept() {
            if let id = UUID(uuidString: idString), pendingEntries[id] == nil {
                pendingVacated[id, default: []].formUnion(gone)
            }
        }
        guard gen == generation else { return }
        guard let keys = listed else {
            // The shared folder couldn't be reached or listed (gone from its
            // path, scope denied, iCloud not reachable). Keep what we have —
            // and if nothing is loaded yet, at least paint from the cache —
            // then retry next time.
            await primeFromCache(weeks: loadedWeeks.union(recentWeekKeys()))
            guard gen == generation else { return }
            lastError = unreachable ?? "Couldn't read the shared folder. Will retry."
            return
        }
        // A week removed from the shared folder must not survive in memory —
        // unless it only exists here because the user just logged into it and
        // that write hasn't landed yet.
        let pendingWeeks = Set(pendingEntries.values.map { WeekKey.key(for: $0.timestamp) })
        knownWeeks = keys.union(pendingWeeks)
        for key in loadedWeeks.filter({ !keys.contains($0) }) {
            if pendingWeeks.contains(key) {
                // Only what's still being written can legitimately be here;
                // anything stamped came from a folder that no longer exists.
                var kept = WeekSnapshot()
                for (id, entry) in pendingEntries where WeekKey.key(for: entry.timestamp) == key {
                    kept.entries["\(id.uuidString).json"] = entry
                }
                weeks[key] = kept
            } else {
                weeks[key] = nil
                loadedWeeks.remove(key)
            }
        }
        dayIndex = dayIndex.filter { keys.contains($0.key) }   // weeks gone from disk lose their dots
        let targets = loadedWeeks.union(recentWeekKeys()).intersection(keys)
        // …nor in the cache. Cached weeks we won't reconcile are also checked
        // against disk stamps — on the first refresh after attaching and at most
        // daily after that — so erased data can't linger while a foreground
        // refresh stays cheap.
        let deep = lastFullPrune.map { Date.now.timeIntervalSince($0) > 24 * 3600 } ?? true
        if deep { lastFullPrune = .now }     // claim it now so a concurrent refresh skips it
        _ = await io.pruneCachedWeeks(keeping: keys, reconciled: deep ? targets : keys)
        guard gen == generation else { return }

        // Any entry filed in more than one week — whichever device left it
        // there: keep the newest copy, trash the rest, hide what can't be
        // settled yet. The duplicate scan lists names only, one listing per
        // week folder, so it runs on every refresh rather than once a day.
        var duplicated = Set(pendingVacated.keys)
        if let found = await io.duplicatedEntryIDs() {
            guard gen == generation else { return }
            duplicated.formUnion(found)
        }
        for id in duplicated where pendingEntries[id] == nil {
            let hide = await io.resolveCopies(id: id)
            guard gen == generation else { return }
            guard let hide else { continue }          // couldn't list: leave as is
            pendingVacated[id] = hide.isEmpty ? nil : hide
        }
        await persistUnswept()
        guard gen == generation else { return }

        await primeFromCache(weeks: targets)
        guard gen == generation else { return }

        for key in targets {
            let prior = weeks[key] ?? WeekSnapshot()
            let result = await io.loadWeek(key, reusing: prior)
            guard gen == generation else { return }
            // A failed coordinated read yields nothing: keep what we have rather
            // than replace a good week with an empty one.
            if let error = result.error { lastError = error; continue }
            applyWeek(key, result.value)
            if result.value.stamps != prior.stamps { await io.saveCachedWeek(key, result.value) }
        }

        let prior = routineSnapshot
        let routineResult = await io.loadRoutines(reusing: prior)
        guard gen == generation else { return }
        if let error = routineResult.error {
            lastError = error
        } else {
            applyRoutines(routineResult.value)
            if routineResult.value.stampsOnly != prior.stampsOnly {
                await io.saveCachedRoutines(routineResult.value)
            }
        }

        rebuildEntries()
    }

    /// Paint weeks not yet in memory (and routines, if none) from the local
    /// cache. The reconcile that follows reads only what actually changed.
    private func primeFromCache(weeks targets: Set<String>) async {
        guard let io else { return }
        let gen = generation
        var primed = 0
        for key in targets where weeks[key] == nil {
            guard let cached = await io.loadCachedWeek(key) else { continue }
            guard gen == generation else { return }
            applyWeek(key, cached)
            primed += cached.entries.count
        }
        if routineSnapshot.items.isEmpty, let cached = await io.loadCachedRoutines() {
            guard gen == generation else { return }
            applyRoutines(cached)
            primed += cached.items.count
        }
        // Dots for every cached week, including ones no one has opened yet.
        // A loaded week keeps its own, which is the fresher of the two.
        let cachedDays = await io.cachedDayIndex()
        guard gen == generation else { return }
        for (key, days) in cachedDays where !loadedWeeks.contains(key) { dayIndex[key] = days }
        rebuildEntries()
        Self.logger.notice("primed \(primed) items from cache, \(self.daysWithEntries.count, privacy: .public) days marked")
    }

    /// Ensure the week containing `date` is loaded — called as the day browser
    /// moves to days that aren't in memory yet.
    func ensureLoaded(weekOf date: Date) {
        // The neighbouring weeks too: an overnight sleep is filed under the
        // week it began, a local day can straddle a UTC week boundary, and a
        // file from before keys were pinned to UTC can sit one week off.
        let key = WeekKey.key(for: date)
        var keys: Set<String> = [key]
        if let start = WeekKey.startDate(for: key) {
            keys.insert(WeekKey.key(for: start.addingTimeInterval(-3.5 * 86400)))
            keys.insert(WeekKey.key(for: start.addingTimeInterval(10.5 * 86400)))
        }
        ensureLoaded(keys: keys)
    }

    /// Load weeks that are on disk but not yet in memory, each painted from
    /// the cache first.
    private func ensureLoaded(keys: Set<String>) {
        guard let io else { return }
        for key in keys {
            guard !loadedWeeks.contains(key), knownWeeks.contains(key) else { continue }
            loadedWeeks.insert(key)     // claim it now so we don't queue it twice
            let gen = generation
            Task {
                var prior = WeekSnapshot()
                if let cached = await io.loadCachedWeek(key) {
                    guard gen == generation else { return }
                    prior = cached
                    applyWeek(key, cached)
                    rebuildEntries()
                }
                let result = await io.loadWeek(key, reusing: prior)
                guard gen == generation else { return }
                if let error = result.error {
                    lastError = error
                    // Un-load only if nothing is in memory for it now — a save
                    // may have landed there meanwhile and must stay visible.
                    if weeks[key]?.entries.isEmpty ?? true {
                        weeks[key] = nil
                        loadedWeeks.remove(key)
                    }
                    return
                }
                applyWeek(key, result.value)
                if result.value.stamps != prior.stamps { await io.saveCachedWeek(key, result.value) }
                rebuildEntries()
            }
        }
    }

    private func recentWeekKeys(daysBack: Int = 14) -> Set<String> {
        let cal = Calendar.current
        var keys: Set<String> = []
        for offset in -1...daysBack {      // tomorrow's week too: UTC can be a day ahead
            if let d = cal.date(byAdding: .day, value: -offset, to: .now) {
                keys.insert(WeekKey.key(for: d))
            }
        }
        return keys
    }

    /// Store a freshly loaded week, keeping any local change still in flight.
    /// An in-flight entry has no disk stamp yet, so it must never keep the old
    /// file's stamp: a later reconcile would then trust it without reading.
    private func applyWeek(_ key: String, _ snapshot: WeekSnapshot) {
        var snapshot = snapshot
        for (id, entry) in pendingEntries {
            let name = "\(id.uuidString).json"
            if WeekKey.key(for: entry.timestamp) == key {
                snapshot.entries[name] = entry
            } else {
                snapshot.entries.removeValue(forKey: name)   // its file is moving away from here
            }
            snapshot.stamps.removeValue(forKey: name)
        }
        for id in pendingEntryDeletes {
            let name = "\(id.uuidString).json"
            snapshot.entries.removeValue(forKey: name)
            snapshot.stamps.removeValue(forKey: name)
        }
        // A superseded copy a sweep couldn't clear stays out of sight until
        // the retry in refresh() has dealt with it.
        for (id, gone) in pendingVacated where gone.contains(key) && pendingEntries[id] == nil {
            let name = "\(id.uuidString).json"
            snapshot.entries.removeValue(forKey: name)
            snapshot.stamps.removeValue(forKey: name)
        }
        weeks[key] = snapshot
        loadedWeeks.insert(key)
        dayIndex[key] = nil     // loaded: rebuildEntries reads it from memory now
    }

    /// Remember, per device, which entries still have a superseded copy in
    /// another week, so refresh() keeps retrying after a relaunch.
    private func persistUnswept() async {
        guard let io else { return }
        var unswept: [String: Set<String>] = [:]
        for (id, gone) in pendingVacated where pendingEntries[id] == nil && !gone.isEmpty {
            unswept[id.uuidString] = gone
        }
        await io.saveUnswept(unswept)
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
        // One row per entry. A copy left in another week by a sweep that
        // couldn't finish carries an older audit record — every save appends
        // one — so the most recently edited copy wins; on a tie the copy in
        // the week of its own timestamp. (Week keys follow the device's time
        // zone, so "home" alone could prefer another device's stale copy.)
        // Hiding the leftover means editing the entry rewrites the current
        // version and the next sweep clears it, instead of the leftover
        // overwriting the current one.
        var best: [UUID: (entry: LogEntry, home: Bool)] = [:]
        for week in loadedWeeks {
            for entry in (weeks[week]?.entries ?? [:]).values {
                let home = WeekKey.key(for: entry.timestamp) == week
                if let current = best[entry.id] {
                    let mine = entry.edits.last?.date ?? .distantPast
                    let theirs = current.entry.edits.last?.date ?? .distantPast
                    guard mine > theirs || (mine == theirs && home && !current.home) else { continue }
                }
                best[entry.id] = (entry, home)
            }
        }
        entries = best.values.map(\.entry).sorted { $0.timestamp > $1.timestamp }
        // Marks come from what is in memory for the weeks that are loaded, so
        // a just-logged entry lights its day at once, and from the cache for
        // the weeks that aren't.
        let cal = Calendar.current
        var days = Set(best.values.flatMap { $0.entry.spannedDays(cal) })
        for (key, cached) in dayIndex where !loadedWeeks.contains(key) {
            days.formUnion(cached)
        }
        daysWithEntries = days
        Self.logger.notice("entries: \(self.entries.count, privacy: .public) rows")
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
        let vacated = removeFromMemory(id: e.id).subtracting([key])
        var snapshot = weeks[key] ?? WeekSnapshot()
        snapshot.entries[name] = e
        weeks[key] = snapshot
        loadedWeeks.insert(key)
        knownWeeks.insert(key)
        pendingEntries[e.id] = e
        pendingVacated[e.id, default: []].formUnion(vacated)
        pendingEntryDeletes.remove(e.id)
        rebuildEntries()

        // Clear stale copies from every week this entry was moved out of, not
        // only the weeks a listing happened to know about.
        let sweep = knownWeeks.union(pendingVacated[e.id] ?? [])
        let gen = generation
        Task {
            let result = await io.write(e, clearingFrom: sweep)
            // Say so even if the user has since switched folders: the entry
            // never reached the folder they logged it in.
            if let warning = result.error { lastError = warning }
            else if result.value == nil { lastError = "Write failed." }
            guard gen == generation else { return }
            let stillCurrent = pendingEntries[e.id] == e
            // Every week this entry has been moved out of while in flight, plus
            // where it is now — the set that memory and cache must agree on.
            let touched = (pendingVacated[e.id] ?? []).union(vacated).union([key])
            if let stamp = result.value {
                // Pair the stamp only with the exact version that was written;
                // a newer edit may already be in memory awaiting its own write.
                if weeks[key]?.entries[name] == e { weeks[key]?.stamps[name] = stamp }
                if stillCurrent {
                    pendingEntries[e.id] = nil
                    // Saved, but the sweep of older copies didn't finish: keep
                    // those weeks listed so the next save sweeps them again.
                    let unswept = touched.subtracting([key])
                    pendingVacated[e.id] = (result.error == nil || unswept.isEmpty) ? nil : unswept
                }
                await persistCache(weeks: touched)
                guard gen == generation else { return }
                await persistUnswept()
            } else {
                // The edit never reached the shared folder. Don't let memory or
                // the cache claim it did: restore what is on disk — which may be
                // in a week an earlier chained edit moved it out of.
                if stillCurrent {
                    pendingEntries[e.id] = nil
                    pendingVacated[e.id] = nil
                    weeks[key]?.entries.removeValue(forKey: name)
                    weeks[key]?.stamps.removeValue(forKey: name)
                    for k in touched {
                        guard gen == generation else { return }
                        await reloadWeekFromDisk(k)
                    }
                    rebuildEntries()
                }
            }
        }
    }

    /// Re-read one week from the shared folder, replacing memory and the cache
    /// with what is actually there. Used after a write or trash failed.
    private func reloadWeekFromDisk(_ key: String) async {
        guard let io else { return }
        let gen = generation
        let prior = weeks[key] ?? WeekSnapshot()
        let result = await io.loadWeek(key, reusing: prior)
        guard gen == generation else { return }
        if let error = result.error { lastError = error; return }
        applyWeek(key, result.value)
        if result.value.stamps != prior.stamps { await io.saveCachedWeek(key, result.value) }
    }

    func delete(_ entry: LogEntry) {
        guard let io else { return }
        let key = WeekKey.key(for: entry.timestamp)
        let vacated = removeFromMemory(id: entry.id)
        // The file may sit in a week an in-flight move left it in, not the one
        // its timestamp implies: trash it wherever it is.
        let touched = (pendingVacated[entry.id] ?? []).union(vacated).union([key])
        pendingEntries[entry.id] = nil
        pendingVacated[entry.id] = nil
        pendingEntryDeletes.insert(entry.id)
        rebuildEntries()

        let sweep = knownWeeks.union(touched)
        let gen = generation
        Task {
            let error = await io.trashEntry(id: entry.id, in: sweep)
            if let error { lastError = error }
            guard gen == generation else { return }
            pendingEntryDeletes.remove(entry.id)
            if error != nil {
                // Still on disk: show it again rather than pretend it's gone.
                for k in touched {
                    guard gen == generation else { return }
                    await reloadWeekFromDisk(k)
                }
                rebuildEntries()
            } else {
                await persistCache(weeks: touched)
                guard gen == generation else { return }
                await persistUnswept()
            }
        }
    }

    /// Drop an entry from every week it might be cached under (an edited time
    /// can move it between weeks). Returns the weeks it was actually in.
    @discardableResult
    private func removeFromMemory(id: UUID) -> Set<String> {
        let name = "\(id.uuidString).json"
        var touched: Set<String> = []
        for key in weeks.keys where weeks[key]?.entries[name] != nil {
            weeks[key]?.entries.removeValue(forKey: name)
            weeks[key]?.stamps.removeValue(forKey: name)
            touched.insert(key)
        }
        return touched
    }

    /// Mirror the in-memory state of these weeks to the local cache. Called
    /// after a write lands, so the next cold launch paints it without a read.
    private func persistCache(weeks keys: Set<String>) async {
        guard let io else { return }
        let gen = generation
        for key in keys {
            guard gen == generation else { return }
            guard let snapshot = weeks[key] else { continue }
            await io.saveCachedWeek(key, snapshot)
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

        let gen = generation
        Task {
            // A doc loaded while its sidecar couldn't be read carries no audit
            // log or translations, so its write must merge, not replace. The
            // doc says so itself: a reload landing mid-edit can't flip it.
            let writeError = await io.writeRoutine(d, mergingSidecar: !d.metaLoaded)
            if let writeError { lastError = writeError }
            let result = await io.loadRoutines(reusing: RoutineSnapshot())
            guard gen == generation else { return }
            if pendingRoutines[d.id]?.edits.count == d.edits.count { pendingRoutines[d.id] = nil }
            if let error = result.error { lastError = error; return }
            applyRoutines(result.value)
            await io.saveCachedRoutines(result.value)
        }
    }

    func deleteRoutine(_ doc: RoutineDoc) {
        guard let io else { return }
        pendingRoutines[doc.id] = nil
        pendingRoutineDeletes.insert(doc.id)
        applyRoutines(routineSnapshot)

        let gen = generation
        Task {
            let trashError = await io.trashRoutine(id: doc.id)
            if let trashError { lastError = trashError }
            let result = await io.loadRoutines(reusing: RoutineSnapshot())
            guard gen == generation else { return }
            pendingRoutineDeletes.remove(doc.id)
            if let error = result.error { lastError = error; return }
            applyRoutines(result.value)
            await io.saveCachedRoutines(result.value)
        }
    }

    /// The error comes back to the caller rather than through `lastError`:
    /// the root alert would tear down the editor sheet the user is typing in.
    func saveMedia(_ data: Data, ext: String) async -> IOResult<String?> {
        guard let io else { return IOResult(value: nil, error: "No folder selected yet.") }
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
        let demo = docs.appendingPathComponent("DemoFolder", isDirectory: true)
        // A picked folder always exists before it is attached. The demo folder
        // is created only the first time, before seeding; after that the
        // store's own rule applies — a root that vanished is never recreated.
        let seededKey = "demoSeeded"
        if !UserDefaults.standard.bool(forKey: seededKey) {
            try? FileManager.default.createDirectory(at: demo, withIntermediateDirectories: true)
        }
        attach(demo, name: "Family")

        Task {
            await refresh()
            for r in routines {
                Self.logger.notice("demo: routine \(r.id.uuidString, privacy: .public) edits \(r.edits.count, privacy: .public) translations \(r.translations.count, privacy: .public)")
            }
            // `-demoMoveEntry`: move the note entry 20 days back, so a harness
            // can drive a cross-week write and its sweep from the shell.
            if ProcessInfo.processInfo.arguments.contains("-demoMoveEntry"),
               var note = entries.first(where: { $0.kind == .note }) {
                note.timestamp = Calendar.current.date(byAdding: .day, value: -20, to: note.timestamp) ?? note.timestamp
                Self.logger.notice("demo: moving entry \(note.id.uuidString, privacy: .public) to \(WeekKey.key(for: note.timestamp), privacy: .public)")
                update(note)
                return
            }
            // `-demoEditRoutine`: save an edit to the routine with the lowest
            // id, so a test harness can drive writeRoutine from the shell.
            if ProcessInfo.processInfo.arguments.contains("-demoEditRoutine"),
               var doc = routines.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                doc.body += "\n\nEdited by harness."
                doc.sourceLanguage = .en
                doc.translations = [:]
                Self.logger.notice("demo: editing routine \(doc.id.uuidString, privacy: .public)")
                try? await Task.sleep(for: .seconds(5))   // lets a harness change the files first
                saveRoutine(doc)
                return
            }
            guard entries.isEmpty, routines.isEmpty else { return }
            UserDefaults.standard.set(true, forKey: seededKey)

            func at(_ h: Int, _ m: Int) -> Date {
                Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? .now
            }
            // Overnight sleep: starts the evening before and ends this
            // morning, so it appears on both days.
            let cal = Calendar.current
            let yesterday = cal.date(byAdding: .day, value: -1, to: .now) ?? .now
            add(LogEntry(kind: .sleep,
                         timestamp: cal.date(bySettingHour: 21, minute: 45, second: 0,
                                             of: yesterday) ?? yesterday,
                         endTimestamp: at(7, 30),
                         note: "Settled quickly", noteLanguage: .en))
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
        // Accept ISO8601 with or without fractional seconds: the app's own
        // encoder writes whole seconds, but the offline translation process
        // emits millisecond timestamps. The plain `.iso8601` strategy rejects
        // fractional seconds on iOS 17's Foundation, which would silently fail
        // the whole sidecar decode and drop the translations.
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601.withFractional.date(from: s)
                ?? ISO8601.plain.date(from: s) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid ISO8601 date: \(s)"))
        }
        return d
    }
}

private enum ISO8601 {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}
