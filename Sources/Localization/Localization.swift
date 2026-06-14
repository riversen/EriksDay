import Foundation

/// The languages the app toggles between, each shown as a flag (+ a code for
/// the two Norwegian written standards, which share the same flag).
enum Language: String, Codable, CaseIterable, Identifiable {
    case en, nb, nn
    var id: String { rawValue }

    /// Flag emoji — American for English, Norwegian for both Bokmål/Nynorsk.
    var flag: String {
        switch self {
        case .en: "🇺🇸"
        case .nb, .nn: "🇳🇴"
        }
    }

    /// Short code shown under the flag (US / NB / NN).
    var code: String {
        switch self {
        case .en: "US"
        case .nb: "NB"
        case .nn: "NN"
        }
    }

    var accessibilityName: String {
        switch self {
        case .en: "English"
        case .nb: "Norsk bokmål"
        case .nn: "Norsk nynorsk"
        }
    }

    /// Locale for all date/time rendering. Month names/date order follow the
    /// language, but the hour cycle is pinned to 24-hour.
    var locale: Locale {
        let id: String
        switch self {
        case .en: id = "en_US"
        case .nb: id = "nb_NO"
        case .nn: id = "nn_NO"
        }
        var components = Locale.Components(locale: Locale(identifier: id))
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
            // First launch: follow the device. Plain "no" defaults to Bokmål.
            switch Locale.current.language.languageCode?.identifier {
            case "nn": current = .nn
            case "nb", "no": current = .nb
            default: current = .en
            }
        }
    }

    var s: Strings { Strings(current) }
}

/// All user-facing text, resolved for one language. Each entry carries the
/// English, Bokmål, and Nynorsk forms side by side.
struct Strings {
    let lang: Language
    init(_ lang: Language) { self.lang = lang }

    private func t(_ en: String, _ nb: String, _ nn: String) -> String {
        switch lang {
        case .en: en
        case .nb: nb
        case .nn: nn
        }
    }

    // Folder prompt
    var chooseFolderTitle: String { t("Choose your shared folder", "Velg den delte mappen", "Vel den delte mappa") }
    var chooseFolderBody: String {
        t("Pick the iCloud Drive folder you shared with family. Everyone selects the same folder on their own device.",
          "Velg iCloud Drive-mappen du delte med familien. Alle velger den samme mappen på sin egen enhet.",
          "Vel iCloud Drive-mappa du delte med familien. Alle vel den same mappa på si eiga eining.")
    }
    var chooseFolderButton: String { t("Choose Folder", "Velg mappe", "Vel mappe") }

    // Errors
    var errorTitle: String { t("Something went wrong", "Noe gikk galt", "Noko gjekk gale") }
    var ok: String { t("OK", "OK", "OK") }

    // Tabs
    var tabLog: String { t("Log", "Logg", "Logg") }
    var tabRoutines: String { t("Routines", "Rutiner", "Rutinar") }

    // Log screen
    var today: String { t("Today", "I dag", "I dag") }
    var yesterday: String { t("Yesterday", "I går", "I går") }
    var nothingYet: String { t("Nothing logged yet today.", "Ingenting registrert i dag ennå.", "Ingenting registrert i dag enno.") }
    var nothingThisDay: String { t("Nothing logged this day.", "Ingenting registrert denne dagen.", "Ingenting registrert denne dagen.") }
    var ongoing: String { t("ongoing", "pågår", "pågår") }

    // Entry editor
    var fellAsleep: String { t("Fell asleep", "Sovnet", "Sovna") }
    var time: String { t("Time", "Tidspunkt", "Tidspunkt") }
    var hasWokenUp: String { t("Has woken up", "Har våknet", "Har vakna") }
    var wokeUp: String { t("Woke up", "Våknet", "Vakna") }
    var amount: String { t("Amount", "Mengde", "Mengd") }
    var mood: String { t("Mood", "Humør", "Humør") }
    var notes: String { t("Notes", "Notater", "Notat") }
    var notesOptional: String { t("Notes (optional)", "Notater (valgfritt)", "Notat (valfritt)") }
    var history: String { t("History", "Historikk", "Historikk") }
    var cancel: String { t("Cancel", "Avbryt", "Avbryt") }
    var add: String { t("Add", "Legg til", "Legg til") }
    var save: String { t("Save", "Lagre", "Lagre") }
    var delete: String { t("Delete", "Slett", "Slett") }

    var sleepNotePrompt: String { t("Sleep quality, how he settled…", "Søvnkvalitet, hvordan han la seg …", "Søvnkvalitet, korleis han la seg …") }
    var mealNotePrompt: String { t("What he ate", "Hva han spiste", "Kva han åt") }
    var moodNotePrompt: String { t("What happened, how he seemed…", "Hva skjedde, hvordan han virket …", "Kva skjedde, korleis han verka …") }
    var notePrompt: String { t("Anything worth noting…", "Noe verdt å notere …", "Noko verdt å notere …") }

    // Routines
    var routines: String { t("Routines", "Rutiner", "Rutinar") }
    var newRoutine: String { t("New Routine", "Ny rutine", "Ny rutine") }
    var routineNamePrompt: String {
        t("Name (e.g. Sign Language, Likes, Dislikes)",
          "Navn (f.eks. Tegnspråk, Liker, Misliker)",
          "Namn (t.d. Teiknspråk, Likar, Mislikar)")
    }
    var noRoutines: String {
        t("No routines yet. Tap + to add one.",
          "Ingen rutiner ennå. Trykk + for å legge til.",
          "Ingen rutinar enno. Trykk + for å leggje til.")
    }
    var untitled: String { t("Untitled", "Uten navn", "Utan namn") }
    var editTab: String { t("Edit", "Rediger", "Rediger") }
    var previewTab: String { t("Preview", "Forhåndsvis", "Førehandsvis") }
    var rename: String { t("Rename", "Gi nytt navn", "Gi nytt namn") }

    // Formatting toolbar (accessibility labels)
    var bold: String { t("Bold", "Fet", "Feit") }
    var italic: String { t("Italic", "Kursiv", "Kursiv") }
    var strikethrough: String { t("Strikethrough", "Gjennomstreking", "Gjennomstreking") }
    var heading: String { t("Heading", "Overskrift", "Overskrift") }
    var bulletList: String { t("Bullet list", "Punktliste", "Punktliste") }
    var numberedList: String { t("Numbered list", "Nummerert liste", "Nummerert liste") }
    var insertLink: String { t("Link", "Lenke", "Lenkje") }
    var attachPhoto: String { t("Photo", "Bilde", "Bilete") }
    var attachVideo: String { t("Video", "Video", "Video") }
    var linkText: String { t("Text", "Tekst", "Tekst") }
    var linkURL: String { t("URL", "URL", "URL") }
    var routineBodyPrompt: String {
        t("Write notes here. Use the toolbar to format and attach photos or videos.",
          "Skriv notater her. Bruk verktøylinjen for å formatere og legge ved bilder eller video.",
          "Skriv notat her. Bruk verktøylinja for å formatere og leggje ved bilete eller video.")
    }

    // Enum labels
    func kind(_ kind: LogKind) -> String {
        switch kind {
        case .sleep: t("Sleep", "Sove", "Sove")
        case .wake:  t("Wake", "Våkne", "Vakne")
        case .nap:   t("Nap", "Lur", "Lur")
        case .meal:  t("Meal", "Måltid", "Måltid")
        case .urine: t("Pee", "Tiss", "Tiss")
        case .stool: t("Poop", "Bæsj", "Bæsj")
        case .mood:  t("Mood", "Humør", "Humør")
        case .note:  t("Note", "Notat", "Notat")
        }
    }

    func amount(_ amount: Amount) -> String {
        switch amount {
        case .little: t("A little", "Litt", "Litt")
        case .normal: t("Normal", "Normal", "Normal")
        case .extra:  t("Extra", "Ekstra", "Ekstra")
        }
    }

    func mood(_ mood: Mood) -> String {
        switch mood {
        case .happy:     t("Happy", "Glad", "Glad")
        case .energetic: t("Energetic", "Energisk", "Energisk")
        case .relaxed:   t("Relaxed", "Avslappet", "Avslappa")
        case .okay:      t("Okay", "Grei", "Grei")
        case .tired:     t("Tired", "Trøtt", "Trøtt")
        case .loud:      t("Loud", "Høylytt", "Høglydd")
        case .sad:       t("Sad", "Trist", "Trist")
        case .upset:     t("Upset", "Opprørt", "Opprørt")
        case .sib:       t("Self Injury (SIB)", "Selvskading (SIB)", "Sjølvskading (SIB)")
        }
    }
}
