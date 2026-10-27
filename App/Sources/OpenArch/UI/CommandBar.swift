import AppKit
import Observation
import OpenArchCore
import SwiftUI

/// Arc's command bar: ⌘T opens a new tab, ⌘L edits the current URL. One
/// field searches open tabs, pinned tabs, history, commands and the web.
@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    enum Mode {
        case newTab
        case editURL
        case newSplit(Item)
    }

    private unowned let browser: BrowserWindowController
    private var panel: CommandBarPanel?
    let model: CommandBarModel

    init(browser: BrowserWindowController) {
        self.browser = browser
        model = CommandBarModel(browser: browser)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(mode: Mode) {
        guard let window = browser.window else { return }
        model.reset(mode: mode)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let width: CGFloat = min(720, max(480, window.frame.width - 160))
        let content = window.convertToScreen(browser.contentRect)
        let x = content.midX - width / 2
        let top = window.frame.maxY - max(90, window.frame.height * 0.18)
        panel.setFrame(NSRect(x: x, y: top - CommandBarModel.maxHeight, width: width, height: CommandBarModel.maxHeight),
                       display: false)
        if AppPaths.isSelfTest {
            panel.level = .normal
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
            panel.order(.above, relativeTo: window.windowNumber)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        browser.state.activeItem?.pane?.focus()
    }

    private func makePanel() -> CommandBarPanel {
        let panel = CommandBarPanel(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // The self-test runs in the background; keep the panel up for screenshots.
        panel.hidesOnDeactivate = !AppPaths.isSelfTest
        panel.delegate = self
        let host = NSHostingView(rootView: CommandBarView(model: model, controller: self))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)
    }
}

final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Model

struct CommandResult: Identifiable {
    enum Icon {
        case item(Item)
        case url(String)
        case symbol(String)
    }

    let id: String
    let icon: Icon
    let title: String
    var subtitle: String?
    var badge: String?
    let action: @MainActor () -> Void
}

@MainActor @Observable
final class CommandBarModel {
    static let maxHeight: CGFloat = 470

    @ObservationIgnored private unowned let browser: BrowserWindowController
    private(set) var mode: CommandBarController.Mode = .newTab
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            selection = 0
            rebuild()
            fetchSuggestions()
        }
    }
    private(set) var results: [CommandResult] = []
    var selection = 0
    /// The site being searched after "yt" + Tab; shown as a chip.
    private(set) var site: SiteSearch?
    /// Bumped to make the field select its text (⌘L).
    private(set) var selectAllToken = 0
    @ObservationIgnored private var suggestions: [String] = []
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var placeholder: String {
        if let site { return "\(site.name) durchsuchen …" }
        return switch mode {
        case .newTab: "Suchen oder URL eingeben …"
        case .editURL: "URL bearbeiten …"
        case .newSplit: "Neben dem aktuellen Tab öffnen …"
        }
    }

    func reset(mode: CommandBarController.Mode) {
        self.mode = mode
        site = nil
        suggestions = []
        if case .editURL = mode, let url = browser.state.activeItem?.currentURL {
            query = InternalURL.display(url)
            selectAllToken += 1
        } else {
            query = ""
        }
        selection = 0
        rebuild()
    }

    /// Tab: searches the site the input names (keyword or name), like
    /// Arc. Returns false when there is none, so Tab moves the selection.
    func tab() -> Bool {
        guard site == nil, let candidate = siteCandidate(query.trimmingCharacters(in: .whitespaces)) else { return false }
        enterSite(candidate)
        return true
    }

    func enterSite(_ candidate: SiteSearch) {
        site = candidate
        suggestions = []
        query = ""
        selection = 0
        rebuild()
    }

    /// Backspace in the empty field leaves the site search.
    func leaveSite() -> Bool {
        guard site != nil, query.isEmpty else { return false }
        site = nil
        rebuild()
        return true
    }

    /// An exact keyword wins; otherwise a site whose name starts with the input.
    private func siteCandidate(_ text: String) -> SiteSearch? {
        let lower = text.lowercased()
        guard !lower.isEmpty, !lower.contains(" ") else { return nil }
        let sites = browser.library.settings.siteSearches
        if let exact = sites.first(where: { $0.keyword.lowercased() == lower || $0.name.lowercased() == lower }) {
            return exact
        }
        guard lower.count >= 2 else { return nil }
        return sites.first { $0.name.lowercased().hasPrefix(lower) }
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func run(_ index: Int? = nil) {
        let index = index ?? selection
        guard results.indices.contains(index) else { return }
        let action = results[index].action
        browser.commandBar.hide()
        action()
    }

    // MARK: Results

    private func rebuild() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [CommandResult] = []
        var seenURLs = Set<String>()

        if let site {
            self.results = siteResults(site, text)
            selection = min(selection, max(0, self.results.count - 1))
            return
        }

        if text.isEmpty {
            results += recentTabs()
            self.results = results
            return
        }

        if let url = Self.url(fromInput: text) {
            results.append(CommandResult(id: "open:\(url)", icon: .url(url), title: InternalURL.display(url),
                                         subtitle: modeVerb, action: { [unowned self] in self.open(url) }))
            seenURLs.insert(url)
        } else {
            results.append(searchResult(text))
        }
        if let candidate = siteCandidate(text) {
            results.append(CommandResult(id: "site:\(candidate.id)", icon: .url(candidate.url), title: "\(candidate.name) durchsuchen",
                                         subtitle: candidate.keyword.isEmpty ? nil : "Kürzel: \(candidate.keyword)", badge: "Tab",
                                         action: { [unowned self] in self.enterSite(candidate) }))
        }

        let tabs = matchingTabs(text).prefix(5)
        for item in tabs {
            seenURLs.insert(item.currentURL)
            results.append(tabResult(item))
        }

        for command in matchingCommands(text).prefix(3) {
            results.append(command)
        }

        for entry in browser.history.search(text, limit: 8) where !seenURLs.contains(entry.url) {
            seenURLs.insert(entry.url)
            results.append(CommandResult(id: "history:\(entry.url)", icon: .url(entry.url),
                                         title: entry.title.isEmpty ? entry.url : entry.title,
                                         subtitle: Self.shortURL(entry.url),
                                         action: { [unowned self] in self.open(entry.url) }))
            if results.count >= 12 { break }
        }

        let archived = browser.library.archive.filter { matches(text, $0.title, $0.url) && !seenURLs.contains($0.url) }
        for tab in archived.prefix(2) {
            seenURLs.insert(tab.url)
            results.append(CommandResult(id: "archive:\(tab.url)", icon: .url(tab.url), title: tab.title,
                                         subtitle: "Archiviert · " + Self.shortURL(tab.url),
                                         action: { [unowned self] in self.open(tab.url) }))
        }

        if Self.url(fromInput: text) == nil {
            for suggestion in suggestions.prefix(4) where suggestion.lowercased() != text.lowercased() {
                results.append(searchResult(suggestion))
            }
        }
        self.results = results
        selection = min(selection, max(0, results.count - 1))
    }

    private func siteResults(_ site: SiteSearch, _ text: String) -> [CommandResult] {
        guard !text.isEmpty else { return [] }
        var results = [CommandResult(id: "sitesearch:\(text)", icon: .url(site.url), title: text,
                                     subtitle: "\(site.name) durchsuchen",
                                     action: { [unowned self] in self.open(site.url(for: text)) })]
        let host = site.host.replacingOccurrences(of: "www.", with: "")
        for entry in browser.history.search(text, limit: 20) where !host.isEmpty && entry.url.contains(host) {
            results.append(CommandResult(id: "history:\(entry.url)", icon: .url(entry.url),
                                         title: entry.title.isEmpty ? entry.url : entry.title,
                                         subtitle: Self.shortURL(entry.url),
                                         action: { [unowned self] in self.open(entry.url) }))
            if results.count >= 5 { break }
        }
        for suggestion in suggestions.prefix(5) where suggestion.lowercased() != text.lowercased() {
            results.append(CommandResult(id: "sitesearch:\(suggestion)", icon: .symbol("magnifyingglass"), title: suggestion,
                                         subtitle: "\(site.name) durchsuchen",
                                         action: { [unowned self] in self.open(site.url(for: suggestion)) }))
        }
        return results
    }

    private var modeVerb: String {
        switch mode {
        case .newTab: "In neuem Tab öffnen"
        case .editURL: "Öffnen"
        case .newSplit: "In Split View öffnen"
        }
    }

    private func searchResult(_ text: String) -> CommandResult {
        let engine = browser.library.settings.searchEngine
        let url = engine.url(for: text)
        return CommandResult(id: "search:\(text)", icon: .symbol("magnifyingglass"), title: text,
                             subtitle: "\(engine.name)-Suche", action: { [unowned self] in self.open(url) })
    }

    private func tabResult(_ item: Item) -> CommandResult {
        let space = browser.library.space(containing: item)
        var subtitle = Self.shortURL(item.currentURL)
        if let space, space !== browser.state.space {
            subtitle = space.name + " · " + subtitle
        }
        let isOpen = item.pane != nil || item.role == .today
        return CommandResult(id: "tab:\(item.id)", icon: .item(item), title: item.displayTitle, subtitle: subtitle,
                             badge: isOpen ? "Zu Tab wechseln" : "Öffnen",
                             action: { [unowned self] in self.switchTo(item) })
    }

    private func recentTabs() -> [CommandResult] {
        let space = browser.state.space
        let tabs = (space.today.allTabs + space.pinned.allTabs.filter { $0.pane != nil })
            .filter { $0 !== browser.state.activeItem }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        return tabs.prefix(6).map(tabResult)
    }

    private func matchingTabs(_ text: String) -> [Item] {
        let profileFavorites = browser.library.profile(id: browser.state.space.profileID).favorites.allTabs
        let spaces = [browser.state.space] + browser.library.spaces.filter { $0 !== browser.state.space }
        let all = profileFavorites + spaces.flatMap { $0.today.allTabs + $0.pinned.allTabs }
        return all.filter { matches(text, $0.displayTitle, $0.currentURL) || matches(text, $0.savedTitle, $0.savedURL) }
            .sorted { lhs, rhs in
                // Open tabs first, then the current space, then recency.
                let lhsOpen = lhs.pane != nil, rhsOpen = rhs.pane != nil
                if lhsOpen != rhsOpen { return lhsOpen }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
    }

    private func matches(_ text: String, _ fields: String...) -> Bool {
        let haystack = fields.joined(separator: " ").lowercased()
        return text.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    private func open(_ url: String) {
        switch mode {
        case .newTab:
            browser.openInNewTab(url)
        case .editURL:
            browser.open(url, inNewTab: false)
        case .newSplit(let base):
            let item = browser.openInNewTab(url, after: base, select: false)
            browser.split(item, with: base)
        }
    }

    private func switchTo(_ item: Item) {
        if case .newSplit(let base) = mode, item.kind == .tab, item.split == nil, item.role == .today {
            browser.split(item, with: base)
        } else {
            browser.select(item)
        }
    }

    // MARK: Commands

    private func matchingCommands(_ text: String) -> [CommandResult] {
        let browser = self.browser
        let active = browser.state.activeItem
        typealias Command = (String, String, String?, @MainActor () -> Void)
        var commands: [Command] = [
            ("Neuer Space", "plus.square.on.square", nil, { browser.addSpace() }),
            ("Little OpenArch", "macwindow.on.rectangle", "⌥⌘N", {
                if let app = NSApp.delegate as? AppDelegate { LittleOpenArchWindowController.show(url: nil, app: app) }
            }),
            ("Space bearbeiten", "paintpalette", nil, { browser.state.editingSpaceID = browser.state.space.id }),
            ("Neues Profil", "person.crop.circle.badge.plus", nil, {
                if let profile = ProfileDialog.run(library: browser.library, over: browser.window) {
                    browser.setProfile(profile.id, for: browser.state.space)
                }
            }),
            ("Neuer Ordner", "folder.badge.plus", nil, { browser.newFolder() }),
            ("Split View", "rectangle.split.2x1", "⌃⇧=", { browser.splitWithNewTab() }),
            ("Sidebar ein-/ausblenden", "sidebar.left", "⌘S", { browser.toggleSidebar() }),
            ("Chrome-Toolbar ein-/ausblenden", "menubar.rectangle", "⌘⇧L", { browser.toggleChromeToolbar() }),
            ("Geschlossenen Tab wiederherstellen", "arrow.uturn.backward", "⌘⇧T", { browser.reopenClosedTab() }),
            ("Heute aufräumen", "archivebox", nil, { browser.clearToday() }),
            ("Extensions verwalten", "puzzlepiece.extension", nil, { browser.openChromePage("chrome://extensions") }),
            ("Chrome Web Store", "bag", nil, { browser.openChromePage("https://chromewebstore.google.com") }),
            ("Verlauf", "clock", "⌘Y", { browser.openChromePage("chrome://history") }),
            ("Downloads", "arrow.down.circle", "⌥⌘L", { browser.openChromePage("chrome://downloads") }),
            ("Passwörter", "key", nil, { browser.openChromePage("chrome://password-manager") }),
            ("Browser-Einstellungen", "gearshape.2", nil, { browser.openChromePage("chrome://settings") }),
            ("OpenArch-Einstellungen", "gearshape", "⌘,", { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }),
            ("Aus Arc importieren", "square.and.arrow.down", nil, { (NSApp.delegate as? AppDelegate)?.importFromArc(nil) }),
        ]
        if let active {
            let tabCommands: [Command] = [
                ("URL kopieren", "link", "⌘⇧C", { browser.copyURL() }),
                (active.role == .today ? "Tab anheften" : "Tab lösen", "pin", "⌘D", { browser.togglePin(active) }),
                ("Zu Favoriten hinzufügen", "star", nil, { browser.addToFavorites(active) }),
                ("Entwicklertools", "hammer", "⌥⌘I", { active.pane?.showDevTools() }),
                ("Neu laden", "arrow.clockwise", "⌘R", { active.pane?.reload() }),
                ("Tab duplizieren", "plus.square.on.square", nil, { browser.duplicate(active) }),
                ("Boost bearbeiten", "paintbrush", "⌃⌘B", { browser.editBoost() }),
            ]
            commands += tabCommands
            if active.split != nil {
                let unsplit: Command = ("Split View aufheben", "rectangle", "⌃⇧-", { browser.unsplit() })
                commands.append(unsplit)
            }
        }
        for space in browser.library.spaces where space !== browser.state.space {
            let switchSpace: Command = ("Zu Space „\(space.name)“ wechseln", "square.stack", nil, { browser.switchSpace(to: space) })
            commands.append(switchSpace)
        }
        let needle = text.lowercased()
        return commands
            .filter { title, _, _, _ in
                let lower = title.lowercased()
                return lower.hasPrefix(needle) || lower.split(separator: " ").contains { $0.hasPrefix(needle) }
                    || (needle.count >= 3 && lower.contains(needle))
            }
            .map { title, symbol, shortcut, action in
                CommandResult(id: "command:\(title)", icon: .symbol(symbol), title: title, badge: shortcut, action: action)
            }
    }

    // MARK: Suggestions

    private func fetchSuggestions() {
        suggestionTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        let settings = browser.library.settings
        guard settings.searchSuggestions, text.count >= 2, Self.url(fromInput: text) == nil,
              let endpoint = Self.suggestionURL(for: text, engine: settings.searchEngine) else {
            suggestions = []
            return
        }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  case (let data?, 200) = await ChromiumFetch.get(endpoint),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count > 1, let list = json[1] as? [String],
                  !Task.isCancelled, let self, self.query.trimmingCharacters(in: .whitespaces) == text
            else { return }
            self.suggestions = list
            self.rebuild()
        }
    }

    private static func suggestionURL(for text: String, engine: Settings.SearchEngine) -> URL? {
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
        switch engine {
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/ac/?type=list&q=\(q)")
        case .bing: return URL(string: "https://api.bing.com/osjson.aspx?query=\(q)")
        default: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        }
    }

    // MARK: URL parsing

    /// Turns typed input into a URL if it looks like one.
    static func url(fromInput input: String) -> String? {
        let text = InternalURL.resolve(input.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "chrome://", "chrome-extension://", "file://", "about:", "data:", "view-source:"]
            where lower.hasPrefix(scheme) {
            return text
        }
        let hostPart = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let host = String(hostPart.split(separator: ":").first ?? "")
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test") {
            return "http://" + text
        }
        if host.split(separator: ".").count == 4, host.split(separator: ".").allSatisfy({ Int($0) != nil }) {
            return "http://" + text
        }
        let labels = host.split(separator: ".")
        if labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
           labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) {
            return "https://" + text
        }
        return nil
    }

    static func shortURL(_ url: String) -> String {
        var text = InternalURL.display(url)
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

/// Chrome's internal pages (chrome://history, chrome://settings, …) are
/// shown as openarch:// in OpenArch's own UI, and typed openarch:// URLs open
/// them. Chrome's toolbar inside a tab keeps showing chrome://.
enum InternalURL {
    static func display(_ url: String) -> String {
        url.hasPrefix("chrome://") ? "openarch://" + url.dropFirst("chrome://".count) : url
    }

    static func resolve(_ url: String) -> String {
        url.lowercased().hasPrefix("openarch://") ? "chrome://" + url.dropFirst("openarch://".count) : url
    }
}

// MARK: - View

struct CommandBarView: View {
    let model: CommandBarModel
    unowned let controller: CommandBarController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.6)
                    if let site = model.site {
                        Text(site.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.22)))
                    }
                    CommandField(model: model, controller: controller)
                        .frame(height: 24)
                }
                .padding(.horizontal, 18)
                .frame(height: 56)

                if !model.results.isEmpty {
                    Divider().opacity(0.6)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                                    CommandResultRow(result: result, isSelected: index == model.selection)
                                        .id(index)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.run(index) }
                                        .onHover { if $0 { model.selection = index } }
                                }
                            }
                            .padding(8)
                        }
                        .scrollIndicators(.never)
                        .frame(maxHeight: CommandBarModel.maxHeight - 110)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: model.selection) { _, selection in
                            proxy.scrollTo(selection)
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 10))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 40)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CommandResultRow: View {
    let result: CommandResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isSymbol ? 0.08 : 0)))
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                if let subtitle = result.subtitle {
                    Text(subtitle).font(.system(size: 11.5)).opacity(0.55).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let badge = result.badge {
                HStack(spacing: 8) {
                    Text(badge).font(.system(size: 11.5, weight: .medium)).opacity(isSelected ? 0.85 : 0.45)
                    if badge == "Zu Tab wechseln" || badge == "Öffnen" {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isSelected ? 0.9 : 0.1)))
                            .foregroundStyle(isSelected ? Color(nsColor: .windowBackgroundColor) : .primary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Color.primary.opacity(0.13) : .clear))
    }

    private var isSymbol: Bool {
        if case .symbol = result.icon { return true }
        return false
    }

    @ViewBuilder private var icon: some View {
        switch result.icon {
        case .item(let item):
            FaviconView(item: item, size: 18)
        case .url(let url):
            if let image = FaviconStore.shared.image(forURL: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 18, height: 18)
            } else {
                Image(systemName: "globe").font(.system(size: 13)).opacity(0.7)
            }
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 12, weight: .medium)).opacity(0.8)
        }
    }
}

/// The text field, as AppKit for reliable arrow/return/escape handling.
private struct CommandField: NSViewRepresentable {
    let model: CommandBarModel
    unowned let controller: CommandBarController

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.placeholderString = model.placeholder
        if field.stringValue != model.query {
            field.stringValue = model.query
        }
        if context.coordinator.selectAllToken != model.selectAllToken || field.window?.firstResponder !== field.currentEditor() {
            context.coordinator.selectAllToken = model.selectAllToken
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, controller: controller)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: CommandBarModel
        unowned let controller: CommandBarController
        var selectAllToken = -1

        init(model: CommandBarModel, controller: CommandBarController) {
            self.model = model
            self.controller = controller
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.moveSelection(-1)
            case #selector(NSResponder.moveDown(_:)):
                model.moveSelection(1)
            case #selector(NSResponder.insertTab(_:)):
                if !model.tab() { model.moveSelection(1) }
            case #selector(NSResponder.deleteBackward(_:)):
                return model.leaveSite()
            case #selector(NSResponder.insertNewline(_:)):
                model.run()
            case #selector(NSResponder.cancelOperation(_:)):
                controller.hide()
            default:
                return false
            }
            return true
        }
    }
}
