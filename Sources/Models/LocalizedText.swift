import Foundation

/// Free text plus its source language and (optionally) translations into the
/// other languages. An offline process can fill `translations` later; until it
/// does, `resolved(for:)` falls back to the closest available language.
///
/// JSON shape (friendly for an external translator):
/// ```
/// { "source": "Great day", "sourceLanguage": "en",
///   "translations": { "nb": "Fin dag", "nn": "Fin dag" } }
/// ```
struct LocalizedText: Codable, Hashable {
    /// The text exactly as entered.
    var source: String
    /// Language it was entered in; nil for text from before this was tracked.
    var sourceLanguage: Language?
    /// Translated text keyed by language code (rawValue), set by the offline
    /// translation process. Does not include the source language.
    var translations: [String: String]

    init(_ source: String = "", language: Language? = nil, translations: [String: String] = [:]) {
        self.source = source
        self.sourceLanguage = language
        self.translations = translations
    }

    /// Wrap pre-existing plain text whose language we don't know.
    init(legacy source: String) {
        self.source = source
        self.sourceLanguage = nil
        self.translations = [:]
    }

    var isEmpty: Bool {
        source.isEmpty && !translations.values.contains { !$0.isEmpty }
    }

    /// Best text for the requested language, falling back to the closest one
    /// available, then to the source.
    func resolved(for lang: Language) -> String {
        for candidate in Self.preference(for: lang) {
            if let t = translations[candidate.rawValue], !t.isEmpty { return t }
            if sourceLanguage == candidate, !source.isEmpty { return source }
        }
        if !source.isEmpty { return source }
        return translations.values.first { !$0.isEmpty } ?? ""
    }

    /// Preference order when a language's own text is missing: English falls to
    /// the Norwegian standards; each Norwegian standard falls to the other then
    /// English.
    static func preference(for lang: Language) -> [Language] {
        switch lang {
        case .en: [.en, .nb, .nn]
        case .nb: [.nb, .nn, .en]
        case .nn: [.nn, .nb, .en]
        }
    }
}
