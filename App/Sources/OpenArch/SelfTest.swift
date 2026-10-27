import AppKit
import CommonCrypto
import SQLite3
import SwiftUI
import OpenArchCore

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

    func start() {
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
            if let item = library.spaces.first?.today.items.first { browser.select(item) }
            return
        }
        if CommandLine.arguments.contains("--marketing") {
            marketingScreens()
            return
        }
        populate()
        let steps: [(Double, String, () -> Void)] = [
            (0.5, "today tab", { self.selectToday() }),
            (6, "command bar", { self.commandBar() }),
            (9, "split view", { self.split() }),
            (15, "second space", { self.secondSpace() }),
            (18, "shortcuts", { self.shortcuts() }),
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
            (36.4, "menus", { self.menus() }),
            (36.6, "arc crypto", { self.arcCrypto() }),
            (36.8, "little openarch", { self.littleOpenArch() }),
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
            after(45) {
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
        after(CommandLine.arguments.contains("--arc") ? 49 : 44) {
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

    private func closeAndReopen() {
        guard let first = library.spaces.first else { return }
        browser.switchSpace(to: first)
        let before = first.today.allTabs.count
        guard let tab = first.today.allTabs.first(where: { $0.split == nil }) ?? first.today.allTabs.first else { return }
        browser.select(tab)
        browser.closeActiveTab()
        expect(first.today.allTabs.count == before - 1, "closing a today tab removes it")
        browser.reopenClosedTab()
        expect(first.today.allTabs.count == before, "⌘⇧T reopens it")
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

    /// Plays a tone in a tab that was muted first (so nothing is heard) and
    /// checks that the sidebar learns about it.
    private func audioIndicator() {
        guard let space = library.spaces.first else { return }
        browser.switchSpace(to: space)
        let tab = browser.openInNewTab("https://example.com/audio")
        after(2) {
            self.browser.toggleMute(tab)
            tab.pane?.executeJavaScript("""
                window.__tone = new AudioContext();
                const osc = window.__tone.createOscillator();
                osc.connect(window.__tone.destination);
                osc.start();
                """)
            after(3) {
                self.expect(tab.isAudible && tab.isMuted, "a muted tab playing sound shows the speaker (audible \(tab.isAudible), muted \(tab.isMuted))")
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

    func consoleMessage(_ message: String, from item: Item?) {
        if message.hasPrefix("[selftest-probe]") || message.hasPrefix("[probe] checks") {
            Swift.print("[selftest] \(item?.displayTitle ?? "?"): \(message)")
            if message.hasPrefix("[selftest-probe]"), message.contains("\"tabs\"") {
                expect(!message.contains("\"tabs\":\"0 tab(s)\""), "extension sees the tab via chrome.tabs")
            }
        }
    }
}
