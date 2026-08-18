import SwiftUI

struct LogView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage

    @State private var editing: EditTarget?
    @State private var newEntry: LogEntry?
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)

    private var s: Strings { language.s }

    private let quickKinds: [LogKind] = [.sleep, .wake, .nap, .meal, .urine, .stool, .mood, .note]
    // Fixed 4 columns so 8 kinds lay out as a compact 4×2 grid on iPhone.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    private let cal = Calendar.current

    /// Entries on the selected day, including sleep that spans into or out of
    /// it, ordered by when each one happened *on this day*.
    private var dayEntries: [LogEntry] {
        store.entries
            .filter { $0.occupies(selectedDay, cal) }
            .sorted { $0.sortTime(on: selectedDay, cal) > $1.sortTime(on: selectedDay, cal) }
    }

    /// Days that have at least one entry, for the strip's dots.
    private var daysWithEntries: Set<Date> {
        Set(store.entries.flatMap { $0.spannedDays(cal) })
    }

    /// A continuous run of days ending today, reaching back far enough to cover
    /// the oldest entry but always at least two weeks.
    private var days: [Date] {
        let today = cal.startOfDay(for: .now)
        let twoWeeksAgo = cal.date(byAdding: .day, value: -13, to: today) ?? today
        // earliest comes from week-folder names (cheap), so the strip can reach
        // back past what's currently loaded into memory.
        let oldest = store.earliestEntryDate.map { cal.startOfDay(for: $0) } ?? today
        var day = min(oldest, twoWeeksAgo)
        var result: [Date] = []
        while day <= today {
            result.append(day)
            day = cal.date(byAdding: .day, value: 1, to: day) ?? today.addingTimeInterval(1)
        }
        return result
    }

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(quickKinds) { kind in
                        Button {
                            if kind == .wake, let open = openDurationEntry() {
                                // Finish the sleep that's already running rather
                                // than logging a second, disconnected event.
                                editing = EditTarget(entry: open, prefillEnd: newEntryDate())
                            } else {
                                newEntry = LogEntry(kind: kind,
                                                    timestamp: newEntryDate(),
                                                    amount: kind.hasAmount ? .normal : nil)
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: kind.symbol).font(.body)
                                Text(s.kind(kind)).font(.caption2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }

            Section {
                DayStrip(days: days, daysWithEntries: daysWithEntries, selected: $selectedDay)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section {
                if dayEntries.isEmpty {
                    Text(cal.isDateInToday(selectedDay) ? s.nothingYet : s.nothingThisDay)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(dayEntries) { entry in
                        Button { editing = EditTarget(entry: entry, prefillEnd: nil) } label: {
                            EntryRow(entry: entry, day: selectedDay)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { dayEntries[$0] }.forEach(store.delete)
                    }
                }
            } header: {
                Text(dayTitle)
            }
        }
        .onAppear { store.ensureLoaded(weekOf: selectedDay) }
        .onChange(of: selectedDay) { _, day in store.ensureLoaded(weekOf: day) }
        .sheet(item: $editing) { target in
            NavigationStack {
                EntryEditor(entry: target.entry, isNew: false, uiLanguage: language.current,
                            prefillEnd: target.prefillEnd,
                            onSave: store.update,
                            onDelete: { store.delete(target.entry) })
            }
        }
        .sheet(item: $newEntry) { entry in
            NavigationStack {
                EntryEditor(entry: entry, isNew: true, uiLanguage: language.current,
                            prefillEnd: nil,
                            onSave: store.add,
                            onDelete: nil)
            }
        }
    }

    private var dayTitle: String {
        if cal.isDateInToday(selectedDay) { return s.today }
        if cal.isDateInYesterday(selectedDay) { return s.yesterday }
        return selectedDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(language.current.locale))
    }

    /// The most recent sleep or nap still open within the last 24 hours — what
    /// a Wake tap finishes instead of creating a separate entry. Nothing open
    /// means Wake logs a plain wake event.
    private func openDurationEntry() -> LogEntry? {
        let now = newEntryDate()
        let cutoff = now.addingTimeInterval(-24 * 3600)
        return store.entries
            .filter { $0.kind.hasDuration && $0.endTimestamp == nil
                      && $0.timestamp <= now && $0.timestamp >= cutoff }
            .max { $0.timestamp < $1.timestamp }
    }

    /// New entries log the actual moment on today; on a past day they are
    /// back-filled at the current time-of-day so they land on that day.
    private func newEntryDate() -> Date {
        if cal.isDateInToday(selectedDay) { return .now }
        let now = Date.now
        let hm = cal.dateComponents([.hour, .minute], from: now)
        return cal.date(bySettingHour: hm.hour ?? 12, minute: hm.minute ?? 0,
                        second: 0, of: selectedDay) ?? selectedDay
    }
}

/// What the editor sheet opens on. `prefillEnd` is set when a Wake tap is
/// finishing an already-running sleep, so the editor opens with the wake time
/// filled in.
private struct EditTarget: Identifiable {
    let entry: LogEntry
    let prefillEnd: Date?
    var id: UUID { entry.id }
}

/// Horizontally scrolling day picker, auto-scrolled to the selected day.
private struct DayStrip: View {
    let days: [Date]
    let daysWithEntries: Set<Date>
    @Binding var selected: Date

    private let cal = Calendar.current

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.self) { day in
                        DayCell(day: day,
                                selected: cal.isDate(day, inSameDayAs: selected),
                                hasEntries: daysWithEntries.contains(cal.startOfDay(for: day)))
                            .id(day)
                            .onTapGesture { selected = day }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .trailing) }
            .onChange(of: selected) { _, day in
                withAnimation { proxy.scrollTo(day, anchor: .center) }
            }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let selected: Bool
    let hasEntries: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(day, format: .dateTime.weekday(.abbreviated))
                .font(.caption2)
                .textCase(.uppercase)
            Text(day, format: .dateTime.day())
                .font(.headline)
            Circle()
                .frame(width: 5, height: 5)
                .foregroundStyle(selected ? .white : Color.accentColor)
                .opacity(hasEntries ? 1 : 0)
        }
        .frame(width: 48, height: 64)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EntryRow: View {
    @EnvironmentObject private var language: AppLanguage
    let entry: LogEntry
    let day: Date

    private var s: Strings { language.s }

    /// True when this is the tail of a sleep that began on an earlier day.
    private var continued: Bool { entry.continues(into: day) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .frame(width: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.kind(entry.kind))
                if continued {
                    Text("\(s.fromLabel) \(entry.timestamp.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(language.current.locale)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let amount = entry.amount {
                    Text(s.amount(amount)).font(.caption).foregroundStyle(.secondary)
                }
                if !entry.moods.isEmpty {
                    Text(entry.moods.map(s.mood).joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !entry.note.isEmpty {
                    Text(entry.note.resolved(for: language.current))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            times
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var times: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if continued {
                // What happened on *this* day is the waking, so lead with it.
                if let end = entry.endTimestamp {
                    Text(end, style: .time).monospacedDigit()
                } else {
                    Text(s.ongoing).font(.caption2)
                }
            } else {
                Text(entry.timestamp, style: .time).monospacedDigit()
                if let end = entry.endTimestamp {
                    Text(end, style: .time).font(.caption).monospacedDigit()
                } else if entry.kind.hasDuration {
                    Text(s.ongoing).font(.caption2)
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// A wrapping grid of multi-select mood chips — more than one can be true at
/// once (e.g. energetic and loud).
private struct MoodPicker: View {
    @EnvironmentObject private var language: AppLanguage
    @Binding var selection: Set<Mood>

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Mood.allCases) { mood in
                Button {
                    if selection.contains(mood) { selection.remove(mood) }
                    else { selection.insert(mood) }
                } label: {
                    Text(language.s.mood(mood))
                }
                .buttonStyle(MoodChipStyle(selected: selection.contains(mood)))
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MoodChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(selected ? Color.accentColor : Color(.secondarySystemBackground),
                        in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.primary)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct EntryEditor: View {
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    @State private var entry: LogEntry
    @State private var hasEnd: Bool
    @State private var endDate: Date
    @State private var amount: Amount
    @State private var moods: Set<Mood>
    @State private var noteText: String
    @State private var addSleepStart = false
    @State private var sleepStart: Date

    let isNew: Bool
    let uiLanguage: Language
    let onSave: (LogEntry) -> Void
    let onDelete: (() -> Void)?

    init(entry: LogEntry, isNew: Bool, uiLanguage: Language,
         prefillEnd: Date?,
         onSave: @escaping (LogEntry) -> Void,
         onDelete: (() -> Void)?) {
        _entry = State(initialValue: entry)
        _hasEnd = State(initialValue: entry.endTimestamp != nil || prefillEnd != nil)
        _endDate = State(initialValue: entry.endTimestamp ?? prefillEnd ?? entry.timestamp)
        _amount = State(initialValue: entry.amount ?? .normal)
        _moods = State(initialValue: Set(entry.moods))
        _noteText = State(initialValue: entry.note.resolved(for: uiLanguage))
        // Only a starting point; the caregiver adjusts it if they use it at all.
        _sleepStart = State(initialValue: entry.timestamp.addingTimeInterval(-8 * 3600))
        self.isNew = isNew
        self.uiLanguage = uiLanguage
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var s: Strings { language.s }
    private var kind: LogKind { entry.kind }

    var body: some View {
        Form {
            Section {
                DatePicker(kind.hasDuration ? s.fellAsleep : s.time,
                           selection: $entry.timestamp)
            }

            if kind.hasDuration {
                Section {
                    Toggle(s.hasWokenUp, isOn: $hasEnd.animation())
                    if hasEnd {
                        DatePicker(s.wokeUp, selection: $endDate,
                                   in: entry.timestamp...)
                    }
                }
            }

            if kind == .wake {
                Section {
                    Toggle(s.addSleepStart, isOn: $addSleepStart.animation())
                    if addSleepStart {
                        DatePicker(s.fellAsleep, selection: $sleepStart,
                                   in: ...entry.timestamp)
                    }
                } footer: {
                    Text(s.addSleepStartHelp)
                }
            }

            if kind.hasAmount {
                Section(s.amount) {
                    Picker(s.amount, selection: $amount) {
                        ForEach(Amount.allCases) { Text(s.amount($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if kind.hasMood {
                Section(s.mood) {
                    MoodPicker(selection: $moods)
                }
            }

            Section(s.notesOptional) {
                TextField(notePrompt, text: $noteText, axis: .vertical)
                    .lineLimit(1...6)
            }

            if !entry.edits.isEmpty {
                Section(s.history) {
                    ForEach(Array(entry.edits.enumerated()), id: \.offset) { _, edit in
                        HStack {
                            Text(edit.device).font(.caption)
                            Spacer()
                            Text(edit.date, format: .dateTime.day().month().hour().minute()
                                .locale(language.current.locale))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let onDelete {
                Section {
                    Button(s.delete, role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(s.kind(kind))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(s.cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? s.add : s.save) { save() }
            }
        }
    }

    private var notePrompt: String {
        switch kind {
        case .sleep, .nap: s.sleepNotePrompt
        case .meal:        s.mealNotePrompt
        case .mood:        s.moodNotePrompt
        case .note:        s.notePrompt
        default:           s.notes
        }
    }

    private func save() {
        var e = entry
        e.endTimestamp = kind.hasDuration && hasEnd ? endDate : nil
        e.amount = kind.hasAmount ? amount : nil
        e.moods = kind.hasMood ? Mood.allCases.filter { moods.contains($0) } : []
        // Only re-author the note (and invalidate translations) if it changed.
        if noteText != entry.note.resolved(for: uiLanguage) {
            e.note = noteText.isEmpty ? LocalizedText() : LocalizedText(noteText, language: uiLanguage)
        }
        // A wake with a known bedtime is really a sleep: recorded the same way
        // as one logged at bedtime, so durations work out identically.
        if kind == .wake, addSleepStart {
            e.kind = .sleep
            e.endTimestamp = e.timestamp
            e.timestamp = sleepStart
        }
        onSave(e)
        dismiss()
    }
}
