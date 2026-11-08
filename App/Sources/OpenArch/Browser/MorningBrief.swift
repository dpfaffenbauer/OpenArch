import AppKit

/// The morning brief (Settings › KI): once a day at the chosen time, or at
/// the first launch after it, Claude Code writes a page about the day
/// ahead (calendar, new mail, chat messages, open tasks) from whatever
/// connectors (MCP servers) it has. The page opens as a tab "Morning
/// Brief" at the top of the today tabs, with a dot until it is read.
@MainActor
final class MorningBrief {
    static let shared = MorningBrief()

    private(set) var isRunning = false
    private weak var library: Library?
    private var timer: Timer?

    static let title = "Morning Brief"

    /// Where claude runs for it and the pages are kept, one per day.
    static var folder: URL {
        let url = AppPaths.support.appendingPathComponent("MorningBrief", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Your own prompt, once "Bearbeiten …" made it; else OpenArch's.
    static var promptFile: URL {
        folder.appendingPathComponent("Prompt.md")
    }

    // MARK: Schedule

    func start(_ library: Library) {
        self.library = library
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { MorningBrief.shared.runIfDue() }
        }
        // Once launching has settled (and the Arc question is out of the way).
        after(8) { self.runIfDue() }
    }

    private func runIfDue() {
        guard let library, library.settings.morningBrief, !isRunning, !AppPaths.isSelfTest,
              Self.isDue(now: Date(), minutes: library.settings.morningBriefMinutes, lastDay: Self.lastDay),
              let browser = (NSApp.delegate as? AppDelegate)?.mainBrowser else { return }
        run(in: browser, manual: false)
    }

    /// Whether today's brief is due at |now|: past the time and not made today.
    nonisolated static func isDue(now: Date, minutes: Int, lastDay: String?) -> Bool {
        guard lastDay != day(now) else { return false }
        return now >= Calendar.current.startOfDay(for: now).addingTimeInterval(Double(minutes) * 60)
    }

    nonisolated static func day(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The day the brief was last made.
    private static var lastDay: String? {
        get { try? String(contentsOf: folder.appendingPathComponent("last-run"), encoding: .utf8) }
        set { try? newValue?.write(to: folder.appendingPathComponent("last-run"), atomically: true, encoding: .utf8) }
    }

    // MARK: Making it

    /// Makes today's brief in |browser|'s current space. |manual| (the
    /// command bar, Settings) shows the tab at once, with a page that says
    /// it is being made.
    func run(in browser: BrowserWindowController, manual: Bool) {
        guard !browser.isStandalone else { return }
        let space = browser.state.space
        let now = Date()
        let file = Self.folder.appendingPathComponent("\(Self.day(now)).html")
        if isRunning {
            if manual, let tab = Self.tab(in: browser.state.space) { browser.select(tab) }
            return
        }
        isRunning = true
        Self.lastDay = Self.day(now)
        if manual {
            try? Self.statusPage("Dein Morning Brief entsteht …",
                                 "Claude Code schaut mit deinen Connectors in Kalender, Mails, Chats und Aufgaben. Das dauert meist ein, zwei Minuten; die Seite lädt dann von selbst neu.",
                                 working: true)
                .write(to: file, atomically: true, encoding: .utf8)
            show(file, in: space, of: browser, select: true)
        }
        Task {
            let page = await Self.make(now: now)
            try? page.write(to: file, atomically: true, encoding: .utf8)
            isRunning = false
            // A space deleted meanwhile: the one in front.
            let target = browser.library.spaces.contains { $0 === space } ? space : browser.state.space
            let tab = show(file, in: target, of: browser, select: false)
            tab.isUnread = !BrowserWindowController.isShowing(tab)
        }
    }

    /// The brief tab of |space|: a today tab showing a page of the brief's folder.
    static func tab(in space: Space) -> Item? {
        let prefix = folder.absoluteString
        return space.today.allTabs.first { $0.currentURL.hasPrefix(prefix) }
    }

    /// Puts |file| in |space|'s brief tab at the top of its today tabs (a
    /// new one if there is none) and loads it.
    @discardableResult
    private func show(_ file: URL, in space: Space, of browser: BrowserWindowController, select: Bool) -> Item {
        let url = file.absoluteString
        let tab: Item
        if let existing = Self.tab(in: space) {
            tab = existing
            if tab.split == nil, tab.parent != nil || tab.indexInParent != 0 {
                space.today.insert(tab, at: 0)
            }
            if let pane = tab.pane {
                pane.loadURL(url)
            } else {
                tab.liveURL = url
            }
        } else {
            tab = Item.tab(url: url, title: Self.title)
            space.today.insert(tab, at: 0)
        }
        tab.savedURL = url
        tab.customTitle = Self.title
        if select {
            browser.select(tab)
        }
        browser.library.setNeedsSave()
        return tab
    }

    /// The brief as a page: Claude's HTML, or a page that says what went wrong.
    static func make(now: Date) async -> String {
        // First only which tools Claude Code has, so the brief may use the
        // connectors' reading ones: claude -p cannot ask for permission, and
        // a mail must not be able to make it send or delete anything. The
        // claude.ai connectors bring their tools a moment later, so it asks
        // again (no model call) until each connected server has shown them.
        var offered = Set<String>()
        for _ in 0..<3 {
            let probe = await ClaudeRun.run("OK", in: folder, untilInit: true, timeout: 120)
            if let problem = problemPage(probe) { return problem }
            offered.formUnion(probe.tools)
            if serversWithoutTools(probe.servers, tools: offered).isEmpty { break }
        }
        var arguments = ["--permission-mode", "default"]
        let tools = readingTools(offered.sorted())
        if !tools.isEmpty {
            arguments += ["--allowedTools", tools.joined(separator: ",")]
        }
        let outcome = await ClaudeRun.run(prompt(now: now), in: folder, arguments: arguments, timeout: 900)
        if let problem = problemPage(outcome) { return problem }
        return html(in: outcome.text) ?? textPage(outcome.text)
    }

    private static func problemPage(_ outcome: ClaudeRun.Outcome) -> String? {
        if outcome.isMissing {
            return statusPage("Claude Code wurde nicht gefunden.",
                              "Der Morning Brief braucht Claude Code auf diesem Mac. Installiere es (claude.ai/code) und melde dich einmal im Terminal mit „claude“ an. Danach in der Befehlsleiste: „Morning Brief jetzt erstellen“.")
        }
        guard let error = outcome.error else { return nil }
        if outcome.needsLogin {
            return statusPage("Claude Code ist nicht angemeldet.",
                              "Öffne das Terminal, starte „claude“ und melde dich an. Danach in der Befehlsleiste: „Morning Brief jetzt erstellen“.",
                              detail: error)
        }
        return statusPage("Der Morning Brief ließ sich nicht erstellen.",
                          "Claude Code meldet einen Fehler. In der Befehlsleiste versucht „Morning Brief jetzt erstellen“ es noch einmal.",
                          detail: error)
    }

    /// Servers that are (being) connected but have not shown any tools yet.
    /// Their tools start with mcp__ and the name, other characters as _
    /// ("claude.ai Gmail" → mcp__claude_ai_Gmail__).
    nonisolated static func serversWithoutTools(_ servers: [String: String], tools: Set<String>) -> [String] {
        servers.filter { name, status in
            guard status == "connected" || status == "pending" else { return false }
            let prefix = "mcp__" + String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }) + "__"
            return !tools.contains { $0.hasPrefix(prefix) }
        }
        .map(\.key)
        .sorted()
    }

    /// Connector tools whose names say they read: get, list, search … and
    /// nothing that creates, sends, changes or deletes.
    nonisolated static func readingTools(_ tools: [String]) -> [String] {
        let reading: Set<String> = ["get", "list", "search", "read", "fetch", "find", "query", "show", "view", "lookup",
                                    "look", "describe", "retrieve", "check", "count", "browse", "my", "today",
                                    "day", "recent", "upcoming"]
        let writing: Set<String> = ["create", "update", "delete", "remove", "send", "set", "add", "post", "write", "edit",
                                    "move", "archive", "complete", "log", "book", "start", "stop", "publish", "install",
                                    "upload", "download", "save", "reset", "merge", "assign", "transition", "comment",
                                    "reply", "forward", "share", "invite", "cancel", "mark", "modify", "draft", "trash",
                                    "approve", "decline", "accept", "rename", "subscribe", "disconnect", "launch", "run"]
        return tools.filter { tool in
            guard tool.hasPrefix("mcp__") else { return false }
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            guard parts.count >= 2, let server = parts.first, let name = parts.last else { return false }
            var words = Self.words(name)
            // "slack_read_channel" of the Slack server reads.
            if words.count > 1, words.first == Self.words(server).last { words.removeFirst() }
            guard let first = words.first, reading.contains(first) else { return false }
            return !words.contains { writing.contains($0) }
        }
    }

    /// "searchJiraIssues", "list_events", "get-today" → their words, lowercased.
    nonisolated private static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
            } else if character.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                words.append(current.lowercased())
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    /// The prompt, with today's date and the time filled in.
    static func prompt(now: Date) -> String {
        let template = (try? String(contentsOf: promptFile, encoding: .utf8))
            ?? Bundle.main.url(forResource: "MorningBrief", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Erstelle meinen Morning Brief für heute, {{DATUM}}, als eigenständige HTML-Seite."
        let date = DateFormatter()
        date.locale = Locale(identifier: "de_DE")
        date.dateFormat = "EEEE, d. MMMM yyyy"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return template.replacingOccurrences(of: "{{DATUM}}", with: date.string(from: now))
            .replacingOccurrences(of: "{{UHRZEIT}}", with: time.string(from: now))
    }

    /// Opens the prompt in your editor; the first time, as a copy of OpenArch's.
    static func editPrompt() {
        if !FileManager.default.fileExists(atPath: promptFile.path),
           let bundled = Bundle.main.url(forResource: "MorningBrief", withExtension: "md") {
            try? FileManager.default.copyItem(at: bundled, to: promptFile)
        }
        NSWorkspace.shared.open(promptFile)
    }

    // MARK: Pages

    /// The HTML document in Claude's answer, from <!DOCTYPE html> (or
    /// <html>) to </html>, also inside a ```html block.
    nonisolated static func html(in text: String) -> String? {
        guard let start = text.range(of: "<!doctype html", options: .caseInsensitive)
                ?? text.range(of: "<html", options: .caseInsensitive),
              let end = text.range(of: "</html>", options: [.caseInsensitive, .backwards]),
              start.lowerBound < end.upperBound else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// An answer that is no page, shown as text.
    private static func textPage(_ text: String) -> String {
        page(body: "<pre>\(escaped(text))</pre>")
    }

    static func statusPage(_ heading: String, _ explanation: String, detail: String? = nil, working: Bool = false) -> String {
        var body = "<h1>\(working ? "<span class=\"spin\"></span>" : "")\(escaped(heading))</h1><p>\(escaped(explanation))</p>"
        if let detail, !detail.isEmpty {
            body += "<pre>\(escaped(detail))</pre>"
        }
        return page(body: body)
    }

    private static func page(body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="de"><head><meta charset="utf-8"><title>\(title)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.55 -apple-system, system-ui, sans-serif; max-width: 640px; margin: 18vh auto 2em; padding: 0 24px;
               color: light-dark(#1d1d1f, #f2f2f4); background: light-dark(#fbfbfd, #1c1c1e); }
        h1 { font-size: 22px; margin: 0 0 10px; display: flex; align-items: center; gap: 12px; }
        p { color: light-dark(#55555a, #a8a8ae); margin: 0 0 16px; }
        pre { white-space: pre-wrap; font: 12.5px/1.5 ui-monospace, monospace; padding: 12px 14px; border-radius: 10px;
              background: light-dark(#f0f0f3, #2a2a2d); }
        .spin { width: 18px; height: 18px; border-radius: 50%; border: 2.5px solid light-dark(#d4d4d8, #48484d);
                border-top-color: light-dark(#7b6cf6, #a79df9); animation: spin 0.9s linear infinite; }
        @keyframes spin { to { transform: rotate(360deg); } }
        </style></head><body>\(body)</body></html>
        """
    }

    nonisolated static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
