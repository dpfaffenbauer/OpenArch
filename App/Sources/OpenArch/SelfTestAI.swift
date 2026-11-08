import AppKit
import OpenArchCore

/// The self-test of the AI features (chat with the page, skills, the
/// morning brief, tidying tabs), with a stand-in for claude. `--ai-test`
/// runs only these.
extension SelfTest {
    func aiFeatures(then next: @escaping () -> Void) {
        let stub = ClaudeStub()
        AgentEnvironment.stub = AgentEnvironment.Resolved(claude: stub.executable.path, variables: ProcessInfo.processInfo.environment)
        let steps: [(String, (@escaping () -> Void) -> Void)] = [
            ("page chat", { self.pageChatTest(stub, then: $0) }),
            ("browser tools", { self.browserToolsTest(stub, then: $0) }),
            ("skills", { self.skillsTest(stub, then: $0) }),
            ("morning brief", { self.morningBriefTest(stub, then: $0) }),
            ("tidy tabs", { self.tidyTest(stub, then: $0) }),
            ("ai settings", { self.aiSettingsShot(then: $0) }),
        ]
        func run(_ index: Int) {
            guard index < steps.count else {
                AgentEnvironment.stub = nil
                stub.remove()
                return next()
            }
            Swift.print("[selftest] STEP \(steps[index].0)")
            steps[index].1 { run(index + 1) }
        }
        run(0)
    }

    /// Settings › KI with the morning brief, for a picture (--shots).
    private func aiSettingsShot(then next: @escaping () -> Void) {
        guard CommandLine.arguments.contains("--shots"), let app = NSApp.delegate as? AppDelegate else { return next() }
        app.showSettings(page: .ai)
        shot("settings", of: app.settingsWindow) {
            app.settingsWindow?.close()
            next()
        }
    }

    /// The command bar lists your Claude Code skills and commands by name
    /// and runs one on the page, in the page's chat.
    fileprivate func skillsTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
        let root = stub.folder.appendingPathComponent("claude-config", isDirectory: true)
        let files: [String: String] = [
            "skills/zusammenfassen/SKILL.md": """
                ---
                name: zusammenfassen
                description: >
                  Fasst eine Seite in fünf Punkten
                  zusammen.
                metadata:
                  type: test
                ---
                # Zusammenfassen
                """,
            "skills/ohne-datei/README.md": "Kein Skill",
            "commands/tldr.md": "---\ndescription: \"Kurz und knapp\"\n---\nSchreib eine Kurzfassung von $ARGUMENTS\n",
            "commands/team/standup.md": "# Bereite das Standup vor.\n\nMehr dazu.\n",
        ]
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        let skills = ClaudeSkills.load(root: root)
        expect(skills.map(\.name) == ["standup", "tldr", "zusammenfassen"]
               && skills.map(\.description) == ["Bereite das Standup vor.", "Kurz und knapp", "Fasst eine Seite in fünf Punkten zusammen."]
               && skills.map(\.kind) == [.command, .command, .skill],
               "skills and commands are read with their names and descriptions (\(skills.map { "\($0.name): \($0.description)" }))")
        let originalRoot = ClaudeSkills.root
        ClaudeSkills.root = root
        stub.answer([ClaudeStub.initEvent(session: "selftest-skill"), ClaudeStub.textEvent("- Punkt eins"),
                     ClaudeStub.resultEvent(session: "selftest-skill")])
        let shown = browser.state.activeItem
        let tab = browser.openInNewTab("https://example.com/?skill")
        after(2.5) {
            let bar = self.browser.commandBar
            bar.show(mode: .newTab)
            bar.model.query = "zusam"
            let row = bar.model.results.first { $0.title == "/zusammenfassen" }
            self.expect(row?.subtitle == "Skill · Fasst eine Seite in fünf Punkten zusammen.",
                        "typing a skill's name lists it in the command bar (\(bar.model.results.map(\.title)))")
            bar.model.query = "/"
            self.expect(bar.model.results.prefix(3).map(\.title) == ["/standup", "/tldr", "/zusammenfassen"],
                        "a / lists the skills and commands first")
            bar.model.query = "/zusam"
            bar.model.run(0)
            self.eventually({ tab.pageChat?.session.messages.count ?? 0 >= 2 && tab.pageChat?.session.isRunning == false }, timeout: 10) { ran in
                let prompt = stub.lastPrompt
                let message = tab.pageChat?.session.messages.first
                self.expect(ran && tab.pageChat?.isOpen == true
                            && prompt.hasPrefix("/zusammenfassen <page url=\"https://example.com/?skill\"")
                            && prompt.hasSuffix("Wende das auf diese Seite an.")
                            && message?.text == "/zusammenfassen" && message?.attachments?.first?.kind == .page,
                            "choosing it runs the skill on the page, in the page's chat (\(prompt.prefix(60)))")
                ClaudeSkills.root = originalRoot
                self.browser.close(tab)
                if let shown, shown.container != nil { self.browser.select(shown, focus: false) }
                next()
            }
        }
    }

    /// ⌘E opens a chat beside the page that gets the page, the selection
    /// and a tab named with @, continues its session, closes with ⌘E and
    /// keeps its conversation until the tab closes.
    fileprivate func pageChatTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
        guard let app = NSApp.delegate as? AppDelegate, let space = library.spaces.first else { return next() }
        browser.switchSpace(to: space)
        let shown = browser.state.activeItem
        let tab = browser.openInNewTab("https://example.com/?chat")
        let other = browser.openInNewTab("https://example.org/?mention", select: false)
        browser.select(tab, focus: false)
        stub.answer([ClaudeStub.initEvent(session: "selftest-page"),
                     ClaudeStub.textEvent("Die Seite erklärt [Beispiele](https://example.com/more) und https://www.iana.org/domains."),
                     ClaudeStub.resultEvent(session: "selftest-page")])
        func pressE() {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: browser.window?.windowNumber ?? 0, context: nil,
                                               characters: "e", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14)
            else { return }
            _ = ShortcutMonitor.handle(event, target: app)
        }
        func finish() {
            if let shown, shown.container != nil { browser.select(shown, focus: false) }
            browser.close(other)
            next()
        }
        func select(_ text: String) {
            tab.pane?.executeJavaScript("""
                document.body.insertAdjacentHTML('afterbegin', '<h2 id="openarch-pick">\(text)</h2>');
                getSelection().selectAllChildren(document.getElementById('openarch-pick'));
                document.getElementById('openarch-pick').id = '';
                """)
        }
        after(2.5) {
            select("Gewählter Satz")
        }
        after(3) {
            let area = self.browser.contentAreaRect
            pressE()
            guard let chat = tab.pageChat else {
                self.expect(false, "⌘E opens a chat beside the page")
                return finish()
            }
            let panel = self.browser.pageChatHost.frame
            let page = self.browser.contentRect
            self.expect(chat.isOpen && self.browser.pageChatTab === tab && !self.browser.pageChatHost.isHidden
                        && panel.maxX == area.maxX && page.maxX < panel.minX && page.minX == area.minX,
                        "⌘E opens a chat right of the page, which makes room for it (page \(page), chat \(panel))")
            after(0.5) { self.checkPaneFrames("with the page chat open") }
            do {
                self.eventually({ chat.selection == "Gewählter Satz" }) { attached in
                    self.expect(attached && chat.isOpen, "text selected on the page is the chat's focus (\(chat.selection ?? "none"))")
                    let candidates = self.browser.pageChatMentionCandidates(for: tab, query: "mention")
                    self.expect(candidates.first === other && !self.browser.pageChatMentionCandidates(for: tab, query: "").contains { $0 === tab },
                                "@ lists the space's other tabs (\(candidates.map(\.displayTitle)))")
                    chat.mentions = [other]
                    chat.session.draft = "Worum geht es?"
                    self.browser.sendPageChat(tab)
                    self.eventually({ !chat.isPreparing && !chat.session.isRunning && chat.session.messages.count >= 2 }, timeout: 15) { answered in
                        let prompt = stub.lastPrompt
                        let arguments = stub.lastArguments
                        self.expect(answered && prompt.hasPrefix("<page url=\"https://example.com/?chat\" title=\"Example Domain\">")
                                    && prompt.contains("Gewählter Satz\n") && prompt.contains("<selection>\nGewählter Satz\n</selection>")
                                    && prompt.contains("<tab url=\"https://example.org/?mention\"") && prompt.hasSuffix("Worum geht es?"),
                                    "the chat sends the page's text, the selection and the tab named with @ (\(prompt.prefix(120)))")
                        self.expect(arguments.contains("beside a web page") && arguments.contains("--permission-mode\ndefault\n"),
                                    "a page chat tells Claude it sits beside a page, and asks before tools")
                        let sent = chat.session.messages.first
                        self.expect(sent?.text == "Worum geht es?" && sent?.attachments?.map(\.kind) == [.page, .selection, .tab]
                                    && chat.selection == nil && chat.mentions.isEmpty,
                                    "the message shows what went along with it, and the selection and tabs are used up")
                        let answer = chat.session.messages.last { $0.role == .assistant }?.text ?? ""
                        let links = MarkdownText.attributed(answer).runs.compactMap(\.link).map(\.absoluteString)
                        self.expect(links == ["https://example.com/more", "https://www.iana.org/domains"],
                                    "links in answers, also written out, are links (\(links))")
                        chat.session.draft = "Und sonst?"
                        self.browser.sendPageChat(tab)
                        self.eventually({ !chat.isPreparing && !chat.session.isRunning && chat.session.messages.count >= 4 }, timeout: 10) { _ in
                            self.expect(!stub.lastPrompt.contains("<page") && stub.lastPrompt == "Und sonst?"
                                        && stub.lastArguments.contains("--resume\nselftest-page\n"),
                                        "the next message continues the session without sending the page again")
                            select("Zweiter Satz")
                            after(0.5) { pressE() }
                            after(1.2) {
                                self.expect(chat.isOpen && chat.selection == "Zweiter Satz",
                                            "⌘E with other text selected keeps the chat open and takes that text (\(chat.selection ?? "none"))")
                                tab.pane?.executeJavaScript("getSelection().removeAllRanges()")
                            }
                            after(1.7) {
                                pressE()
                                self.eventually({ !chat.isOpen }) { closed in
                                    self.expect(closed && self.browser.pageChatHost.isHidden && self.browser.contentRect == self.browser.contentAreaRect,
                                                "⌘E closes the chat and the page gets its room back (open \(chat.isOpen), selection \(chat.selection ?? "none"))")
                                    self.browser.togglePageChat()
                                    self.expect(tab.pageChat === chat && chat.isOpen && chat.session.messages.count == 4,
                                                "the chat comes back with its conversation")
                                    if let pane = tab.pane { self.browser.pane(pane, askAboutSelection: "  Ausgewählter Text \n") }
                                    self.expect(chat.selection == "Ausgewählter Text", "„Claude fragen“ on selected text makes it the chat's focus")
                                    self.shot("page chat") {
                                        self.browser.close(tab)
                                        self.expect(tab.pageChat == nil && self.browser.pageChatHost.isHidden, "closing the tab ends its chat")
                                        finish()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension SelfTest {
    /// With --shots, names the window to take a picture of and waits for it.
    func shot(_ name: String, of window: NSWindow? = nil, then next: @escaping () -> Void) {
        guard CommandLine.arguments.contains("--shots"), let window = window ?? browser.window else { return next() }
        window.orderFrontRegardless()
        Swift.print("[selftest] SHOT \(name) \(window.windowNumber)")
        after(4) { next() }
    }
}

extension SelfTest {
    /// The morning brief: due once a day, made with the connectors' reading
    /// tools only, opened at the top of the today tabs with a dot, and a
    /// page that says so when claude is not signed in or not there.
    fileprivate func morningBriefTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
        let midnight = Calendar.current.startOfDay(for: Date())
        let seven = midnight.addingTimeInterval(7 * 3600), eight = midnight.addingTimeInterval(8 * 3600)
        expect(!MorningBrief.isDue(now: seven, minutes: 450, lastDay: nil) && MorningBrief.isDue(now: eight, minutes: 450, lastDay: nil)
               && MorningBrief.isDue(now: eight, minutes: 450, lastDay: "2000-01-01")
               && !MorningBrief.isDue(now: eight, minutes: 450, lastDay: MorningBrief.day(eight)),
               "the morning brief is due once a day, from its time on")
        let tools = ["Read", "Bash", "mcp__cal__list_events", "mcp__cal__create_event", "mcp__mail__searchThreads",
                     "mcp__mail__sendMessage", "mcp__tasks__get_today", "mcp__tasks__complete_item", "mcp__tasks__getOrCreateList",
                     "mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack__slack_send_message"]
        let reading = MorningBrief.readingTools(tools)
        expect(reading == ["mcp__cal__list_events", "mcp__mail__searchThreads", "mcp__tasks__get_today", "mcp__claude_ai_Slack__slack_read_channel"],
               "the brief gets only the connectors' reading tools (\(reading))")
        let waiting = MorningBrief.serversWithoutTools(["claude.ai Gmail": "connected", "chronos": "connected", "Figma": "pending",
                                                        "Notion": "needs-auth"],
                                                       tools: ["mcp__chronos__list_issues", "mcp__Figma__get_file"])
        expect(waiting == ["claude.ai Gmail"], "a connected server without tools yet is asked about again (\(waiting))")
        let html = "<!DOCTYPE html><html><head><title>Morning Brief</title></head><body><h1>Guten Morgen</h1></body></html>"
        stub.answer([ClaudeStub.initEvent(session: "selftest-brief", tools: tools), ClaudeStub.textEvent("Hier ist er."),
                     ClaudeStub.resultEvent(session: "selftest-brief", result: "Hier ist er:\n```html\n\(html)\n```")])
        guard let space = library.spaces.first else { return next() }
        browser.switchSpace(to: space)
        let shown = browser.state.activeItem
        func page(of tab: Item?) -> String {
            guard let url = tab.flatMap({ URL(string: $0.currentURL) }) else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        MorningBrief.shared.run(in: browser, manual: false)
        eventually({ !MorningBrief.shared.isRunning }, timeout: 10) { done in
            let tab = MorningBrief.tab(in: space)
            self.expect(done && tab != nil && tab === space.today.items.first && tab?.displayTitle == "Morning Brief"
                        && tab?.isUnread == true && page(of: tab) == html && self.browser.state.activeItem === shown,
                        "the brief opens as a tab at the top of the today tabs, with a dot and Claude's page (\(page(of: tab).prefix(60)))")
            let date = DateFormatter()
            date.locale = Locale(identifier: "de_DE")
            date.dateFormat = "EEEE, d. MMMM yyyy"
            self.expect(stub.lastArguments.contains("--allowedTools\n" + MorningBrief.readingTools(tools.sorted()).joined(separator: ",") + "\n")
                        && stub.lastPrompt.contains(date.string(from: Date())) && stub.lastPrompt.contains("<!DOCTYPE html>"),
                        "Claude is asked for today's brief as a page, with the reading tools allowed")
            guard let tab else { return next() }
            self.expect(Item(data: tab.data).isUnread, "the dot stays until the brief is read, also after a restart")
            self.browser.select(tab, focus: false)
            self.expect(!tab.isUnread, "reading the brief takes the dot away")
            stub.answer([ClaudeStub.initEvent(session: "selftest-brief"),
                         ClaudeStub.resultEvent(session: "selftest-brief", result: "Invalid API key · Please run /login", isError: true)])
            MorningBrief.shared.run(in: self.browser, manual: true)
            self.expect(self.browser.state.activeItem === tab && page(of: tab).contains("entsteht"),
                        "made from the command bar, the brief shows at once and says it is being made")
            self.eventually({ !MorningBrief.shared.isRunning }, timeout: 10) { _ in
                let briefs = space.today.allTabs.filter { $0.currentURL.hasPrefix(MorningBrief.folder.absoluteString) }
                self.expect(page(of: tab).contains("Claude Code ist nicht angemeldet.") && page(of: tab).contains("Please run /login")
                            && briefs.count == 1,
                            "without a login the brief tab says so plainly, and stays the only one")
                self.shot("morning brief") {
                    let saved = AgentEnvironment.stub
                    AgentEnvironment.stub = AgentEnvironment.Resolved(claude: nil, variables: [:])
                    MorningBrief.shared.run(in: self.browser, manual: false)
                    self.eventually({ !MorningBrief.shared.isRunning }, timeout: 5) { _ in
                        self.expect(page(of: tab).contains("Claude Code wurde nicht gefunden."),
                                    "without claude on the Mac the brief tab says so")
                        AgentEnvironment.stub = saved
                        self.browser.close(tab)
                        if let shown, shown.container != nil { self.browser.select(shown, focus: false) }
                        next()
                    }
                }
            }
        }
    }
}

extension SelfTest {
    /// Tidying with AI: Claude gets titles and addresses, the proposal shows
    /// first, applying makes folders at the top of the today tabs with
    /// shorter titles, pinned tabs stay, and ⌘Z puts it all back.
    fileprivate func tidyTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
        guard let space = library.spaces.first else { return next() }
        browser.switchSpace(to: space)
        let shown = browser.state.activeItem
        let mine = [
            Item.tab(url: "https://docs.swift.org/swift-book/concurrency", title: "Concurrency | The Swift Programming Language (6.2) | Documentation"),
            Item.tab(url: "https://developer.apple.com/documentation/appkit/nspanel", title: "NSPanel | Apple Developer Documentation"),
            Item.tab(url: "https://www.tagesschau.de/", title: "tagesschau.de - die erste Adresse für Nachrichten und Information"),
            Item.tab(url: "https://www.spiegel.de/", title: "DER SPIEGEL | Online-Nachrichten"),
        ]
        for tab in mine.reversed() { space.today.insert(tab, at: 0) }
        let tabs = TabTidy.tabs(in: space)
        let number = { (tab: Item) in (tabs.firstIndex { $0 === tab } ?? -10) + 1 }
        let answer = """
            ```json
            {"folders": [{"name": "📚 Doku", "tabs": [\(number(mine[0])), \(number(mine[1]))]},
                         {"name": "📰 News", "tabs": [\(number(mine[2])), "\(number(mine[3]))"]},
                         {"name": "Allein", "tabs": [\(number(mine[0]))]}],
             "titles": {"\(number(mine[0]))": "Swift Concurrency", "99": "Gibt es nicht"}}
            ```
            """
        stub.answer([ClaudeStub.initEvent(session: "selftest-tidy"), ClaudeStub.resultEvent(session: "selftest-tidy", result: answer)])
        let order = space.today.items.map(\.id)
        let pinned = space.pinned.allItems.map { "\($0.id) \($0.displayTitle) \($0.parent?.id.uuidString ?? "")" }
        func finish() {
            for tab in mine where tab.container != nil { browser.close(tab) }
            if let shown, shown.container != nil { browser.select(shown, focus: false) }
            next()
        }
        guard let tidy = browser.tidyTabsWithAI() else {
            expect(false, "Tabs mit KI aufräumen starts")
            return finish()
        }
        expect(tidy.window?.isVisible == true && tidy.phase == .working, "tidying shows a panel while Claude sorts")
        eventually({ tidy.phase != .working }, timeout: 10) { _ in
            let prompt = stub.lastPrompt
            self.expect(tidy.phase == .ready && tidy.folders.map(\.name) == ["📚 Doku", "📰 News"]
                        && tidy.folders[0].tabs.count == 2 && tidy.folders[1].tabs.map(\.id) == [mine[2].id, mine[3].id]
                        && tidy.title(of: mine[0]) == "Swift Concurrency" && tidy.looseTabs.count == tabs.count - 4,
                        "the proposal has Claude's folders and shorter titles, and the rest stays loose (\(tidy.phase), \(tidy.folders.map(\.name)))")
            self.expect(prompt.contains("\(number(mine[2])). tagesschau.de - die erste Adresse für Nachrichten und Information — https://www.tagesschau.de/")
                        && !prompt.contains("<page"),
                        "Claude gets only the tabs' titles and addresses")
            self.expect(space.today.items.map(\.id) == order, "nothing changes before the proposal is taken")
            self.shot("tidy proposal", of: tidy.window) {
                tidy.apply()
                let top = space.today.items
                let doku = top.first, news = top.count > 1 ? top[1] : nil
                self.expect(doku?.kind == .folder && doku?.displayTitle == "📚 Doku" && doku?.children.map(\.id) == [mine[0].id, mine[1].id]
                            && news?.displayTitle == "📰 News" && news?.children.count == 2
                            && mine[0].displayTitle == "Swift Concurrency" && tidy.window?.isVisible != true,
                            "applying puts the folders at the top of the today tabs, with the shorter titles")
                self.expect(space.pinned.allItems.map { "\($0.id) \($0.displayTitle) \($0.parent?.id.uuidString ?? "")" } == pinned,
                            "pinned tabs stay as they were")
                self.expect(self.browser.toast?.isVisible == true && TabTidy.lastUndo != nil, "a toast offers Rückgängig")
                self.shot("tidy applied") {
                    let undo = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: self.browser.window?.windowNumber ?? 0, context: nil,
                                                characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6)
                    // As the key monitor gets it, from wherever the focus is.
                    if let undo { self.expect(TabTidy.takesUndoKey(undo), "⌘Z is taken while the toast shows") }
                    self.eventually({ TabTidy.lastUndo == nil }) { undone in
                        self.expect(undone && space.today.items.map(\.id) == order && mine[0].customTitle == nil
                                    && mine[0].displayTitle.hasPrefix("Concurrency |") && !space.today.allItems.contains { $0.kind == .folder },
                                    "⌘Z puts the tabs back in their order, with their titles (undone \(undone), order \(space.today.items.map(\.id) == order), title \(mine[0].displayTitle), folders \(space.today.allItems.filter { $0.kind == .folder }.count))")
                        stub.answer([ClaudeStub.initEvent(session: "selftest-tidy"),
                                     ClaudeStub.resultEvent(session: "selftest-tidy", result: "Das kann ich nicht sortieren.")])
                        guard let again = self.browser.tidyTabsWithAI() else { return finish() }
                        self.eventually({ again.phase != .working }, timeout: 10) { _ in
                            if case .failed(let message) = again.phase {
                                self.expect(message.hasPrefix("Claude hat keinen brauchbaren Vorschlag"), "an answer without folders says so")
                            } else {
                                self.expect(false, "an answer without folders says so (\(again.phase))")
                            }
                            again.close()
                            finish()
                        }
                    }
                }
            }
        }
    }
}

/// A stand-in for claude: a script that keeps each prompt and its
/// arguments and answers with stream-json events the test chose.
@MainActor
final class ClaudeStub {
    let folder: URL
    var executable: URL { folder.appendingPathComponent("claude") }

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-claude-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            dir="$(dirname "$0")"
            n=$(ls "$dir" | grep -c '^prompt-')
            cat > "$dir/prompt-$n.txt"
            printf '%s\\n' "$@" > "$dir/arguments-$n.txt"
            cat "$dir/answer.jsonl"
            """
        try? script.write(to: executable, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        answer([])
    }

    func answer(_ events: [String]) {
        try? events.joined(separator: "\n").appending("\n").write(to: folder.appendingPathComponent("answer.jsonl"),
                                                                atomically: true, encoding: .utf8)
    }

    private var runs: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("prompt-") }.count
    }

    var lastPrompt: String {
        (try? String(contentsOf: folder.appendingPathComponent("prompt-\(runs - 1).txt"), encoding: .utf8)) ?? ""
    }

    var lastArguments: String {
        (try? String(contentsOf: folder.appendingPathComponent("arguments-\(runs - 1).txt"), encoding: .utf8)) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func initEvent(session: String, tools: [String] = []) -> String {
        json(["type": "system", "subtype": "init", "session_id": session, "model": "claude-test", "tools": tools,
              "mcp_servers": []])
    }

    static func textEvent(_ text: String) -> String {
        json(["type": "assistant", "message": ["content": [["type": "text", "text": text]]]])
    }

    static func resultEvent(session: String, result: String = "", isError: Bool = false) -> String {
        json(["type": "result", "subtype": isError ? "error" : "success", "is_error": isError, "session_id": session,
              "result": result])
    }
}
