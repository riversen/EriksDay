import Foundation

/// One reference document in the Routines tab (e.g. "Sign Language", "Likes").
/// The source body is a markdown file at `<folder>/routines/<id>.md`; an audit
/// log, source language, and translations live in a sidecar
/// `<folder>/routines/<id>.json`; attached media is copied into
/// `<folder>/routines/media/`.
struct RoutineDoc: Identifiable, Hashable, Codable {
    let id: UUID
    var body: String          // source markdown
    var updatedAt: Date
    var edits: [EditRecord]
    /// Language the body was written in; nil for docs from before this was
    /// tracked.
    var sourceLanguage: Language?
    /// Translated markdown bodies keyed by language code, set offline.
    var translations: [String: String]
    /// False when the sidecar was on disk but couldn't be read: this doc's
    /// `edits`, `sourceLanguage` and `translations` are then empty because
    /// they are unknown, not because they are gone. Saving such a doc must
    /// merge into the sidecar rather than replace it.
    var metaLoaded: Bool

    init(id: UUID,
         body: String,
         updatedAt: Date,
         edits: [EditRecord] = [],
         sourceLanguage: Language? = nil,
         translations: [String: String] = [:],
         metaLoaded: Bool = true) {
        self.id = id
        self.body = body
        self.updatedAt = updatedAt
        self.edits = edits
        self.sourceLanguage = sourceLanguage
        self.translations = translations
        self.metaLoaded = metaLoaded
    }

    private enum CodingKeys: String, CodingKey {
        case id, body, updatedAt, edits, sourceLanguage, translations, metaLoaded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        body = try c.decode(String.self, forKey: .body)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        edits = try c.decodeIfPresent([EditRecord].self, forKey: .edits) ?? []
        sourceLanguage = try c.decodeIfPresent(Language.self, forKey: .sourceLanguage)
        translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:]
        metaLoaded = try c.decodeIfPresent(Bool.self, forKey: .metaLoaded) ?? true
    }

    /// Markdown body for the requested language, falling back to the closest
    /// available, then the source.
    func resolvedBody(for lang: Language) -> String {
        for candidate in LocalizedText.preference(for: lang) {
            if let t = translations[candidate.rawValue], !t.isEmpty { return t }
            if sourceLanguage == candidate, !body.isEmpty { return body }
        }
        return body
    }

    /// Title of the source body (first heading or first non-empty line).
    var title: String { Self.title(from: body) }

    func resolvedTitle(for lang: Language) -> String { Self.title(from: resolvedBody(for: lang)) }

    static func title(from body: String) -> String {
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
    var sourceLanguage: Language?
    var translations: [String: String]
    /// Fields that were present but couldn't be decoded. Their content is
    /// unknown, not empty — writing the sidecar back must carry them over
    /// verbatim rather than replace them with what this build could parse.
    var undecodedKeys: Set<String> = []

    init(edits: [EditRecord] = [], sourceLanguage: Language? = nil, translations: [String: String] = [:]) {
        self.edits = edits
        self.sourceLanguage = sourceLanguage
        self.translations = translations
    }

    private enum CodingKeys: String, CodingKey { case edits, sourceLanguage, translations }

    /// Every field is decoded on its own, so one unknown language or malformed
    /// date costs only that field: an audit log and offline translations can't
    /// be reproduced. What failed is recorded rather than silently emptied.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var failed: Set<String> = []
        do { edits = try c.decodeIfPresent([EditRecord].self, forKey: .edits) ?? [] }
        catch { edits = []; failed.insert(CodingKeys.edits.rawValue) }
        do { sourceLanguage = try c.decodeIfPresent(Language.self, forKey: .sourceLanguage) }
        catch { sourceLanguage = nil; failed.insert(CodingKeys.sourceLanguage.rawValue) }
        do { translations = try c.decodeIfPresent([String: String].self, forKey: .translations) ?? [:] }
        catch { translations = [:]; failed.insert(CodingKeys.translations.rawValue) }
        undecodedKeys = failed
    }
}
