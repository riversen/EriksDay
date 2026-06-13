import Foundation

enum LogKind: String, Codable, CaseIterable, Identifiable {
    case sleep, wake, nap, meal, urine, stool, note
    var id: String { rawValue }

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

    /// Sleep and naps have a start and an (optional, open-ended) end.
    var hasDuration: Bool { self == .sleep || self == .nap }

    /// Meals record how much was eaten.
    var hasAmount: Bool { self == .meal }
}

enum Amount: String, Codable, CaseIterable, Identifiable {
    case little, medium, lots
    var id: String { rawValue }
}

/// One logged event. Persisted as a single JSON file named `<id>.json`
/// so concurrent writers never touch the same file.
struct LogEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var kind: LogKind
    var amount: Amount?
    /// Open-ended while nil (e.g. just noting that he went to sleep).
    var endTimestamp: Date?
    /// Freetext: for sleep this is where quality/how-he-settled goes; for a
    /// meal it's what he ate.
    var note: String

    init(kind: LogKind,
         timestamp: Date = .now,
         amount: Amount? = nil,
         endTimestamp: Date? = nil,
         note: String = "") {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.amount = amount
        self.endTimestamp = endTimestamp
        self.note = note
    }
}
