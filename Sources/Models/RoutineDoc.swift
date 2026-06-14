import Foundation

/// One reference document in the Routines tab (e.g. "Sign Language", "Likes").
/// The body is a markdown file at `<folder>/routines/<id>.md`; an audit log
/// lives in a sidecar `<folder>/routines/<id>.json`; attached media is copied
/// into `<folder>/routines/media/`.
struct RoutineDoc: Identifiable, Hashable {
    let id: UUID
    var body: String          // markdown source
    var updatedAt: Date
    var edits: [EditRecord]

    init(id: UUID, body: String, updatedAt: Date, edits: [EditRecord] = []) {
        self.id = id
        self.body = body
        self.updatedAt = updatedAt
        self.edits = edits
    }

    /// Title shown in the list: the first markdown heading, else the first
    /// non-empty line. Empty when the document has no text yet.
    var title: String {
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                return String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return ""
    }
}

/// Sidecar metadata persisted next to the markdown body.
struct RoutineMeta: Codable {
    var edits: [EditRecord]
}
