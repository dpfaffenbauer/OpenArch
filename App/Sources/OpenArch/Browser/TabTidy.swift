import AppKit
import SwiftUI

/// "Tabs mit KI aufräumen": Claude sorts the current space's today tabs
/// into folders with short names and gives tabs shorter titles. Only their
/// titles and addresses go to Claude, nothing of the pages. The proposal
/// shows first and is applied on "Übernehmen"; ⌘Z (or Rückgängig in the
/// toast) puts everything back. Pinned tabs and favorites are never touched.
@MainActor @Observable
final class TabTidy {
    enum Phase: Equatable {
        case working, ready, failed(String)
    }

    struct Folder: Identifiable {
        let id = UUID()
        var name: String
        var tabs: [Item]
    }

    private(set) var phase = Phase.working
    private(set) var folders: [Folder] = []
    /// Shorter titles, by tab.
    private(set) var titles: [ObjectIdentifier: String] = [:]
    let tabs: [Item]
    let space: Space
    @ObservationIgnored private weak var browser: BrowserWindowController?
    @ObservationIgnored private var panel: NSPanel?

    /// The proposal on screen, and what one ⌘Z undoes.
    private(set) static weak var current: TabTidy?
    private(set) static var lastUndo: Undo?
    private static var keyMonitor: Any?

    private init(tabs: [Item], space: Space, browser: BrowserWindowController) {
        self.tabs = tabs
        self.space = space
        self.browser = browser
    }

    /// Where claude runs for it: a folder of its own, away from your files.
    static var folder: URL {
        AppPaths.support.appendingPathComponent("TabTidy", isDirectory: true)
    }

    /// The tabs it sorts: the today tabs, also those in folders of an earlier
    /// tidy, but not the sides of a split view.
    static func tabs(in space: Space) -> [Item] {
        Array(space.today.allItems.filter { $0.kind == .tab && $0.split == nil }.prefix(80))
    }

    /// Asks Claude and shows the proposal over |browser|'s page.
    @discardableResult
    static func start(in browser: BrowserWindowController) -> TabTidy? {
        guard !browser.isStandalone else { return nil }
        let space = browser.state.space
        let tabs = tabs(in: space)
        guard tabs.count >= 3 else {
            browser.showToast("Zu wenige Tabs zum Aufräumen", symbol: "info.circle.fill")
            return nil
        }
        current?.close()
        let tidy = TabTidy(tabs: tabs, space: space, browser: browser)
        current = tidy
        tidy.showPanel()
        Task {
            let outcome = await ClaudeRun.run(prompt(for: tabs), in: folder, arguments: ["--permission-mode", "default"],
                                              timeout: 240)
            tidy.take(outcome)
        }
        return tidy
    }

    static func prompt(for tabs: [Item]) -> String {
        let list = tabs.enumerated().map { index, tab in
            "\(index + 1). \(tab.displayTitle.replacingOccurrences(of: "\n", with: " ")) — \(tab.currentURL)"
        }
        return """
            Sortiere diese offenen Browser-Tabs in Ordner. Jede Zeile: Nummer, Titel — Adresse.

            \(list.joined(separator: "\n"))

            Antworte nur mit JSON in dieser Form, ohne Text davor oder danach:
            {"folders": [{"name": "🛠️ Entwicklung", "tabs": [1, 4]}], "titles": {"1": "Kurzer Titel"}}

            - 2 bis 7 Ordner nach Thema oder Aufgabe, mit kurzen Namen (ein bis drei Wörter), gern mit einem passenden Emoji vorn.
            - Ein Ordner braucht mindestens zwei Tabs, jeder Tab steht in höchstens einem Ordner; was nirgends passt, lässt du weg.
            - "titles": kürzere, klare Titel (höchstens etwa 30 Zeichen) für Tabs, deren Titel lang oder unklar ist, in der Sprache des Titels.
            - Benutze keine Werkzeuge; Titel und Adressen genügen.
            """
    }

    /// Claude's answer as a proposal, or why there is none.
    private func take(_ outcome: ClaudeRun.Outcome) {
        if outcome.isMissing {
            phase = .failed("Claude Code wurde auf diesem Mac nicht gefunden. Installiere es (claude.ai/code) und melde dich einmal im Terminal mit „claude“ an.")
        } else if let error = outcome.error {
            phase = .failed(outcome.needsLogin
                ? "Claude Code ist nicht angemeldet. Starte „claude“ im Terminal und melde dich an.\n\n\(error)"
                : error)
        } else if !read(outcome.text) {
            phase = .failed("Claude hat keinen brauchbaren Vorschlag gemacht. Versuch es noch einmal.")
        } else {
            phase = .ready
        }
    }

    /// Reads {"folders": [...], "titles": {...}}; false when it holds nothing to do.
    func read(_ text: String) -> Bool {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
        else { return false }
        var used = Set<Int>()
        folders = []
        for case let entry as [String: Any] in json["folders"] as? [Any] ?? [] {
            let name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let numbers = (entry["tabs"] as? [Any] ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap { Int($0) } }
            var members: [Int] = []
            for number in numbers where tabs.indices.contains(number - 1) && !used.contains(number) && !members.contains(number) {
                members.append(number)
            }
            guard !name.isEmpty, members.count >= 2 else { continue }
            used.formUnion(members)
            folders.append(Folder(name: String(name.prefix(40)), tabs: members.map { tabs[$0 - 1] }))
        }
        titles = [:]
        for (key, value) in json["titles"] as? [String: Any] ?? [:] {
            guard let number = Int(key), tabs.indices.contains(number - 1), let title = value as? String else { continue }
            let tab = tabs[number - 1]
            let short = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // A name you gave a tab yourself stays.
            guard !short.isEmpty, short != tab.displayTitle, tab.customTitle == nil else { continue }
            titles[ObjectIdentifier(tab)] = String(short.prefix(60))
        }
        return !folders.isEmpty || !titles.isEmpty
    }

    func title(of tab: Item) -> String {
        titles[ObjectIdentifier(tab)] ?? tab.displayTitle
    }

    /// The tabs no folder takes.
    var looseTabs: [Item] {
        let grouped = Set(folders.flatMap(\.tabs).map(ObjectIdentifier.init))
        return tabs.filter { !grouped.contains(ObjectIdentifier($0)) }
    }

    // MARK: Applying

    /// Puts the folders at the top of the today tabs and gives the tabs
    /// their new titles; ⌘Z or the toast's Rückgängig undoes it.
    func apply() {
        guard phase == .ready, let browser else { return close() }
        let today = space.today
        let alive = tabs.filter { $0.container === today }
        let undo = Undo(browser: browser, space: space, top: today.items,
                        folders: today.allItems.filter { $0.kind == .folder }.map { ($0, $0.children) },
                        titles: alive.map { ($0, $0.customTitle) })
        for (index, folder) in folders.enumerated() {
            let members = folder.tabs.filter { $0.container === today }
            guard members.count >= 2 else { continue }
            let item = Item.folder(folder.name)
            today.insert(item, at: index)
            for tab in members {
                today.insert(tab, into: item)
            }
            undo.created.append(item)
        }
        for tab in alive {
            if let title = titles[ObjectIdentifier(tab)] { tab.customTitle = title }
        }
        // Folders of an earlier tidy that are empty now go.
        for folder in today.allItems where folder.kind == .folder && folder.children.isEmpty
            && !undo.created.contains(where: { $0 === folder }) {
            folder.detach()
            undo.removed.append(folder)
        }
        browser.library.setNeedsSave()
        close()
        Self.offer(undo)
    }

    /// Keeps |undo| for ⌘Z and the toast's button, for as long as the toast shows.
    private static func offer(_ undo: Undo) {
        lastUndo = undo
        undo.browser?.window?.undoManager?.registerUndo(withTarget: undo) { undo in
            MainActor.assumeIsolated { _ = TabTidy.undoLast(undo) }
        }
        undo.browser?.window?.undoManager?.setActionName("Tabs aufräumen")
        let folders = undo.created.count
        undo.browser?.showToast(folders == 1 ? "1 Ordner angelegt" : "\(folders) Ordner angelegt", symbol: "sparkles",
                                action: ToastAction(title: "Rückgängig") { _ = TabTidy.undoLast() })
        // ⌘Z also from the page, which would otherwise take it.
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { TabTidy.takesUndoKey(event) } ? nil : event
        }
        after(8) {
            if let monitor = keyMonitor, lastUndo === undo {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }

    /// ⌘Z while the toast shows: the tidy is undone and the key goes no further.
    static func takesUndoKey(_ event: NSEvent) -> Bool {
        // As ShortcutMonitor compares keys: by the key's own letter or the one typed.
        let keys = [event.characters(byApplyingModifiers: []), event.charactersIgnoringModifiers].compactMap { $0?.lowercased() }
        let undoKey = keyMonitor != nil && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
            && keys.contains("z")
        return undoKey && undoLast()
    }

    /// Puts the today tabs back as they were before the last tidy: order,
    /// folders and titles. Tabs closed since stay closed, tabs opened since
    /// stay at the top. False when there is nothing to undo.
    @discardableResult
    static func undoLast(_ only: Undo? = nil) -> Bool {
        guard let undo = lastUndo, only == nil || only === undo else { return false }
        lastUndo = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        undo.browser?.window?.undoManager?.removeAllActions(withTarget: undo)
        let today = undo.space.today
        func id(_ item: Item) -> ObjectIdentifier { ObjectIdentifier(item) }
        let alive = Set((today.allItems + undo.removed).map(id))
        let created = Set(undo.created.map(id))
        let known = Set((undo.top + undo.folders.flatMap { [$0.0] + $0.1 }).map(id))
        let opened = today.allItems.filter { !known.contains(id($0)) && !created.contains(id($0)) && ($0.parent == nil || created.contains(id($0.parent!))) }
        for folder in undo.created {
            folder.children = []
        }
        for (folder, children) in undo.folders {
            folder.children = children.filter { alive.contains(id($0)) }
        }
        today.replace(with: opened + undo.top.filter { alive.contains(id($0)) })
        for folder in undo.created {
            folder.detach()
        }
        for (tab, title) in undo.titles where tab.container === today {
            tab.customTitle = title
        }
        undo.browser?.library.setNeedsSave()
        undo.browser?.layoutContent()
        return true
    }

    /// The today section before a tidy.
    final class Undo {
        weak var browser: BrowserWindowController?
        let space: Space
        let top: [Item]
        let folders: [(Item, [Item])]
        let titles: [(Item, String?)]
        var created: [Item] = []
        var removed: [Item] = []

        init(browser: BrowserWindowController, space: Space, top: [Item], folders: [(Item, [Item])], titles: [(Item, String?)]) {
            self.browser = browser
            self.space = space
            self.top = top
            self.folders = folders
            self.titles = titles
        }
    }

    // MARK: Panel

    private func showPanel() {
        guard let browser, let window = browser.window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: TabTidyView(tidy: self))
        let area = window.convertToScreen(browser.contentRect)
        panel.setFrameOrigin(NSPoint(x: area.midX - 230, y: area.midY - 260 + area.height * 0.05))
        // Above the tabs' own windows, like the toast.
        window.addChildWindow(panel, ordered: .above)
        if AppPaths.isSelfTest {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        self.panel = panel
    }

    func close() {
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        if Self.current === self { Self.current = nil }
    }

    /// The panel's window (self-test).
    var window: NSWindow? { panel }
}

extension BrowserWindowController {
    /// "Tabs mit KI aufräumen" in the command bar.
    @discardableResult
    func tidyTabsWithAI() -> TabTidy? {
        TabTidy.start(in: self)
    }
}

/// The proposal: folders with their tabs (new titles, the old one beside
/// it), then what stays without a folder.
private struct TabTidyView: View {
    let tidy: TabTidy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Tabs aufräumen", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                Text("Vorschlag von Claude für die Tabs unter dem Strich in „\(tidy.space.name)“. Claude bekommt nur Titel und Adressen, angeheftete Tabs und Favoriten bleiben, wie sie sind.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Abbrechen") { tidy.close() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") { tidy.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(tidy.phase != .ready)
            }
            .padding(14)
        }
        .frame(width: 460, height: 520)
    }

    @ViewBuilder private var content: some View {
        switch tidy.phase {
        case .working:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Claude sortiert \(tidy.tabs.count) Tabs …").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label {
                Text(message).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(20)
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(tidy.folders) { folder in
                        group(folder.name, symbol: "folder", tabs: folder.tabs)
                    }
                    let loose = tidy.looseTabs
                    if !loose.isEmpty {
                        group("Ohne Ordner", symbol: "tray", tabs: loose)
                    }
                }
                .padding(20)
            }
        }
    }

    private func group(_ name: String, symbol: String, tabs: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name, systemImage: symbol).font(.system(size: 13, weight: .semibold))
            ForEach(tabs) { tab in
                HStack(spacing: 8) {
                    FaviconView(item: tab, size: 14)
                    Text(tidy.title(of: tab)).font(.system(size: 12.5)).lineLimit(1)
                    if tidy.title(of: tab) != tab.displayTitle {
                        Text(tab.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 22)
                .help(tab.currentURL)
            }
        }
    }
}
