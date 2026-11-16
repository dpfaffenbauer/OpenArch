import Foundation
@testable import OpenArchLocalization
import Testing

/// The shipped tables must stay complete: every language has every key, and
/// every placeholder survives translation. A missing key would otherwise fall
/// back to German text in the middle of an English window.
struct CatalogTests {
    private static let languages = ["en", "de", "fr", "es", "it"]

    private static var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenArchLocalizationTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Localization
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("App/Resources")
    }

    private static func strings(_ language: String, _ name: String) throws -> [String: String] {
        let url = resources.appendingPathComponent("\(language).lproj/\(name).strings")
        guard let table = NSDictionary(contentsOf: url) as? [String: String] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return table
    }

    @Test func everyLanguageHasTheSameKeys() throws {
        let english = try Self.strings("en", "Localizable")
        #expect(!english.isEmpty)
        for language in Self.languages.dropFirst() {
            let table = try Self.strings(language, "Localizable")
            #expect(Set(table.keys) == Set(english.keys),
                    "\(language) differs: missing \(Set(english.keys).subtracting(table.keys).sorted()), extra \(Set(table.keys).subtracting(english.keys).sorted())")
        }
    }

    @Test func noTranslationIsEmpty() throws {
        for language in Self.languages {
            let table = try Self.strings(language, "Localizable")
            let empty = table.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            #expect(empty.isEmpty, "\(language) has empty translations for \(empty.keys.sorted())")
        }
    }

    @Test func placeholdersSurviveTranslation() throws {
        let english = try Self.strings("en", "Localizable")
        for language in Self.languages {
            let table = try Self.strings(language, "Localizable")
            for (key, value) in table {
                #expect(Self.placeholders(value) == Self.placeholders(key),
                        "\(language): placeholders differ for \(key.debugDescription): \(value.debugDescription)")
            }
        }
        #expect(!english.isEmpty)
    }

    @Test func infoPlistStringsCoverEveryLanguage() throws {
        let english = try Self.strings("en", "InfoPlist")
        let wanted: Set<String> = [
            "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
            "NSBluetoothAlwaysUsageDescription", "NSLocationUsageDescription",
            "NSAppleEventsUsageDescription", "NSCalendarsFullAccessUsageDescription",
            "NSCalendarsUsageDescription",
        ]
        #expect(Set(english.keys) == wanted)
        for language in Self.languages.dropFirst() {
            let table = try Self.strings(language, "InfoPlist")
            #expect(Set(table.keys) == wanted, "\(language) InfoPlist keys differ")
        }
    }

    @Test func languageNamesAreEndonyms() {
        #expect(AppLanguage.english.endonym == "English")
        #expect(AppLanguage.german.endonym == "Deutsch")
        #expect(AppLanguage.french.endonym == "Français")
        #expect(AppLanguage.spanish.endonym == "Español")
        #expect(AppLanguage.italian.endonym == "Italiano")
    }

    @Test func lowercaseLabelsAndSemicolonCopyAreTranslated() throws {
        let keys = [
            "nie", "jetzt", "gestern", "einmal",
            "Gelöscht; der Link zeigt noch den letzten Stand.",
            "Die Lesezeichen liegen verschlüsselt auf dem Teilen-Server; der Schlüssel steht nur im Link. Änderungen erscheinen bei allen mit dem Link.",
            "Die Lesezeichen reisen verschlüsselt im Link selbst; kein Server ist beteiligt. Spätere Änderungen erscheinen nicht.",
        ]
        for language in Self.languages {
            let table = try Self.strings(language, "Localizable")
            for key in keys {
                #expect(table[key] != nil, "\(language) is missing \(key)")
            }
        }
        #expect(try Self.strings("en", "Localizable")["nie"] == "never")
        #expect(try Self.strings("fr", "Localizable")["nie"] == "jamais")
        #expect(try Self.strings("es", "Localizable")["nie"] == "nunca")
        #expect(try Self.strings("it", "Localizable")["nie"] == "mai")
    }

    /// iPhone and iPad: Xcode's string catalogs, filled in by scripts/localize.py.
    private static func iOSCatalog(_ name: String) throws -> [String: Any] {
        let url = resources.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/OpenArch/\(name)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require((object as? [String: Any])?["strings"] as? [String: Any])
    }

    @Test(arguments: ["Localizable.xcstrings", "InfoPlist.xcstrings"])
    func iOSCatalogsHaveEveryLanguage(_ name: String) throws {
        let strings = try Self.iOSCatalog(name)
        #expect(!strings.isEmpty)
        for (key, value) in strings {
            let entry = try #require(value as? [String: Any])
            if entry["shouldTranslate"] as? Bool == false { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in ["en", "fr", "es", "it"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                let translated = unit?["value"] as? String ?? ""
                #expect(!translated.isEmpty, "\(name): \(language) is missing \(key.debugDescription)")
                // English may number its placeholders (%1$@); compare without.
                #expect(Self.placeholders(translated).map(Self.unnumbered) == Self.placeholders(key).map(Self.unnumbered)
                        || language == "en" && Set(Self.placeholders(translated).map(Self.unnumbered)) == Set(Self.placeholders(key).map(Self.unnumbered)),
                        "\(name): \(language) placeholders differ for \(key.debugDescription): \(translated.debugDescription)")
            }
        }
    }

    private static func unnumbered(_ placeholder: String) -> String {
        placeholder.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
    }

    private static func placeholders(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|lld|ld|d|s|f|\\.\\d+f|%)")
        return pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }
    }
}
