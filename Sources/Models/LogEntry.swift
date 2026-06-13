import Foundation

enum LogKind: String, Codable, CaseIterable, Identifiable {
    case sleep, wake, nap, meal, urine, stool, note
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sleep: "Sleep"
        case .wake:  "Wake"
        case .nap:   "Nap"
        case .meal:  "Meal"
        case .urine: "Pee"
        case .stool: "Poop"
        case .note:  "Note"
        }
    }

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .wake:  "sun.max.fill"
        case .nap:   "zzz"
        case .meal:  "fork.knife"
        case .urine: "drop.fill"
        case .stool: "toilet.fill"
        case .note:  "note.text"
        }
    }
}

enum Amount: String, Codable, CaseIterable, Identifiable {
    case little, some, normal, lots
    var id: String { rawValue }
}

enum SleepQuality: String, Codable, CaseIterable, Identifiable {
    case poor, fair, good
    var id: String { rawValue }
}

/// One logged event. Persisted as a single JSON file named `<id>.json`
/// so concurrent writers never touch the same file.
struct LogEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var kind: LogKind
    var amount: Amount?
    var quality: SleepQuality?
    var endTimestamp: Date?
    var note: String

    init(kind: LogKind,
         timestamp: Date = .now,
         amount: Amount? = nil,
         quality: SleepQuality? = nil,
         endTimestamp: Date? = nil,
         note: String = "") {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.amount = amount
        self.quality = quality
        self.endTimestamp = endTimestamp
        self.note = note
    }
}
