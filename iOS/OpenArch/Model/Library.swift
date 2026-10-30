import Foundation
import Observation

/// A sidebar entry: a tab (favorite, pinned or today) or a folder.
@MainActor @Observable
final class Item: Identifiable {
    enum Kind: String, Codable {
        case tab, folder
    }

    let id: UUID
    let kind: Kind
    /// Folders: their name. Tabs: the page's title, or a name of your own.
    var title: String
    /// Pinned tabs and favorites: the address they return to. Today tabs:
    /// the last one shown.
    var url: String
    /// Folders: an SF Symbol shown in the folder icon.
    var icon: String?
    var children: [Item]
    var isExpanded: Bool
    var lastActiveAt: Date

    // While its page is open.
    var liveURL: String?
    var liveTitle: String?
    var progress = 0.0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false

    init(id: UUID = UUID(), kind: Kind, title: String = "", url: String = "", icon: String? = nil,
         children: [Item] = [], isExpanded: Bool = true, lastActiveAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.icon = icon
        self.children = children
        self.isExpanded = isExpanded
        self.lastActiveAt = lastActiveAt
    }

    static func tab(url: String, title: String = "") -> Item {
        Item(kind: .tab, title: title, url: url)
    }

    static func folder(_ name: String, children: [Item] = []) -> Item {
        Item(kind: .folder, title: name, children: children)
    }

    var currentURL: String { liveURL ?? url }

    var displayTitle: String {
        if kind == .folder { return title.isEmpty ? "Ordner" : title }
        if let liveTitle, !liveTitle.isEmpty { return liveTitle }
        if !title.isEmpty { return title }
        return host.isEmpty ? currentURL : host
    }

    var host: String {
        URL(string: currentURL)?.host() ?? ""
    }

    var descendants: [Item] {
        children.flatMap { [$0] + $0.descendants }
    }

    /// Whether a pinned tab or favorite moved away from its own address.
    var hasNavigatedAway: Bool {
        guard let liveURL else { return false }
        func normalized(_ url: String) -> String {
            var text = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return normalized(liveURL) != normalized(url)
    }

    convenience init(data: ItemData) {
        self.init(id: data.id, kind: data.kind, title: data.title, url: data.url ?? "", icon: data.icon,
                  children: (data.children ?? []).map(Item.init(data:)), isExpanded: data.isExpanded ?? true,
                  lastActiveAt: data.lastActiveAt ?? Date())
    }

    func data(today: Bool) -> ItemData {
        ItemData(id: id, kind: kind, title: kind == .tab && today ? displayTitle : title,
                 url: kind == .tab ? (today ? currentURL : url) : nil, icon: icon,
                 children: kind == .folder ? children.map { $0.data(today: false) } : nil,
                 isExpanded: kind == .folder ? isExpanded : nil, lastActiveAt: lastActiveAt)
    }
}

@MainActor @Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    /// An SF Symbol name or an emoji.
    var icon: String
    var colorHex: String
    var pinned: [Item]
    var today: [Item]
    /// The tab last shown in this space.
    var activeItemID: UUID?

    init(id: UUID = UUID(), name: String, icon: String = "circle.fill", colorHex: String = "#7B6CF6",
         pinned: [Item] = [], today: [Item] = []) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.pinned = pinned
        self.today = today
    }

    convenience init(data: SpaceData) {
        self.init(id: data.id, name: data.name, icon: data.icon, colorHex: data.colorHex,
                  pinned: data.pinned.map(Item.init(data:)), today: data.today.map(Item.init(data:)))
        activeItemID = data.activeItemID
    }

    var data: SpaceData {
        SpaceData(id: id, name: name, icon: icon, colorHex: colorHex, pinned: pinned.map { $0.data(today: false) },
                  today: today.map { $0.data(today: true) }, activeItemID: activeItemID)
    }

    var folders: [Item] {
        pinned.flatMap { [$0] + $0.descendants }.filter { $0.kind == .folder }
    }
}

/// Where an item sits.
enum Place: Equatable {
    case favorites, pinned, today
}

/// Everything the user keeps: favorites, spaces with pinned folders and
/// today tabs, and the archive. Saved as JSON in Application Support.
@MainActor @Observable
final class Library {
    var favorites: [Item] = []
    var spaces: [Space] = []
    var settings = Settings()
    /// Today tabs closed or archived, newest first.
    var archive: [ArchivedTab] = []
    var selectedSpaceID: UUID?

    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored var didSave: (() -> Void)?
    @ObservationIgnored let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Lookup

    func space(id: UUID?) -> Space? {
        spaces.first { $0.id == id }
    }

    func item(id: UUID) -> Item? {
        let roots = favorites + spaces.flatMap { $0.pinned + $0.today }
        return roots.lazy.flatMap { [$0] + $0.descendants }.first { $0.id == id }
    }

    /// The space and section an item is in.
    func place(of item: Item) -> (space: Space?, place: Place)? {
        if contains(item, in: favorites) { return (nil, .favorites) }
        for space in spaces {
            if contains(item, in: space.pinned) { return (space, .pinned) }
            if space.today.contains(where: { $0 === item }) { return (space, .today) }
        }
        return nil
    }

    private func contains(_ item: Item, in roots: [Item]) -> Bool {
        roots.contains { $0 === item || $0.descendants.contains { $0 === item } }
    }

    /// The folder |item| is in, if any.
    func parent(of item: Item) -> Item? {
        let roots = favorites + spaces.flatMap(\.pinned)
        return roots.lazy.flatMap { [$0] + $0.descendants }.first { folder in
            folder.children.contains { $0 === item }
        }
    }

    // MARK: Editing

    /// Takes |item| out of wherever it is.
    func remove(_ item: Item) {
        favorites.removeAll { $0 === item }
        for space in spaces {
            space.pinned.removeAll { $0 === item }
            space.today.removeAll { $0 === item }
        }
        parent(of: item)?.children.removeAll { $0 === item }
        setNeedsSave()
    }

    func insert(_ item: Item, into folder: Item?, of space: Space, at index: Int? = nil) {
        remove(item)
        if let folder {
            folder.children.insert(item, at: min(index ?? folder.children.count, folder.children.count))
            folder.isExpanded = true
        } else {
            space.pinned.insert(item, at: min(index ?? space.pinned.count, space.pinned.count))
        }
        setNeedsSave()
    }

    @discardableResult
    func addSpace(name: String, icon: String = "circle.fill", colorHex: String = "#7B6CF6") -> Space {
        let space = Space(name: name, icon: icon, colorHex: colorHex)
        spaces.append(space)
        setNeedsSave()
        return space
    }

    func removeSpace(_ space: Space) {
        guard spaces.count > 1 else { return }
        spaces.removeAll { $0 === space }
        setNeedsSave()
    }

    func archive(_ item: Item, from space: Space) {
        guard item.kind == .tab else { return }
        archive.insert(ArchivedTab(title: item.displayTitle, url: item.currentURL, date: Date(), spaceID: space.id), at: 0)
        if archive.count > 500 {
            archive.removeLast(archive.count - 500)
        }
    }

    // MARK: Persistence

    func setNeedsSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            saveScheduled = false
            save()
        }
    }

    func save() {
        let data = LibraryData(favorites: favorites.map { $0.data(today: false) }, spaces: spaces.map(\.data),
                               settings: settings, archive: archive, selectedSpaceID: selectedSpaceID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(data).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("[OpenArch] could not save the library: \(error)")
        }
        didSave?()
    }

    /// The saved library, or a first one with a few favorites.
    static func load() -> Library {
        let library = Library(fileURL: directory.appendingPathComponent("Library.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let raw = try? Data(contentsOf: library.fileURL),
           let data = try? decoder.decode(LibraryData.self, from: raw), !data.spaces.isEmpty {
            library.favorites = data.favorites.map(Item.init(data:))
            library.spaces = data.spaces.map(Space.init(data:))
            library.settings = data.settings ?? Settings()
            library.archive = data.archive ?? []
            library.selectedSpaceID = data.selectedSpaceID
        } else {
            library.spaces = [Space(name: "Persönlich", icon: "person.fill", colorHex: "#7B6CF6")]
            library.favorites = [
                .tab(url: "https://www.google.com/", title: "Google"),
                .tab(url: "https://de.wikipedia.org/", title: "Wikipedia"),
                .tab(url: "https://github.com/", title: "GitHub"),
                .tab(url: "https://www.youtube.com/", title: "YouTube"),
            ]
        }
        return library
    }
}

// MARK: - Saved form

struct LibraryData: Codable {
    var version = 1
    var favorites: [ItemData]
    var spaces: [SpaceData]
    var settings: Settings?
    var archive: [ArchivedTab]?
    var selectedSpaceID: UUID?
}

struct SpaceData: Codable {
    var id: UUID
    var name: String
    var icon: String
    var colorHex: String
    var pinned: [ItemData]
    var today: [ItemData]
    var activeItemID: UUID?
}

struct ItemData: Codable {
    var id: UUID
    var kind: Item.Kind
    var title: String
    var url: String?
    var icon: String?
    var children: [ItemData]?
    var isExpanded: Bool?
    var lastActiveAt: Date?
}

struct ArchivedTab: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var url: String
    var date: Date
    var spaceID: UUID?
}

struct Settings: Codable, Equatable {
    enum SearchEngine: String, Codable, CaseIterable, Identifiable {
        case google, duckDuckGo, ecosia, bing, kagi
        var id: String { rawValue }
        var name: String {
            switch self {
            case .google: "Google"
            case .duckDuckGo: "DuckDuckGo"
            case .ecosia: "Ecosia"
            case .bing: "Bing"
            case .kagi: "Kagi"
            }
        }

        func url(for query: String) -> String {
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
            switch self {
            case .google: return "https://www.google.com/search?q=\(q)"
            case .duckDuckGo: return "https://duckduckgo.com/?q=\(q)"
            case .ecosia: return "https://www.ecosia.org/search?q=\(q)"
            case .bing: return "https://www.bing.com/search?q=\(q)"
            case .kagi: return "https://kagi.com/search?q=\(q)"
            }
        }

        func suggestionURL(for query: String) -> URL? {
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
            switch self {
            case .duckDuckGo: return URL(string: "https://duckduckgo.com/ac/?type=list&q=\(q)")
            case .bing: return URL(string: "https://api.bing.com/osjson.aspx?query=\(q)")
            default: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
            }
        }
    }

    var searchEngine = SearchEngine.google
    var searchSuggestions = true
    /// Hours after which today tabs not looked at are archived; 0 = never.
    var archiveAfterHours = 12
    /// The relay for live shares; empty: share.openarch.app.
    var relay = ""

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        searchEngine = try container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? defaults.searchEngine
        searchSuggestions = try container.decodeIfPresent(Bool.self, forKey: .searchSuggestions) ?? defaults.searchSuggestions
        archiveAfterHours = try container.decodeIfPresent(Int.self, forKey: .archiveAfterHours) ?? defaults.archiveAfterHours
        relay = try container.decodeIfPresent(String.self, forKey: .relay) ?? defaults.relay
    }

    /// The relay to use for new live shares, nil for the default one.
    var relayURL: URL? {
        let text = relay.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = URL(string: text.contains("://") ? text : "https://" + text),
              url.scheme == "https" else { return nil }
        return url
    }
}
