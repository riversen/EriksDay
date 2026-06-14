import Foundation

/// The two languages the app toggles between, each shown as a flag.
enum Language: String, CaseIterable, Identifiable {
    case en, no
    var id: String { rawValue }

    /// Flag emoji used for the toggle (American English / Norwegian).
    var flag: String {
        switch self {
        case .en: "🇺🇸"
        case .no: "🇳🇴"
        }
    }

    var accessibilityName: String {
        switch self {
        case .en: "English"
        case .no: "Norsk"
        }
    }

    /// Locale used for all date/time rendering. Month names and date order
    /// follow the language, but the hour cycle is pinned to 24-hour for both
    /// so the time is never shown as AM/PM.
    var locale: Locale {
        let base: Locale
        switch self {
        case .en: base = Locale(identifier: "en_US")
        case .no: base = Locale(identifier: "nb_NO")
        }
        var components = Locale.Components(locale: base)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }
}

/// Holds the chosen language, persisted per device. Toggling re-renders every
/// view that reads it via `@EnvironmentObject`.
@MainActor
final class AppLanguage: ObservableObject {
    @Published var current: Language {
        didSet { UserDefaults.standard.set(current.rawValue, forKey: key) }
    }

    private let key = "appLanguage"

    init() {
        if let saved = UserDefaults.standard.string(forKey: key),
           let lang = Language(rawValue: saved) {
            current = lang
        } else {
            // First launch: follow the device, defaulting to English.
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            current = ["nb", "nn", "no"].contains(code) ? .no : .en
        }
    }

    /// Localized strings for the current language.
    var s: Strings { Strings(current) }
}

/// All user-facing text, resolved for one language. Adding a string here keeps
/// both translations side by side.
struct Strings {
    let lang: Language
    init(_ lang: Language) { self.lang = lang }

    private func t(_ en: String, _ no: String) -> String { lang == .no ? no : en }

    // Folder prompt
    var chooseFolderTitle: String { t("Choose your shared folder", "Velg den delte mappen") }
    var chooseFolderBody: String {
        t("Pick the iCloud Drive folder you shared with family. Everyone selects the same folder on their own device.",
          "Velg iCloud Drive-mappen du delte med familien. Alle velger den samme mappen på sin egen enhet.")
    }
    var chooseFolderButton: String { t("Choose Folder", "Velg mappe") }

    // Errors
    var errorTitle: String { t("Something went wrong", "Noe gikk galt") }
    var ok: String { t("OK", "OK") }

    // Log screen
    var today: String { t("Today", "I dag") }
    var yesterday: String { t("Yesterday", "I går") }
    var nothingYet: String { t("Nothing logged yet today.", "Ingenting registrert i dag ennå.") }
    var nothingThisDay: String { t("Nothing logged this day.", "Ingenting registrert denne dagen.") }
    var ongoing: String { t("ongoing", "pågår") }

    // Editor
    var fellAsleep: String { t("Fell asleep", "Sovnet") }
    var time: String { t("Time", "Tidspunkt") }
    var hasWokenUp: String { t("Has woken up", "Har våknet") }
    var wokeUp: String { t("Woke up", "Våknet") }
    var amount: String { t("Amount", "Mengde") }
    var mood: String { t("Mood", "Humør") }
    var notes: String { t("Notes", "Notater") }
    var cancel: String { t("Cancel", "Avbryt") }
    var add: String { t("Add", "Legg til") }
    var save: String { t("Save", "Lagre") }
    var delete: String { t("Delete", "Slett") }

    var sleepNotePrompt: String { t("Sleep quality, how he settled…", "Søvnkvalitet, hvordan han la seg …") }
    var mealNotePrompt: String { t("What he ate", "Hva han spiste") }
    var moodNotePrompt: String { t("What happened, how he seemed…", "Hva skjedde, hvordan han virket …") }
    var notePrompt: String { t("Anything worth noting…", "Noe verdt å notere …") }

    // Enum labels
    func kind(_ kind: LogKind) -> String {
        switch kind {
        case .sleep: t("Sleep", "Sove")
        case .wake:  t("Wake", "Våkne")
        case .nap:   t("Nap", "Lur")
        case .meal:  t("Meal", "Måltid")
        case .urine: t("Pee", "Tiss")
        case .stool: t("Poop", "Bæsj")
        case .mood:  t("Mood", "Humør")
        case .note:  t("Note", "Notat")
        }
    }

    func amount(_ amount: Amount) -> String {
        switch amount {
        case .little: t("A little", "Litt")
        case .medium: t("Medium", "Middels")
        case .lots:   t("A lot", "Mye")
        }
    }

    func mood(_ mood: Mood) -> String {
        switch mood {
        case .happy:     t("Happy", "Glad")
        case .energetic: t("Energetic", "Energisk")
        case .relaxed:   t("Relaxed", "Avslappet")
        case .okay:      t("Okay", "Grei")
        case .tired:     t("Tired", "Trøtt")
        case .loud:      t("Loud", "Høylytt")
        case .sad:       t("Sad", "Trist")
        case .upset:     t("Upset", "Opprørt")
        }
    }
}
