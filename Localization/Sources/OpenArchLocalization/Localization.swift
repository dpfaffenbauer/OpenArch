import Foundation

/// The languages OpenArch ships with. `system` follows macOS and falls back
/// to English when macOS asks for a language OpenArch does not have.
public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"

    public var id: String { rawValue }

    /// All languages with a translation table, including English.
    public static let supported: [AppLanguage] = [.english, .german, .french, .spanish, .italian]

    /// The language's own name, as language pickers show it.
    public var endonym: String {
        switch self {
        case .system: return Localization.string("System")
        case .english: return "English"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        }
    }

    /// Picks the first supported language from a preference list. Anything
    /// unsupported (Japanese, for example) falls back to English.
    public static func resolved(from preferred: [String]) -> AppLanguage {
        for identifier in preferred {
            let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            let primary = code.split(separator: "-").first.map(String.init) ?? code
            if let language = supported.first(where: { $0.rawValue == primary }) {
                return language
            }
        }
        return .english
    }
}

/// OpenArch's language choice. English is the default, in the app and in
/// every lookup that has no translation. The selection lives in the app's
/// preferences, so it can be applied before the first window opens.
public enum Localization {
    public static let selectionKey = "OpenArchLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    /// The saved choice; English unless the user chose another language.
    public static func selection(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let raw = defaults.string(forKey: selectionKey) else { return .english }
        return AppLanguage(rawValue: raw) ?? .english
    }

    /// The language whose UI strings are shown now.
    public static func current(in defaults: UserDefaults = .standard) -> AppLanguage {
        switch selection(in: defaults) {
        case .system:
            return AppLanguage.resolved(from: Locale.preferredLanguages)
        case let language:
            return language
        }
    }

    /// Applies the saved choice to the bundle for this process. Call it at
    /// the very start of `main.swift`, before AppKit and SwiftUI read a
    /// localized string. A changed choice needs a restart because Foundation
    /// caches the bundle's language for the lifetime of the process.
    @discardableResult
    public static func bootstrap(defaults: UserDefaults = .standard) -> AppLanguage {
        let choice = selection(in: defaults)
        let effective = current(in: defaults)
        if choice == .system {
            // Let macOS choose at launch: the app declares English as its
            // development language, so unsupported system languages get English.
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([effective.rawValue], forKey: appleLanguagesKey)
        }
        return effective
    }

    /// Remembers a new choice. The caller tells the user that OpenArch has
    /// to restart; on the next launch `bootstrap` applies it.
    public static func setSelection(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: selectionKey)
    }

    /// A localized string from the selected language, then English, then the
    /// key itself. `key` is the German source string, so untranslated strings
    /// are still readable in the source.
public static func string(_ key: String, language: AppLanguage? = nil,
                          bundle: Bundle = .main) -> String {
    let wanted = language ?? current()
    let code = wanted == .system ? current().rawValue : wanted.rawValue
    if let value = lookup(key, code: code, bundle: bundle) {
        return value
    }
    if code != "en", let value = lookup(key, code: "en", bundle: bundle) {
        return value
    }
    return key
}

    /// A localized format string with arguments. Use this for strings with
    /// values (counts, names, addresses), which SwiftUI cannot localize by
    /// itself. Placeholders in the translations use `%@` and `%lld`.
    public static func format(_ key: String, language: AppLanguage? = nil,
                              bundle: Bundle = .main, arguments: [CVarArg]) -> String {
        let format = string(key, language: language, bundle: bundle)
        guard !arguments.isEmpty else { return format }
        let wanted = language ?? current()
        let code = wanted == .system ? current().rawValue : wanted.rawValue
        return String(format: format, locale: Locale(identifier: code), arguments: arguments)
    }

    /// One or another string for a count. English, German, French, Spanish
    /// and Italian all use the singular for exactly one and the plural for
    /// every other number in the strings OpenArch shows.
    public static func count(_ count: Int, one: String, other: String, _ args: CVarArg...) -> String {
        let key = count == 1 ? one : other
        return format(key, arguments: [count] + args)
    }

    private static func lookup(_ key: String, code: String, bundle: Bundle) -> String? {
        guard let path = bundle.path(forResource: code, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else { return nil }
        let value = languageBundle.localizedString(forKey: key, value: nil, table: nil)
        return value
    }
}

/// Shorthand for a localized string in app code. Static SwiftUI literals
/// (`Text("…")`, `Button("…")`) are localized by SwiftUI itself; use `L`
/// for AppKit, model strings and interpolated values.
public func L(_ key: String, _ args: CVarArg...) -> String {
    Localization.format(key, arguments: args)
}
