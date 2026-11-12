import AppKit
import OpenArchLocalization
import SwiftUI

/// `--selftest --settings-test`: navigation, search destinations and window sizing.
extension SelfTest {
    func settingsTests() {
        var navigation = SettingsNavigation(page: .general)
        expect(!navigation.canGoBack && !navigation.canGoForward, "settings history starts with both arrows disabled")
        navigation.back()
        navigation.forward()
        expect(navigation.page == .general, "disabled history actions leave the page unchanged")
        navigation.visit(.about)
        navigation.visit(.links)
        navigation.back()
        expect(navigation.page == .about && navigation.canGoBack && navigation.canGoForward,
               "Back returns to the previous settings page and enables Forward")
        navigation.forward()
        expect(navigation.page == .links && !navigation.canGoForward, "Forward restores the next settings page")
        navigation.back()
        navigation.visit(.keyboard)
        expect(navigation.history == [.general, .about, .keyboard] && !navigation.canGoForward,
               "opening another category after Back replaces the forward branch")
        navigation.visit(.keyboard)
        expect(navigation.history.count == 3, "reselecting the current category adds no duplicate history entry")
        expect(navigation.recentPages == [.keyboard, .about, .general], "search suggestions show unique recent categories")

        expect(SettingsSearchResult.matching(" \n ").isEmpty, "empty settings search has no result list")
        let engine = SettingsSearchResult.matching(L("Suchmaschine"))
        expect(engine.contains { $0.page == .general && $0.target == "Suchmaschine" },
               "settings search finds an individual setting with a scroll destination")
        let backup = SettingsSearchResult.matching(L("Sicherung"))
        expect(backup.contains { $0.page == .about && $0.target == "Sicherung" },
               "search finds a section even when the category title does not match")
        let mixedCase = SettingsSearchResult.matching("  " + L("Suchmaschine").uppercased() + "  ")
        expect(mixedCase.map(\.id) == engine.map(\.id), "settings search ignores case and surrounding whitespace")
        expect(SettingsSearchResult.matching("zzzz-no-matching-setting").isEmpty, "unmatched queries show an empty result")

        guard let app = NSApp.delegate as? AppDelegate else {
            return expect(false, "the app delegate exists for settings window tests")
        }
        app.showSettings(page: .about)
        guard let window = app.settingsWindow else { return expect(false, "the settings window exists") }
        expect(window.styleMask.contains(.resizable) && window.styleMask.contains(.miniaturizable),
               "settings can be resized and minimized like System Settings")
        expect(!window.isOpaque && window.backgroundColor == .clear, "the settings sidebar can show native window material")
        expect(window.minSize == NSSize(width: 820, height: 600), "settings has a supported minimum size")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [NSSize(width: 820, height: 600), NSSize(width: 1100, height: 800)] {
                let host = NSHostingView(rootView: SettingsView(app: app, page: .about))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                expect(host.fittingSize.width <= size.width && host.fittingSize.height <= size.height,
                       "settings fits \(Int(size.width))×\(Int(size.height)) in \(appearance.rawValue)")
            }
        }
        window.close()
    }
}
