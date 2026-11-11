import Foundation
@testable import OpenArchLocalization
import Testing

struct AppLanguageTests {
    @Test func knownSystemLanguagesWinInOrder() {
        #expect(AppLanguage.resolved(from: ["de-AT", "en-US"]) == .german)
        #expect(AppLanguage.resolved(from: ["fr-CA", "en-US"]) == .french)
        #expect(AppLanguage.resolved(from: ["es-419", "de-DE"]) == .spanish)
        #expect(AppLanguage.resolved(from: ["it-CH", "fr-FR"]) == .italian)
        #expect(AppLanguage.resolved(from: ["en-GB"]) == .english)
    }

    @Test func unsupportedAndEmptyPreferenceListsFallBackToEnglish() {
        #expect(AppLanguage.resolved(from: ["ja-JP", "ko-KR"]) == .english)
        #expect(AppLanguage.resolved(from: []) == .english)
    }

    @Test func defaultSelectionIsEnglish() {
        let suite = UserDefaults(suiteName: "OpenArchLocalizationTests.\(UUID().uuidString)")!
        #expect(Localization.selection(in: suite) == .english)
        #expect(Localization.current(in: suite) == .english)
    }

    @Test func explicitSelectionBeatsSystem() {
        let suite = UserDefaults(suiteName: "OpenArchLocalizationTests.\(UUID().uuidString)")!
        Localization.setSelection(.french, in: suite)
        #expect(Localization.selection(in: suite) == .french)
        #expect(Localization.current(in: suite) == .french)
    }

    @Test func bootstrapWritesAppleLanguagesForExplicitChoices() {
        let suite = UserDefaults(suiteName: "OpenArchLocalizationTests.\(UUID().uuidString)")!
        Localization.setSelection(.italian, in: suite)
        #expect(Localization.bootstrap(defaults: suite) == .italian)
        #expect(suite.stringArray(forKey: "AppleLanguages") == ["it"])
    }

    @Test func bootstrapLetsSystemChooseForSystemChoice() {
        let name = "OpenArchLocalizationTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        Localization.setSelection(.system, in: suite)
        suite.set(["de"], forKey: "AppleLanguages")
        _ = Localization.bootstrap(defaults: suite)
        // The standard domain can still see the host's global AppleLanguages;
        // what matters is that the app's own domain no longer overrides it.
        #expect(suite.persistentDomain(forName: name)?["AppleLanguages"] == nil)
    }
}
