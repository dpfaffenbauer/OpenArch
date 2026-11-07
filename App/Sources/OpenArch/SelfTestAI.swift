import AppKit
import OpenArchCore

/// The self-test of the AI features (chat with the page, skills, the
/// morning brief, tidying tabs), with a stand-in for claude. `--ai-test`
/// runs only these.
extension SelfTest {
    func aiFeatures(then next: @escaping () -> Void) {
        let stub = ClaudeStub()
        AgentEnvironment.stub = AgentEnvironment.Resolved(claude: stub.executable.path, variables: ProcessInfo.processInfo.environment)
        Swift.print("[selftest] STEP page chat")
        pageChatTest(stub) {
            Swift.print("[selftest] STEP skills")
            self.skillsTest(stub) {
                AgentEnvironment.stub = nil
                stub.remove()
                next()
            }
        }
    }

    /// The command bar lists your Claude Code skills and commands by name
    /// and runs one on the page, in the page's chat.
    private func skillsTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
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
    private func pageChatTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
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
    func shot(_ name: String, then next: @escaping () -> Void) {
        guard CommandLine.arguments.contains("--shots") else { return next() }
        browser.window?.orderFrontRegardless()
        Swift.print("[selftest] SHOT \(name) \(browser.window?.windowNumber ?? 0)")
        after(4) { next() }
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
