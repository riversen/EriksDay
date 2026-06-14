import Foundation

enum LogKind: String, Codable, CaseIterable, Identifiable {
    case sleep, wake, nap, meal, urine, stool, mood, note
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sleep: "moon.fill"
        case .wake:  "sun.max.fill"
        case .nap:   "zzz"
        case .meal:  "fork.knife"
        case .urine: "drop.fill"
        case .stool: "toilet.fill"
        case .mood:  "face.smiling"
        case .note:  "note.text"
        }
    }

    /// Sleep and naps have a start and an (optional, open-ended) end.
    var hasDuration: Bool { self == .sleep || self == .nap }

    /// Meals record how much was eaten.
    var hasAmount: Bool { self == .meal }

    /// Mood entries record how he seemed (one or more).
    var hasMood: Bool { self == .mood }
}

enum Amount: String, Codable, CaseIterable, Identifiable {
    case little, normal, extra
    var id: String { rawValue }

    /// Tolerant mapping that also accepts the pre-1.0 case names.
    init?(legacy raw: String) {
        switch raw {
        case "little":            self = .little
        case "normal", "medium":  self = .normal
        case "extra", "lots":     self = .extra
        default:                  return nil
        }
    }
}

enum Mood: String, Codable, CaseIterable, Identifiable {
    case happy, energetic, relaxed, okay, tired, loud, sad, upset, sib
    var id: String { rawValue }
}

/// One device's edit of an entry, for the per-entry audit log.
struct EditRecord: Codable, Hashable {
    var device: String
    var date: Date
}

/// One logged event. Persisted as a single JSON file at
/// `<folder>/entries/<weekKey>/<id>.json` so concurrent writers never touch the
/// same file and weeks can be loaded independently.
struct LogEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var kind: LogKind
    var amount: Amount?
    var moods: [Mood]
    /// Open-ended while nil (e.g. just noting that he went to sleep).
    var endTimestamp: Date?
    /// Freetext (optional): sleep quality, what he ate, etc. Carries its source
    /// language and any translations.
    var note: LocalizedText
    /// Accumulating audit log of who (which device) edited and when.
    var edits: [EditRecord]

    init(kind: LogKind,
         timestamp: Date = .now,
         amount: Amount? = nil,
         moods: [Mood] = [],
         endTimestamp: Date? = nil,
         note: String = "",
         noteLanguage: Language? = nil) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.amount = amount
        self.moods = moods
        self.endTimestamp = endTimestamp
        self.note = note.isEmpty ? LocalizedText() : LocalizedText(note, language: noteLanguage)
        self.edits = []
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, amount, moods, mood, endTimestamp, note, edits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        kind = try c.decode(LogKind.self, forKey: .kind)
        if let raw = try c.decodeIfPresent(String.self, forKey: .amount) {
            amount = Amount(legacy: raw)
        } else {
            amount = nil
        }
        // Prefer the multi-select array; fall back to a pre-1.0 single mood.
        if let arr = try c.decodeIfPresent([Mood].self, forKey: .moods) {
            moods = arr
        } else if let single = try c.decodeIfPresent(Mood.self, forKey: .mood) {
            moods = [single]
        } else {
            moods = []
        }
        endTimestamp = try c.decodeIfPresent(Date.self, forKey: .endTimestamp)
        // Accept the new LocalizedText object, or a pre-1.5 plain string.
        if let localized = try? c.decodeIfPresent(LocalizedText.self, forKey: .note) {
            note = localized
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .note), !legacy.isEmpty {
            note = LocalizedText(legacy: legacy)
        } else {
            note = LocalizedText()
        }
        edits = try c.decodeIfPresent([EditRecord].self, forKey: .edits) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(amount, forKey: .amount)
        try c.encode(moods, forKey: .moods)
        try c.encodeIfPresent(endTimestamp, forKey: .endTimestamp)
        try c.encode(note, forKey: .note)
        try c.encode(edits, forKey: .edits)
    }
}
