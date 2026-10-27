import AppKit
import OpenArchCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let selfTest: Bool
    private(set) var library: Library!
    private(set) var history: History!
    private(set) var browser: BrowserWindowController?
    private var settingsWindow: NSWindow?
    private var pendingURLs: [String] = []
    private var test: SelfTest?

    init(selfTest: Bool) {
        self.selfTest = selfTest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The self-test runs in the background: no Dock icon, no focus.
        NSApp.setActivationPolicy(selfTest ? .accessory : .regular)
        NSApp.mainMenu = MainMenu.build(target: self)
        ShortcutMonitor.install(target: self)
        log("Chromium \(OACEngine.versionString)")
        library = Library.load()
        history = History()
        OACEngine.whenReady { [self] in
            let browser = BrowserWindowController(library: library, history: history)
            self.browser = browser
            browser.showWindow(nil)
            if selfTest {
                test = SelfTest(browser: browser)
                test?.start()
            } else {
                browser.restoreSession()
                for url in pendingURLs { browser.openInNewTab(url) }
                pendingURLs = []
                offerArcImportOnFirstRun()
                importArcFaviconsOnce()
                if let result = ArcProfileImport.takeResult() {
                    let alert = NSAlert()
                    alert.messageText = "Import aus Arc"
                    alert.informativeText = result
                    alert.runModal()
                }
            }
        }
        if !selfTest {
            NSApp.activate()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        library?.save()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        browser?.showWindow(nil)
        return true
    }

    /// Links opened from other apps (when OpenArch is the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        let strings = urls.map(\.absoluteString)
        if let browser {
            browser.showWindow(nil)
            for url in strings { browser.openInNewTab(url) }
        } else {
            pendingURLs += strings
        }
    }

    /// Libraries imported before favicons were part of the import.
    private func importArcFaviconsOnce() {
        let key = "didImportArcFavicons"
        guard !UserDefaults.standard.bool(forKey: key), ArcImporter.isAvailable else { return }
        UserDefaults.standard.set(true, forKey: key)
        ArcFavicons.importIcons(for: ArcFavicons.urls(in: library))
    }

    private func offerArcImportOnFirstRun() {
        let key = "didOfferArcImport"
        guard !UserDefaults.standard.bool(forKey: key), ArcImporter.isAvailable else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Sidebar aus Arc übernehmen?"
        alert.informativeText = "OpenArch kann Spaces, Favoriten, angeheftete Tabs mit Ordnern und offene Tabs aus Arc übernehmen. Arc selbst bleibt unverändert."
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Nicht jetzt")
        if alert.runModal() == .alertFirstButtonReturn {
            importFromArc(nil)
        }
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "OpenArch-Einstellungen"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(app: self))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func importFromArc(_ sender: Any?) {
        guard let browser else { return }
        do {
            let (data, summary) = try ArcImporter.load()
            let alert = NSAlert()
            alert.messageText = "Aus Arc importieren"
            alert.informativeText = """
                Sidebar: \(summary.spaces) Space(s), \(summary.favorites) Favoriten, \(summary.pinned) angeheftete Tabs \
                in \(summary.folders) Ordnern und \(summary.today) offene Tabs.

                „Alles übernehmen“ holt zusätzlich Logins und Cookies, gespeicherte Passwörter, Verlauf, Website-Daten \
                und die installierten Extensions samt Einstellungen. Dafür startet OpenArch neu, Arc muss beendet sein, \
                und macOS fragt einmal nach dem Zugriff auf „Arc Safe Storage“. Bisherige OpenArch-Daten bleiben als \
                Sicherung erhalten.
                """
            alert.addButton(withTitle: "Alles übernehmen")
            alert.addButton(withTitle: "Nur Sidebar")
            alert.addButton(withTitle: "Abbrechen")
            let choice = alert.runModal()
            guard choice != .alertThirdButtonReturn else { return }
            if choice == .alertFirstButtonReturn, !quitArcIfNeeded() {
                return
            }
            browser.prepareForLibraryReplacement()
            library.replace(with: data)
            ArcFavicons.importIcons(for: ArcFavicons.urls(in: library))
            browser.libraryWasReplaced()
            if choice == .alertFirstButtonReturn {
                library.save()
                ArcProfileImport.scheduleAndRelaunch()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Arc has to be closed so its databases are complete on disk.
    private func quitArcIfNeeded() -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: ArcProfileImport.arcBundleID)
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Arc beenden?"
        alert.informativeText = "Arc läuft noch. Damit Logins und Website-Daten vollständig übernommen werden, muss Arc beendet sein. Deine Tabs in Arc bleiben erhalten."
        alert.addButton(withTitle: "Arc beenden")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, running.contains(where: { !$0.isTerminated }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if running.contains(where: { !$0.isTerminated }) {
            let failed = NSAlert()
            failed.messageText = "Arc ließ sich nicht beenden."
            failed.informativeText = "Bitte beende Arc selbst und starte den Import dann noch einmal."
            failed.runModal()
            return false
        }
        return true
    }

    @objc func installArcExtensions(_ sender: Any?) {
        guard let browser else { return }
        let extensions = ArcExtensions.installed()
        guard !extensions.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Keine Extensions in Arc gefunden."
            alert.runModal()
            return
        }
        browser.addExtensionFolder(extensions)
    }

    @objc func setAsDefaultBrowser(_ sender: Any?) {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "http") { _ in }
        NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "https") { _ in }
    }

    @objc func newTab(_ sender: Any?) { browser?.commandBar.show(mode: .newTab) }
    @objc func openLocation(_ sender: Any?) { browser?.commandBar.show(mode: .editURL) }
    @objc func closeTab(_ sender: Any?) {
        if let key = NSApp.keyWindow, key === settingsWindow {
            key.close()
        } else {
            browser?.closeActiveTab()
        }
    }
    @objc func reopenTab(_ sender: Any?) { browser?.reopenClosedTab() }
    @objc func newFolder(_ sender: Any?) { browser?.newFolder() }
    @objc func newSpace(_ sender: Any?) { browser?.addSpace() }
    @objc func editSpace(_ sender: Any?) {
        guard let browser else { return }
        browser.state.editingSpaceID = browser.state.space.id
    }
    @objc func toggleSidebar(_ sender: Any?) { browser?.toggleSidebar() }
    @objc func toggleLibrary(_ sender: Any?) { browser?.toggleLibrary() }
    @objc func toggleToolbar(_ sender: Any?) { browser?.toggleChromeToolbar() }
    @objc func splitView(_ sender: Any?) { browser?.splitWithNewTab() }
    @objc func unsplitView(_ sender: Any?) { browser?.unsplit() }
    @objc func copyURL(_ sender: Any?) { browser?.copyURL() }
    @objc func reload(_ sender: Any?) { browser?.reload() }
    @objc func reloadHard(_ sender: Any?) { browser?.runChromeCommand(.reloadBypassingCache) }
    @objc func goBack(_ sender: Any?) { browser?.goBack() }
    @objc func goForward(_ sender: Any?) { browser?.goForward() }
    @objc func find(_ sender: Any?) { browser?.runChromeCommand(.find) }
    @objc func findNext(_ sender: Any?) { browser?.runChromeCommand(.findNext) }
    @objc func findPrevious(_ sender: Any?) { browser?.runChromeCommand(.findPrevious) }
    @objc func zoomIn(_ sender: Any?) { browser?.runChromeCommand(.zoomPlus) }
    @objc func zoomOut(_ sender: Any?) { browser?.runChromeCommand(.zoomMinus) }
    @objc func zoomReset(_ sender: Any?) { browser?.runChromeCommand(.zoomNormal) }
    @objc func printPage(_ sender: Any?) { browser?.runChromeCommand(.print) }
    @objc func devTools(_ sender: Any?) { browser?.activePane?.showDevTools() }
    @objc func viewSource(_ sender: Any?) { browser?.runChromeCommand(.viewSource) }
    @objc func toggleFullScreen(_ sender: Any?) { browser?.window?.toggleFullScreen(nil) }
    @objc func showHistory(_ sender: Any?) { browser?.openChromePage("chrome://history") }
    @objc func showDownloads(_ sender: Any?) { browser?.openChromePage("chrome://downloads") }
    @objc func showPasswords(_ sender: Any?) { browser?.openChromePage("chrome://password-manager") }
    @objc func manageExtensions(_ sender: Any?) { browser?.openChromePage("chrome://extensions") }
    @objc func openWebStore(_ sender: Any?) { browser?.openChromePage("https://chromewebstore.google.com") }
    @objc func chromeSettings(_ sender: Any?) { browser?.openChromePage("chrome://settings") }
    @objc func nextTab(_ sender: Any?) { browser?.selectAdjacentTab(1) }
    @objc func previousTab(_ sender: Any?) { browser?.selectAdjacentTab(-1) }
    @objc func togglePin(_ sender: Any?) {
        if let active = browser?.state.activeItem { browser?.togglePin(active) }
    }
    @objc func addFavorite(_ sender: Any?) {
        if let active = browser?.state.activeItem { browser?.addToFavorites(active) }
    }
    @objc func duplicateTab(_ sender: Any?) {
        if let active = browser?.state.activeItem { browser?.duplicate(active) }
    }
    @objc func selectTab(_ sender: NSMenuItem) { browser?.selectTab(at: sender.tag) }
    @objc func recentTab(_ sender: Any?) { browser?.selectRecentTab(1) }
    @objc func recentTabBack(_ sender: Any?) { browser?.selectRecentTab(-1) }
    @objc func clearToday(_ sender: Any?) { browser?.clearToday() }
    @objc func stopLoading(_ sender: Any?) { browser?.activePane?.stopLoading() }
    @objc func showDownloadsLibrary(_ sender: Any?) { browser?.showLibrary(.downloads) }
    @objc func copyURLAsMarkdown(_ sender: Any?) { browser?.copyURLAsMarkdown() }
    @objc func javaScriptConsole(_ sender: Any?) { browser?.runChromeCommand(.devToolsConsole) }
    @objc func inspectElement(_ sender: Any?) { browser?.runChromeCommand(.devToolsInspect) }
    @objc func savePage(_ sender: Any?) { browser?.runChromeCommand(.savePage) }
    @objc func newIncognitoWindow(_ sender: Any?) { browser?.runChromeCommand(.newIncognitoWindow) }
    @objc func focusSplit(_ sender: NSMenuItem) { browser?.focusSplitPane(sender.tag) }
    @objc func nextSplit(_ sender: Any?) { browser?.focusAdjacentSplitPane(1) }
    @objc func previousSplit(_ sender: Any?) { browser?.focusAdjacentSplitPane(-1) }
    @objc func nextSpace(_ sender: Any?) { browser?.switchSpace(by: 1) }
    @objc func previousSpace(_ sender: Any?) { browser?.switchSpace(by: -1) }
    @objc func selectSpace(_ sender: NSMenuItem) {
        guard let browser, sender.tag < library.spaces.count else { return }
        browser.switchSpace(to: library.spaces[sender.tag])
    }
}

/// The menu bar, with Arc's keyboard shortcuts.
enum MainMenu {
    @MainActor
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                  tag: Int = 0, toDelegate: Bool = true, hidden: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            if toDelegate, action != nil { item.target = target }
            if hidden {
                // A second shortcut for the same command.
                item.isHidden = true
                item.allowsKeyEquivalentWhenHidden = true
            }
            return item
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            for entry in items { menu.addItem(entry) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }

        main.addItem(submenu("OpenArch", [
            item("Über OpenArch", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toDelegate: false),
            .separator(),
            item("Einstellungen …", #selector(AppDelegate.showSettings(_:)), ","),
            item("Als Standardbrowser festlegen", #selector(AppDelegate.setAsDefaultBrowser(_:))),
            .separator(),
            item("OpenArch ausblenden", #selector(NSApplication.hide(_:)), "h", toDelegate: false),
            item("Andere ausblenden", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toDelegate: false),
            item("Alle einblenden", #selector(NSApplication.unhideAllApplications(_:)), toDelegate: false),
            .separator(),
            item("OpenArch beenden", #selector(NSApplication.terminate(_:)), "q", toDelegate: false),
        ]))

        main.addItem(submenu("Ablage", [
            item("Neuer Tab", #selector(AppDelegate.newTab(_:)), "t"),
            item("Neues Inkognito-Fenster", #selector(AppDelegate.newIncognitoWindow(_:)), "n", [.command, .shift]),
            item("Adresse öffnen …", #selector(AppDelegate.openLocation(_:)), "l"),
            item("Neuer Ordner", #selector(AppDelegate.newFolder(_:))),
            .separator(),
            item("Tab schließen", #selector(AppDelegate.closeTab(_:)), "w"),
            item("Geschlossenen Tab wieder öffnen", #selector(AppDelegate.reopenTab(_:)), "t", [.command, .shift]),
            item("Heute aufräumen", #selector(AppDelegate.clearToday(_:)), "k", [.command, .shift]),
            .separator(),
            item("Seite sichern unter …", #selector(AppDelegate.savePage(_:)), "s", [.command, .shift]),
            item("Aus Arc importieren …", #selector(AppDelegate.importFromArc(_:))),
            .separator(),
            item("Drucken …", #selector(AppDelegate.printPage(_:)), "p"),
        ]))

        main.addItem(submenu("Bearbeiten", [
            item("Widerrufen", Selector(("undo:")), "z", toDelegate: false),
            item("Wiederholen", Selector(("redo:")), "z", [.command, .shift], toDelegate: false),
            .separator(),
            item("Ausschneiden", #selector(NSText.cut(_:)), "x", toDelegate: false),
            item("Kopieren", #selector(NSText.copy(_:)), "c", toDelegate: false),
            item("Einsetzen", #selector(NSText.paste(_:)), "v", toDelegate: false),
            item("Einsetzen und Stil anpassen", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift], toDelegate: false),
            item("Alles auswählen", #selector(NSText.selectAll(_:)), "a", toDelegate: false),
            .separator(),
            item("Suchen …", #selector(AppDelegate.find(_:)), "f"),
            item("Weitersuchen", #selector(AppDelegate.findNext(_:)), "g"),
            item("Rückwärts suchen", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift]),
            .separator(),
            item("URL kopieren", #selector(AppDelegate.copyURL(_:)), "c", [.command, .shift]),
            item("URL als Markdown kopieren", #selector(AppDelegate.copyURLAsMarkdown(_:)), "c", [.command, .shift, .option]),
        ]))

        main.addItem(submenu("Ansicht", [
            item("Sidebar ein-/ausblenden", #selector(AppDelegate.toggleSidebar(_:)), "s"),
            item("Bibliothek", #selector(AppDelegate.toggleLibrary(_:)), "l", [.command, .shift]),
            item("Bibliothek", #selector(AppDelegate.toggleLibrary(_:)), "b", [.command, .option], hidden: true),
            item("Chrome-Toolbar ein-/ausblenden", #selector(AppDelegate.toggleToolbar(_:)), "d", [.command, .shift]),
            .separator(),
            item("Neu laden", #selector(AppDelegate.reload(_:)), "r"),
            item("Neu laden ohne Cache", #selector(AppDelegate.reloadHard(_:)), "r", [.command, .shift]),
            item("Laden stoppen", #selector(AppDelegate.stopLoading(_:)), "."),
            .separator(),
            item("Vergrößern", #selector(AppDelegate.zoomIn(_:)), "+"),
            item("Vergrößern", #selector(AppDelegate.zoomIn(_:)), "=", hidden: true),
            item("Verkleinern", #selector(AppDelegate.zoomOut(_:)), "-"),
            item("Originalgröße", #selector(AppDelegate.zoomReset(_:)), "0"),
            .separator(),
            item("Entwicklertools", #selector(AppDelegate.devTools(_:)), "i", [.command, .option]),
            item("Element untersuchen", #selector(AppDelegate.inspectElement(_:)), "c", [.command, .option]),
            item("JavaScript-Konsole", #selector(AppDelegate.javaScriptConsole(_:)), "j", [.command, .option]),
            item("Quelltext anzeigen", #selector(AppDelegate.viewSource(_:)), "u", [.command, .option]),
            .separator(),
            item("Vollbild", #selector(AppDelegate.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("Verlauf", [
            item("Zurück", #selector(AppDelegate.goBack(_:)), "["),
            item("Vorwärts", #selector(AppDelegate.goForward(_:)), "]"),
            .separator(),
            item("Verlauf anzeigen", #selector(AppDelegate.showHistory(_:)), "y"),
            item("Downloads", #selector(AppDelegate.showDownloadsLibrary(_:)), "j", [.command, .shift]),
            item("Alle Downloads", #selector(AppDelegate.showDownloads(_:)), "l", [.command, .option]),
            item("Passwörter", #selector(AppDelegate.showPasswords(_:))),
        ]))

        var tabItems = [
            item("Nächster Tab", #selector(AppDelegate.nextTab(_:)), "\u{F701}", [.command, .option]),
            item("Vorheriger Tab", #selector(AppDelegate.previousTab(_:)), "\u{F700}", [.command, .option]),
            item("Nächster Tab", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift], hidden: true),
            item("Vorheriger Tab", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift], hidden: true),
            item("Zuletzt benutzter Tab", #selector(AppDelegate.recentTab(_:)), "\t", .control),
            item("Zuletzt benutzter Tab rückwärts", #selector(AppDelegate.recentTabBack(_:)), "\t", [.control, .shift]),
            .separator(),
            item("Anheften / Lösen", #selector(AppDelegate.togglePin(_:)), "d"),
            item("Zu Favoriten hinzufügen", #selector(AppDelegate.addFavorite(_:))),
            item("Tab duplizieren", #selector(AppDelegate.duplicateTab(_:))),
            .separator(),
        ]
        for index in 0..<9 {
            let entry = item(index == 8 ? "Letzter Tab" : "Tab \(index + 1)", #selector(AppDelegate.selectTab(_:)),
                             "\(index + 1)", tag: index == 8 ? -1 : index)
            entry.allowsKeyEquivalentWhenHidden = true
            tabItems.append(entry)
        }
        let tabsMenu = submenu("Tabs", tabItems)
        tabsMenu.submenu?.delegate = TabsMenuUpdater.shared
        main.addItem(tabsMenu)

        var splitItems = [
            item("Split View", #selector(AppDelegate.splitView(_:)), "=", [.control, .shift]),
            item("Split View aufheben", #selector(AppDelegate.unsplitView(_:)), "-", [.control, .shift]),
            .separator(),
            item("Nächste Seite der Split View", #selector(AppDelegate.nextSplit(_:)), "]", [.control, .shift]),
            item("Vorherige Seite der Split View", #selector(AppDelegate.previousSplit(_:)), "[", [.control, .shift]),
        ]
        for index in 0..<4 {
            let entry = item("Seite \(index + 1)", #selector(AppDelegate.focusSplit(_:)), "\(index + 1)", [.control, .shift], tag: index)
            entry.allowsKeyEquivalentWhenHidden = true
            splitItems.append(entry)
        }
        let splitMenu = submenu("Split View", splitItems)
        splitMenu.submenu?.delegate = SplitMenuUpdater.shared
        splitMenu.submenu?.autoenablesItems = false
        main.addItem(splitMenu)

        var spaceItems = [
            item("Nächster Space", #selector(AppDelegate.nextSpace(_:)), "\u{F703}", [.command, .option]),
            item("Vorheriger Space", #selector(AppDelegate.previousSpace(_:)), "\u{F702}", [.command, .option]),
            .separator(),
            item("Neuer Space", #selector(AppDelegate.newSpace(_:))),
            item("Space bearbeiten …", #selector(AppDelegate.editSpace(_:))),
            .separator(),
        ]
        for index in 0..<9 {
            // Shortcuts stay active while hidden; titles follow the spaces.
            let entry = item("Space \(index + 1)", #selector(AppDelegate.selectSpace(_:)), "\(index + 1)", .control, tag: index)
            entry.allowsKeyEquivalentWhenHidden = true
            spaceItems.append(entry)
        }
        let spacesMenu = submenu("Spaces", spaceItems)
        spacesMenu.submenu?.delegate = SpacesMenuUpdater.shared
        main.addItem(spacesMenu)

        main.addItem(submenu("Extensions", [
            item("Extensions verwalten", #selector(AppDelegate.manageExtensions(_:))),
            item("Chrome Web Store", #selector(AppDelegate.openWebStore(_:))),
            item("Extensions aus Arc …", #selector(AppDelegate.installArcExtensions(_:))),
            .separator(),
            item("Browser-Einstellungen", #selector(AppDelegate.chromeSettings(_:))),
        ]))

        let windowMenu = submenu("Fenster", [
            item("Minimieren", #selector(NSWindow.performMiniaturize(_:)), "m", toDelegate: false),
            item("Zoomen", #selector(NSWindow.performZoom(_:)), toDelegate: false),
            .separator(),
            item("Alle nach vorne bringen", #selector(NSApplication.arrangeInFront(_:)), toDelegate: false),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return main
    }
}

/// A favicon sized for a menu item.
@MainActor
private func menuIcon(for item: Item) -> NSImage? {
    guard let icon = item.favicon ?? FaviconStore.shared.image(forURL: item.currentURL)
        ?? FaviconStore.shared.image(forURL: item.savedURL) else {
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        icon.draw(in: rect)
        return true
    }
    return image
}

private func menuTitle(_ text: String) -> String {
    text.count > 60 ? String(text.prefix(57)) + "…" : text
}

/// ⌘1…⌘9 in the Tabs menu show the tabs they jump to.
@MainActor
final class TabsMenuUpdater: NSObject, NSMenuDelegate {
    static let shared = TabsMenuUpdater()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let browser = (NSApp.delegate as? AppDelegate)?.browser else { return }
        let tabs = browser.orderedTabs
        for item in menu.items where item.action == #selector(AppDelegate.selectTab(_:)) {
            let tab = item.tag < 0 ? (tabs.count > 8 ? tabs.last : nil) : (item.tag < tabs.count ? tabs[item.tag] : nil)
            guard let tab else {
                item.isHidden = true
                continue
            }
            item.isHidden = false
            item.title = menuTitle(tab.displayTitle)
            item.image = menuIcon(for: tab)
            item.state = tab === browser.state.activeItem ? .on : .off
        }
    }
}

/// The Split View menu names the sides that are open and greys out what
/// only works in a split view.
@MainActor
final class SplitMenuUpdater: NSObject, NSMenuDelegate {
    static let shared = SplitMenuUpdater()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let browser = (NSApp.delegate as? AppDelegate)?.browser else { return }
        let sides = browser.shownTabs.count > 1 ? browser.shownTabs : []
        for item in menu.items {
            switch item.action {
            case #selector(AppDelegate.focusSplit(_:)):
                guard item.tag < sides.count else {
                    item.isHidden = true
                    continue
                }
                let side = sides[item.tag]
                item.isHidden = false
                item.title = menuTitle(side.displayTitle)
                item.image = menuIcon(for: side)
                item.state = side === browser.state.activeItem ? .on : .off
            case #selector(AppDelegate.unsplitView(_:)), #selector(AppDelegate.nextSplit(_:)),
                 #selector(AppDelegate.previousSplit(_:)):
                item.isEnabled = !sides.isEmpty
            case #selector(AppDelegate.splitView(_:)):
                item.isEnabled = browser.state.activeItem != nil && sides.count < 4
            default:
                break
            }
        }
    }
}

/// Shows the real spaces (name, icon, current one checked) in the Spaces
/// menu, like Arc.
@MainActor
final class SpacesMenuUpdater: NSObject, NSMenuDelegate {
    static let shared = SpacesMenuUpdater()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let app = NSApp.delegate as? AppDelegate, let library = app.library else { return }
        let current = app.browser?.state.space
        for item in menu.items where item.action == #selector(AppDelegate.selectSpace(_:)) {
            guard item.tag < library.spaces.count else {
                item.isHidden = true
                continue
            }
            let space = library.spaces[item.tag]
            item.isHidden = false
            item.title = space.name
            item.state = space === current ? .on : .off
            item.image = NSImage(systemSymbolName: space.icon, accessibilityDescription: nil)
        }
    }
}

/// OpenArch's own shortcuts win over the page, like in Arc: a page cannot
/// take ⌘T, ⌘L or ⌃Tab, and Chrome's own meaning of a key (⌘⌥→ switches
/// tabs in Chrome, spaces in Arc) never applies.
@MainActor
enum ShortcutMonitor {
    private static var monitor: Any?

    static func install(target: AppDelegate) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { handle(event, target: target) }
            return handled ? nil : event
        }
    }

    /// Runs the OpenArch menu command for |event|, if there is one.
    static func handle(_ event: NSEvent, target: AppDelegate) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control]).isEmpty, NSApp.modalWindow == nil,
              let menu = NSApp.mainMenu, let item = item(in: menu, matching: event, target: target),
              let action = item.action else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    static func item(in menu: NSMenu, matching event: NSEvent, target: AppDelegate) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu, let found = self.item(in: submenu, matching: event, target: target) {
                return found
            }
            if item.target === target, !item.keyEquivalent.isEmpty, matches(item, event) {
                return item
            }
        }
        return nil
    }

    /// Compares the unmodified key (so ⌃⇧= is "=" and ⌘⇧[ is "[" on any
    /// keyboard layout) and the exact modifiers.
    static func matches(_ item: NSMenuItem, _ event: NSEvent) -> Bool {
        var key = item.keyEquivalent
        var modifiers = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
        if key != key.lowercased() {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == modifiers else { return false }
        let plain = (event.characters(byApplyingModifiers: []) ?? "").lowercased()
        let ignoring = (event.charactersIgnoringModifiers ?? "").lowercased()
        return key == plain || key == ignoring
    }
}
