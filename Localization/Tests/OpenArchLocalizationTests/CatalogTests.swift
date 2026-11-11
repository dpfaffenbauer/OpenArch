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

    private static func placeholders(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|lld|ld|d|s|f|\\.\\d+f|%)")
        return pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
            String(value[Range($0.range, in: value)!])
        }
    }
}
