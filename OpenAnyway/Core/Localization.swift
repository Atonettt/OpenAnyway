import Foundation

/// Picks Chinese or English text based on the user's preferred language.
/// Set the user default "OpenAnywayLanguage" to "zh" or "en" to override.
enum Lang {
    static var isChinese: Bool {
        if let forced = UserDefaults.standard.string(forKey: "OpenAnywayLanguage") {
            return forced.hasPrefix("zh")
        }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
    }
}

/// Returns the Chinese or English variant of a UI string.
func L(_ zh: String, _ en: String) -> String { Lang.isChinese ? zh : en }
