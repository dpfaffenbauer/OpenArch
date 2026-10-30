import OpenArchShared
import SwiftUI
import UIKit

/// What the address field does: open a new today tab, or load another page
/// in the tab shown.
enum CommandBarMode: Hashable {
    case newTab, edit
}

/// A folder or a space, to share.
enum ShareTarget {
    case folder(Item)
    case space(Space)

    var id: UUID {
        switch self {
        case .folder(let item): item.id
        case .space(let space): space.id
        }
    }

    @MainActor var name: String {
        switch self {
        case .folder(let item): item.displayTitle
        case .space(let space): space.name
        }
    }

    var kind: SharePayload.Kind {
        switch self {
        case .folder: .folder
        case .space: .space
        }
    }
}

/// The one sheet shown at a time.
enum Sheet: Identifiable {
    case sidebar
    case commandBar(CommandBarMode)
    case share(ShareTarget)
    case importShare(ShareURL)
    case settings
    case scanner
    case editSpace(Space)

    var id: String {
        switch self {
        case .sidebar: "sidebar"
        case .commandBar(let mode): "command-\(mode)"
        case .share(let target): "share-\(target.id)"
        case .importShare(let link): "import-\(link.fragment.hashValue)"
        case .settings: "settings"
        case .scanner: "scanner"
        case .editSpace(let space): "space-\(space.id)"
        }
    }
}

/// The browser: the space shown, the tab shown, and the pages of the tabs
/// opened lately.
@MainActor @Observable
final class Browser {
    let library: Library
    let sharing: Sharing
    var space: Space
    var activeItem: Item?
    var sheet: Sheet?
    /// iPad: the sidebar beside the page.
    var sidebarVisible = true
    /// The item whose rename alert is open.
    var renaming: Item?
    var toast: String?

    @ObservationIgnored private var tabs: [UUID: WebTab] = [:]
    /// Tabs with a page, the one shown last first.
    @ObservationIgnored private var recent: [UUID] = []
    private static let livePages = 8

    init(library: Library) {
        self.library = library
        space = library.space(id: library.selectedSpaceID) ?? library.spaces[0]
        sharing = Sharing(library: library)
        sharing.browser = self
        library.didSave = { [weak self] in self?.sharing.libraryDidSave() }
        if let id = space.activeItemID, let item = library.item(id: id), item.kind == .tab {
            activeItem = item
        }
    }

    // MARK: Pages

    /// The tab's page, made now if it has none.
    func webTab(for item: Item) -> WebTab {
        if let tab = tabs[item.id] { return tab }
        let tab = WebTab(item: item, browser: self)
        tabs[item.id] = tab
        return tab
    }

    /// The shown tab's page (made by select()).
    var activeTab: WebTab? {
        activeItem.flatMap { tabs[$0.id] }
    }

    func hasPage(_ item: Item) -> Bool {
        tabs[item.id] != nil
    }

    /// Closes the tab's page; it loads again when shown.
    func unload(_ item: Item) {
        tabs.removeValue(forKey: item.id)?.close()
        recent.removeAll { $0 == item.id }
        if item.liveURL != nil, place(of: item) == .today { item.url = item.currentURL }
        item.liveURL = nil
        item.liveTitle = nil
        item.progress = 0
        item.isLoading = false
        item.canGoBack = false
        item.canGoForward = false
    }

    private func touch(_ item: Item) {
        recent.removeAll { $0 == item.id }
        recent.insert(item.id, at: 0)
        // Only so many pages stay open; the others load again when shown.
        while recent.count > Self.livePages, let oldest = recent.last {
            if let item = library.item(id: oldest) {
                unload(item)
            } else {
                tabs.removeValue(forKey: oldest)?.close()
                recent.removeLast()
            }
        }
    }

    func pageDidChange(_ item: Item) {
        if place(of: item) == .today { library.setNeedsSave() }
    }

    // MARK: Selecting

    func select(_ item: Item) {
        guard item.kind == .tab else { return }
        if let owner = library.place(of: item)?.space, owner !== space {
            switchSpace(to: owner, restoring: false)
        }
        activeItem = item
        item.lastActiveAt = Date()
        space.activeItemID = item.id
        touch(item)
        _ = webTab(for: item)
        if case .sidebar = sheet { sheet = nil }
        library.setNeedsSave()
    }

    func switchSpace(to space: Space, restoring: Bool = true) {
        guard space !== self.space else { return }
        self.space = space
        library.selectedSpaceID = space.id
        if restoring {
            activeItem = space.activeItemID.flatMap { library.item(id: $0) }
            if let activeItem {
                touch(activeItem)
                _ = webTab(for: activeItem)
            }
        }
        library.setNeedsSave()
    }

    func place(of item: Item) -> Place? {
        library.place(of: item)?.place
    }

    // MARK: Opening

    /// Typed input: an address, or a search.
    func go(_ input: String, mode: CommandBarMode) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let url = URL(string: text), let link = ShareURL(url: url) {
            present(.importShare(link))
            return
        }
        let address = URLInput.url(from: text) ?? library.settings.searchEngine.url(for: text)
        if mode == .edit, let item = activeItem {
            webTab(for: item).load(address)
            sheet = nil
        } else {
            openInNewTab(address)
        }
    }

    func openInNewTab(_ address: String) {
        let item = Item.tab(url: address)
        space.today.insert(item, at: 0)
        select(item)
        sheet = nil
    }

    /// A link from another app: a share link, or a web page.
    func open(externalURL url: URL) {
        if let link = ShareURL(url: url) {
            present(.importShare(link))
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openInNewTab(url.absoluteString)
        }
    }

    func present(_ sheet: Sheet) {
        self.sheet = sheet
    }

    func showToast(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toast == text { toast = nil }
        }
    }

    // MARK: Editing

    /// Today tabs close (into the archive); pinned tabs and favorites only
    /// close their page.
    func close(_ item: Item) {
        guard let found = library.place(of: item) else { return }
        let owner = found.space, place = found.place
        let wasActive = activeItem === item
        if place == .today, let owner {
            library.archive(item, from: owner)
            let index = owner.today.firstIndex { $0 === item } ?? 0
            unload(item)
            owner.today.removeAll { $0 === item }
            if wasActive {
                let next = owner.today.indices.contains(index) ? owner.today[index] : owner.today.last
                activeItem = nil
                if let next { select(next) }
            }
        } else {
            unload(item)
            if wasActive { activeItem = nil }
        }
        library.setNeedsSave()
    }

    func pin(_ item: Item, into folder: Item? = nil) {
        if place(of: item) == .today {
            item.url = item.currentURL
            item.title = item.displayTitle
        }
        library.insert(item, into: folder, of: space)
    }

    func unpin(_ item: Item) {
        library.remove(item)
        item.url = item.currentURL
        space.today.insert(item, at: 0)
        library.setNeedsSave()
    }

    func addToFavorites(_ item: Item) {
        if place(of: item) == .today {
            item.url = item.currentURL
            item.title = item.displayTitle
        }
        library.remove(item)
        library.favorites.append(item)
        library.setNeedsSave()
    }

    func removeFromFavorites(_ item: Item) {
        library.remove(item)
        space.today.insert(item, at: 0)
        library.setNeedsSave()
    }

    /// Deletes a pinned tab or a folder with everything in it.
    func delete(_ item: Item) {
        for tab in [item] + item.descendants {
            unload(tab)
            if activeItem === tab { activeItem = nil }
            sharing.forget(tab.id)
        }
        library.remove(item)
    }

    @discardableResult
    func newFolder(in parent: Item? = nil, name: String = "Neuer Ordner") -> Item {
        let folder = Item.folder(name)
        library.insert(folder, into: parent, of: space)
        renaming = folder
        return folder
    }

    func rename(_ item: Item, to name: String) {
        let text = name.trimmingCharacters(in: .whitespaces)
        item.title = text
        if item.kind == .tab { item.liveTitle = nil }
        library.setNeedsSave()
    }

    func goToSavedURL(_ item: Item) {
        webTab(for: item).load(item.url)
    }

    func saveCurrentURL(_ item: Item) {
        item.url = item.currentURL
        library.setNeedsSave()
    }

    func clearToday() {
        for item in space.today {
            library.archive(item, from: space)
            unload(item)
            if activeItem === item { activeItem = nil }
        }
        space.today.removeAll()
        library.setNeedsSave()
    }

    func moveToday(from source: IndexSet, to destination: Int) {
        space.today.move(fromOffsets: source, toOffset: destination)
        library.setNeedsSave()
    }

    /// Today tabs not looked at for a while go to the archive, as on the Mac.
    func archiveStaleTabs(now: Date = Date()) {
        let hours = library.settings.archiveAfterHours
        guard hours > 0 else { return }
        for space in library.spaces {
            for item in space.today where item !== activeItem && now.timeIntervalSince(item.lastActiveAt) > Double(hours) * 3600 {
                library.archive(item, from: space)
                unload(item)
                space.today.removeAll { $0 === item }
            }
        }
        library.setNeedsSave()
    }

    func reopen(_ tab: ArchivedTab) {
        library.archive.removeAll { $0 == tab }
        if let owner = library.space(id: tab.spaceID) { switchSpace(to: owner, restoring: false) }
        let item = Item.tab(url: tab.url, title: tab.title)
        space.today.insert(item, at: 0)
        select(item)
        sheet = nil
    }

    // MARK: Spaces

    @discardableResult
    func addSpace() -> Space {
        let color = spaceColorPresets[library.spaces.count % spaceColorPresets.count]
        let space = library.addSpace(name: "Space \(library.spaces.count + 1)", icon: "circle.fill", colorHex: color)
        switchSpace(to: space)
        return space
    }

    func deleteSpace(_ space: Space) {
        guard library.spaces.count > 1 else { return }
        for item in space.pinned.flatMap({ [$0] + $0.descendants }) + space.today {
            unload(item)
            sharing.forget(item.id)
        }
        sharing.forget(space.id)
        if self.space === space, let other = library.spaces.first(where: { $0 !== space }) {
            switchSpace(to: other)
        }
        library.removeSpace(space)
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        showToast("Kopiert")
    }
}

/// Typed input that looks like an address (the Mac's command bar rules).
enum URLInput {
    static func url(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "about:"] where lower.hasPrefix(scheme) {
            return text
        }
        let hostPart = String(lower.split(separator: "/", maxSplits: 1).first ?? "")
        let host = String(hostPart.split(separator: ":").first ?? "")
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".test") {
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

    static func short(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
