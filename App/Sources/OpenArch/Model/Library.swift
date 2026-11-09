import AppKit
import Observation
import OpenArchCore
import OpenArchShared

/// Everything the user keeps: profiles, spaces, favorites, pinned folders and
/// the open "today" tabs. Saved as JSON in Application Support.
@MainActor @Observable
final class Library {
    private(set) var profiles: [Profile] = []
    private(set) var spaces: [Space] = []
    var settings = Settings()
    /// Today tabs closed or archived, newest first (for ⌘⇧T and the command bar).
    private(set) var archive: [ArchivedTab] = []
    var selectedSpaceID: UUID?

    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private let fileURL = AppPaths.support.appendingPathComponent("Library.json")

    // MARK: Lookup

    func profile(id: String) -> Profile {
        profiles.first { $0.id == id } ?? profiles[0]
    }

    func space(id: UUID?) -> Space? {
        spaces.first { $0.id == id }
    }

    /// Every container that can hold tabs, for searching and lookup.
    var allContainers: [Container] {
        profiles.map(\.favorites) + spaces.flatMap { [$0.pinned, $0.today] }
    }

    func item(id: UUID) -> Item? {
        for container in allContainers {
            if let item = container.find(id: id) {
                return item
            }
        }
        return nil
    }

    func space(containing item: Item) -> Space? {
        guard let container = item.container else { return nil }
        return spaces.first { $0.pinned === container || $0.today === container }
    }

    func profile(for item: Item, in space: Space) -> Profile {
        if let container = item.container, let owner = profiles.first(where: { $0.favorites === container }) {
            return owner
        }
        return profile(id: (self.space(containing: item) ?? space).profileID)
    }

    // MARK: Editing

    @discardableResult
    func addProfile(name: String) -> Profile {
        let directory = AppPaths.unusedProfileDirectory(besides: Set(profiles.map(\.id)))
        let profile = Profile(id: directory, name: name)
        profiles.append(profile)
        setNeedsSave()
        return profile
    }

    func renameProfile(_ profile: Profile, to name: String) {
        profile.name = name
        setNeedsSave()
    }

    @discardableResult
    func addSpace(id: UUID = UUID(), name: String, icon: String = "circle.fill", colorHex: String = "#7B6CF6",
                  profileID: String? = nil) -> Space {
        let space = Space(id: id, name: name, icon: icon, colorHex: colorHex, profileID: profileID ?? profiles[0].id)
        spaces.append(space)
        setNeedsSave()
        return space
    }

    func removeSpace(_ space: Space) {
        guard spaces.count > 1 else { return }
        for item in space.pinned.allItems + space.today.allItems {
            item.pane?.close()
            if item.kind == .agent {
                item.agentSession?.discard()
                AgentSession.deleteTranscript(item.id)
            }
        }
        spaces.removeAll { $0 === space }
        setNeedsSave()
    }

    func moveSpace(_ space: Space, by offset: Int) {
        guard let index = spaces.firstIndex(where: { $0 === space }) else { return }
        let target = max(0, min(spaces.count - 1, index + offset))
        spaces.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        setNeedsSave()
    }

    /// Sorting by dragging in „Spaces verwalten“.
    func moveSpaces(fromOffsets source: IndexSet, toOffset destination: Int) {
        spaces.move(fromOffsets: source, toOffset: destination)
        setNeedsSave()
    }

    /// Puts |space| where |target| is (dragging space icons).
    func moveSpace(_ space: Space, to target: Space) {
        guard let from = spaces.firstIndex(where: { $0 === space }),
              let to = spaces.firstIndex(where: { $0 === target }), from != to else { return }
        moveSpace(space, by: to - from)
    }

    /// |home|: the space a tab outside the library (in a window of its own)
    /// belongs to, so ⌘⇧T brings it back there.
    func archive(_ item: Item, from home: Space? = nil) {
        guard item.kind == .tab else { return }
        // The place under the line: of the tab, or of the split it was in.
        var root = item.split ?? item
        while let parent = root.parent { root = parent }
        let space = space(containing: item) ?? home
        let index = space.map { root.container === $0.today } == true ? root.indexInParent : nil
        archive.insert(ArchivedTab(title: item.displayTitle, url: item.currentURL, date: Date(),
                                   spaceID: space?.id, index: index), at: 0)
        if archive.count > 500 {
            archive.removeLast(archive.count - 500)
        }
    }

    func popArchived() -> ArchivedTab? {
        archive.isEmpty ? nil : archive.removeFirst()
    }

    func removeArchived(_ tab: ArchivedTab) {
        if let index = archive.firstIndex(of: tab) {
            archive.remove(at: index)
            setNeedsSave()
        }
    }

    func clearArchive() {
        archive.removeAll()
        setNeedsSave()
    }

    // MARK: Persistence

    /// Quitting: saved one last time, then left as it is while the tabs'
    /// browsers close. Each of them would otherwise close its tab too.
    private(set) var isFrozen = false

    func freeze() {
        save()
        isFrozen = true
    }

    func setNeedsSave() {
        guard !saveScheduled, !isFrozen else { return }
        saveScheduled = true
        after(1) {
            self.saveScheduled = false
            self.save()
        }
    }

    func save() {
        guard !isFrozen else { return }
        let data = LibraryData(
            profiles: profiles.map { ProfileData(id: $0.id, name: $0.name, favorites: $0.favorites.items.map(\.data)) },
            spaces: spaces.map(\.data),
            settings: settings,
            archive: archive,
            selectedSpaceID: selectedSpaceID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(data).write(to: fileURL, options: .atomic)
        } catch {
            log("could not save library: \(error)")
        }
        Sharing.shared.libraryDidSave()
    }

    /// Keeps a copy of the saved library beside it, as "Library (vor
    /// <reason> <time>).json", before something replaces it.
    @discardableResult
    func backUp(before reason: String) -> URL? {
        save()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Library (vor \(reason) \(formatter.string(from: Date()))).json")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backup)
            return backup
        } catch {
            log("could not back up the library: \(error)")
            return nil
        }
    }

    /// Loads the saved library, or sets up a first-run one.
    static func load() -> Library {
        let library = Library()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let raw = try? Data(contentsOf: library.fileURL),
           let data = try? decoder.decode(LibraryData.self, from: raw), !data.spaces.isEmpty {
            library.apply(data)
        } else {
            library.profiles = [Profile(id: "Default", name: "Persönlich")]
            library.spaces = [Space(name: "Persönlich", icon: "person.fill", colorHex: "#7B6CF6", profileID: "Default")]
        }
        return library
    }

    func apply(_ data: LibraryData) {
        profiles = data.profiles.map { profileData in
            let profile = Profile(id: profileData.id, name: profileData.name)
            profile.favorites.replace(with: profileData.favorites.map(Item.init(data:)))
            return profile
        }
        if profiles.isEmpty {
            profiles = [Profile(id: "Default", name: "Persönlich")]
        }
        settings = data.settings ?? Settings()
        // Before themes, grain was one setting for every space.
        spaces = data.spaces.map { Space(data: $0, legacyGrain: settings.grain) }
        archive = data.archive ?? []
        selectedSpaceID = data.selectedSpaceID
    }

    /// Replaces spaces and favorites with an import (e.g. from Arc).
    func replace(with data: LibraryData) {
        for container in allContainers {
            for item in container.allItems {
                item.pane?.close()
            }
        }
        let keepSettings = settings
        apply(data)
        settings = keepSettings
        setNeedsSave()
    }
}

// MARK: - Profiles and spaces

@MainActor @Observable
final class Profile: Identifiable {
    /// Directory name below Chromium's user data directory.
    let id: String
    var name: String
    let favorites = Container(role: .favorites)

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var chromium: OACProfile {
        OACProfile(directoryName: id)
    }
}

@MainActor @Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    /// SF Symbol name, or a single emoji.
    var icon: String
    /// Arc's theme: colors, intensity, grain, light or dark.
    var theme: ThemeData
    var profileID: String
    let pinned = Container(role: .pinned)
    let today = Container(role: .today)

    init(id: UUID = UUID(), name: String, icon: String, colorHex: String, profileID: String, theme: ThemeData? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.theme = theme ?? ThemeData(hex: colorHex)
        self.profileID = profileID
    }

    /// The tab last shown in this space.
    var activeItemID: UUID?

    /// |legacyGrain|: the grain of every space before each had its own.
    convenience init(data: SpaceData, legacyGrain: Double = 0) {
        self.init(id: data.id, name: data.name, icon: data.icon, colorHex: data.colorHex, profileID: data.profileID,
                  theme: data.theme ?? ThemeData(hex: data.colorHex, grain: legacyGrain))
        pinned.replace(with: data.pinned.map(Item.init(data:)))
        today.replace(with: data.today.map(Item.init(data:)))
        activeItemID = data.activeItemID
    }

    var data: SpaceData {
        SpaceData(id: id, name: name, icon: icon, colorHex: colorHex, profileID: profileID,
                  pinned: pinned.items.map(\.data), today: today.items.map(\.data), activeItemID: activeItemID,
                  theme: theme)
    }

    /// The theme's first color (the app icon, shared spaces). Setting it
    /// changes only that color.
    var colorHex: String {
        get { theme.colors.first ?? "#7B6CF6" }
        set {
            guard RGB(hex: newValue) != nil else { return }
            if theme.colors.isEmpty { theme.colors = [newValue] } else { theme.colors[0] = newValue }
        }
    }

    var color: NSColor {
        NSColor(hex: colorHex) ?? .systemPurple
    }
}

struct ArchivedTab: Codable, Hashable {
    var title: String
    var url: String
    var date: Date
    /// Where the tab was, so ⌘⇧T puts it back there.
    var spaceID: UUID?
    var index: Int?
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
    }

    var searchEngine = SearchEngine.google
    var searchSuggestions = true
    /// Hours after which inactive today tabs are archived; 0 = never.
    var archiveAfterHours = 12
    var showChromeToolbar = true
    var showSidebarAddress = false
    var sidebarWidth = 300.0
    /// Links from other apps open in a Little OpenArch window, as in Arc,
    /// instead of a new tab in the window. (A new key: the old one was on by
    /// default, and links now go to the window unless this is chosen.)
    var linksInLittleOpenArch = false
    /// Sites to search from the command bar: keyword or name, then Tab.
    var siteSearches = SiteSearch.defaults
    /// Where links from other apps go, by address; the first match wins.
    var linkRules: [LinkRule] = []
    /// A playing video moves to picture-in-picture when you switch tabs.
    var autoPictureInPicture = true
    /// A call (a page using the camera or the microphone) moves to a
    /// floating window when you leave its tab or window.
    var callPictureInPicture = true
    /// Sites (hosts) whose videos and calls never float by themselves.
    var pictureInPictureExceptions: [String] = []
    /// Where the floating window was moved to last (screen coordinates);
    /// nil: the bottom right of the screen.
    var pictureInPictureFrame: CGRect?
    /// Links from pinned tabs and favorites to other sites, and ⇧-clicks on
    /// any link, open in Peek.
    var peek = true
    /// Where the command bar sends a question.
    var askAI = AIChat.claude
    /// Minutes after which a tab nobody looks at goes to sleep (its page is
    /// closed until you come back to it); 0 = never.
    var sleepAfterMinutes = 120
    /// Pinned tabs and favorites of chat and mail sites (KeepAwakeSites)
    /// never sleep.
    var keepChatSitesAwake = true
    /// More sites (hosts) for that.
    var keepAwakeSites: [String] = []
    /// Chromium's HTTPS-First mode: http:// addresses try https:// first and
    /// warn before loading without it.
    var httpsOnly = false
    /// Where DevTools open (Ansicht › DevTools anordnen).
    var devToolsDock = DevToolsDock.right
    /// Streaming services (Spotify, Netflix …) open in WebKit, which plays
    /// their DRM with Apple's FairPlay (see ProtectedMedia).
    var protectedMediaWebKit = true
    /// Chromium's Widevine for sites that accept it without Verified Media
    /// Path. Off until the licence question with Google is settled.
    var widevine = false
    /// Sites whose links to an app open it without asking: "host scheme".
    var allowedExternalApps: [String] = []
    /// The relay for new live shares (docs/sharing.md); empty: share.openarch.app.
    var shareRelay = ""
    /// Agent chats (Claude Code) in the sidebar, next to the tabs.
    var agentChats = false
    /// Agent chats are on and not switched off (FeatureSwitches).
    var agentChatsOn: Bool { agentChats && FeatureSwitches.shared.isOn(.agentChats) }
    /// The folder new agent chats work in; empty for the home folder.
    var agentFolder = ""
    /// The glass look: the desktop shows through the window, and from
    /// macOS 26 on the sidebar floats on it as Liquid Glass.
    var glass = false
    /// How much of the space's color is in the glass (0–1).
    var glassTint = 0.4
    /// A click on the library button shows the newest downloads over it, as
    /// in Arc, instead of the library.
    var downloadStack = true
    /// Kinds of files (DownloadKind) they leave out, as strings, so that a
    /// kind unknown to this version does not spoil the settings.
    var downloadStackHidden: [String] = []
    /// The grain every space had before each space's theme got its own;
    /// read once to carry it over (ThemeData.grain).
    var grain = 0.0
    /// The sidebar on the window's right instead of its left, in every window.
    var sidebarOnRight = false
    /// A picture of the page when the pointer rests on a tab in the sidebar.
    var tabPreviews = true
    /// The next meeting from the Mac's calendar at the bottom of the sidebar,
    /// with a button to join it.
    var meetingBar = false
    /// Keyboard shortcuts the user set for menu commands, by command
    /// (MainMenu.commandID); an empty string takes the shortcut away.
    var shortcuts: [String: String] = [:]
    /// The morning brief: once a day Claude Code writes a page about the
    /// day ahead (see MorningBrief).
    var morningBrief = false
    /// When, in minutes after midnight (7:30).
    var morningBriefMinutes = 450
    /// Long tab titles get a short name from Apple's on-device model
    /// (ShortTitles), while Apple Intelligence is there.
    var tidyTitles = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        searchEngine = try container.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? defaults.searchEngine
        searchSuggestions = try container.decodeIfPresent(Bool.self, forKey: .searchSuggestions) ?? defaults.searchSuggestions
        archiveAfterHours = try container.decodeIfPresent(Int.self, forKey: .archiveAfterHours) ?? defaults.archiveAfterHours
        showChromeToolbar = try container.decodeIfPresent(Bool.self, forKey: .showChromeToolbar) ?? defaults.showChromeToolbar
        showSidebarAddress = try container.decodeIfPresent(Bool.self, forKey: .showSidebarAddress) ?? defaults.showSidebarAddress
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? defaults.sidebarWidth
        linksInLittleOpenArch = try container.decodeIfPresent(Bool.self, forKey: .linksInLittleOpenArch) ?? defaults.linksInLittleOpenArch
        siteSearches = try container.decodeIfPresent([SiteSearch].self, forKey: .siteSearches) ?? defaults.siteSearches
        linkRules = try container.decodeIfPresent([LinkRule].self, forKey: .linkRules) ?? defaults.linkRules
        autoPictureInPicture = try container.decodeIfPresent(Bool.self, forKey: .autoPictureInPicture) ?? defaults.autoPictureInPicture
        callPictureInPicture = try container.decodeIfPresent(Bool.self, forKey: .callPictureInPicture) ?? defaults.callPictureInPicture
        pictureInPictureExceptions = try container.decodeIfPresent([String].self, forKey: .pictureInPictureExceptions)
            ?? defaults.pictureInPictureExceptions
        pictureInPictureFrame = try container.decodeIfPresent(CGRect.self, forKey: .pictureInPictureFrame)
        peek = try container.decodeIfPresent(Bool.self, forKey: .peek) ?? defaults.peek
        askAI = try container.decodeIfPresent(AIChat.self, forKey: .askAI) ?? defaults.askAI
        sleepAfterMinutes = try container.decodeIfPresent(Int.self, forKey: .sleepAfterMinutes) ?? defaults.sleepAfterMinutes
        keepChatSitesAwake = try container.decodeIfPresent(Bool.self, forKey: .keepChatSitesAwake) ?? defaults.keepChatSitesAwake
        keepAwakeSites = try container.decodeIfPresent([String].self, forKey: .keepAwakeSites) ?? defaults.keepAwakeSites
        httpsOnly = try container.decodeIfPresent(Bool.self, forKey: .httpsOnly) ?? defaults.httpsOnly
        devToolsDock = try container.decodeIfPresent(DevToolsDock.self, forKey: .devToolsDock) ?? defaults.devToolsDock
        protectedMediaWebKit = try container.decodeIfPresent(Bool.self, forKey: .protectedMediaWebKit) ?? defaults.protectedMediaWebKit
        widevine = try container.decodeIfPresent(Bool.self, forKey: .widevine) ?? defaults.widevine
        allowedExternalApps = try container.decodeIfPresent([String].self, forKey: .allowedExternalApps) ?? defaults.allowedExternalApps
        shareRelay = try container.decodeIfPresent(String.self, forKey: .shareRelay) ?? defaults.shareRelay
        agentChats = try container.decodeIfPresent(Bool.self, forKey: .agentChats) ?? defaults.agentChats
        agentFolder = try container.decodeIfPresent(String.self, forKey: .agentFolder) ?? defaults.agentFolder
        glass = try container.decodeIfPresent(Bool.self, forKey: .glass) ?? defaults.glass
        glassTint = try container.decodeIfPresent(Double.self, forKey: .glassTint) ?? defaults.glassTint
        downloadStack = try container.decodeIfPresent(Bool.self, forKey: .downloadStack) ?? defaults.downloadStack
        downloadStackHidden = try container.decodeIfPresent([String].self, forKey: .downloadStackHidden) ?? defaults.downloadStackHidden
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? defaults.grain
        sidebarOnRight = try container.decodeIfPresent(Bool.self, forKey: .sidebarOnRight) ?? defaults.sidebarOnRight
        tabPreviews = try container.decodeIfPresent(Bool.self, forKey: .tabPreviews) ?? defaults.tabPreviews
        meetingBar = try container.decodeIfPresent(Bool.self, forKey: .meetingBar) ?? defaults.meetingBar
        shortcuts = try container.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? defaults.shortcuts
        morningBrief = try container.decodeIfPresent(Bool.self, forKey: .morningBrief) ?? defaults.morningBrief
        morningBriefMinutes = try container.decodeIfPresent(Int.self, forKey: .morningBriefMinutes) ?? defaults.morningBriefMinutes
        tidyTitles = try container.decodeIfPresent(Bool.self, forKey: .tidyTitles) ?? defaults.tidyTitles
        // 260 was the first default; Arc's rows need a bit more room.
        if sidebarWidth == 260 { sidebarWidth = defaults.sidebarWidth }
    }
}

extension Settings {
    /// The relay for new live shares, nil for the default one.
    var shareRelayURL: URL? {
        ShareRelay.url(setting: shareRelay)
    }

    /// The settings that Chromium and every tab apply themselves.
    @MainActor func applyToChromium() {
        OACProfile.setPreference("https_only_mode_enabled", value: httpsOnly)
        OACPane.devToolsDock = devToolsDock.dock
        ProtectedMedia.isEnabled = protectedMediaWebKit
    }

    /// Where a new agent chat works: the chosen folder while it is there,
    /// else the home folder.
    var agentFolderPath: String {
        var isFolder: ObjCBool = false
        if !agentFolder.isEmpty, FileManager.default.fileExists(atPath: agentFolder, isDirectory: &isFolder), isFolder.boolValue {
            return agentFolder
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}

enum DevToolsDock: String, Codable, CaseIterable {
    case right, left, bottom, window

    var title: String {
        switch self {
        case .right: "Rechts"
        case .left: "Links"
        case .bottom: "Unten"
        case .window: "Eigenes Fenster"
        }
    }

    var dock: OACDevToolsDock {
        switch self {
        case .right: .right
        case .left: .left
        case .bottom: .bottom
        case .window: .window
        }
    }
}

/// A site the command bar can search directly: "yt" + Tab, then the query.
struct SiteSearch: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var keyword: String
    /// The search URL with %s where the query goes.
    var url: String

    func url(for query: String) -> String {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? query
        return url.replacingOccurrences(of: "%s", with: q)
    }

    var host: String {
        URL(string: url.replacingOccurrences(of: "%s", with: ""))?.host() ?? ""
    }

    static let defaults: [SiteSearch] = [
        SiteSearch(name: "YouTube", keyword: "yt", url: "https://www.youtube.com/results?search_query=%s"),
        SiteSearch(name: "Google", keyword: "g", url: "https://www.google.com/search?q=%s"),
        SiteSearch(name: "Wikipedia", keyword: "w", url: "https://de.wikipedia.org/w/index.php?search=%s"),
        SiteSearch(name: "GitHub", keyword: "gh", url: "https://github.com/search?q=%s"),
        SiteSearch(name: "Google Maps", keyword: "maps", url: "https://www.google.com/maps/search/%s"),
        SiteSearch(name: "Amazon", keyword: "amz", url: "https://www.amazon.de/s?k=%s"),
        SiteSearch(name: "Stack Overflow", keyword: "so", url: "https://stackoverflow.com/search?q=%s"),
        SiteSearch(name: "MDN", keyword: "mdn", url: "https://developer.mozilla.org/search?q=%s"),
        SiteSearch(name: "npm", keyword: "npm", url: "https://www.npmjs.com/search?q=%s"),
        SiteSearch(name: "Claude", keyword: "cl", url: "https://claude.ai/new?q=%s"),
        SiteSearch(name: "ChatGPT", keyword: "gpt", url: "https://chatgpt.com/?q=%s"),
        SiteSearch(name: "Perplexity", keyword: "pp", url: "https://www.perplexity.ai/search?q=%s"),
    ]
}

/// The chat a question from the command bar goes to: a new chat on the
/// site, signed in as you, so it runs on your own subscription. No API key.
enum AIChat: String, Codable, CaseIterable, Identifiable {
    case off, claude, chatGPT

    var id: String { rawValue }

    var name: String {
        switch self {
        case .off: "Aus"
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    /// A new chat with |question| in it, or nil when off.
    func url(for question: String) -> String? {
        let template = switch self {
        case .off: ""
        case .claude: "https://claude.ai/new?q=%s"
        case .chatGPT: "https://chatgpt.com/?q=%s"
        }
        guard !template.isEmpty else { return nil }
        return SiteSearch(name: name, keyword: "", url: template).url(for: question)
    }

    /// A sentence or a question rather than a few search words.
    static func readsLikeQuestion(_ text: String) -> Bool {
        text.hasSuffix("?") || text.split(whereSeparator: \.isWhitespace).count >= 5
    }
}

/// A link rule: links from other apps whose address matches |pattern| open
/// in a space (or in Little OpenArch when |spaceID| is nil).
struct LinkRule: Codable, Equatable, Identifiable {
    var id = UUID()
    /// "github.com" (and its subdomains), "*.atlassian.net",
    /// "docs.google.com/spreadsheets" (a path prefix).
    var pattern: String
    var spaceID: UUID?

    func matches(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let rawHost = components.host?.lowercased() else { return false }
        var text = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        guard !text.isEmpty else { return false }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        let hostPattern = parts[0]
        let hostMatches: Bool
        if hostPattern.contains("*") {
            let regex = "^" + NSRegularExpression.escapedPattern(for: hostPattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
            hostMatches = host.range(of: regex, options: .regularExpression) != nil
        } else {
            hostMatches = host == hostPattern || host.hasSuffix("." + hostPattern)
        }
        guard hostMatches else { return false }
        guard parts.count > 1, !parts[1].isEmpty else { return true }
        return components.path.lowercased().hasPrefix("/" + parts[1])
    }
}
