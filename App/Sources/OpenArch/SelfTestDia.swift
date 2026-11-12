import AppKit
import OpenArchLocalization
import OpenArchCore

/// Checks for the features taken from Dia: "new doc" in the command bar,
/// reopening a closed window, grain, tab previews, shortcuts of your own,
/// screen sharing, CI checks in live folders and the meeting card.
/// `--selftest --dia-test` runs only these.
extension SelfTest {
    func diaFeatures(then done: @escaping () -> Void) {
        quickCreateTest()
        ownShortcutsTest()
        grainTest()
        checksTest()
        meetingTest()
        screenShareTest {
            self.tabPreviewTest {
                self.reopenWindowTest(then: done)
            }
        }
    }

    private func quickCreateTest() {
        let model = browser.commandBar.model
        browser.commandBar.show(mode: .newTab)
        model.query = "new doc"
        let first = model.results.first
        expect(first?.title == L("Neues Google-Dokument") && first?.badge == L("Erstellen"),
               "„new doc“ in the command bar offers a new Google doc first (\(first?.title ?? "nothing"))")
        model.query = "neue tabelle"
        expect(model.results.first?.title == L("Neue Google-Tabelle"), "„neue tabelle“ offers a new sheet first")
        model.query = "new"
        expect(!model.results.contains { $0.id.hasPrefix("create:") }, "„new“ alone offers no new documents")
        expect(QuickCreate.matching("new ticket") { "acme.atlassian.net" }.first?.url
               == "https://acme.atlassian.net/secure/CreateIssue!default.jspa",
               "„new ticket“ makes a ticket on the company's Jira from the history")
        browser.commandBar.hide()
    }

    private func ownShortcutsTest() {
        guard let app = NSApp.delegate as? AppDelegate else { return expect(false, "the app delegate") }
        expect(KeyShortcut(string: "$@t")?.display == "⇧⌘T" && KeyShortcut(string: "^~k")?.string == "^~k",
               "shortcuts are stored and shown like macOS's own")
        let id = "toggleLibrary:#0"
        expect(MainMenu.commands.contains { $0.id == id && $0.defaultShortcut?.display == "⇧⌘L" },
               "Settings › Tastatur lists the menu's commands with their shortcuts (\(MainMenu.commands.count))")
        library.settings.shortcuts[id] = "^@k"
        app.rebuildMenu()
        let new = keyEvent("k", keyCode: 40, [.command, .control])
        let old = keyEvent("l", keyCode: 37, [.command, .shift])
        let toggleLibrary = #selector(AppDelegate.toggleLibrary(_:))
        if let menu = NSApp.mainMenu, let new, let old {
            expect(ShortcutMonitor.item(in: menu, matching: new, target: app)?.action == toggleLibrary
                   && ShortcutMonitor.item(in: menu, matching: old, target: app)?.action != toggleLibrary,
                   "a shortcut of your own replaces the command's own (⌃⌘K for Bibliothek)")
            var recorded: NSEvent?
            ShortcutRecorder.shared.start { recorded = $0 }
            let handled = ShortcutMonitor.handle(new, target: app)
            ShortcutRecorder.shared.stop()
            expect(handled && recorded === new && !browser.state.libraryVisible,
                   "while a shortcut is recorded, the keys go to the recorder and run nothing")
        } else {
            expect(false, "key events for the shortcut test")
        }
        library.settings.shortcuts = [:]
        app.rebuildMenu()
    }

    private func keyEvent(_ key: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: browser.window?.windowNumber ?? 0, context: nil, characters: key,
                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)
    }

    private func grainTest() {
        let space = browser.state.space
        space.theme.grain = 0.6
        browser.applyTheme()
        expect(browser.grainAmount == 0.6, "the space's theme gets Arc's grain")
        space.theme.grain = 0
        browser.applyTheme()
        expect(browser.grainAmount == 0, "and none at zero")
    }

    private func checksTest() {
        expect(LiveFolders.pullPath("https://github.com/cli/cli/pull/14964/files") == "/cli/cli/pull/14964"
               && LiveFolders.pullPath("https://github.com/cli/cli/issues/3") == nil,
               "a live folder's pull request has its path for the checks")
        let sha = "dab49c4e4a2c5b75c27cd8bae26fbb0970316364"
        let channel = Data(#"{"c":"repo:1:commit:\#(sha)","t":1}"#.utf8).base64EncodedString() + "--signature"
        let commits = #"{"payload":{"pullRequestsCommitsRoute":{"metadata":{"commitHeadShaChannel":"\#(channel)"},"commitGroups":[{"commits":[{"oid":"1111"}]}]}}}"#
        let plain = #"{"payload":{"pullRequestsCommitsRoute":{"metadata":{},"commitGroups":[{"commits":[{"oid":"aaaa"},{"oid":"bbbb"}]}]}}}"#
        expect(LiveFolders.headSHA(fromCommits: Data(commits.utf8)) == sha
               && LiveFolders.headSHA(fromCommits: Data(plain.utf8)) == "bbbb",
               "the newest commit of a pull request comes from GitHub's commit list")
        let icon = { (octicon: String, label: String) in
            #"<summary class="color-fg-success"><svg aria-label="\#(label)" role="img" class="octicon \#(octicon)"></svg></summary><svg class="anim-rotate"></svg>"#
        }
        expect(LiveFolders.checks(fromStatusIcon: icon("octicon-check", "9 / 15 checks OK")) == Checks(state: .success, label: "9 / 15 checks OK")
               && LiveFolders.checks(fromStatusIcon: icon("octicon-x", "2 / 5 checks OK"))?.state == .failure
               && LiveFolders.checks(fromStatusIcon: icon("octicon-dot-fill", "0 / 3 checks OK"))?.state == .pending
               && LiveFolders.checks(fromStatusIcon: "<div></div>") == nil,
               "GitHub's status icon reads as passed, failed or running")
    }

    private func meetingTest() {
        expect(Meetings.joinURL(in: [nil, "Zoom: https://us02web.zoom.us/j/123?pwd=x).", "https://meet.google.com/abc"])
               == "https://us02web.zoom.us/j/123?pwd=x"
               && Meetings.joinURL(in: ["Raum 3", "Details: https://meet.google.com/abc-defg-hij\nBis dann"])
               == "https://meet.google.com/abc-defg-hij"
               && Meetings.joinURL(in: ["https://example.com/agenda"]) == nil,
               "the video call link is found in an invitation")
        let meetings = Meetings.shared
        meetings.tick()
        let now = meetings.now
        let running = Meetings.Meeting(id: "running", title: "Läuft", start: now - 600, end: now + 600, joinURL: nil)
        let soon = Meetings.Meeting(id: "soon", title: "Gleich", start: now + 300, end: now + 1200, joinURL: nil)
        let later = Meetings.Meeting(id: "later", title: "Später", start: now + 2400, end: now + 3600, joinURL: nil)
        expect(meetings.pick(from: [running, soon, later])?.id == "soon" && meetings.pick(from: [running, later])?.id == "running"
               && meetings.pick(from: [later])?.id == "later",
               "the card shows the meeting starting within ten minutes, else the running one, else the next")

        browser.toast?.orderOut(nil)
        let call = Meetings.Meeting(id: "selftest", title: "Selftest-Call", start: Date().addingTimeInterval(50),
                                    end: Date().addingTimeInterval(1800), joinURL: "https://example.com/selftest-call")
        meetings.testMeeting = call
        expect(meetings.current == call && meetings.countdown(for: call) == "beginnt jetzt" && browser.toast?.isVisible == true,
               "the meeting card shows the next call, and a toast says it begins shortly before")
        browser.joinMeeting(call)
        let today = browser.state.space.today
        let folder = today.items.first
        let tab = folder?.children.first
        expect(folder?.kind == .folder && folder?.displayTitle == "📹 Selftest-Call"
               && tab?.currentURL.hasPrefix("https://example.com/selftest-call") == true && browser.state.activeItem === tab,
               "joining opens the call in a folder of its own, under the line")
        if let tab {
            let link = browser.openInNewTab("https://example.com/from-the-call", after: tab, select: false)
            expect(link.parentFolder === folder, "links opened from the call land in its folder")
        }
        browser.joinMeeting(call)
        expect(today.items.filter { $0.displayTitle == "📹 Selftest-Call" }.count == 1 && browser.state.activeItem === tab,
               "joining again goes back to the call")
        meetings.testMeeting = nil
        browser.toast?.orderOut(nil)
        if let folder {
            for child in folder.children { browser.close(child) }
            folder.detach()
            library.setNeedsSave()
        }
    }

    /// A call reporting a shared tab shows which one, and the card goes when
    /// it stops. WebKit has no capture handles, so pages name themselves no
    /// longer: the share shows its sharer without a named tab.
    private func screenShareTest(then done: @escaping () -> Void) {
        guard let shared = browser.state.space.today.allTabs.first(where: { $0.pane != nil }) else {
            expect(false, "a loaded tab to share")
            return done()
        }
        let call = browser.openInNewTab("https://example.com/share-call", select: false)
        browser.select(call, focus: false)
        eventually({ call.pane != nil }, timeout: 5) { loaded in
            self.expect(loaded && shared.captureHandle == nil,
                        "WebKit names no page for tab sharing (\(shared.captureHandle ?? "none"))")
            guard let pane = call.pane else { return done() }
            self.browser.pane(pane, consoleMessage: #"__openarch_capture__ {"surface":"browser","handle":""}"#,
                              source: "", line: 0)
            let share = self.browser.screenShare
            self.expect(call.screenShare?.surface == "browser" && share?.sharer === call && share?.shared == nil
                        && !self.browser.isBeingShared(shared),
                        "a call sharing shows its sharer (WebKit names no shared tab)")
            // A picture of the sidebar with the sharing and meeting cards.
            Meetings.shared.testMeeting = Meetings.Meeting(id: "picture", title: "Weekly", start: Date().addingTimeInterval(240),
                                                           end: Date().addingTimeInterval(3600), joinURL: "https://example.com/weekly")
            self.render(self.browser.window?.contentView, to: "dia-sidebar.png")
            Meetings.shared.testMeeting = nil
            self.browser.pane(pane, consoleMessage: #"__openarch_capture__ {"surface":"monitor","handle":""}"#, source: "", line: 0)
            self.expect(self.browser.screenShare?.sharer === call && self.browser.screenShare?.shared == nil
                        && !self.browser.isBeingShared(shared), "sharing the whole screen names no tab")
            self.browser.pane(pane, consoleMessage: "__openarch_capture__ null", source: "", line: 0)
            self.expect(call.screenShare == nil && self.browser.screenShare == nil, "the card goes when sharing ends")
            self.browser.close(call)
            done()
        }
    }

    private func tabPreviewTest(then done: @escaping () -> Void) {
        let preview = browser.tabPreview
        preview.delay = 0
        let sidebar = browser.state.sidebarFrame
        guard let target = browser.orderedTabs.first(where: { $0 !== browser.state.activeItem }),
              !sidebar.isEmpty, let parent = browser.window else {
            expect(false, "a tab to preview")
            return done()
        }
        let row = CGRect(x: sidebar.minX + 8, y: sidebar.minY + 220, width: sidebar.width - 16, height: 34)
        preview.hover(target, row: row, inside: true)
        after(0.6) {
            let window = NSApp.windows.first { $0 is TabPreviewWindow }
            let page = self.browser.activePane?.window
            let left = parent.frame.minX + self.browser.sidebarWidth + 4
            let size = window?.frame.size ?? .zero
            self.expect(preview.isShown && window != nil && abs((window?.frame.minX ?? 0) - left) < 2
                        && size.width > TabPreviewCard.width && size.height > 150
                        && (page == nil || window!.orderedIndex < page!.orderedIndex),
                        "resting on a tab shows its preview beside the sidebar, above the page (\(Int(window?.frame.minX ?? 0)) vs \(Int(left)), \(Int(size.width))×\(Int(size.height)))")
            self.render(window?.contentView, to: "tab-preview.png")
            preview.hover(target, row: row, inside: false)
            after(0.4) {
                self.expect(!preview.isShown, "and it goes when the pointer leaves")
                preview.delay = 0.6
                done()
            }
        }
    }

    private func render(_ view: NSView?, to name: String) {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return Swift.print("[selftest] nothing to render for \(name)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = AppPaths.support.appendingPathComponent(name)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        Swift.print("[selftest] rendered \(url.path)")
    }

    private func reopenWindowTest(then done: @escaping () -> Void) {
        guard let app = NSApp.delegate as? AppDelegate else { return done() }
        ClosedWindows.shared.forget()
        let tab = browser.openInNewTab("https://example.com/reopen-window", select: false)
        guard let separate = browser.openInSeparateWindow(tab, at: nil), let frame = separate.window?.frame else {
            expect(false, "a window of its own to close")
            return done()
        }
        separate.openInNewTab("https://example.com/reopen-window-2", select: false)
        let urls = separate.state.space.today.allTabs.map(\.currentURL)
        separate.window?.performClose(nil)
        expect(!app.browsers.contains { $0 === separate } && !ClosedWindows.shared.isEmpty, "a closed window is remembered")
        app.reopenTab(nil)
        let reopened = app.browsers.last
        let restored = reopened?.window?.frame ?? .zero
        expect(reopened !== separate && reopened?.isSeparate == true && reopened?.state.space.today.allTabs.map(\.currentURL) == urls
               && abs(restored.minX - frame.minX) < 2 && abs(restored.maxY - frame.maxY) < 2
               && !library.archive.contains { urls.contains($0.url) },
               "⌘⇧T brings the closed window back where it was, with its tabs in order (\(reopened?.state.space.today.allTabs.map(\.currentURL) ?? []))")
        after(1) {
            reopened?.window?.performClose(nil)
            ClosedWindows.shared.forget()
            done()
        }
    }
}
