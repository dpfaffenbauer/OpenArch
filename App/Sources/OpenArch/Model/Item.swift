import AppKit
import Observation
import OpenArchCore

/// An ordered list of sidebar items: a profile's favorites, or a space's
/// pinned or today section.
@MainActor @Observable
final class Container {
    enum Role: String {
        case favorites, pinned, today
    }

    let role: Role
    private(set) var items: [Item] = []

    init(role: Role) {
        self.role = role
    }

    func replace(with items: [Item]) {
        self.items = items
        for item in items {
            item.attach(to: self, parent: nil)
        }
    }

    /// Inserts |item| into |folder| (or at the top level) at |index|.
    func insert(_ item: Item, into folder: Item? = nil, at index: Int? = nil) {
        item.detach()
        if let folder {
            let position = min(index ?? folder.children.count, folder.children.count)
            folder.children.insert(item, at: position)
            item.attach(to: self, parent: folder)
        } else {
            let position = min(index ?? items.count, items.count)
            items.insert(item, at: position)
            item.attach(to: self, parent: nil)
        }
    }

    fileprivate func removeTopLevel(_ item: Item) {
        items.removeAll { $0 === item }
    }

    /// All items, depth first.
    var allItems: [Item] {
        items.flatMap { [$0] + $0.descendants }
    }

    /// All tabs (including tabs inside folders and splits).
    var allTabs: [Item] {
        allItems.filter { $0.kind == .tab }
    }

    func find(id: UUID) -> Item? {
        allItems.first { $0.id == id }
    }
}

/// A sidebar entry: a tab (pinned, favorite or today), a folder, or a split
/// view grouping tabs side by side. A tab is loaded lazily: it gets a Chrome
/// pane the first time it is shown.
@MainActor @Observable
final class Item: Identifiable {
    enum Kind: String, Codable {
        case tab, folder, split
    }

    let id: UUID
    let kind: Kind
    /// A user-chosen name (folders, renamed tabs).
    var customTitle: String?
    /// Folders: an SF Symbol shown inside the folder icon.
    var icon: String?
    /// For pinned tabs and favorites: the URL the tab returns to. For today
    /// tabs: the last known URL.
    var savedURL: String
    var savedTitle: String
    var children: [Item] = []
    var isExpanded = true
    /// Split views: the share of the width (or height) each child gets.
    var splitFractions: [Double] = []
    /// Split views: the tabs one above the other instead of side by side.
    var splitStacked = false
    var lastActiveAt: Date

    private(set) weak var container: Container?
    private(set) weak var parent: Item?

    // Live state while a pane exists.
    var pane: OACPane?
    var liveURL: String?
    var liveTitle: String?
    var favicon: NSImage?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    /// Played sound in the last moments (reported by Chrome).
    var isAudible = false
    var isMuted = false
    /// What the page plays, from OpenArch's built-in extension.
    var media: MediaState?
    /// The media card was closed; it comes back when the page plays again.
    var mediaDismissed = false
    /// Its page was closed to save memory; it loads again when shown.
    var isAsleep = false

    init(id: UUID = UUID(), kind: Kind, title: String = "", url: String = "", customTitle: String? = nil,
         children: [Item] = [], lastActiveAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.savedTitle = title
        self.savedURL = url
        self.customTitle = customTitle
        self.children = children
        self.lastActiveAt = lastActiveAt
        for child in children {
            child.parent = self
        }
    }

    static func tab(url: String, title: String = "") -> Item {
        Item(kind: .tab, title: title, url: url)
    }

    static func folder(_ name: String, children: [Item] = []) -> Item {
        Item(kind: .folder, customTitle: name, children: children)
    }

    // MARK: Tree

    fileprivate func attach(to container: Container, parent: Item?) {
        self.container = container
        self.parent = parent
        for child in children {
            child.attach(to: container, parent: self)
        }
    }

    /// Removes the item from its container or parent.
    func detach() {
        if let parent {
            parent.children.removeAll { $0 === self }
            // A split with one tab left is just that tab.
            if parent.kind == .split, parent.children.count == 1, let remaining = parent.children.first,
               let container = parent.container {
                let index = parent.indexInParent
                let grandparent = parent.parent
                parent.detach()
                container.insert(remaining, into: grandparent, at: index)
            }
        } else {
            container?.removeTopLevel(self)
        }
        parent = nil
        container = nil
    }

    var descendants: [Item] {
        children.flatMap { [$0] + $0.descendants }
    }

    var indexInParent: Int {
        if let parent {
            return parent.children.firstIndex { $0 === self } ?? 0
        }
        return container?.items.firstIndex { $0 === self } ?? 0
    }

    func isDescendant(of other: Item) -> Bool {
        var current = parent
        while let item = current {
            if item === other { return true }
            current = item.parent
        }
        return false
    }

    /// The folder this item sits in, if any.
    var parentFolder: Item? {
        parent?.kind == .folder ? parent : nil
    }

    /// The split view this tab is shown in, if any.
    var split: Item? {
        parent?.kind == .split ? parent : nil
    }

    var role: Container.Role? {
        container?.role
    }

    // MARK: Display

    var currentURL: String {
        liveURL ?? savedURL
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        switch kind {
        case .folder: return "Ordner"
        case .split: return children.map(\.displayTitle).joined(separator: " | ")
        case .tab:
            if let liveTitle, !liveTitle.isEmpty { return liveTitle }
            if !savedTitle.isEmpty { return savedTitle }
            return URL(string: currentURL)?.host() ?? currentURL
        }
    }

    var host: String {
        URL(string: currentURL)?.host() ?? ""
    }

    /// Whether a pinned tab or favorite moved away from its saved URL.
    var hasNavigatedAway: Bool {
        guard role != .today, let liveURL else { return false }
        func normalized(_ url: String) -> String {
            var text = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return normalized(liveURL) != normalized(savedURL)
    }

    // MARK: Persistence

    convenience init(data: ItemData) {
        self.init(id: data.id, kind: data.kind, title: data.title ?? "", url: data.url ?? "",
                  customTitle: data.customTitle, children: (data.children ?? []).map(Item.init(data:)),
                  lastActiveAt: data.lastActiveAt ?? Date())
        isExpanded = data.isExpanded ?? true
        splitFractions = data.splitFractions ?? []
        splitStacked = data.splitStacked ?? false
        icon = data.icon
    }

    var data: ItemData {
        ItemData(id: id, kind: kind,
                 title: kind == .tab ? (liveTitle ?? savedTitle) : nil,
                 url: kind == .tab ? (role == .today ? currentURL : savedURL) : nil,
                 customTitle: customTitle,
                 children: kind == .tab ? nil : children.map(\.data),
                 isExpanded: kind == .folder ? isExpanded : nil,
                 splitFractions: kind == .split && !splitFractions.isEmpty ? splitFractions : nil,
                 splitStacked: kind == .split && splitStacked ? true : nil,
                 lastActiveAt: lastActiveAt,
                 icon: icon)
    }
}

// MARK: - Saved form

struct LibraryData: Codable {
    var version = 1
    var profiles: [ProfileData]
    var spaces: [SpaceData]
    var settings: Settings?
    var archive: [ArchivedTab]?
    var selectedSpaceID: UUID?
}

struct ProfileData: Codable {
    var id: String
    var name: String
    var favorites: [ItemData]
}

struct SpaceData: Codable {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var profileID: String
    var pinned: [ItemData]
    var today: [ItemData]
    var activeItemID: UUID?
}

struct ItemData: Codable {
    var id: UUID
    var kind: Item.Kind
    var title: String?
    var url: String?
    var customTitle: String?
    var children: [ItemData]?
    var isExpanded: Bool?
    var splitFractions: [Double]?
    var splitStacked: Bool?
    var lastActiveAt: Date?
    var icon: String?
}

/// A page's audio or video, as its media element and Media Session report it.
struct MediaState: Equatable, Decodable {
    var playing = false
    var video = false
    var audible = false
    var title = ""
    var artist = ""
    var pip = false
}
