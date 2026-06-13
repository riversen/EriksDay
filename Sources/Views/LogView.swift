import SwiftUI

struct LogView: View {
    @EnvironmentObject private var store: FolderStore

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
                                Text(kind.label).font(.caption)
                            }
                            .frame(maxWidth: .infinity, minHeight: 68)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section("Today") {
                if todays.isEmpty {
                    Text("Nothing logged yet today.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todays) { entry in
                        EntryRow(entry: entry)
                    }
                    .onDelete { offsets in
                        offsets.map { todays[$0] }.forEach(store.delete)
                    }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .frame(width: 26)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.label)
                if let amount = entry.amount {
                    Text(amount.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.timestamp, style: .time)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
