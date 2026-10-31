import AppKit
import CommonCrypto
import SQLite3
import SwiftUI
import UniformTypeIdentifiers
import OpenArchCore
import OpenArchShared

/// `--selftest`: drives the real UI through its main paths with a throwaway
/// library and the probe extension, logs results with a "[selftest]" prefix
/// and quits. Marker lines ("STEP …") let a script take screenshots.
@MainActor
final class SelfTest {
    static private(set) weak var current: SelfTest?

    private let browser: BrowserWindowController
    private var library: Library { browser.library }
    private var failures: [String] = []

    init(browser: BrowserWindowController) {
        self.browser = browser
        SelfTest.current = self
    }

    /// Where the self-test's downloads go, not the user's Downloads folder.
    static let downloadFolder = AppPaths.support.appendingPathComponent("Downloads", isDirectory: true)

    func start() {
        try? FileManager.default.removeItem(at: Self.downloadFolder)
        try? FileManager.default.createDirectory(at: Self.downloadFolder, withIntermediateDirectories: true)
        OACProfile.setPreference("download.default_directory", value: Self.downloadFolder.path)
        OACProfile.setPreference("download.prompt_for_download", value: false)
        if CommandLine.arguments.contains("--popup-test") {
            popupTest()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--show"), index + 1 < CommandLine.arguments.count {
            // Just one tab with this page, for driving OpenArch from outside.
            library.replace(with: LibraryData(
                profiles: [ProfileData(id: "Default", name: "Test", favorites: [])],
                spaces: [SpaceData(id: UUID(), name: "Test", icon: "star.fill", colorHex: "#9C99BA", profileID: "Default",
                                   pinned: [], today: [tab(CommandLine.arguments[index + 1], "Test")])]))
            browser.libraryWasReplaced()
            if let item = library.spaces.first?.today.items.first {
                browser.select(item)
                // --open-devtools: the tab's DevTools, to look at from outside.
                if CommandLine.arguments.contains("--open-devtools") {
                    after(3) { item.pane?.showDevTools() }
                }
                // --cancel-downloads: the first download started from outside
                // is cancelled two seconds in.
                if CommandLine.arguments.contains("--cancel-downloads") {
                    self.cancelFirstDownload()
                }
            }
            return
        }
        if CommandLine.arguments.contains("--marketing") {
            marketingScreens()
            return
        }
        if CommandLine.arguments.contains("--loading-bar-shots") {
            loadingBarShots()
            return
        }
        if CommandLine.arguments.contains("--fullscreen-test") {
            fullscreenTest()
            return
        }
        // --about: the About window, to film from outside; --about-warp
        // goes to warp speed two seconds in.
        if CommandLine.arguments.contains("--about") {
            AboutWindowController.shared.show(selfTest: true)
            Swift.print("[selftest] about window \(AboutWindowController.shared.window?.windowNumber ?? 0)")
            if CommandLine.arguments.contains("--about-warp") {
                after(2.5) { AboutWindowController.shared.warp() }
            }
            return
        }
        if CommandLine.arguments.contains("--quit-test") {
            quitWithStuckBrowser()
            return
        }
        // --share-owner <relay> <folder>: a live share for another device to
        // follow, changed when <folder>/update appears, ended on <folder>/end.
        if let index = CommandLine.arguments.firstIndex(of: "--share-owner"), index + 2 < CommandLine.arguments.count {
            shareOwner(relay: CommandLine.arguments[index + 1], signals: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
            return
        }
        populate()
        let steps: [(Double, String, () -> Void)] = [
            (0.5, "today tab", { self.selectToday() }),
            (6, "command bar", { self.commandBar() }),
            (9, "split view", { self.split() }),
            (15, "second space", { self.secondSpace() }),
            (18, "shortcuts", { self.shortcuts() }),
            (20.5, "copy link", { self.copyLinkShortcut() }),
            (20.6, "quit shortcut", { self.quitShortcut() }),
            (20.7, "external link", { self.externalLink() }),
            (24.5, "drag out", { self.dragOutTest() }),
            (21, "close and reopen", { self.closeAndReopen() }),
            (23, "folders and pinning", { self.foldersAndPinning() }),
            (25, "arc import (dry run)", { self.arcImport() }),
            (26, "persistence", { self.persistence() }),
            (27, "layout after resize", { self.layoutAfterResize() }),
            (29, "split by drop", { self.splitByDrop() }),
            (31, "library", { self.libraryView() }),
            (33.5, "sidebar collapse", { self.sidebarCollapse() }),
            (34.5, "space editor", { self.spaceEditor() }),
            (35.5, "sidebar swipe", { self.sidebarSwipe() }),
            (36, "audio indicator", { self.audioIndicator() }),
            (36.2, "internal urls", { self.internalURLs() }),
            (36.3, "floating sidebar", { self.floatingSidebarTest() }),
            (36.35, "site search", { self.siteSearchTest() }),
            (36.38, "link rules", { self.linkRulesTest() }),
            (36.39, "drop links", { self.dropLinks() }),
            (36.39, "space order", { self.spaceOrder() }),
            (36.392, "live folders", { self.liveFolders() }),
            (36.393, "inline completion", { self.inlineCompletion() }),
            (36.394, "about", { self.aboutWindow() }),
            (36.396, "load in background", { self.loadInBackground() }),
            (36.395, "site controls", { self.siteControls() }),
            (36.45, "copy link key press", { self.copyLinkKeyPress() }),
            (36.47, "tab switcher", { self.tabSwitcherTest() }),
            (36.48, "tab switcher previews", { self.tabSwitcherPreviews() }),
            (36.4, "menus", { self.menus() }),
            (36.6, "arc crypto", { self.arcCrypto() }),
            (36.8, "little openarch", { self.littleOpenArch() }),
            (37, "updater", { self.updaterTest() }),
            (37.1, "loading bar", { self.loadingBar() }),
            (38, "downloads", { self.downloadTest() }),
            (43.6, "media", { self.mediaTest() }),
            (50.5, "boosts", { self.boostTest() }),
            (56, "peek", { self.peekTest() }),
            (64.5, "windows", { self.windowsTest() }),
            // Last and on its own: it renders windows, which the steps taking
            // pictures of tabs do not like.
            (73, "sharing", { self.sharingTest() }),
            (68.5, "agent chats", { self.agentChats { self.sleepingTabs { self.httpsOnly { self.devToolsDock { self.externalAppLinks() } } } } }),
        ]
        for (time, name, step) in steps {
            after(time) {
                Swift.print("[selftest] STEP \(name)")
                step()
            }
        }
        let stay = CommandLine.arguments.contains("--stay")
        if CommandLine.arguments.contains("--arc"), ArcImporter.isAvailable {
            // The user's real Arc sidebar, without loading any of its tabs.
            after(89.5) {
                guard let (data, _) = try? ArcImporter.load() else { return }
                self.browser.prepareForLibraryReplacement()
                self.library.replace(with: data)
                let icons = ArcFavicons.importIcons(for: ArcFavicons.urls(in: self.library))
                Swift.print("[selftest] Arc favicons for \(icons) sites")
                for space in self.library.spaces { space.activeItemID = nil }
                self.browser.libraryWasReplaced()
                Swift.print("[selftest] STEP arc sidebar")
            }
        }
        after(CommandLine.arguments.contains("--arc") ? 94 : 89) {
            Swift.print("[selftest] DONE failures=\(self.failures.count) \(self.failures)")
            if !stay { Self.quit() }
        }
    }

    // MARK: Screenshots for the website

    /// Demo content (no personal data) in the states the website shows.
    /// Prints "STEP shot <name>" when a state is ready to be captured.
    private func marketingScreens() {
        func tab(_ url: String, _ title: String) -> ItemData { ItemData(id: UUID(), kind: .tab, title: title, url: url) }
        func folder(_ name: String, _ children: [ItemData], icon: String? = nil) -> ItemData {
            ItemData(id: UUID(), kind: .folder, customTitle: name, children: children, isExpanded: true, icon: icon)
        }
        // Sharp captures: put the window on a Retina display if there is one.
        if let retina = NSScreen.screens.first(where: { $0.backingScaleFactor > 1 }), let window = browser.window {
            let frame = retina.visibleFrame
            window.setFrame(NSRect(x: frame.midX - 720, y: frame.midY - 450, width: 1440, height: 900), display: true)
        }
        library.settings.showChromeToolbar = false
        library.replace(with: LibraryData(
            profiles: [ProfileData(id: "Default", name: "Persönlich", favorites: [
                tab("https://github.com/", "GitHub"),
                tab("https://www.youtube.com/", "YouTube"),
                tab("https://en.wikipedia.org/wiki/Main_Page", "Wikipedia"),
                tab("https://www.figma.com/", "Figma"),
                tab("https://open.spotify.com/", "Spotify"),
                tab("https://linear.app/", "Linear"),
            ])],
            spaces: [
                SpaceData(id: UUID(), name: "Work", icon: "briefcase.fill", colorHex: "#55B860", profileID: "Default",
                          pinned: [
                              folder("OpenArch", [
                                  tab("https://github.com/dpfaffenbauer/OpenArch", "dpfaffenbauer/OpenArch"),
                                  tab("https://github.com/dpfaffenbauer/OpenArch/actions", "Actions"),
                              ], icon: "bolt.fill"),
                              folder("Reading", [
                                  tab("https://en.wikipedia.org/wiki/Gothic_architecture", "Gothic architecture"),
                                  tab("https://en.wikipedia.org/wiki/Roman_bridge", "Roman bridge"),
                              ]),
                              tab("https://news.ycombinator.com/", "Hacker News"),
                          ],
                          today: [
                              tab("https://en.wikipedia.org/wiki/Arch", "Arch - Wikipedia"),
                              tab("https://en.wikipedia.org/wiki/Keystone_(architecture)", "Keystone (architecture)"),
                              tab("https://developer.mozilla.org/en-US/docs/Web/CSS/border-radius", "border-radius - CSS"),
                          ]),
                SpaceData(id: UUID(), name: "Home", icon: "house.fill", colorHex: "#E5A33B", profileID: "Default",
                          pinned: [
                              folder("Recipes", [
                                  tab("https://en.wikipedia.org/wiki/Focaccia", "Focaccia"),
                                  tab("https://en.wikipedia.org/wiki/Ramen", "Ramen"),
                              ]),
                              tab("https://www.youtube.com/", "YouTube"),
                          ],
                          today: [
                              tab("https://en.wikipedia.org/wiki/Sourdough", "Sourdough - Wikipedia"),
                              tab("https://en.wikipedia.org/wiki/Bread", "Bread - Wikipedia"),
                          ]),
                SpaceData(id: UUID(), name: "Travel", icon: "airplane", colorHex: "#3FA9F5", profileID: "Default",
                          pinned: [
                              folder("Utah", [
                                  tab("https://en.wikipedia.org/wiki/Delicate_Arch", "Delicate Arch"),
                                  tab("https://en.wikipedia.org/wiki/Canyonlands_National_Park", "Canyonlands"),
                              ]),
                          ],
                          today: [
                              tab("https://en.wikipedia.org/wiki/Arches_National_Park", "Arches National Park"),
                              tab("https://en.wikipedia.org/wiki/Moab,_Utah", "Moab, Utah"),
                          ]),
            ]))
        browser.libraryWasReplaced()
        let work = library.spaces[0], home = library.spaces[1], travel = library.spaces[2]
        browser.select(work.today.items[0])
        after(7) { Swift.print("[selftest] STEP shot hero") }
        after(9) {
            self.browser.switchSpace(to: home)
            self.browser.split(home.today.items[1], with: home.today.items[0])
            after(6) { Swift.print("[selftest] STEP shot split") }
        }
        after(17) {
            self.browser.switchSpace(to: travel)
            self.browser.select(travel.today.items[0])
            after(5) {
                self.browser.commandBar.show(mode: .newTab)
                self.browser.commandBar.model.query = "arches"
                after(3) { Swift.print("[selftest] STEP shot commandbar") }
            }
        }
        after(28) {
            self.browser.commandBar.hide()
            self.browser.switchSpace(to: work)
            self.browser.state.librarySection = .spaces
            self.browser.toggleLibrary()
            after(3) { Swift.print("[selftest] STEP shot library") }
        }
        after(33) {
            Swift.print("[selftest] DONE marketing")
            Self.quit()
        }
    }

    // MARK: Extension popup timing

    /// Opens a pinned extension's popup by clicking its toolbar button (with
    /// synthesized clicks, the real pointer stays put) and measures how long
    /// the popup window takes to appear. Three rounds: first open, open
    /// again, and open after the extension's service worker went to sleep.
    private func popupTest() {
        let url = CommandLine.arguments.firstIndex(of: "--popup-url").map { CommandLine.arguments[$0 + 1] } ?? "https://wordpress.org/"
        library.replace(with: LibraryData(
            profiles: [ProfileData(id: "Default", name: "Test", favorites: [])],
            spaces: [SpaceData(id: UUID(), name: "Test", icon: "star.fill", colorHex: "#9A95B5", profileID: "Default",
                               pinned: [], today: [tab(url, "Test")])]))
        browser.libraryWasReplaced()
        if let item = library.spaces.first?.today.items.first {
            browser.select(item)
        }
        Swift.print("[selftest] STEP popup page")
        // Toolbar, right to left: menu, puzzle piece, then the pinned
        // extensions in reverse order of --pin-extension. One round at a
        // time: click, wait for the popup, close it, pause, next.
        popupRounds = [
            ("wappalyzer 1 (cold)", 148), ("wappalyzer 2", 148), ("wappalyzer 3", 148),
            ("probe 1 (cold)", 114), ("probe 2", 114), ("probe 3", 114),
        ]
        if CommandLine.arguments.contains("--standalone") {
            // Compare: Wappalyzer's welcome page stays in a normal Chrome
            // window (not adopted into the sidebar); click its toolbar there.
            OACPane.externalTabHandler = nil
            after(9) { self.clickStandaloneChromeWindow(round: 1) }
            return
        }
        if CommandLine.arguments.contains("--foreground") {
            // Like a real user: OpenArch in front, its window key.
            after(6) {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                self.browser.window?.orderFrontRegardless()
                self.browser.state.activeItem?.pane?.window?.orderFrontRegardless()
            }
        }
        after(8) { self.nextPopupRound() }
    }

    private var popupRounds: [(String, CGFloat)] = []

    private func clickStandaloneChromeWindow(round: Int) {
        let panes = Set(library.allContainers.flatMap(\.allTabs).compactMap { $0.pane?.window }.map(ObjectIdentifier.init))
        guard round <= 3, let window = NSApp.windows
            .filter({ $0.isVisible && $0 !== browser.window && !panes.contains(ObjectIdentifier($0)) && $0.frame.width > 600 })
            .max(by: { $0.frame.width < $1.frame.width }) else {
            Swift.print("[selftest] DONE popup test")
            Self.quit()
            return
        }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        // Chrome's own window: tab strip above the toolbar, profile button
        // right of the puzzle piece.
        let point = NSPoint(x: window.frame.width - 145, y: window.frame.height - 63)
        let start = Date()
        click(window, at: point)
        func poll() {
            let popup = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0.frame.width > 150 && $0.frame.height > 80
            }
            let elapsed = Date().timeIntervalSince(start)
            if let popup {
                Swift.print("[selftest] POPUP standalone chrome window \(round): \(Int(elapsed * 1000)) ms, \(Int(popup.frame.width))x\(Int(popup.frame.height))")
                after(1) {
                    self.click(window, at: point)
                    after(2) { self.clickStandaloneChromeWindow(round: round + 1) }
                }
            } else if elapsed > 8 {
                Swift.print("[selftest] POPUP standalone chrome window \(round): no popup after 8 s")
                self.clickStandaloneChromeWindow(round: round + 1)
            } else {
                after(0.005) { poll() }
            }
        }
        poll()
    }

    private func nextPopupRound() {
        guard !popupRounds.isEmpty else {
            Swift.print("[selftest] DONE popup test")
            Self.quit()
            return
        }
        let (label, offset) = popupRounds.removeFirst()
        clickToolbarButton(label, offset: offset)
    }

    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    private func clickToolbarButton(_ label: String, offset: CGFloat) {
        guard let tab = browser.state.space.today.allTabs.first(where: { $0.currentURL.contains("wordpress") }),
              let pane = tab.pane, let window = pane.window else { return }
        if browser.state.activeItem !== tab {
            browser.select(tab)
        }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let point = NSPoint(x: window.frame.width - offset, y: window.frame.height - 23)
        let start = Date()
        Swift.print("[selftest] CLICK \(label) at \(Date().timeIntervalSince1970)")
        click(window, at: point)
        func poll() {
            // Tooltips are small; the popup is a real window.
            let popup = NSApp.windows.first {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0.frame.width > 150 && $0.frame.height > 80
            }
            let elapsed = Date().timeIntervalSince(start)
            if let popup {
                Swift.print("[selftest] POPUP \(label): \(Int(elapsed * 1000)) ms, \(Int(popup.frame.width))x\(Int(popup.frame.height)) at \(Date().timeIntervalSince1970)")
                // Clicking the button again closes the popup, as Chrome expects.
                after(1.0) {
                    self.click(window, at: point)
                    after(1.5) {
                        if popup.isVisible { Swift.print("[selftest] POPUP \(label): still open, closing") ; popup.close() }
                        after(1.0) { self.nextPopupRound() }
                    }
                }
            } else if elapsed > 8 {
                Swift.print("[selftest] POPUP \(label): no popup after 8 s")
                self.nextPopupRound()
            } else {
                after(0.005) { poll() }
            }
        }
        poll()
    }

    /// Quits, and makes sure the process ends even if Chromium's shutdown
    /// stalls (a test run must never hang a CI job).
    static func quit() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { exit(0) }
        NSApp.terminate(nil)
    }

    /// Checks |condition| until it holds or |timeout| passes, for results
    /// that wait on the main thread while other steps keep it busy.
    private func eventually(_ condition: @escaping () -> Bool, timeout: Double = 3, then report: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() { return report(true) }
            if Date() > deadline { return report(false) }
            after(0.1) { check() }
        }
        check()
    }

    private func expect(_ condition: Bool, _ message: String) {
        Swift.print("[selftest] \(condition ? "ok  " : "FAIL") \(message)")
        if !condition { failures.append(message) }
    }

    // MARK: Steps

    private func populate() {
        let data = LibraryData(
            profiles: [
                ProfileData(id: "Default", name: "Arbeit", favorites: [
                    tab("https://example.com/", "Example"),
                    tab("https://www.iana.org/", "IANA"),
                    tab("https://example.net/fav", "Example Net"),
                ]),
                ProfileData(id: "Profile 2", name: "Privat", favorites: []),
            ],
            spaces: [
                SpaceData(id: UUID(), name: "Arbeit", icon: "briefcase.fill", colorHex: "#9A95B5", profileID: "Default",
                          pinned: [
                              folder("Kunden", [
                                  folder("Projekt A", [tab("https://example.net/a", "Projekt A Board")]),
                                  tab("https://example.org/kunde", "Kundenportal"),
                              ]),
                              tab("https://example.com/pinned", "Gepinnt"),
                          ],
                          today: [tab("https://example.org/", "Example Org")]),
                SpaceData(id: UUID(), name: "Privat", icon: "house.fill", colorHex: "#E5A33B", profileID: "Profile 2",
                          pinned: [], today: [tab("https://example.com/privat", "Privat")]),
            ])
        library.replace(with: data)
        browser.libraryWasReplaced()
    }

    private func tab(_ url: String, _ title: String) -> ItemData {
        ItemData(id: UUID(), kind: .tab, title: title, url: url)
    }

    private func folder(_ name: String, _ children: [ItemData]) -> ItemData {
        ItemData(id: UUID(), kind: .folder, customTitle: name, children: children, isExpanded: true)
    }

    private func selectToday() {
        guard let item = browser.state.space.today.items.first else { return expect(false, "today tab exists") }
        browser.select(item)
        expect(browser.state.activeItem === item && item.pane != nil, "selecting a today tab creates its pane")
    }

    private func commandBar() {
        browser.commandBar.show(mode: .newTab)
        browser.commandBar.model.query = "exam"
        let titles = browser.commandBar.model.results.prefix(5).map(\.title)
        expect(browser.commandBar.model.results.count >= 3, "command bar finds tabs for 'exam': \(titles)")
        expect(browser.commandBar.model.results.contains { $0.badge == "Zu Tab wechseln" }, "command bar offers 'Zu Tab wechseln'")
        after(2) {
            let searches = self.browser.commandBar.model.results.filter { $0.subtitle?.hasSuffix("-Suche") == true }
            self.expect(searches.count > 1, "search suggestions arrive (\(searches.count - 1))")
            self.expect(FaviconStore.shared.image(forURL: "https://www.iana.org/") != nil, "favicons load for pages that are not open")
            self.browser.commandBar.hide()
        }
    }

    private func split() {
        guard let base = browser.state.activeItem else { return expect(false, "active tab before split") }
        let other = browser.openInNewTab("https://example.net/split", after: base, select: false)
        browser.split(other, with: base)
        expect(base.split != nil && base.split === other.split, "split view groups both tabs")
        expect(base.pane?.isVisible == true && other.pane?.isVisible == true, "both split panes are visible")
        after(4) {
            for item in [base, other] {
                item.pane?.executeJavaScript("""
                    console.log('[selftest-probe] ' + (document.documentElement.dataset.openarchProbeChecks ?? 'none'));
                    """)
            }
        }
    }

    private func secondSpace() {
        guard let space = library.spaces.last else { return }
        browser.switchSpace(to: space)
        expect(browser.state.space === space, "switched to space \(space.name)")
        if let item = space.today.items.first {
            browser.select(item)
            expect(library.profile(for: item, in: space).id == "Profile 2", "space 2 tab uses its own profile")
        }
    }

    /// Arc's shortcuts, through the same handler that sees real key presses.
    private func shortcuts() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        func press(_ key: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: browser.window?.windowNumber ?? 0, context: nil,
                                               characters: key, charactersIgnoringModifiers: key,
                                               isARepeat: false, keyCode: code)
            else { return false }
            return ShortcutMonitor.handle(event, target: app)
        }
        let spaces = library.spaces
        let startSpace = browser.state.space

        _ = press("t", 17, .command)
        expect(browser.commandBar.isVisible, "⌘T opens the command bar")
        browser.commandBar.hide()

        _ = press("s", 1, .command)
        expect(!browser.state.sidebarVisible, "⌘S hides the sidebar")
        _ = press("s", 1, .command)
        expect(browser.state.sidebarVisible, "⌘S shows it again")

        _ = press("l", 37, [.command, .shift])
        expect(browser.state.libraryVisible, "⌘⇧L opens the library")
        _ = press("j", 38, [.command, .shift])
        expect(browser.state.librarySection == .downloads, "⌘⇧J shows downloads in the library")
        _ = press("l", 37, [.command, .shift])
        expect(!browser.state.libraryVisible, "⌘⇧L closes it")

        if let index = spaces.firstIndex(where: { $0 === startSpace }) {
            _ = press("\u{F703}", 124, [.command, .option, .numericPad, .function])
            expect(browser.state.space === spaces[(index + 1) % spaces.count], "⌘⌥→ switches to the next space")
            _ = press("\u{F702}", 123, [.command, .option, .numericPad, .function])
            expect(browser.state.space === startSpace, "⌘⌥← switches back")
        }

        let first = browser.state.activeItem
        let second = browser.openInNewTab("https://example.com/second")
        _ = press("\t", 48, .control)
        expect(first != nil && browser.state.activeItem === first && second !== first, "⌃Tab switches to the last used tab")

        _ = press("1", 18, .command)
        expect(browser.state.activeItem === browser.orderedTabs.first, "⌘1 selects the first tab in the sidebar")

        expect(!press("b", 11, .command), "keys OpenArch does not use (⌘B) stay with the page")

        // Whatever tab is shown now.
        guard let shown = browser.state.activeItem?.pane else {
            return expect(false, "a tab is shown before closing the window")
        }
        browser.window?.performClose(nil)
        expect(browser.window?.isVisible == false && shown.window?.isVisible == false,
               "closing the window hides it with its panes")
        browser.showWindow(nil)
        expect(browser.window?.isVisible == true && shown.window?.isVisible == true,
               "the window comes back with its panes")
    }

    /// A link from another app (as macOS hands it over when OpenArch is the
    /// default browser) opens in Little OpenArch.
    private func externalLink() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let before = LittleOpenArchWindowController.openCount
        let url = "https://example.com/from-another-app"
        app.application(NSApp, open: [URL(string: url)!])
        expect(LittleOpenArchWindowController.openCount == before && browser.state.activeItem?.currentURL == url,
               "a link from another app opens as a new tab in the window")
        if browser.state.activeItem?.currentURL == url { browser.closeActiveTab() }
        library.settings.linksInLittleOpenArch = true
        app.application(NSApp, open: [URL(string: url)!])
        expect(LittleOpenArchWindowController.openCount == before + 1,
               "with the setting on, it opens in Little OpenArch")
        library.settings.linksInLittleOpenArch = false
        LittleOpenArchWindowController.closeAll()
    }

    /// A today tab dragged out of the sidebar onto the desktop becomes a
    /// Little OpenArch window there, keeping its page; a pinned tab stays and
    /// opens a copy.
    private func dragOutTest() {
        let tab = browser.openInNewTab("https://example.com/drag-out")
        after(2.5) {
            guard let pane = tab.pane, let screen = self.browser.window?.screen?.visibleFrame else {
                return self.expect(false, "a tab to drag out")
            }
            let point = NSPoint(x: screen.midX, y: screen.midY)
            self.browser.openInSeparateWindow(tab, at: point)
            let little = LittleOpenArchWindowController.all.last
            self.expect(little?.shownPane === pane && pane.window?.parent === little?.window
                        && !self.browser.state.space.today.allTabs.contains { $0 === tab }
                        && little?.window?.frame.contains(NSPoint(x: point.x, y: point.y - 10)) == true,
                        "a tab dragged out of the sidebar opens with its page in its own window where it was dropped")
            let pinnedCount = self.browser.state.space.pinned.allTabs.count
            if let pinned = self.browser.state.space.pinned.allTabs.first {
                self.browser.openInSeparateWindow(pinned, at: point)
                self.expect(self.browser.state.space.pinned.allTabs.count == pinnedCount
                            && LittleOpenArchWindowController.all.last?.shownPane !== pinned.pane,
                            "a pinned tab dragged out stays pinned and opens a copy")
            }
            LittleOpenArchWindowController.closeAll()
        }
    }

    /// ⌘⇧C reaches OpenArch (not the page or Chrome's inspector) and copies
    /// the address, into the self-test's own pasteboard.
    private func copyLinkShortcut() {
        guard let app = NSApp.delegate as? AppDelegate, let url = browser.state.activeItem?.currentURL,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                           windowNumber: browser.window?.windowNumber ?? 0, context: nil, characters: "C",
                                           charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else {
            return expect(false, "⌘⇧C test setup")
        }
        copyPasteboard.clearContents()
        let handled = ShortcutMonitor.handle(event, target: app)
        expect(handled && copyPasteboard.string(forType: .string) == url, "⌘⇧C copies the address (\(url))")
        // "Link kopiert" has to be in front of the page, not behind it.
        let toast = browser.toast, page = browser.activePane?.window
        expect(toast?.isVisible == true && page != nil && toast!.orderedIndex < page!.orderedIndex,
               "⌘⇧C shows „Link kopiert“ above the page")
        // A 0×0 window is "visible" too: the pill has to have its size.
        let pill = toast?.frame.size ?? .zero
        expect(pill.width > 80 && pill.height > 30, "„Link kopiert“ has its size (\(Int(pill.width))×\(Int(pill.height)))")
        // Chrome's own Copy URL command (its ⌘⇧C) goes the same way.
        copyPasteboard.clearContents()
        toast?.orderOut(nil)
        if let pane = browser.activePane {
            _ = browser.pane(pane, handleChromeCommand: OACChromeCommand.copyURL.rawValue)
        }
        expect(copyPasteboard.string(forType: .string) == url && browser.toast?.isVisible == true,
               "Chrome's Copy URL copies through OpenArch, with „Link kopiert“")

    }

    /// ⌘Q quits through OpenArch's own shortcuts, so a page or Chrome cannot
    /// keep it; Chrome's own quit command from a Little OpenArch tab too.
    private func quitShortcut() {
        guard let app = NSApp.delegate as? AppDelegate,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                           windowNumber: browser.window?.windowNumber ?? 0, context: nil, characters: "q",
                                           charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12) else {
            return expect(false, "⌘Q test setup")
        }
        var quits = 0
        app.quitProbe = { quits += 1 }
        let handled = ShortcutMonitor.handle(event, target: app)
        expect(handled && quits == 1, "⌘Q quits OpenArch")
        if let little = LittleOpenArchWindowController.show(url: "https://example.com/little-quit", app: app) {
            _ = little.pane(little.shownPane, handleChromeCommand: OACChromeCommand.exit.rawValue)
            expect(quits == 2, "Chrome's quit command from Little OpenArch quits too")
        }
        app.quitProbe = nil
        LittleOpenArchWindowController.closeAll()
    }

    private func closeAndReopen() {
        guard let first = library.spaces.first else { return }
        browser.switchSpace(to: first)
        // Two tabs of its own; the second one (not on top) gets closed, and
        // ⌘⇧T has to find its place again.
        let tab = browser.openInNewTab("https://example.com/reopen-b", select: false)
        browser.openInNewTab("https://example.com/reopen-a", select: false)
        let before = first.today.allTabs.count
        let index = tab.indexInParent
        browser.select(tab)
        browser.closeActiveTab()
        expect(first.today.allTabs.count == before - 1, "closing a today tab removes it")
        browser.reopenClosedTab()
        expect(first.today.allTabs.count == before && browser.state.activeItem?.indexInParent == index
               && browser.state.activeItem?.currentURL == tab.currentURL,
               "⌘⇧T reopens it at its old place (\(index))")

        // Closing goes back to the tab used before, not to the one below:
        // used in the order older, middle, newest, older again, newest.
        let older = browser.openInNewTab("https://example.com/close-older")
        let middle = browser.openInNewTab("https://example.com/close-middle")
        let newest = browser.openInNewTab("https://example.com/close-newest")
        browser.select(older)
        browser.select(newest)
        browser.closeActiveTab()
        // (The tab below the closed one would be "middle".)
        expect(browser.state.activeItem === older,
               "closing a tab goes back to the one used before (\(browser.state.activeItem?.currentURL ?? "-"))")
        browser.close(middle)
        browser.close(older)
    }

    private func foldersAndPinning() {
        let space = browser.state.space
        let folder = browser.newFolder(name: "Testordner")
        browser.state.renamingItemID = nil
        guard let tab = space.today.allTabs.first(where: { $0.split == nil }) else { return }
        browser.pin(tab, into: folder)
        expect(tab.role == .pinned && tab.parentFolder === folder, "pinning into a folder")
        browser.unpin(tab)
        expect(tab.role == .today, "unpinning moves the tab back under the line")
        if let nested = space.pinned.allItems.first(where: { $0.displayTitle == "Projekt A" }) {
            expect(nested.parentFolder?.displayTitle == "Kunden", "nested folders survive")
        }
    }

    private func arcImport() {
        guard ArcImporter.isAvailable else {
            Swift.print("[selftest] skip arc import (no Arc data)")
            return
        }
        do {
            let (_, summary) = try ArcImporter.load()
            expect(summary.spaces > 0, "Arc import parses \(summary.spaces) space(s), \(summary.favorites) favorites, \(summary.pinned) pinned in \(summary.folders) folders, \(summary.today) today")
        } catch {
            expect(false, "Arc import: \(error)")
        }
        let extensions = ArcExtensions.installed()
        Swift.print("[selftest] Arc extensions: \(extensions.map(\.name))")
    }

    private func persistence() {
        library.save()
        let url = AppPaths.support.appendingPathComponent("Library.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let saved = try? decoder.decode(LibraryData.self, from: data) else {
            return expect(false, "library saved and readable")
        }
        expect(saved.spaces.count == library.spaces.count, "library saved with \(saved.spaces.count) spaces")
    }

    /// Panes must sit exactly over the content area after the window changes.
    private func checkPaneFrames(_ label: String) {
        let frames = browser.expectedPaneFrames
        let wrong = frames.filter { item, expected in
            guard let actual = item.pane?.window?.frame else { return true }
            return abs(actual.minX - expected.minX) > 1 || abs(actual.minY - expected.minY) > 1
                || abs(actual.width - expected.width) > 1 || abs(actual.height - expected.height) > 1
        }
        expect(!frames.isEmpty && wrong.isEmpty, "panes match the content area \(label) (\(frames.count) pane(s), \(wrong.count) off)")
    }

    private func layoutAfterResize() {
        guard let window = browser.window else { return }
        let original = window.frame
        checkPaneFrames("before resizing")
        var smaller = original
        smaller.origin.x += 150
        smaller.size.width -= 150
        window.setFrame(smaller, display: true)
        after(0.6) {
            self.checkPaneFrames("after resizing from the left")
            window.setFrame(original, display: true, animate: true)
            after(0.8) { self.checkPaneFrames("after an animated resize") }
        }
    }

    private func splitByDrop() {
        guard let space = library.spaces.first else { return }
        browser.switchSpace(to: space)
        let base = browser.openInNewTab("https://example.org/base")
        let other = browser.openInNewTab("https://example.com/drop", select: false)
        browser.dropForSplit(other, leading: true)
        expect(other.split != nil && other.split?.children.first === other && other.split?.children.last === base,
               "dropping a tab on the left half splits it in on the left")
        if let split = other.split {
            browser.swapSplit(split)
            expect(split.children.first === base && split.children.last === other
                   && browser.visibleTabs.first === base && split.data.children?.first?.id == base.id,
                   "swapping the sides puts the right tab on the left")
            browser.swapSplit(split)
        }

        // The top and bottom halves stack the tabs: the dropped one on top,
        // both as wide as the page; the menu puts them side by side again.
        let page = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let zones = [NSPoint(x: 600, y: 780), NSPoint(x: 600, y: 20), NSPoint(x: 20, y: 400), NSPoint(x: 1180, y: 400)]
            .map { SplitDropView.zone(at: $0, in: page) }
        expect(zones == [.top, .bottom, .leading, .trailing], "the drop zones are the page's four halves (\(zones))")
        let lower = browser.openInNewTab("https://example.org/lower")
        let upper = browser.openInNewTab("https://example.com/upper", select: false)
        browser.dropForSplit(upper, leading: true, stacked: true)
        let content = browser.contentRect
        var frames = browser.paneFrames(in: content)
        expect(upper.split?.splitStacked == true && upper.split?.children.first === upper && upper.split?.children.last === lower
               && frames.count == 2 && frames[0].minY > frames[1].maxY && frames.allSatisfy { $0.width == content.width }
               && upper.split?.data.splitStacked == true,
               "dropping a tab on the top half stacks it above (\(frames))")
        if let split = upper.split {
            browser.setSplitStacked(split, false)
            frames = browser.paneFrames(in: content)
            expect(frames.count == 2 && frames[0].maxX < frames[1].minX && frames.allSatisfy { $0.height == content.height },
                   "a stacked split goes side by side again")
        }

        // In the sidebar, a tab or a link dropped on the middle of a tab
        // makes a split view with it; a row's edges still reorder.
        expect(DropZone.at(y: 18, folder: false, tab: true) == .split && DropZone.at(y: 4, folder: false, tab: true) == .before
               && DropZone.at(y: 32, folder: false, tab: true) == .after && DropZone.at(y: 16, folder: true, tab: false) == .into,
               "the middle of a tab row splits, its edges reorder")
        let left = browser.openInNewTab("https://example.org/sidebar-left", select: false)
        let right = browser.openInNewTab("https://example.com/sidebar-right", select: false)
        browser.handleDrop([tabDragProvider(right)], target: .split(left))
        browser.handleDrop([NSItemProvider(object: NSURL(string: "https://example.net/sidebar-link")!)], target: .split(left))
        after(0.5) {
            let split = left.split
            self.expect(split != nil && right.split === split
                        && split?.children.contains { $0.currentURL == "https://example.net/sidebar-link" } == true,
                        "a tab and a link dropped onto a tab in the sidebar join it in a split view")
        }
    }

    private func libraryView() {
        browser.state.librarySection = .archive
        browser.toggleLibrary()
        expect(browser.state.libraryVisible && browser.sidebarWidth >= 400, "library opens in the sidebar")
        after(2) {
            self.browser.toggleLibrary()
            self.expect(!self.browser.state.libraryVisible, "library closes again")
        }
    }

    private func sidebarCollapse() {
        browser.resizeSidebar(to: 100)
        expect(!browser.state.sidebarVisible, "dragging the sidebar edge far left collapses it")
        browser.resizeSidebar(to: 280)
        expect(browser.state.sidebarVisible, "dragging back out opens it again")
    }

    /// Swipes with the fingers to the right (positive) or left.
    private func swipe(_ distance: CGFloat) {
        guard let swipe = browser.sidebarSwipe else { return }
        swipe.update(began: true, changed: false, ended: false, fingerDelta: 0, verticalDelta: 0, inSidebar: true)
        for _ in 0..<8 {
            swipe.update(began: false, changed: true, ended: false, fingerDelta: distance / 8, verticalDelta: 0, inSidebar: true)
        }
        swipe.update(began: false, changed: false, ended: true, fingerDelta: 0, verticalDelta: 0, inSidebar: true)
    }

    private func sidebarSwipe() {
        let spaces = library.spaces
        guard spaces.count >= 2 else { return }
        browser.switchSpace(to: spaces[0])
        swipe(-120)
        expect(browser.state.space === spaces[1], "swiping left moves to the next space")
        swipe(120)
        expect(browser.state.space === spaces[0], "swiping right moves back")
        swipe(120)
        expect(browser.state.libraryVisible, "swiping right past the first space opens the library")
        swipe(-120)
        expect(!browser.state.libraryVisible && browser.state.space === spaces[0], "swiping left closes the library")
        swipe(20)
        expect(browser.state.space === spaces[0] && !browser.state.libraryVisible, "a short swipe changes nothing")
    }

    /// Agent chats, with a stand-in for claude that answers in Claude Code's
    /// stream-json: the chat shows the streamed text, the tool and what was
    /// refused, remembers the session and continues it with the next message.
    private func agentChats(then next: @escaping () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-agent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let events = [
            #"{"type":"system","subtype":"init","session_id":"selftest-session","model":"claude-test","mcp_servers":[{"name":"openarch","status":"connected"},{"name":"jira","status":"failed"}]}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ich schaue "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"nach."}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Ich schaue nach."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Not allowed","is_error":true}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Ich darf **ls** nicht ausführen."}],"usage":{"input_tokens":1000,"cache_read_input_tokens":40000,"output_tokens":500}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"selftest-session","modelUsage":{"claude-test":{"contextWindow":200000}},"permission_denials":[{"tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"command":"ls -la"}}]}"#,
        ]
        let claude = folder.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            cat > "$(dirname "$0")/prompt.txt"
            printf '%s\\n' "$@" > "$(dirname "$0")/arguments.txt"
            cat <<'EOF'
            \(events.joined(separator: "\n"))
            EOF
            """
        try? script.write(to: claude, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        AgentEnvironment.stub = AgentEnvironment.Resolved(claude: claude.path, variables: ProcessInfo.processInfo.environment)
        library.settings.agentChats = true
        library.settings.agentFolder = folder.path
        let shown = browser.state.activeItem
        func done() {
            browser.state.agentsVisible = false
            AgentEnvironment.stub = nil
            library.settings.agentChats = false
            library.settings.agentFolder = ""
            try? FileManager.default.removeItem(at: folder)
            if let shown, shown.container != nil { browser.select(shown, focus: false) }
            next()
        }
        // The overview reads Claude Code's own transcripts.
        let project = folder.appendingPathComponent("projects/-tmp-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = [
            #"{"type":"user","cwd":"/tmp/demo","message":{"role":"user","content":"Baue die Startseite"}}"#,
            #"{"type":"assistant","cwd":"/tmp/demo","message":{"content":[{"type":"tool_use","id":"t1","name":"TodoWrite","input":{"todos":[{"content":"Layout","status":"completed"},{"content":"Texte","status":"pending"}]}}]}}"#,
            #"{"type":"user","cwd":"/tmp/demo","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","cwd":"/tmp/demo","isSidechain":true,"message":{"content":[{"type":"text","text":"Unteragent"}]}}"#,
            #"{"type":"assistant","cwd":"/tmp/demo","message":{"content":[{"type":"text","text":"Das Layout steht."}]}}"#,
        ]
        try? transcript.joined(separator: "\n").write(to: project.appendingPathComponent("demo.jsonl"), atomically: true, encoding: .utf8)
        let projects = folder.appendingPathComponent("projects")
        let idle = ClaudeSessions.scan(root: projects, now: Date(), running: [])
        expect(idle.count == 1 && idle.first?.title == "Baue die Startseite" && idle.first?.folder == "/tmp/demo"
               && idle.first?.lastMessage == "Das Layout steht." && idle.first?.openTodos == 1 && idle.first?.status == .open,
               "the agent overview reads a session: title, folder, last answer, open todos (\(idle))")
        let live = ClaudeSessions.scan(root: projects, now: Date(), running: ["/tmp/demo"])
        expect(live.first?.status == .waiting, "a session whose claude still runs and has answered waits for you")
        let history = ClaudeSessions.messages(in: project.appendingPathComponent("demo.jsonl"))
        expect(history.map(\.role) == [.user, .tool, .assistant] && history[1].output == "ok",
               "a session opens as a chat with its history (\(history.map(\.role)))")
        let page = browser.state.activeItem
        browser.toggleAgents()
        expect(browser.state.agentsVisible && browser.state.activeItem === page,
               "Agents take the sidebar's place like a space, and the page stays")

        // The panel beside a chat reads the folder with git.
        let repo = folder.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try? "eins\nzwei\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q", "-b", "main"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "a"],
                          ["remote", "add", "origin", "git@github.com:dpfaffenbauer/OpenArch.git"]] {
            _ = AgentEnvironment.run("/usr/bin/git", ["-C", repo.path] + arguments)
        }
        try? "eins\ndrei\nvier\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "neu\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let workspace = AgentWorkspace.read(folder: repo.path)
        let changed = workspace.changes.first { $0.path == "a.txt" }
        expect(workspace.branch == "main" && workspace.repository == "dpfaffenbauer/OpenArch"
               && changed?.added == 2 && changed?.removed == 1 && workspace.changes.contains { $0.path == "b.txt" && $0.isNew },
               "the panel beside a chat shows repository, branch and changed files (\(workspace))")

        // The glass look lets the desktop through the window.
        library.settings.glass = true
        browser.applyTheme()
        expect(browser.window?.isOpaque == false && browser.window?.backgroundColor.alphaComponent == 0,
               "the glass look makes the window see-through")
        library.settings.glass = false
        browser.applyTheme()
        expect(browser.window?.isOpaque == true, "and without it the window is solid again")

        guard let chat = browser.newAgentChat(prompt: "Was liegt hier?"), let session = chat.agentSession else {
            expect(false, "a new agent chat")
            return done()
        }
        expect(browser.state.agentsVisible && browser.state.activeItem === chat
               && AgentEntry.all(browser: browser).contains { $0.chat === chat },
               "a new chat opens next to the Agents list and is in it")
        expect(browser.state.activeItem === chat && browser.shownTabs.isEmpty && chat.role == .today,
               "an agent chat shows in place of the page, under the line")
        eventually({ !session.isRunning }, timeout: 5) { finished in
            let roles = session.messages.map(\.role)
            self.expect(finished && roles == [.user, .assistant, .tool, .assistant, .denied],
                        "the agent's answer, its tool and what it was refused show in the chat (\(roles))")
            let tool = session.messages.first { $0.role == .tool }
            self.expect(session.messages.first { $0.role == .assistant }?.text == "Ich schaue nach."
                        && tool?.text == "ls -la" && tool?.failed == true,
                        "streamed text becomes the whole answer, and the refused command shows")
            self.expect(session.messages.last?.tool == "Bash(ls:*)", "allowing the refusal allows ls commands")
            let prompt = try? String(contentsOf: folder.appendingPathComponent("prompt.txt"), encoding: .utf8)
            self.expect(prompt == "Was liegt hier?" && chat.displayTitle == "Was liegt hier?",
                        "the message goes to claude on stdin and names the chat (\(prompt ?? "nothing"))")
            self.expect(chat.agent?.sessionID == "selftest-session", "the chat remembers Claude Code's session")
            self.expect(session.model == "claude-test" && session.connectors.map(\.name) == ["openarch", "jira"]
                        && session.contextUsed == 41_500 && session.contextWindow == 200_000,
                        "the chat knows its model, connectors and how full its context is (\(session.contextUsed ?? 0))")
            let restored = Item(data: chat.data)
            self.expect(restored.kind == .agent && restored.agent == chat.agent && restored.displayTitle == chat.displayTitle
                        && chat.data.kind == .tab,
                        "an agent chat is saved with its folder and session, as a tab to builds without agent chats")
            session.send("Weiter")
            self.eventually({ !session.isRunning }, timeout: 5) { _ in
                let arguments = (try? String(contentsOf: folder.appendingPathComponent("arguments.txt"), encoding: .utf8)) ?? ""
                self.expect(arguments.contains("--resume\nselftest-session\n") && arguments.contains("--permission-mode\ndefault\n"),
                            "the next message continues the session")
                self.browser.close(chat)
                self.expect(chat.container == nil && self.browser.state.activeItem !== chat, "closing an agent chat removes it")
                done()
            }
        }
    }

    /// Plays a tone in a tab that was muted first (so nothing is heard) and
    /// checks that the sidebar learns about it.
    /// A tab nobody looked at goes to sleep and comes back on the same page;
    /// one whose page asks before leaving stays awake.
    private func sleepingTabs(then next: @escaping () -> Void) {
        guard let space = library.spaces.first else { return }
        browser.switchSpace(to: space)
        let shown = browser.state.activeItem
        let sleepy = browser.openInNewTab("https://example.com/?sleepy", select: false)
        let asking = browser.openInNewTab("https://example.com/?asking", select: false)
        browser.select(sleepy, focus: false)
        browser.select(asking, focus: false)
        if let shown { browser.select(shown, focus: false) }
        after(3) {
            asking.pane?.executeJavaScript("window.addEventListener('beforeunload', e => e.preventDefault())")
            for tab in [sleepy, asking] {
                tab.lastActiveAt = Date().addingTimeInterval(-3600)
                tab.loadedAt = tab.lastActiveAt
            }
            after(0.5) {
                self.browser.sleepInactiveTabs(olderThan: 30)
                after(1.5) {
                    self.expect(sleepy.isAsleep && sleepy.pane == nil && sleepy.currentURL == "https://example.com/?sleepy",
                                "a tab nobody looked at sleeps and keeps its address (asleep \(sleepy.isAsleep), \(sleepy.currentURL))")
                    self.expect(!asking.isAsleep && asking.pane != nil, "a page that asks before leaving stays awake")
                    self.browser.select(sleepy, focus: false)
                    after(2.5) {
                        self.expect(!sleepy.isAsleep && sleepy.pane?.url == "https://example.com/?sleepy",
                                    "a sleeping tab wakes up on its page (\(sleepy.pane?.url ?? "no page"))")
                        if let shown { self.browser.select(shown, focus: false) }
                        self.browser.close(sleepy)
                        self.browser.close(asking)
                        next()
                    }
                }
            }
        }
    }

    private func cancelFirstDownload() {
        guard let download = Downloads.shared.running.first else {
            return after(0.5) { self.cancelFirstDownload() }
        }
        Swift.print("[selftest] download running: \(download.name) \(download.progress)")
        after(2) {
            Downloads.shared.cancel(download.id)
            after(1.5) {
                let partial = (try? FileManager.default.contentsOfDirectory(atPath: Self.downloadFolder.path)) ?? []
                Swift.print("[selftest] download cancelled: running \(Downloads.shared.running.count), finished \(Downloads.shared.finished), folder \(partial)")
            }
        }
    }

    /// A file the page downloads lands in the download folder, and the
    /// library hears of it (button bounce, library reload).
    private func downloadTest() {
        guard let tab = browser.state.activeItem else { return expect(false, "a tab to download from") }
        let finished = Downloads.shared.finished
        let target = browser.libraryButtonCenter
        expect(target.x > 10 && target.x < 60 && target.y > 5 && target.y < 45,
               "downloads fly to the library button at the bottom of the sidebar (\(Int(target.x)), \(Int(target.y)))")
        tab.pane?.executeJavaScript("""
            (() => { const a = document.createElement('a');
              a.href = URL.createObjectURL(new Blob(['OpenArch download test'], {type: 'text/plain'}));
              a.download = 'openarch-selftest.txt'; document.body.appendChild(a); a.click(); a.remove(); })()
            """, userGesture: true)
        let file = Self.downloadFolder.appendingPathComponent("openarch-selftest.txt")
        eventually({ (try? String(contentsOf: file, encoding: .utf8)) == "OpenArch download test"
                     && Downloads.shared.finished > finished }, timeout: 8) { _ in
            let saved = (try? String(contentsOf: file, encoding: .utf8)) == "OpenArch download test"
            self.expect(saved, "a download is saved (to the self-test's folder)")
            self.expect(Downloads.shared.finished == finished + 1 && Downloads.shared.progress.isEmpty,
                        "the library hears when a download finishes (\(Downloads.shared.finished - finished))")
        }
    }

    /// An address another app opens (here one no app knows) does not
    /// replace the page with Chromium's error; OpenArch says so instead.
    private func externalAppLinks() {
        guard let tab = browser.state.activeItem, let pane = tab.pane else { return expect(false, "a tab for the app link") }
        let before = tab.currentURL
        browser.toast?.orderOut(nil)
        pane.loadURL("openarch-selftest-unknown://open")
        after(1.2) {
            let toast = self.browser.toast?.isVisible == true
            self.expect(tab.currentURL == before && toast,
                        "a link to an app stays on the page and is handed to macOS (\(tab.currentURL), toast \(toast))")
        }
    }

    /// ⌃Tab with ⌃ held: the switcher opens on the tab used before, moves
    /// along, and goes to the marked tab when ⌃ is let go (Esc stays put).
    private func tabSwitcherTest() {
        let switcher = browser.tabSwitcher
        guard browser.orderedTabs.count >= 3, let current = browser.state.activeItem else {
            return expect(false, "three tabs for the switcher")
        }
        switcher.advance(1)
        expect(switcher.isOpen && switcher.model.tabs.first === current && switcher.model.selection == 1,
               "⌃Tab opens the switcher on the tab used before")
        let row = NSApp.windows.first(where: { $0 is TabSwitcherWindow })?.frame.size ?? .zero
        expect(row.width > 300 && row.height > 100, "the switcher has its size (\(Int(row.width))×\(Int(row.height)))")
        if let host = NSApp.windows.first(where: { $0 is TabSwitcherWindow })?.contentView,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = AppPaths.support.appendingPathComponent("tab-switcher.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            Swift.print("[selftest] tab switcher rendered to \(url.path)")
        }
        switcher.advance(1)
        switcher.cancel()
        expect(!switcher.isOpen && browser.state.activeItem === current, "Esc closes the switcher and stays on the tab")
        switcher.advance(1)
        switcher.advance(1)
        let target = switcher.model.tabs[2]
        switcher.commit()
        expect(!switcher.isOpen && browser.state.activeItem === target, "letting go of ⌃ goes to the marked tab")
        browser.select(current, focus: false)
    }

    /// The switcher shows a picture of each open page, hidden ones too.
    private func tabSwitcherPreviews() {
        let switcher = browser.tabSwitcher
        switcher.advance(1)
        let open = switcher.model.tabs.filter { $0.pane != nil && !$0.isAsleep }
        let hidden = open.filter { tab in !browser.visibleTabs.contains { $0 === tab } }
        eventually({ open.allSatisfy { $0.snapshot != nil } }, timeout: 5) { done in
            let size = hidden.first?.snapshot?.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "none"
            let missing = open.filter { $0.snapshot == nil }.map { "\($0.currentURL) loading \($0.isLoading) shown \($0.pane?.isVisible == true)" }
            self.expect(done && !hidden.isEmpty,
                        "the switcher has pictures of \(open.count) open tabs, \(hidden.count) of them hidden (\(size))\(missing.isEmpty ? "" : ", none of \(missing)")")
            if let host = NSApp.windows.first(where: { $0 is TabSwitcherWindow })?.contentView,
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let url = AppPaths.support.appendingPathComponent("tab-switcher-previews.png")
                try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
                Swift.print("[selftest] tab switcher previews rendered to \(url.path)")
            }
            switcher.cancel()
        }
    }

    /// ⌘⇧C the way a real key press arrives: through the event queue, to
    /// the page's window.
    private func copyLinkKeyPress() {
        copyPasteboard.clearContents()
        guard let url = browser.state.activeItem?.currentURL,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                           windowNumber: browser.activePane?.window?.windowNumber ?? 0, context: nil,
                                           characters: "C", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else {
            return expect(false, "⌘⇧C key press setup")
        }
        NSApp.postEvent(event, atStart: false)
        // Other steps may switch tabs before the key press is handled: any
        // tab's address shows it went the way of a real one.
        let addresses = Set(browser.allTabs.map(\.currentURL)).union([url])
        eventually({ copyPasteboard.string(forType: .string).map(addresses.contains) ?? false }) { copied in
            self.expect(copied, "⌘⇧C pressed in the page copies its address (copied \(copyPasteboard.string(forType: .string) ?? "nothing"))")
        }
    }

    /// The Site Control Center: permissions stick per site, zoom is read
    /// from the page, and the panel renders.
    private func siteControls() {
        guard let tab = browser.state.activeItem, let profile = tab.pane?.profile else {
            return expect(false, "a tab for the site controls")
        }
        let site = "https://example.com"
        expect(SiteControls.origin(of: "https://example.com:8443/a?b") == "https://example.com:8443"
               && SiteControls.origin(of: "chrome://settings") == nil, "site controls work on a page's origin")
        profile.setPermission(.camera, forSite: site, value: .block)
        let blocked = profile.permission(.camera, forSite: site)
        profile.setPermission(.camera, forSite: site, value: .default)
        let reset = profile.permission(.camera, forSite: site)
        // Chrome reports the default it falls back to (ask) once reset.
        expect(blocked == .block && reset != .block,
               "a site's camera can be blocked and set back to the default (\(blocked.rawValue), \(reset.rawValue))")
        expect(tab.pane?.zoomPercent == 100, "the page's zoom reads 100 % (\(tab.pane?.zoomPercent ?? 0))")
        let host = NSHostingView(rootView: SiteControls(browser: browser, item: tab))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = AppPaths.support.appendingPathComponent("site-controls.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            Swift.print("[selftest] site controls rendered \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height)) to \(url.path)")
        }
    }

    /// ⌘-click on a tab in the sidebar loads it in the background: the page
    /// and its title arrive, and the tab in front stays.
    private func loadInBackground() {
        let shown = browser.state.activeItem
        let tab = Item.tab(url: "https://example.com/background", title: "Gespeichert")
        tab.lastActiveAt = .distantPast  // a pinned tab not used for a while
        browser.state.space.pinned.insert(tab)
        browser.loadInBackground(tab)
        expect(tab.pane != nil && browser.state.activeItem === shown, "⌘-click loads a tab without showing it")
        eventually({ tab.liveTitle == "Example Domain" }, timeout: 8) { titled in
            self.expect(titled && tab.pane?.isVisible == false && self.browser.state.activeItem === shown,
                        "the tab loaded in the background shows its page's title (\(tab.displayTitle))")
            self.expect(tab.loadingProgress > 0,
                        "Chrome reports how far the page has loaded (\(Int(tab.loadingProgress * 100)) %)")
            self.browser.unload(tab)
            tab.detach()
        }
    }

    /// While a page loads, a line just above it shows how far it has got,
    /// sidebar shown or hidden; the sidebar's address field shows it
    /// instead when it is switched on.
    private func loadingBar() {
        guard let tab = browser.state.activeItem, let window = browser.window else {
            return expect(false, "a tab for the loading bar")
        }
        func lineAbovePage() -> Bool {
            guard let page = browser.expectedPaneFrames.first(where: { $0.0 === tab }),
                  let line = browser.loadingLineFrame else { return false }
            let top = window.convertFromScreen(page.1).maxY
            return line.minY >= top && line.maxY <= top + BrowserWindowController.contentInset && line.width > 100
        }
        func showSidebar(_ shown: Bool) {
            if browser.state.sidebarVisible != shown { browser.toggleSidebar() }
        }
        tab.isLoading = true
        tab.loadingProgress = 0.45
        let addressField = library.settings.showSidebarAddress, sidebar = browser.state.sidebarVisible
        library.settings.showSidebarAddress = false
        showSidebar(true)
        expect(lineAbovePage(), "a line just above the page shows its loading (\(browser.loadingLineFrame.map(NSStringFromRect) ?? "none"))")
        showSidebar(false)
        expect(lineAbovePage(), "and with the sidebar hidden too (\(browser.loadingLineFrame.map(NSStringFromRect) ?? "none"))")
        showSidebar(true)
        library.settings.showSidebarAddress = true
        expect(browser.loadingLineFrame == nil, "with the address field in the sidebar, the field shows it instead of the line")
        library.settings.showSidebarAddress = addressField
        showSidebar(sidebar)
        tab.isLoading = false
        tab.loadingProgress = 1
    }

    /// A page at 45 %: the line above it, then with the sidebar hidden, then
    /// the address field, each held to be photographed from outside
    /// (`--selftest --loading-bar-shots`; prints "STEP shot <name>").
    private func loadingBarShots() {
        populate()
        let tab = browser.openInNewTab("https://example.com/loading")
        after(6) {
            tab.isLoading = true
            tab.loadingProgress = 0.45
            after(1) { Swift.print("[selftest] STEP shot loading-line") }
            after(2) { self.browser.toggleSidebar() }
            after(3) { Swift.print("[selftest] STEP shot loading-line-hidden") }
            after(4) {
                self.browser.toggleSidebar()
                self.library.settings.showSidebarAddress = true
            }
            after(5) { Swift.print("[selftest] STEP shot loading-field") }
            after(6) {
                tab.isLoading = false
                Swift.print("[selftest] DONE loading bar shots")
                Self.quit()
            }
        }
    }

    /// Über OpenArch opens its own window (behind, in the self-test).
    private func aboutWindow() {
        (NSApp.delegate as? AppDelegate)?.showAbout(nil)
        let window = AboutWindowController.shared.window
        expect(window?.isVisible == true && window?.contentView is NSHostingView<AboutView>, "Über OpenArch opens its window")
        window?.close()
    }

    /// ⌘T completes the address as you type, like Chrome: first the most
    /// visited site, after a "/" the most visited page; the completed part is
    /// selected, Backspace takes it away, → keeps it, Return opens it.
    private func inlineCompletion() {
        let history = browser.history
        for _ in 0..<3 { history.recordVisit(url: "https://github.com/cors-gmbh/shared-workflows/pull/26", title: "PR 26") }
        history.recordVisit(url: "https://github.com/cors-gmbh/shared-workflows", title: "shared-workflows")
        history.recordVisit(url: "https://www.gitlab.example/", title: "GitLab")
        browser.commandBar.show(mode: .newTab)
        let model = browser.commandBar.model
        model.query = "g"
        model.query = "gi"
        expect(model.completion?.text == "github.com" && model.fieldText == "github.com"
               && model.completionRange == NSRange(location: 2, length: 8),
               "typing \"gi\" completes the most visited site (\(model.fieldText))")
        model.query = "github.com/cors-gmbh/s"
        model.query = "github.com/cors-gmbh/sh"
        expect(model.fieldText == "github.com/cors-gmbh/shared-workflows/pull/26"
               && model.results.first?.id == "open:https://github.com/cors-gmbh/shared-workflows/pull/26",
               "after a \"/\" it completes the most visited page, which Return opens (\(model.fieldText))")
        expect(model.dropCompletion() && model.fieldText == "github.com/cors-gmbh/sh",
               "Backspace takes the completion away")
        model.query = "github.com/cors-gmbh/sha"
        expect(model.acceptCompletion() && model.query == "github.com/cors-gmbh/shared-workflows/pull/26"
               && model.completion == nil, "→ keeps the completed address")
        model.query = "github.com/cors-gmbh/shared-workflows/pull/2"
        expect(model.completion == nil, "deleting does not complete again")
        browser.commandBar.hide()
    }

    /// GitHub live folders read GitHub's search JSON and keep tabs that are
    /// still there; signed out, they say so. (A fixture: no GitHub login here.)
    private func liveFolders() {
        let json = #"""
        {"payload":{"blackbirdSearchRoute":{"logged_in":true,"results":[
          {"number":26,"hl_title":"Shared <em>workflows</em> &amp; caches","repo":{"repository":{"name":"shared-workflows","owner_login":"cors-gmbh"}}},
          {"number":7,"hl_title":"","repo":{"repository":{"name":"OpenArch","owner_login":"dpfaffenbauer"}}}]}}}
        """#
        let parsed = LiveFolders.results(from: Data(json.utf8), kind: .pullRequests)
        expect(parsed?.signedIn == true && parsed?.entries == [
            LiveFolders.Entry(url: "https://github.com/cors-gmbh/shared-workflows/pull/26", title: "Shared workflows & caches"),
            LiveFolders.Entry(url: "https://github.com/dpfaffenbauer/OpenArch/pull/7", title: "OpenArch#7"),
        ], "a live folder reads GitHub's pull requests (\(parsed?.entries.map(\.title) ?? []))")
        let signedOut = LiveFolders.results(from: Data(#"{"payload":{"blackbirdSearchRoute":{"logged_in":false,"results":[]}}}"#.utf8), kind: .issues)
        expect(signedOut?.signedIn == false, "a live folder notices when GitHub is signed out")

        let folder = browser.newLiveFolder(.myPullRequests, name: "Live-Test")
        folder.live = nil  // no refresh from the network during the test
        LiveFolders.apply(parsed?.entries ?? [], to: folder)
        let kept = folder.children.first
        LiveFolders.apply(Array((parsed?.entries ?? []).prefix(1)), to: folder)
        expect(folder.children.count == 1 && folder.children.first === kept && kept?.role == .pinned
               && kept?.parentFolder === folder, "refreshing keeps the tabs still open on GitHub and drops the others")
        folder.detach()
        library.setNeedsSave()
    }

    /// Dragging a space icon onto another puts it in that one's place.
    private func spaceOrder() {
        let before = library.spaces.map(\.id)
        guard before.count >= 2, let first = library.spaces.first, let last = library.spaces.last else {
            return expect(false, "two spaces to reorder")
        }
        library.moveSpace(first, to: last)
        expect(library.spaces.last === first && library.spaces.count == before.count, "a space dragged onto the last one moves to the end")
        library.moveSpace(first, to: library.spaces[0])
        expect(library.spaces.map(\.id) == before, "and dragged back onto the first one, the order is as before")
    }

    /// DevTools dock beside the page, on the side Ansicht › DevTools anordnen
    /// says, and the page gets its whole frame back when they close. (A
    /// window of their own is left out: it would show on screen.)
    private func devToolsDock(then next: @escaping () -> Void) {
        guard let pane = browser.activePane, let page = pane.window else { return expect(false, "a tab for DevTools") }
        let content = browser.window.map { $0.convertToScreen(browser.contentRect) } ?? .zero
        let full = page.frame
        pane.showDevTools()
        after(3) {
            let right = page.frame
            OACPane.devToolsDock = .left
            let left = page.frame
            OACPane.devToolsDock = .bottom
            let bottom = page.frame
            self.expect(right.minX == full.minX && right.width < full.width * 0.7
                        && left.maxX == full.maxX && left.width == right.width
                        && bottom.maxY == full.maxY && bottom.width == full.width && bottom.height < full.height * 0.7,
                        "DevTools dock right, left and below the page (\(right), \(left), \(bottom), content \(content))")
            OACPane.devToolsDock = .right
            _ = pane.closeDevTools()
            after(1.5) {
                self.expect(page.frame == full, "closing DevTools gives the page its whole frame back (\(page.frame))")
                next()
            }
        }
    }

    /// HTTPS-only reaches Chromium's preferences, and goes again.
    private func httpsOnly(then next: @escaping () -> Void) {
        library.settings.httpsOnly = true
        library.settings.applyToChromium()
        let shown = browser.state.activeItem
        let tab = browser.openInNewTab("chrome://prefs-internals", select: false)
        browser.select(tab, focus: false)
        after(2.5) {
            let script = "(() => { const p = JSON.parse(document.body.innerText); return String(p.https_only_mode_enabled.value); })()"
            tab.pane?.callDevToolsMethod("Runtime.evaluate", params: ["expression": script, "returnByValue": true]) { result in
                let value = (result?["result"] as? [String: Any])?["value"] as? String
                self.expect(value == "true", "HTTPS-only turns on Chromium's HTTPS-First mode (\(value ?? "no value"))")
                self.library.settings.httpsOnly = false
                self.library.settings.applyToChromium()
                if let shown { self.browser.select(shown, focus: false) }
                self.browser.close(tab)
                next()
            }
        }
    }

    private func audioIndicator() {
        guard let space = library.spaces.first else { return }
        browser.switchSpace(to: space)
        let tab = browser.openInNewTab("https://example.com/audio")
        // Muting and the tone need the page; on a slow machine it takes a while.
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading }, timeout: 8) { _ in
            self.browser.toggleMute(tab)
            tab.pane?.executeJavaScript("""
                window.__tone = new AudioContext();
                const osc = window.__tone.createOscillator();
                osc.connect(window.__tone.destination);
                osc.start();
                """)
            self.eventually({ tab.isAudible && tab.isMuted }, timeout: 5) { shown in
                self.expect(shown, "a muted tab playing sound shows the speaker (audible \(tab.isAudible), muted \(tab.isMuted))")
                tab.pane?.executeJavaScript("window.__tone && window.__tone.close();")
                after(0.5) {
                    self.browser.close(tab)
                }
            }
        }
    }

    private func menus() {
        guard let main = NSApp.mainMenu,
              let tabs = main.items.first(where: { $0.title == "Tabs" })?.submenu,
              let split = main.items.first(where: { $0.title == "Split View" })?.submenu else {
            return expect(false, "Tabs and Split View menus exist")
        }
        TabsMenuUpdater.shared.menuNeedsUpdate(tabs)
        let first = tabs.items.first { $0.action == #selector(AppDelegate.selectTab(_:)) && $0.tag == 0 }
        expect(first?.title == browser.orderedTabs.first.map { String($0.displayTitle.prefix(60)) }, "Tabs menu names tab 1 (\(first?.title ?? "-"))")
        SplitMenuUpdater.shared.menuNeedsUpdate(split)
        let sides = split.items.filter { $0.action == #selector(AppDelegate.focusSplit(_:)) && !$0.isHidden }
        expect(sides.count == (browser.shownTabs.count > 1 ? browser.shownTabs.count : 0),
               "Split View menu lists the open sides (\(sides.map(\.title)))")
    }

    /// Re-encryption as the full Arc import does it, with throwaway keys.
    private func arcCrypto() {
        let arcKey = ArcProfileImport.derivedKey(password: Data("arc-test-password".utf8))
        let openArchKey = ArcProfileImport.derivedKey(password: Data("mock_password".utf8))
        let plain = Data("session=geheim".utf8)
        guard let encrypted = ArcProfileImport.aes(CCOperation(kCCEncrypt), plain, key: arcKey) else {
            return expect(false, "test value encrypts")
        }
        let db = AppPaths.support.appendingPathComponent("crypto-test.sqlite")
        try? FileManager.default.removeItem(at: db)
        var handle: OpaquePointer?
        sqlite3_open(db.path, &handle)
        sqlite3_exec(handle, "CREATE TABLE cookies (encrypted_value BLOB)", nil, nil, nil)
        var insert: OpaquePointer?
        sqlite3_prepare_v2(handle, "INSERT INTO cookies VALUES (?1)", -1, &insert, nil)
        let value = Data("v10".utf8) + encrypted
        _ = value.withUnsafeBytes { sqlite3_bind_blob(insert, 1, $0.baseAddress, Int32(value.count), nil) }
        sqlite3_step(insert)
        sqlite3_finalize(insert)
        sqlite3_close(handle)
        let (converted, failed) = ArcProfileImport.reencryptColumn(database: db, table: "cookies", column: "encrypted_value",
                                                                   from: arcKey, to: openArchKey)
        sqlite3_open(db.path, &handle)
        var select: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT encrypted_value FROM cookies", -1, &select, nil)
        sqlite3_step(select)
        let stored = Data(bytes: sqlite3_column_blob(select, 0), count: Int(sqlite3_column_bytes(select, 0)))
        sqlite3_finalize(select)
        sqlite3_close(handle)
        let roundTrip = ArcProfileImport.aes(CCOperation(kCCDecrypt), stored.dropFirst(3), key: openArchKey)
        expect(converted == 1 && failed == 0 && roundTrip == plain, "Arc values are re-encrypted with OpenArch's key")
    }

    /// Opens a link in Little OpenArch, then moves it into the main window.
    private func littleOpenArch() {
        guard let app = NSApp.delegate as? AppDelegate,
              let little = LittleOpenArchWindowController.show(url: "https://example.com/little", app: app) else {
            return expect(false, "Little OpenArch opens")
        }
        // A Ctrl-click opens the link in the space, a plain click stays here.
        let ctrlLink = "https://example.com/little-ctrl-click"
        let opened = little.openInSpace(ctrlLink, modifiers: [.control])
        let plain = little.openInSpace("https://example.com/little-plain", modifiers: [])
        let inSpace = library.spaces.flatMap(\.today.allTabs).first { $0.currentURL == ctrlLink }
        expect(opened && !plain && inSpace != nil, "a Ctrl-click in Little OpenArch opens the link in the space")
        if let inSpace { browser.close(inSpace) }
        after(2.5) { little.load("https://example.com/little/next") }
        after(4.5) {
            self.expect(little.model.url.contains("/little/next") && little.model.canGoBack,
                        "Little OpenArch follows a link and can go back (\(little.model.url))")
            little.goBack()
        }
        after(6) {
            self.expect(little.model.url.hasSuffix("/little") && little.model.canGoForward,
                        "Little OpenArch goes back and can go forward (\(little.model.url))")
            little.toggleToolbar()
            self.expect(little.pane.toolbarVisible, "the puzzle button shows Chrome's toolbar with the extensions")
            little.toggleToolbar()
            let before = self.browser.state.space.today.allTabs.count
            little.moveToSpace()
            let moved = self.browser.state.activeItem
            self.expect(self.browser.state.space.today.allTabs.count == before + 1 && moved?.pane?.isVisible == true
                        && moved?.currentURL.contains("example.com/little") == true,
                        "\"In Space öffnen\" moves the page into the main window (\(moved?.currentURL ?? "-"))")
        }
    }

    /// Full screen, visibly (it takes over the screen, so it is not part of
    /// the background self-test): a page going full screen leaves the window
    /// and comes back, and the window itself goes full screen with its tabs.
    private func fullscreenTest() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        browser.window?.orderFrontRegardless()
        populate()
        let tab = browser.openInNewTab("https://example.com/fullscreen")
        func paneInPlace() -> Bool {
            guard let (_, expected) = browser.expectedPaneFrames.first, let window = tab.pane?.window else { return false }
            return window.parent === browser.window && abs(window.frame.minX - expected.minX) < 2 && abs(window.frame.width - expected.width) < 2
        }
        after(3) { tab.pane?.executeJavaScript("document.documentElement.requestFullscreen()", userGesture: true) }
        after(6.5) {
            let window = tab.pane?.window
            self.expect(window?.styleMask.contains(.fullScreen) == true && window?.parent == nil,
                        "a page going full screen gets its own full screen space")
            tab.pane?.executeJavaScript("document.exitFullscreen()")
        }
        after(10) {
            self.expect(tab.pane?.window?.styleMask.contains(.fullScreen) == false && paneInPlace(),
                        "after full screen the page is back in the window")
            self.browser.window?.toggleFullScreen(nil)
        }
        after(14) {
            self.expect(self.browser.window?.styleMask.contains(.fullScreen) == true && paneInPlace(),
                        "the window goes full screen with its tab in place")
            self.browser.window?.toggleFullScreen(nil)
        }
        after(18) {
            self.expect(self.browser.window?.styleMask.contains(.fullScreen) == false && paneInPlace(),
                        "leaving full screen keeps the tab in place")
            Swift.print("[selftest] DONE failures=\(self.failures.count) \(self.failures)")
            Self.quit()
        }
    }

    /// A video (from a canvas, silent) plays in a tab: OpenArch learns about
    /// it, shows it in the sidebar once you leave the tab, and pauses it from
    /// there. Picture-in-picture is left out: its window would pop up.
    private func mediaTest() {
        let previous = browser.state.activeItem
        let tab = browser.openInNewTab("https://example.com/media")
        library.settings.autoPictureInPicture = false
        after(3) {
            tab.pane?.executeJavaScript("""
                (() => { const c = document.createElement('canvas'); c.width = 320; c.height = 180;
                  const g = c.getContext('2d'); let i = 0;
                  setInterval(() => { g.fillStyle = `hsl(${i++ % 360} 80% 50%)`; g.fillRect(0, 0, 320, 180); }, 50);
                  const v = document.createElement('video'); v.srcObject = c.captureStream(20); document.body.append(v); })()
                """)
            after(0.5) { self.browser.mediaCommand(tab, "toggle") }
        }
        after(5) {
            self.expect(tab.media?.playing == true && tab.media?.video == true,
                        "a playing video is reported to OpenArch (\(String(describing: tab.media)))")
            if let previous { self.browser.select(previous) }
            self.expect(self.browser.nowPlaying === tab, "the sidebar offers controls for the video in the other tab")
            self.browser.mediaCommand(tab, "toggle")
        }
        after(6.5) {
            self.expect(tab.media?.playing == false, "the sidebar's pause button pauses it")
            self.browser.dismissMedia(tab)
            self.expect(self.browser.nowPlaying == nil, "the media card closes")
            // A muted video playing by itself gets no card.
            tab.pane?.executeJavaScript("document.querySelector('video').muted = true")
            self.browser.mediaCommand(tab, "toggle")
        }
        after(7.5) {
            self.expect(tab.media?.playing == true && self.browser.nowPlaying == nil,
                        "a muted video playing in another tab gets no media card (\(String(describing: tab.media)))")
            self.library.settings.autoPictureInPicture = true
            self.browser.close(tab)
        }
    }

    /// A fake newer build behind a local latest.json: the updater downloads,
    /// verifies and unpacks it, and refuses one with a wrong checksum.
    private func updaterTest() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-update-test-\(UUID().uuidString)")
        let app = folder.appendingPathComponent("build/OpenArch.app/Contents")
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": Bundle.main.bundleIdentifier ?? "", "CFBundleVersion": "999"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        let zip = folder.appendingPathComponent("OpenArch.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.appendingPathComponent("build/OpenArch.app").path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        func manifest(_ name: String, sha: String) -> String {
            let url = folder.appendingPathComponent(name)
            let json = #"{"build": 999, "commit": "test", "sha256": "\#(sha)", "url": "\#(zip.absoluteString)"}"#
            try? json.write(to: url, atomically: true, encoding: .utf8)
            return url.absoluteString
        }
        let sha = (try? Updater.sha256(of: zip)) ?? ""
        let good = Updater()
        good.manifestURL = manifest("latest.json", sha: sha)
        good.check()
        after(3) {
            self.expect(good.phase == .ready(999), "the updater downloads, verifies and unpacks a newer build (\(good.phase))")
            let bad = Updater()
            bad.manifestURL = manifest("tampered.json", sha: String(repeating: "0", count: 64))
            bad.check()
            after(3) {
                if case .failed = bad.phase {
                    self.expect(true, "the updater refuses a download with the wrong checksum")
                } else {
                    self.expect(false, "the updater refuses a download with the wrong checksum (\(bad.phase))")
                }
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Quitting ends OpenArch even when a browser never closes; an update
    /// waits for exactly that. Run on its own (`--selftest --quit-test`):
    /// the process has to be gone a few seconds after the STEP line.
    private func quitWithStuckBrowser() {
        // The script then checks that both tabs are still in the saved
        // sidebar: quitting closes their browsers, not the tabs.
        browser.openInNewTab("https://example.com/kept-after-quit")
        let tab = browser.openInNewTab("https://example.com/never-closes")
        after(3) {
            tab.pane?.refusesToCloseForTesting = true
            Swift.print("[selftest] STEP quit with a browser that does not close")
            NSApp.terminate(nil)
        }
    }

    /// Links dropped on the sidebar become tabs: as a URL (a page, Safari,
    /// Mail), as raw URL data, and as text without a scheme. Plain words
    /// do not, and a link dropped on a space icon opens in that space (all
    /// at once here, so no later step starts in the wrong space).
    private func dropLinks() {
        let space = browser.state.space
        let urlData = NSItemProvider()
        urlData.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(Data("https://example.com/dropped-data".utf8), nil)
            return nil
        }
        let drops: [NSItemProvider] = [NSItemProvider(object: NSURL(string: "https://example.com/dropped-url")!), urlData,
                                       NSItemProvider(object: "example.com/dropped-text" as NSString),
                                       NSItemProvider(object: "just some words" as NSString)]
        if let other = library.spaces.last(where: { $0 !== space }) {
            browser.drop("https://example.com/dropped-space", toSpace: other)
            expect(browser.state.space === other
                   && other.today.allTabs.contains { $0.currentURL == "https://example.com/dropped-space" },
                   "a link dropped on a space icon opens in that space")
            for tab in other.today.allTabs where tab.currentURL.contains("dropped") { browser.close(tab) }
            browser.switchSpace(to: space)
        }
        for provider in drops {
            browser.handleDrop([provider], target: .end(space.today))
        }
        after(0.3) {
            let urls = space.today.allTabs.map(\.currentURL)
            self.expect(["https://example.com/dropped-url", "https://example.com/dropped-data", "https://example.com/dropped-text"]
                            .allSatisfy(urls.contains) && !urls.contains { $0.contains("words") },
                        "links dropped on the sidebar become tabs, plain words do not")
            for tab in space.today.allTabs where tab.currentURL.contains("dropped") { self.browser.close(tab) }
        }
    }

    /// Link rules: patterns match by host, wildcard and path, and a link
    /// from another app lands in the rule's space.
    private func linkRulesTest() {
        let rule = LinkRule(pattern: "example.org")
        let wildcard = LinkRule(pattern: "*.atlassian.net")
        let path = LinkRule(pattern: "docs.google.com/spreadsheets")
        expect(rule.matches("https://www.example.org/a") && rule.matches("https://sub.example.org")
               && !rule.matches("https://notexample.org") && wildcard.matches("https://acme.atlassian.net/browse/X-1")
               && !wildcard.matches("https://atlassian.com") && path.matches("https://docs.google.com/spreadsheets/d/1")
               && !path.matches("https://docs.google.com/document/d/1"),
               "link rules match by host, subdomain, wildcard and path")
        guard let app = NSApp.delegate as? AppDelegate, let target = library.spaces.last else { return }
        let before = browser.state.space
        library.settings.linkRules = [LinkRule(pattern: "example.org", spaceID: target.id)]
        app.openExternal("https://example.org/from-mail")
        expect(browser.state.space === target && target.today.allTabs.contains { $0.currentURL == "https://example.org/from-mail" },
               "a link from another app follows its rule into the space „\(target.name)“")
        library.settings.linkRules = []
        browser.switchSpace(to: before)
    }

    /// "yt" + Tab searches YouTube; Backspace in the empty field leaves.
    private func siteSearchTest() {
        let model = browser.commandBar.model
        model.reset(mode: .newTab)
        model.query = "yt"
        let offered = model.results.contains { $0.title == "YouTube durchsuchen" }
        let entered = model.tab()
        model.query = "lofi beats"
        let url = model.results.first?.subtitle
        expect(offered && entered && model.site?.name == "YouTube" && url == "YouTube durchsuchen",
               "the command bar searches YouTube after yt + Tab")
        model.query = ""
        expect(model.leaveSite() && model.site == nil, "Backspace leaves the site search")
        model.query = "wikip"
        expect(model.tab() && model.site?.name == "Wikipedia", "typing a site's name and Tab works too")
        model.reset(mode: .newTab)

        // A sentence asks Claude first; a few words stay a search with the
        // chat below; off, there is no chat at all.
        let saved = library.settings.askAI
        library.settings.askAI = .claude
        model.query = "haben gestern may day geschaut, guter film, gib mir alternativen dazu"
        expect(model.results.first?.subtitle == "Claude fragen" && model.results.dropFirst().first?.id.hasPrefix("search:") == true,
               "a sentence in the command bar asks Claude first")
        model.query = "may day film"
        expect(model.results.first?.id.hasPrefix("search:") == true && model.results.dropFirst().first?.subtitle == "Claude fragen",
               "a few words stay a search, with Claude one row down")
        expect(AIChat.claude.url(for: "gib mir alternativen?") == "https://claude.ai/new?q=gib%20mir%20alternativen%3F"
               && AIChat.chatGPT.url(for: "a & b") == "https://chatgpt.com/?q=a%20%26%20b",
               "the question goes into a new chat's address, encoded")
        library.settings.askAI = .off
        model.query = "haben gestern may day geschaut, guter film, gib mir alternativen dazu"
        expect(!model.results.contains { $0.id.hasPrefix("ask:") }, "with asking off, the command bar only searches")
        library.settings.askAI = saved
        model.reset(mode: .newTab)

        // The arrow keys put the picked row's address in the field and leave
        // the results as they are; the first row and Esc bring back the
        // typed text.
        model.query = "example"
        let before = model.results.map(\.id)
        if let index = model.results.firstIndex(where: { $0.id.hasPrefix("tab:") || $0.id.hasPrefix("history:") }),
           let address = model.results[index].fieldText {
            model.moveSelection(index)
            let shown = model.shownText
            model.moveSelection(-index)
            let typedAgain = model.shownText == nil
            model.moveSelection(index)
            expect(shown == address && address.contains("example") && typedAgain && model.restoreTyped()
                   && model.shownText == nil && model.query == "example" && model.results.map(\.id) == before,
                   "the arrow keys show the picked address in the field (\(address))")
        } else {
            expect(false, "the command bar finds an example tab to go to")
        }
        model.reset(mode: .newTab)
    }

    private func floatingSidebarTest() {
        let pane = browser.activePane
        expect(pane?.window?.canBecomeMain == false, "tab windows never become main, so the window buttons stay active")
        browser.toggleSidebar()
        browser.floatingSidebar.mouseLocation = { NSPoint(x: -10_000, y: -10_000) }
        browser.floatingSidebar.pressedMouseButtons = { 0 }
        browser.floatingSidebar.show()
        after(0.2) {
            let frame = self.browser.floatingSidebar.frame ?? .zero
            self.expect(self.browser.floatingSidebar.isShown && frame.width == self.browser.sidebarWidth,
                        "the collapsed sidebar floats over the page from the left edge (\(frame))")
        }
        after(0.5) { self.eventually({ !self.browser.floatingSidebar.isShown }) { hidden in
            self.expect(hidden, "the floating sidebar goes away when the mouse is elsewhere")
            self.browser.floatingSidebar.show()
            self.browser.toggleSidebar()
            self.expect(!self.browser.floatingSidebar.isShown && self.browser.state.sidebarVisible,
                        "pinning the sidebar replaces the floating one")
            self.browser.floatingSidebar.mouseLocation = { NSEvent.mouseLocation }
            self.browser.floatingSidebar.pressedMouseButtons = { NSEvent.pressedMouseButtons }
        } }
    }

    private func internalURLs() {
        expect(CommandBarModel.url(fromInput: "openarch://history") == "chrome://history", "openarch://history opens Chrome's history page")
        expect(CommandBarModel.shortURL("chrome://settings/passwords") == "openarch://settings/passwords", "chrome:// pages are shown as openarch://")
    }

    private func spaceEditor() {
        // Popovers do not draw while the app is in the background; render the
        // editor on its own for the screenshot.
        let host = NSHostingView(rootView: SpaceEditor(browser: browser, space: browser.state.space))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = AppPaths.support.appendingPathComponent("space-editor.png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            Swift.print("[selftest] space editor rendered \(Int(host.fittingSize.width))x\(Int(host.fittingSize.height)) to \(url.path)")
        }
        if let app = NSApp.delegate as? AppDelegate {
            library.settings.linkRules = [LinkRule(pattern: "github.com", spaceID: library.spaces.first?.id),
                                          LinkRule(pattern: "*.atlassian.net")]
            // All Dock icons side by side, to look at.
            let sheet = NSImage(size: NSSize(width: 128 * AppIconStyle.allCases.count, height: 128), flipped: false) { _ in
                for (index, style) in AppIconStyle.allCases.enumerated() {
                    AppIcons.image(for: style, size: 128).draw(in: NSRect(x: index * 128, y: 0, width: 128, height: 128))
                }
                return true
            }
            if let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                try? bitmap.representation(using: .png, properties: [:])?.write(to: AppPaths.support.appendingPathComponent("app-icons.png"))
            }
            expect(AppIconStyle.allCases.allSatisfy { AppIcons.image(for: $0, size: 64).isValid }, "every Dock icon style renders")
            let unreadable = AppIconStyle.allCases.filter { $0.design != nil && $0.design?.glyphImage?.isValid != true }
            expect(unreadable.isEmpty, "every icon design's SVG reads (\(unreadable.map(\.name)))")
            expect(AppIcons.design(for: Date()).design != nil
                   && AppIcons.design(for: Date()) != AppIcons.design(for: Date().addingTimeInterval(86_400)),
                   "„Jeden Tag“ picks another design tomorrow")
            // The closed app keeps the chosen icon through the Dock's plug-in,
            // and the bundle stays as signed (the setting is the user's,
            // shared with OpenArch, and only read here).
            AppIcons.saveForDock()
            let saved = FileManager.default.fileExists(atPath: AppIcons.dockIconFile.path)
            let bundle = Bundle.main.bundlePath
            let untouched = !FileManager.default.fileExists(atPath: bundle + "/Icon\r")
                && getxattr(bundle, "com.apple.FinderInfo", nil, 0, 0, 0) < 0
            let plugin = FileManager.default.fileExists(atPath: bundle + "/Contents/PlugIns/OpenArchDockTile.docktileplugin/Contents/MacOS/OpenArchDockTile")
            expect(saved == (AppIcons.style != .standard) && untouched && plugin,
                   "the Dock keeps the chosen icon (\(AppIcons.style.name)) through its plug-in, the bundle stays as signed")
            let picker = NSHostingView(rootView: AppIconSection().padding(24).frame(width: 640))
            picker.frame = NSRect(origin: .zero, size: picker.fittingSize)
            picker.layoutSubtreeIfNeeded()
            if let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) {
                picker.cacheDisplay(in: picker.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: AppPaths.support.appendingPathComponent("settings-app-icon.png"))
            }
            for page in [SettingsPage.general, .links, .about] {
                let settings = NSHostingView(rootView: SettingsView(app: app, page: page))
                settings.frame = NSRect(x: 0, y: 0, width: 640, height: 580)
                settings.layoutSubtreeIfNeeded()
                if let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
                    settings.cacheDisplay(in: settings.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: AppPaths.support.appendingPathComponent("settings-\(page.rawValue).png"))
                }
            }
            // The real window too: its title bar is part of the content area.
            app.showSettings(nil)
            if let window = app.settingsWindow, let content = window.contentView {
                content.layoutSubtreeIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?
                        .write(to: AppPaths.support.appendingPathComponent("settings-window.png"))
                }
                window.close()
            }
            library.settings.linkRules = []
        }
        let dialog = NSHostingView(rootView: ProfileDialogView(existing: [], onCancel: {}, onCreate: { _ in }))
        dialog.frame = NSRect(origin: .zero, size: dialog.fittingSize)
        dialog.appearance = NSAppearance(named: .darkAqua)
        dialog.layoutSubtreeIfNeeded()
        if let bitmap = dialog.bitmapImageRepForCachingDisplay(in: dialog.bounds) {
            dialog.cacheDisplay(in: dialog.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: AppPaths.support.appendingPathComponent("profile-dialog.png"))
        }
    }

    /// A click in a pinned tab on a link to another site opens Peek; the
    /// card becomes a today tab with the same page.
    private func peekTest() {
        guard let pinned = browser.state.space.pinned.allTabs.first(where: { $0.currentURL.contains("example.com") }) else {
            return expect(false, "a pinned example.com tab for Peek")
        }
        browser.select(pinned)
        expect(!PeekController.sameSite("https://example.com/a", "https://www.iana.org")
               && PeekController.sameSite("https://gist.github.com", "https://github.com/x")
               && PeekController.sameSite("https://a.bbc.co.uk", "https://www.bbc.co.uk"), "Peek tells sites apart")
        after(2.5) {
            pinned.pane?.executeJavaScript("document.querySelector('a[href]').click()", userGesture: true)
        }
        after(5) {
            self.expect(self.browser.peek.isOpen && self.browser.peek.model.url.contains("iana.org")
                        && pinned.currentURL.contains("example.com"),
                        "a link in a pinned tab to another site opens in Peek (\(self.browser.peek.model.url))")
            self.browser.peek.openAsTab()
            let active = self.browser.state.activeItem
            self.expect(!self.browser.peek.isOpen && active?.role == .today && active?.currentURL.contains("iana.org") == true,
                        "Peek becomes a tab with the same page")
            if let active { self.browser.close(active) }
        }
    }

    /// ⌘N opens a window on the same tabs; a tab moves to the window that
    /// shows it; closing the window hands its tabs back. A private window
    /// keeps no history, uses an in-memory profile and takes its tabs along.
    private func windowsTest() {
        guard let app = NSApp.delegate as? AppDelegate, let shown = browser.state.activeItem else {
            return expect(false, "a tab to share between windows")
        }
        let second = app.openWindow(isPrivate: false)
        second.commandBar.hide()
        expect(app.browsers.count == 2 && second.state.space === browser.state.space, "⌘N opens a second window on the same space")
        second.select(shown)
        expect(second.shownTabs.contains { $0 === shown } && !browser.shownTabs.contains { $0 === shown }
               && shown.pane?.window?.parent === second.window && browser.state.activeItem == nil,
               "a tab moves to the window that shows it")
        second.window?.performClose(nil)
        expect(app.browsers.count == 1 && shown.pane?.delegate === browser && shown.pane != nil,
               "closing the second window keeps its tabs open for the first")
        browser.select(shown)
        expect(shown.pane?.window?.parent === browser.window, "the tab shows in the first window again")

        let privateWindow = app.openWindow(isPrivate: true)
        privateWindow.commandBar.hide()
        let tab = privateWindow.openInNewTab("https://example.com/private-window")
        after(3) {
            self.expect(tab.pane?.profile.directoryName == "" && self.library.space(containing: tab) == nil
                        && self.browser.history.search("private-window", limit: 5).isEmpty && tab.currentURL.contains("private-window"),
                        "a private window loads pages in its own profile without history")
            // The focus goes into the private window's page (a tab's window,
            // which never becomes main): ⌘W acts there, not in the window
            // that had the focus before.
            if let first = self.browser.window, let page = tab.pane?.window {
                app.windowBecameKey(first)
                app.windowBecameKey(page)
            }
            app.closeTab(nil)
            self.expect(tab.pane == nil && app.browsers.count == 2 && privateWindow.state.activeItem == nil,
                        "⌘W closes the tab in the window with the focus, the private window's last one; the window stays")
            privateWindow.closeActiveTab()
            self.expect(app.browsers.count == 1, "⌘W without a tab closes the window")
        }
    }

    // MARK: Sharing

    /// A folder as a snapshot link, opened again and added as a folder and as
    /// a space; both windows rendered to look at. With --relay <url>, also a
    /// live share, owned and followed in this library.
    private func sharingTest() {
        let space = browser.state.space
        let sharing = Sharing.shared
        sharing.start(library)
        let folder = Item.folder("Lesestoff", children: [.tab(url: "https://example.com/a", title: "Artikel A"),
                                                         .tab(url: "https://example.org/b", title: "Artikel B")])
        space.pinned.insert(folder, at: 0)
        Task { @MainActor in
            do {
                let link = try await sharing.snapshotLink(for: .folder(folder), password: nil)
                self.expect(ShareURL(url: link.url) == link && ShareURL(url: link.appURL) == link, "a snapshot link reads back, as https:// and as openarch://")
                self.expect(Sharing.nodes(Item(id: UUID(), kind: .agent)).isEmpty, "agent chats are not shared")
                let opened = try await ShareReader.open(link)
                self.expect(opened.version == nil && opened.payload.name == "Lesestoff" && opened.payload.allTabs.map(\.url) == ["https://example.com/a", "https://example.org/b"],
                            "the snapshot holds the folder and its tabs")

                sharing.add(opened, asSpace: false, follow: false, in: space, browser: nil)
                let copy = space.pinned.items.first
                self.expect(copy !== folder && copy?.displayTitle == "Lesestoff" && copy?.children.map(\.savedURL) == ["https://example.com/a", "https://example.org/b"],
                            "added as a folder, first in the space")
                self.expect(copy?.children.first?.id != folder.children.first?.id, "a copy gets its own IDs")
                self.expect(sharing.records.subscriptions.isEmpty, "a snapshot is not followed")
                copy?.detach()

                let spaces = self.library.spaces.count
                sharing.add(opened, asSpace: true, follow: false, in: space, browser: nil)
                let added = self.library.spaces.last
                self.expect(self.library.spaces.count == spaces + 1 && added?.name == "Lesestoff" && added?.pinned.allTabs.count == 2,
                            "added as a space of its own")
                self.expect(added?.profileID == space.profileID, "with the profile of the space it came from")
                if let added { self.library.removeSpace(added) }

                let locked = try await sharing.snapshotLink(for: .folder(folder), password: "geheim")
                do {
                    _ = try await ShareReader.open(locked, password: "falsch")
                    self.expect(false, "a wrong password is refused")
                } catch {
                    self.expect(error as? ShareError == .wrongPassword, "a wrong password is refused")
                }
                let unlocked = try await ShareReader.open(locked, password: "geheim")
                self.expect(unlocked.payload.allTabs.count == 2, "the right password opens it")

                if let app = NSApp.delegate as? AppDelegate {
                    await self.renderShare(ShareWindows.shareContent(.folder(folder), app: app), "share-window")
                    await self.renderShare(ShareWindows.importContent(link, app: app), "import-window")
                    await self.renderShare(ShareWindows.importContent(locked, app: app), "import-password-window")
                }
                if let index = CommandLine.arguments.firstIndex(of: "--relay"), index + 1 < CommandLine.arguments.count {
                    try await self.liveShare(of: folder, in: space, relay: CommandLine.arguments[index + 1])
                }
            } catch {
                self.expect(false, "sharing: \(error)")
            }
            folder.detach()
            self.library.setNeedsSave()
        }
    }

    /// A window's content, in a window of its own off screen so that its
    /// tasks run, without taking the focus.
    private func renderShare(_ view: some View, _ name: String) async {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 440, height: 560), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderBack(nil)
        try? await Task.sleep(for: .seconds(1.5))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let url = AppPaths.support.appendingPathComponent("\(name).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            Swift.print("[selftest] \(name) rendered to \(url.path)")
        }
        window.close()
    }

    private func liveShare(of folder: Item, in space: Space, relay: String) async throws {
        let sharing = Sharing.shared
        library.settings.shareRelay = relay
        defer { library.settings.shareRelay = "" }
        let share = try await sharing.makeLiveShare(for: .folder(folder), password: nil)
        expect(share.version == 1 && share.link.isLive, "the folder is uploaded as version 1")
        Swift.print("[selftest] live link \(share.link.appURL.absoluteString)")
        let opened = try await ShareReader.open(share.link)
        expect(opened.version == 1 && opened.payload.allTabs.count == 2, "the live link opens from the relay")
        if let app = NSApp.delegate as? AppDelegate {
            await renderShare(ShareWindows.shareContent(.folder(folder), app: app), "share-window-live")
            await renderShare(ShareWindows.importContent(share.link, app: app), "import-window-live")
        }

        sharing.add(opened, asSpace: false, follow: true, in: space, browser: nil)
        guard let followed = space.pinned.items.first, followed !== folder, sharing.subscription(followed.id)?.id == share.id else {
            return expect(false, "the link is added and followed")
        }
        expect(followed.children.count == 2, "the link is added and followed")

        // A new tab in the original goes up with the next save…
        space.pinned.insert(Item.tab(url: "https://example.net/live", title: "Live-Änderung"), into: folder)
        library.save()
        let uploaded = await changed { sharing.owned(folder.id)?.version == 2 }
        expect(uploaded, "a change is uploaded as version 2 (\(sharing.lastError ?? "no error"))")
        // … and comes down with the next check.
        await sharing.refresh()
        expect(followed.children.contains { $0.savedURL == "https://example.net/live" }, "the followed folder shows the new tab")
        expect(sharing.subscription(followed.id)?.version == 2, "at version 2")
        let kept = followed.children.first?.id

        folder.customTitle = "Lesestoff neu"
        folder.children.last?.detach()
        library.save()
        _ = await changed { sharing.owned(folder.id)?.version == 3 }
        await sharing.refresh()
        expect(followed.displayTitle == "Lesestoff neu", "a rename comes down")
        expect(!followed.children.contains { $0.savedURL == "https://example.net/live" }, "a removed tab goes away")
        expect(followed.children.first?.id == kept, "tabs that stay keep their identity")

        try await sharing.end(share)
        expect(sharing.owned(folder.id) == nil, "ending forgets the share")
        do {
            _ = try await ShareReader.open(share.link)
            expect(false, "an ended link shows nothing")
        } catch {
            expect(error as? ShareError == .ended, "an ended link shows nothing (\(error))")
        }
        await sharing.refresh()
        expect(sharing.subscription(followed.id)?.ended == true, "the follower sees that it ended")
        expect(followed.children.first?.id == kept, "and keeps the last state")
        sharing.unsubscribe(followed.id)
        followed.detach()
    }

    /// Waits up to 15 seconds for |condition|.
    private func changed(_ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    /// The other end of a test across devices: a live share that changes on a
    /// signal, printing its link.
    private func shareOwner(relay: String, signals: URL) {
        populate()
        let sharing = Sharing.shared
        sharing.start(library)
        library.settings.shareRelay = relay
        let space = browser.state.space
        let folder = Item.folder("Vom Mac", children: [.tab(url: "https://example.com/mac", title: "Mac-Lesezeichen")])
        space.pinned.insert(folder, at: 0)
        func signal(_ name: String) async {
            while !FileManager.default.fileExists(atPath: signals.appendingPathComponent(name).path) {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        Task { @MainActor in
            do {
                let share = try await sharing.makeLiveShare(for: .folder(folder), password: nil)
                Swift.print("[selftest] live fragment \(share.link.fragment)")
                fflush(stdout)
                await signal("update")
                space.pinned.insert(Item.tab(url: "https://example.org/vom-mac", title: "Neu vom Mac"), into: folder)
                self.library.save()
                let uploaded = await self.changed { sharing.owned(folder.id)?.version == 2 }
                Swift.print("[selftest] updated \(uploaded) \(sharing.lastError ?? "")")
                fflush(stdout)
                await signal("end")
                if let current = sharing.owned(folder.id) { try await sharing.end(current) }
                Swift.print("[selftest] ended")
            } catch {
                Swift.print("[selftest] FAIL \(error)")
            }
            fflush(stdout)
            Self.quit()
        }
    }

    private var boostChecks: [String] = []

    /// A boost recolors the page background and zaps the paragraphs, live and
    /// again after a reload; deleting it restores the page.
    private func boostTest() {
        guard let tab = browser.state.activeItem, let editor = BoostPanelController.show(for: tab, browser: browser)?.model else {
            return expect(false, "the boost editor opens")
        }
        let probe = "console.debug('__selftest_boost__ ' + getComputedStyle(document.body).backgroundColor + ' ' + getComputedStyle(document.querySelector('p') || document.body).display)"
        let boosted = "rgb(1, 2, 3) none"
        // Asks the page until its answer is |wanted| (or not, with |not|).
        func probeUntil(_ matches: @escaping (String) -> Bool, then report: @escaping (Bool) -> Void) {
            boostChecks = []
            eventually({ [self] in
                tab.pane?.executeJavaScript(probe)
                return boostChecks.last.map(matches) ?? false
            }, timeout: 6, then: report)
        }
        editor.boost.css = "body { background: rgb(1, 2, 3) !important; }"
        editor.zapped("p")
        probeUntil({ $0 == boosted }) { live in
            tab.pane?.reload()
            after(1) {
                probeUntil({ $0 == boosted }) { reloaded in
                    self.expect(live && reloaded, "a boost restyles the page live and after reloading (\(self.boostChecks.last ?? "no answer"), \(tab.currentURL))")
                    editor.delete()
                    probeUntil({ !$0.hasPrefix("rgb(1, 2, 3)") }) { restored in
                        self.expect(restored, "deleting the boost restores the page (\(self.boostChecks.last ?? "no answer"))")
                    }
                }
            }
        }
    }

    func consoleMessage(_ message: String, from item: Item?) {
        if message.hasPrefix("__selftest_boost__ ") {
            boostChecks.append(String(message.dropFirst("__selftest_boost__ ".count)))
            return
        }
        if message.hasPrefix("[selftest-probe]") || message.hasPrefix("[probe] checks") {
            Swift.print("[selftest] \(item?.displayTitle ?? "?"): \(message)")
            if message.hasPrefix("[selftest-probe]"), message.contains("\"tabs\"") {
                expect(!message.contains("\"tabs\":\"0 tab(s)\""), "extension sees the tab via chrome.tabs")
            }
        }
    }
}
