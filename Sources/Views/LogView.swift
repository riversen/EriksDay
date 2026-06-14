import SwiftUI

struct LogView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage

    @State private var editing: LogEntry?
    @State private var newEntry: LogEntry?
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)

    private var s: Strings { language.s }

    private let quickKinds: [LogKind] = [.sleep, .wake, .nap, .meal, .urine, .stool]
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private let cal = Calendar.current

    /// Entries on the selected day (store keeps them newest-first).
    private var dayEntries: [LogEntry] {
        store.entries.filter { cal.isDate($0.timestamp, inSameDayAs: selectedDay) }
    }

    /// Days that have at least one entry, for the strip's dots.
    private var daysWithEntries: Set<Date> {
        Set(store.entries.map { cal.startOfDay(for: $0.timestamp) })
    }

    /// A continuous run of days ending today, reaching back far enough to cover
    /// the oldest entry but always at least two weeks.
    private var days: [Date] {
        let today = cal.startOfDay(for: .now)
        let twoWeeksAgo = cal.date(byAdding: .day, value: -13, to: today) ?? today
        let oldest = daysWithEntries.min() ?? today
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
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(quickKinds) { kind in
                        Button {
                            newEntry = LogEntry(kind: kind,
                                                timestamp: newEntryDate(),
                                                amount: kind.hasAmount ? .medium : nil)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: kind.symbol).font(.title2)
                                Text(s.kind(kind)).font(.caption)
                            }
                            .frame(maxWidth: .infinity, minHeight: 68)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
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
                        Button { editing = entry } label: {
                            EntryRow(entry: entry)
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
        .sheet(item: $editing) { entry in
            NavigationStack {
                EntryEditor(entry: entry, isNew: false,
                            onSave: store.update,
                            onDelete: { store.delete(entry) })
            }
        }
        .sheet(item: $newEntry) { entry in
            NavigationStack {
                EntryEditor(entry: entry, isNew: true,
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

    private var s: Strings { language.s }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .frame(width: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.kind(entry.kind))
                if let amount = entry.amount {
                    Text(s.amount(amount)).font(.caption).foregroundStyle(.secondary)
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            times
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var times: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(entry.timestamp, style: .time).monospacedDigit()
            if let end = entry.endTimestamp {
                Text(end, style: .time).font(.caption).monospacedDigit()
            } else if entry.kind.hasDuration {
                Text(s.ongoing).font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct EntryEditor: View {
    @EnvironmentObject private var language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    @State private var entry: LogEntry
    @State private var hasEnd: Bool
    @State private var endDate: Date
    @State private var amount: Amount

    let isNew: Bool
    let onSave: (LogEntry) -> Void
    let onDelete: (() -> Void)?

    init(entry: LogEntry, isNew: Bool,
         onSave: @escaping (LogEntry) -> Void,
         onDelete: (() -> Void)?) {
        _entry = State(initialValue: entry)
        _hasEnd = State(initialValue: entry.endTimestamp != nil)
        _endDate = State(initialValue: entry.endTimestamp ?? entry.timestamp)
        _amount = State(initialValue: entry.amount ?? .medium)
        self.isNew = isNew
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

            if kind.hasAmount {
                Section(s.amount) {
                    Picker(s.amount, selection: $amount) {
                        ForEach(Amount.allCases) { Text(s.amount($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section(s.notes) {
                TextField(notePrompt, text: $entry.note, axis: .vertical)
                    .lineLimit(1...6)
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
        default:           s.notes
        }
    }

    private func save() {
        var e = entry
        e.endTimestamp = kind.hasDuration && hasEnd ? endDate : nil
        e.amount = kind.hasAmount ? amount : nil
        onSave(e)
        dismiss()
    }
}
