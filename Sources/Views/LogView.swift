import SwiftUI

struct LogView: View {
    @EnvironmentObject private var store: FolderStore
    @EnvironmentObject private var language: AppLanguage

    @State private var editing: LogEntry?
    @State private var newEntry: LogEntry?

    private var s: Strings { language.s }

    private let quickKinds: [LogKind] = [.sleep, .wake, .nap, .meal, .urine, .stool]
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var todays: [LogEntry] {
        store.entries.filter { Calendar.current.isDateInToday($0.timestamp) }
    }

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(quickKinds) { kind in
                        Button {
                            store.add(LogEntry(kind: kind))
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: kind.symbol).font(.title2)
                                Text(s.kind(kind)).font(.caption)
                            }
                            .frame(maxWidth: .infinity, minHeight: 68)
                        }
                        .buttonStyle(.bordered)
                        .contextMenu {
                            Button {
                                newEntry = LogEntry(kind: kind,
                                                    amount: kind.hasAmount ? .medium : nil)
                            } label: {
                                Label(s.addWithDetails, systemImage: "square.and.pencil")
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section(s.today) {
                if todays.isEmpty {
                    Text(s.nothingYet)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todays) { entry in
                        Button { editing = entry } label: {
                            EntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { todays[$0] }.forEach(store.delete)
                    }
                }
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
