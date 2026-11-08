import CryptoKit
import Foundation
import SQLite3

// Moving over from other browsers: the Chromium family (Chrome and its
// channels, Brave, Edge, Vivaldi, Opera, Chromium, Dia, Helium, Comet),
// Firefox and Zen, and Safari. Bookmarks and history are read from the
// browser's own files; nothing is written there. Logins and cookies of
// Chromium browsers come over at the next launch (CredentialImport.swift).
// Nothing here logs an address, a title or a name.
//
// The approach (profile lists from `Local State` and `profiles.ini`, IDs
// that stay the same between imports) follows Airc's import
// (github.com/red545/airc, Apache-2.0).

enum BrowserKind: String, CaseIterable, Sendable, Codable {
    case chrome, brave, edge, vivaldi, opera, chromium, dia, helium, comet, firefox, zen, safari

    enum Family: Sendable { case chromium, firefox, safari }

    var family: Family {
        switch self {
        case .firefox, .zen: .firefox
        case .safari: .safari
        default: .chromium
        }
    }

    var name: String {
        switch self {
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        case .dia: "Dia"
        case .helium: "Helium"
        case .comet: "Comet"
        case .firefox: "Firefox"
        case .zen: "Zen"
        case .safari: "Safari"
        }
    }

    /// The space's color when the profile has none.
    var color: String {
        switch self {
        case .chrome, .chromium: "#4C8BF5"
        case .brave: "#FB542B"
        case .edge: "#2FA6C8"
        case .vivaldi: "#EF3939"
        case .opera: "#D9262C"
        case .dia: "#7F8FE8"
        case .helium: "#3FAE8C"
        case .comet: "#20808D"
        case .firefox: "#F1792C"
        case .zen: "#A57BE8"
        case .safari: "#1E90F0"
        }
    }

    var icon: String {
        switch family {
        case .chromium: "globe"
        case .firefox: "flame.fill"
        case .safari: "safari.fill"
        }
    }
}

/// One installation's data folder (Chrome and Chrome Beta are two).
struct BrowserInstall: Identifiable, Sendable {
    /// Stable between launches ("chrome", "chrome-beta"); part of every
    /// imported item's key.
    var id: String
    var kind: BrowserKind
    var name: String
    var bundleIDs: [String]
    /// The keychain item the browser encrypts logins and cookies with.
    var safeStorage: String?
    var folder: URL
    var profiles: [BrowserProfile]
    /// The folder is there, but macOS does not let OpenArch read it
    /// (Full Disk Access, or the protection of other apps' data).
    var needsAccess = false

    var canImportLogins: Bool { kind.family == .chromium && safeStorage != nil }
}

struct BrowserProfile: Identifiable, Sendable, Hashable {
    /// The profile's folder below the install's ("Default", "Profile 1",
    /// Firefox's "Profiles/x.default-release"; "" where the data folder is
    /// the profile, as in Opera).
    var id: String
    /// The name the browser shows, or the browser's name for a profile
    /// nobody named ("Person 1").
    var name: String
    var color: String?
    var folder: URL
    var isDefault: Bool
}

/// A bookmark (with a URL) or a folder.
struct ImportedNode: Sendable {
    /// Stable between imports: the source's own ID where it has one.
    var key: String
    var title: String
    var url: String?
    var children: [ImportedNode] = []
}

struct ImportedVisit: Sendable {
    var url: String
    var title: String
    var visitCount: Int
    var lastVisit: Date
}

/// What was left out, by reason. Counts only, never a title or an address.
struct ImportSkips: Sendable, Equatable {
    var bookmarklets = 0
    var noAddress = 0
    var tooMany = 0
    var tooDeep = 0

    static func + (a: ImportSkips, b: ImportSkips) -> ImportSkips {
        ImportSkips(bookmarklets: a.bookmarklets + b.bookmarklets, noAddress: a.noAddress + b.noAddress,
                    tooMany: a.tooMany + b.tooMany, tooDeep: a.tooDeep + b.tooDeep)
    }
}

/// One browser profile, read: it becomes an OpenArch profile and a space.
struct ImportedProfile: Sendable {
    /// "chrome/Default": the space's and the items' keys start with it.
    var sourceKey: String
    var browserName: String
    var name: String
    var color: String
    var icon: String
    /// The bookmarks bar, then one folder per other root ("Weitere Lesezeichen").
    var items: [ImportedNode]
    var visits: [ImportedVisit] = []
    var bookmarks = 0
    var folders = 0
    var skips = ImportSkips()
    /// "Lesezeichen", "Verlauf": parts that could not be read.
    var unreadable: [String] = []
    /// A bookmarks file goes into a space on an existing profile instead of
    /// a new one: a file brings no logins.
    var usesCurrentProfile = false
}

enum ImportReadError: LocalizedError {
    case unreadable, notBookmarks, notPasswords, tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: "Die Datei ließ sich nicht lesen."
        case .notBookmarks: "Die Datei enthält keine Lesezeichen im HTML-Format."
        case .notPasswords: "Die Datei ist keine Passwort-CSV: Es fehlen die Spalten für Adresse und Passwort."
        case .tooLarge: "Die Datei ist zu groß."
        }
    }
}

enum BrowserImporter {
    static let maxBookmarks = 10_000
    static let maxDepth = 64
    static let historyLimit = 20_000
    static let maxFileSize = 128 << 20

    struct Location {
        var id: String, kind: BrowserKind, name: String, path: String, bundleIDs: [String], safeStorage: String?
    }

    /// Where each browser keeps its data, below ~/Library/Application Support.
    static let locations: [Location] = [
        .init(id: "chrome", kind: .chrome, name: "Chrome", path: "Google/Chrome", bundleIDs: ["com.google.Chrome"], safeStorage: "Chrome Safe Storage"),
        .init(id: "chrome-beta", kind: .chrome, name: "Chrome Beta", path: "Google/Chrome Beta", bundleIDs: ["com.google.Chrome.beta"], safeStorage: "Chrome Safe Storage"),
        .init(id: "chrome-dev", kind: .chrome, name: "Chrome Dev", path: "Google/Chrome Dev", bundleIDs: ["com.google.Chrome.dev"], safeStorage: "Chrome Safe Storage"),
        .init(id: "chrome-canary", kind: .chrome, name: "Chrome Canary", path: "Google/Chrome Canary", bundleIDs: ["com.google.Chrome.canary"], safeStorage: "Chrome Safe Storage"),
        .init(id: "brave", kind: .brave, name: "Brave", path: "BraveSoftware/Brave-Browser", bundleIDs: ["com.brave.Browser"], safeStorage: "Brave Safe Storage"),
        .init(id: "edge", kind: .edge, name: "Edge", path: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], safeStorage: "Microsoft Edge Safe Storage"),
        .init(id: "edge-beta", kind: .edge, name: "Edge Beta", path: "Microsoft Edge Beta", bundleIDs: ["com.microsoft.edgemac.Beta"], safeStorage: "Microsoft Edge Safe Storage"),
        .init(id: "edge-dev", kind: .edge, name: "Edge Dev", path: "Microsoft Edge Dev", bundleIDs: ["com.microsoft.edgemac.Dev"], safeStorage: "Microsoft Edge Safe Storage"),
        .init(id: "edge-canary", kind: .edge, name: "Edge Canary", path: "Microsoft Edge Canary", bundleIDs: ["com.microsoft.edgemac.Canary"], safeStorage: "Microsoft Edge Safe Storage"),
        .init(id: "vivaldi", kind: .vivaldi, name: "Vivaldi", path: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], safeStorage: "Vivaldi Safe Storage"),
        .init(id: "vivaldi-snapshot", kind: .vivaldi, name: "Vivaldi Snapshot", path: "Vivaldi Snapshot", bundleIDs: ["com.vivaldi.Vivaldi.snapshot"], safeStorage: "Vivaldi Safe Storage"),
        .init(id: "opera", kind: .opera, name: "Opera", path: "com.operasoftware.Opera", bundleIDs: ["com.operasoftware.Opera"], safeStorage: "Opera Safe Storage"),
        .init(id: "opera-gx", kind: .opera, name: "Opera GX", path: "com.operasoftware.OperaGX", bundleIDs: ["com.operasoftware.OperaGX"], safeStorage: "Opera Safe Storage"),
        .init(id: "dia", kind: .dia, name: "Dia", path: "Dia/User Data", bundleIDs: ["company.thebrowser.dia"], safeStorage: "Dia Safe Storage"),
        .init(id: "helium", kind: .helium, name: "Helium", path: "net.imput.helium", bundleIDs: ["net.imput.helium"], safeStorage: "Helium Storage Key"),
        .init(id: "comet", kind: .comet, name: "Comet", path: "Comet", bundleIDs: ["ai.perplexity.comet"], safeStorage: "Comet Safe Storage"),
        .init(id: "chromium", kind: .chromium, name: "Chromium", path: "Chromium", bundleIDs: ["org.chromium.Chromium"], safeStorage: "Chromium Safe Storage"),
        .init(id: "firefox", kind: .firefox, name: "Firefox", path: "Firefox", bundleIDs: ["org.mozilla.firefox"], safeStorage: nil),
        .init(id: "zen", kind: .zen, name: "Zen", path: "zen", bundleIDs: ["app.zen-browser.zen"], safeStorage: nil),
    ]

    // MARK: Finding browsers

    /// Every browser with a data folder under |home|, Chromium browsers
    /// first, then Firefox, Zen and Safari. Reads only the profile lists.
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [BrowserInstall] {
        let support = home.appendingPathComponent("Library/Application Support")
        var installs: [BrowserInstall] = locations.compactMap { location in
            let folder = support.appendingPathComponent(location.path)
            guard isDirectory(folder) else { return nil }
            var install = BrowserInstall(id: location.id, kind: location.kind, name: location.name, bundleIDs: location.bundleIDs,
                                         safeStorage: location.safeStorage, folder: folder, profiles: [])
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil {
                install.needsAccess = true
                return install
            }
            install.profiles = location.kind.family == .firefox
                ? firefoxProfiles(folder, kind: location.kind)
                : chromiumProfiles(folder, name: location.name)
            return install.profiles.isEmpty ? nil : install
        }
        let safari = home.appendingPathComponent("Library/Safari")
        if isDirectory(safari) {
            var install = BrowserInstall(id: "safari", kind: .safari, name: "Safari", bundleIDs: ["com.apple.Safari"],
                                         safeStorage: nil, folder: safari,
                                         profiles: [BrowserProfile(id: "Safari", name: "Safari", color: nil, folder: safari, isDefault: true)])
            // Safari's library needs Full Disk Access; reading tells.
            install.needsAccess = !isReadable(safari.appendingPathComponent("Bookmarks.plist"))
                && !isReadable(safari.appendingPathComponent("History.db"))
            installs.append(install)
        }
        return installs
    }

    /// Chromium's profile list: `Local State` › profile.info_cache (name,
    /// color) in profiles_order. Only folders with bookmarks or history.
    static func chromiumProfiles(_ folder: URL, name browserName: String) -> [BrowserProfile] {
        var cache: [String: Any] = [:]
        var order: [String] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Local State")), data.count < 64 << 20,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = root["profile"] as? [String: Any] {
            cache = profile["info_cache"] as? [String: Any] ?? [:]
            order = profile["profiles_order"] as? [String] ?? []
        }
        var directories = order.filter { cache[$0] != nil }
        directories += cache.keys.filter { !directories.contains($0) }.sorted { a, b in
            a == "Default" || (b != "Default" && a.localizedStandardCompare(b) == .orderedAscending)
        }
        if !directories.contains("Default") { directories.insert("Default", at: 0) }
        var profiles: [BrowserProfile] = []
        for directory in directories where isSafeRelative(directory) && !["System Profile", "Guest Profile"].contains(directory) {
            let path = folder.appendingPathComponent(directory)
            guard hasChromiumData(path) else { continue }
            let info = cache[directory] as? [String: Any] ?? [:]
            let own = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let generic = info["is_using_default_name"] as? Bool ?? own.map(isDefaultName) ?? true
            let color = (info["profile_highlight_color"] ?? info["default_avatar_fill_color"]) as? NSNumber
            profiles.append(BrowserProfile(id: directory, name: (generic ? nil : own) ?? browserName,
                                           color: color.map { hex(argb: $0.int64Value) }, folder: path,
                                           isDefault: directory == "Default"))
        }
        // Opera keeps its one profile in the data folder itself.
        if profiles.isEmpty, hasChromiumData(folder) {
            profiles.append(BrowserProfile(id: "", name: browserName, color: nil, folder: folder, isDefault: true))
        }
        return profiles
    }

    static func hasChromiumData(_ profile: URL) -> Bool {
        isFile(profile.appendingPathComponent("Bookmarks")) || isFile(profile.appendingPathComponent("History"))
    }

    /// Firefox's (and Zen's) profiles.ini: [ProfileN] sections with Name,
    /// Path and IsRelative; the default from [Install…] or Default=1.
    static func firefoxProfiles(_ folder: URL, kind: BrowserKind) -> [BrowserProfile] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var sections: [(name: String, values: [String: String])] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if !sections.isEmpty, let equals = line.firstIndex(of: "="), !line.hasPrefix(";"), !line.hasPrefix("#") {
                sections[sections.count - 1].values[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        }
        let installDefault = sections.first { $0.name.hasPrefix("Install") }?.values["Default"]
        var profiles: [BrowserProfile] = []
        for section in sections where section.name.hasPrefix("Profile") {
            guard let path = section.values["Path"], section.values["IsRelative"] != "0", isSafeRelative(path) else { continue }
            let profile = folder.appendingPathComponent(path)
            guard isFile(profile.appendingPathComponent("places.sqlite")) else { continue }
            let own = section.values["Name"].flatMap { $0.isEmpty ? nil : $0 }
            let generic = own.map(isDefaultName) ?? true
            profiles.append(BrowserProfile(id: path, name: (generic ? nil : own) ?? kind.name, color: nil, folder: profile,
                                           isDefault: installDefault.map { $0 == path } ?? (section.values["Default"] == "1")))
        }
        return profiles.filter(\.isDefault) + profiles.filter { !$0.isDefault }
    }

    /// Names browsers give profiles nobody named.
    static func isDefaultName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if ["default", "default-release", "default-esr", "default-nightly", "your chrome", "user", "guest"].contains(lower) {
            return true
        }
        return lower.range(of: #"^(person|profile|user|default|nutzer|profil)[ -]?\d+$"#, options: .regularExpression) != nil
    }

    // MARK: Reading

    /// Reads |profiles| of |install|. Runs anywhere; the caller keeps it off
    /// the main thread. A profile whose bookmarks or history cannot be read
    /// still brings the other part.
    static func read(_ install: BrowserInstall, profiles chosen: [BrowserProfile], bookmarks: Bool, history: Bool) -> [ImportedProfile] {
        var names: [String: Int] = [:]
        return chosen.map { profile in
            let prefix = "\(install.id)/\(profile.id.isEmpty ? "_" : profile.id)"
            var builder = BookmarkBuilder(prefix: prefix)
            var bar: [ImportedNode] = []
            var visits: [ImportedVisit] = []
            var unreadable: [String] = []
            switch install.kind.family {
            case .chromium:
                if bookmarks {
                    let file = profile.folder.appendingPathComponent("Bookmarks")
                    if isFile(file) {
                        if let data = try? readLimited(file), let tree = ChromiumBookmarks.parse(data, &builder) {
                            bar = tree
                        } else {
                            unreadable.append("Lesezeichen")
                        }
                    }
                }
                if history, isFile(profile.folder.appendingPathComponent("History")) {
                    if let read = SQLiteCopy.withCopy(of: profile.folder.appendingPathComponent("History"), { ChromiumHistoryReader.read($0) }) {
                        visits = read
                    } else {
                        unreadable.append("Verlauf")
                    }
                }
            case .firefox:
                let places = profile.folder.appendingPathComponent("places.sqlite")
                let result = SQLiteCopy.withCopy(of: places) { db -> ([ImportedNode]?, [ImportedVisit]?) in
                    (bookmarks ? FirefoxPlaces.bookmarks(db, &builder) : [], history ? FirefoxPlaces.history(db) : [])
                }
                if let result {
                    if let tree = result.0 { bar = tree } else { unreadable.append("Lesezeichen") }
                    if let read = result.1 { visits = read } else { unreadable.append("Verlauf") }
                } else {
                    unreadable += (bookmarks ? ["Lesezeichen"] : []) + (history ? ["Verlauf"] : [])
                }
            case .safari:
                if bookmarks {
                    if let data = try? readLimited(profile.folder.appendingPathComponent("Bookmarks.plist")),
                       let tree = SafariBookmarks.parse(data, &builder) {
                        bar = tree
                    } else {
                        unreadable.append("Lesezeichen")
                    }
                }
                if history {
                    if let read = SQLiteCopy.withCopy(of: profile.folder.appendingPathComponent("History.db"), { SafariHistory.read($0) }) {
                        visits = read
                    } else {
                        unreadable.append("Verlauf")
                    }
                }
            }
            // Spaces are named after their profiles; two of the same name
            // in one import get "Chrome", "Chrome 2".
            var name = profile.name
            names[name.lowercased(), default: 0] += 1
            if let count = names[name.lowercased()], count > 1 { name += " \(count)" }
            return ImportedProfile(sourceKey: prefix, browserName: install.name, name: name,
                                   color: profile.color ?? install.kind.color, icon: install.kind.icon, items: bar,
                                   visits: visits, bookmarks: builder.bookmarks, folders: builder.folders,
                                   skips: builder.skips, unreadable: unreadable)
        }
    }

    /// A bookmarks HTML file (Netscape format), as Safari, Chrome, Firefox
    /// and Edge export it. It becomes one space; the same file imported
    /// again merges into it.
    static func readBookmarksFile(_ url: URL) throws -> ImportedProfile {
        let data = try readLimited(url)
        guard let (root, kind) = BookmarksHTML.parse(data) else { throw ImportReadError.notBookmarks }
        let prefix = "file-\(kind?.rawValue ?? "html")"
        var builder = BookmarkBuilder(prefix: prefix)
        let items = BookmarksHTML.tree(root, firefox: kind == .firefox, &builder)
        guard builder.bookmarks > 0 || builder.folders > 0 else { throw ImportReadError.notBookmarks }
        let name = kind.map { "\($0.name)-Lesezeichen" } ?? "Lesezeichen"
        return ImportedProfile(sourceKey: prefix, browserName: kind?.name ?? "Lesezeichen-Datei", name: name,
                               color: (kind ?? .safari).color, icon: "bookmark.fill", items: items,
                               bookmarks: builder.bookmarks, folders: builder.folders, skips: builder.skips,
                               usesCurrentProfile: true)
    }

    // MARK: Helpers

    static func readLimited(_ url: URL, limit: Int = maxFileSize) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw ImportReadError.tooLarge }
        guard let data = try? Data(contentsOf: url) else { throw ImportReadError.unreadable }
        return data
    }

    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    static func hex(argb: Int64) -> String {
        let value = UInt32(truncatingIfNeeded: argb)
        return String(format: "#%02X%02X%02X", (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Opening tells; macOS answers "not permitted" without Full Disk Access.
    static func isReadable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    static func isFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }

    /// A UUID that is always the same for |key|, so a second import finds
    /// what the first one made.
    static func stableID(_ key: String) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data(("openarch-import:" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Builds the bookmark tree with the limits every source shares, and keys
/// that stay unique even where the source repeats an ID.
struct BookmarkBuilder {
    let prefix: String
    private(set) var bookmarks = 0
    private(set) var folders = 0
    var skips = ImportSkips()
    private var given: [String: Int] = [:]

    init(prefix: String) {
        self.prefix = prefix
    }

    mutating func tab(id: String, url raw: String?, title: String?) -> ImportedNode? {
        let url = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scheme = url.prefix { $0 != ":" }.lowercased()
        if scheme == "javascript" {
            skips.bookmarklets += 1
            return nil
        }
        guard !url.isEmpty, url.contains(":"), scheme != "place", scheme != "data" else {
            skips.noAddress += 1
            return nil
        }
        guard bookmarks < BrowserImporter.maxBookmarks else {
            skips.tooMany += 1
            return nil
        }
        bookmarks += 1
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ImportedNode(key: prefix + "/" + unique(id), title: name.isEmpty ? url : name, url: url)
    }

    mutating func folder(id: String, title: String?, fallback: String = "Ordner", children: [ImportedNode]) -> ImportedNode {
        folders += 1
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ImportedNode(key: prefix + "/" + unique(id), title: name.isEmpty ? fallback : name, children: children)
    }

    func tooDeep(_ depth: Int) -> Bool { depth > BrowserImporter.maxDepth }

    /// |id|, or for a repeat "id#2", "id#3" …: two bookmarks with one ID in
    /// the source stay two. The same source read again gives the same keys.
    private mutating func unique(_ id: String) -> String {
        guard let count = given[id] else {
            given[id] = 1
            return id
        }
        var next = count + 1
        while given["\(id)#\(next)"] != nil { next += 1 }
        given[id] = next
        let key = "\(id)#\(next)"
        given[key] = 1
        return key
    }
}

// MARK: - Chromium

/// Chromium's `Bookmarks` file: roots.bookmark_bar, roots.other and
/// roots.synced, each a folder with children {type, name, url, guid}.
enum ChromiumBookmarks {
    static func parse(_ data: Data, _ builder: inout BookmarkBuilder) -> [ImportedNode]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return nil }
        func children(_ node: [String: Any], depth: Int) -> [ImportedNode] {
            guard !builder.tooDeep(depth) else {
                builder.skips.tooDeep += 1
                return []
            }
            var nodes: [ImportedNode] = []
            for case let child as [String: Any] in node["children"] as? [Any] ?? [] {
                let id = (child["guid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (child["id"] as? String) ?? "\(nodes.count)"
                if child["type"] as? String == "folder" {
                    let inner = children(child, depth: depth + 1)
                    nodes.append(builder.folder(id: id, title: child["name"] as? String, children: inner))
                } else if let tab = builder.tab(id: id, url: child["url"] as? String, title: child["name"] as? String) {
                    nodes.append(tab)
                }
            }
            return nodes
        }
        var nodes = children(roots["bookmark_bar"] as? [String: Any] ?? [:], depth: 1)
        for (key, fallback) in [("other", "Weitere Lesezeichen"), ("synced", "Mobile Lesezeichen")] {
            let node = roots[key] as? [String: Any] ?? [:]
            let inner = children(node, depth: 1)
            guard !inner.isEmpty else { continue }
            nodes.append(builder.folder(id: "root:" + key, title: fallback, children: inner))
        }
        return nodes
    }
}

/// Chromium's `History` database; times in microseconds since 1601.
enum ChromiumHistoryReader {
    static func read(_ db: OpaquePointer) -> [ImportedVisit]? {
        SQLiteCopy.rows(db, """
            SELECT url, title, visit_count, last_visit_time FROM urls
            WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_time DESC LIMIT \(BrowserImporter.historyLimit)
            """) { row in
            ImportedVisit(url: row.text(0) ?? "", title: row.text(1) ?? "", visitCount: max(1, Int(row.int(2))),
                          lastVisit: Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000 - 11_644_473_600))
        }
    }
}

// MARK: - Firefox

/// Firefox's (and Zen's) places.sqlite: moz_bookmarks (type 1 a bookmark,
/// 2 a folder) joined to moz_places; the roots by their fixed GUIDs.
enum FirefoxPlaces {
    struct Row {
        var id: Int64, type: Int64, parent: Int64, title: String?, guid: String?, url: String?
    }

    static func bookmarks(_ db: OpaquePointer, _ builder: inout BookmarkBuilder) -> [ImportedNode]? {
        guard let rows = SQLiteCopy.rows(db, """
            SELECT b.id, b.type, b.parent, b.title, b.guid, p.url
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """, { Row(id: $0.int(0), type: $0.int(1), parent: $0.int(2), title: $0.text(3), guid: $0.text(4), url: $0.text(5)) })
        else { return nil }
        var children: [Int64: [Row]] = [:]
        var roots: [String: Int64] = [:]
        for row in rows {
            children[row.parent, default: []].append(row)
            if let guid = row.guid, guid.hasSuffix("_") { roots[guid] = row.id }
        }
        var seen = Set<Int64>()
        func nodes(_ parent: Int64, depth: Int) -> [ImportedNode] {
            guard !builder.tooDeep(depth) else {
                builder.skips.tooDeep += 1
                return []
            }
            var result: [ImportedNode] = []
            for row in children[parent] ?? [] where seen.insert(row.id).inserted {
                let key = row.guid ?? "\(row.id)"
                if row.type == 1 {
                    if let tab = builder.tab(id: key, url: row.url, title: row.title) { result.append(tab) }
                } else if row.type == 2 {
                    let inner = nodes(row.id, depth: depth + 1)
                    result.append(builder.folder(id: key, title: row.title, children: inner))
                }
            }
            return result
        }
        var result = roots["toolbar_____"].map { nodes($0, depth: 1) } ?? []
        for (guid, title) in [("menu________", "Lesezeichen-Menü"), ("unfiled_____", "Weitere Lesezeichen"),
                              ("mobile______", "Mobile Lesezeichen")] {
            guard let id = roots[guid] else { continue }
            let inner = nodes(id, depth: 1)
            guard !inner.isEmpty else { continue }
            result.append(builder.folder(id: "root:" + guid.trimmingCharacters(in: CharacterSet(charactersIn: "_")),
                                         title: title, children: inner))
        }
        return result
    }

    /// Times in microseconds since 1970.
    static func history(_ db: OpaquePointer) -> [ImportedVisit]? {
        SQLiteCopy.rows(db, """
            SELECT url, title, visit_count, last_visit_date FROM moz_places
            WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
              AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_date DESC LIMIT \(BrowserImporter.historyLimit)
            """) { row in
            ImportedVisit(url: row.text(0) ?? "", title: row.text(1) ?? "", visitCount: max(1, Int(row.int(2))),
                          lastVisit: Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000))
        }
    }
}

// MARK: - Safari

/// Safari's Bookmarks.plist: nested WebBookmarkTypeList entries with
/// WebBookmarkTypeLeaf bookmarks; the bar is "BookmarksBar".
enum SafariBookmarks {
    static func parse(_ data: Data, _ builder: inout BookmarkBuilder) -> [ImportedNode]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func nodes(_ entries: [Any], depth: Int) -> [ImportedNode] {
            guard !builder.tooDeep(depth) else {
                builder.skips.tooDeep += 1
                return []
            }
            var result: [ImportedNode] = []
            for case let entry as [String: Any] in entries {
                let id = entry["WebBookmarkUUID"] as? String ?? "\(depth)-\(result.count)"
                switch entry["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    let title = (entry["URIDictionary"] as? [String: Any])?["title"] as? String
                    if let tab = builder.tab(id: id, url: entry["URLString"] as? String, title: title) { result.append(tab) }
                case "WebBookmarkTypeList":
                    let inner = nodes(entry["Children"] as? [Any] ?? [], depth: depth + 1)
                    result.append(builder.folder(id: id, title: entry["Title"] as? String, children: inner))
                default:
                    continue
                }
            }
            return result
        }
        let top = (root["Children"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var result: [ImportedNode] = []
        if let bar = top.first(where: { $0["Title"] as? String == "BookmarksBar" }) {
            result = nodes(bar["Children"] as? [Any] ?? [], depth: 1)
        }
        for entry in top where entry["Title"] as? String != "BookmarksBar" {
            let title = entry["Title"] as? String
            let id = entry["WebBookmarkUUID"] as? String ?? (title ?? "root")
            switch entry["WebBookmarkType"] as? String {
            case "WebBookmarkTypeList":
                let inner = nodes(entry["Children"] as? [Any] ?? [], depth: 1)
                guard !inner.isEmpty else { continue }
                let name = switch title {
                case "BookmarksMenu": "Lesezeichenmenü"
                case "com.apple.ReadingList": "Leseliste"
                default: title
                }
                result.append(builder.folder(id: id, title: name, children: inner))
            case "WebBookmarkTypeLeaf":
                let leafTitle = (entry["URIDictionary"] as? [String: Any])?["title"] as? String
                if let tab = builder.tab(id: id, url: entry["URLString"] as? String, title: leafTitle) { result.append(tab) }
            default:
                continue
            }
        }
        return result
    }
}

/// Safari's History.db; visit times in seconds since 2001.
enum SafariHistory {
    static func read(_ db: OpaquePointer) -> [ImportedVisit]? {
        SQLiteCopy.rows(db, """
            SELECT i.url, (SELECT v2.title FROM history_visits v2 WHERE v2.history_item = i.id ORDER BY v2.visit_time DESC LIMIT 1),
                   i.visit_count, MAX(v.visit_time) AS last
            FROM history_items i JOIN history_visits v ON v.history_item = i.id
            WHERE i.url LIKE 'http://%' OR i.url LIKE 'https://%'
            GROUP BY i.id ORDER BY last DESC LIMIT \(BrowserImporter.historyLimit)
            """) { row in
            ImportedVisit(url: row.text(0) ?? "", title: row.text(1) ?? "", visitCount: max(1, Int(row.int(2))),
                          lastVisit: Date(timeIntervalSinceReferenceDate: row.double(3)))
        }
    }
}

// MARK: - Bookmarks HTML

/// A bookmarks HTML file ("NETSCAPE-Bookmark-file-1"): folders are
/// <DT><H3>name</H3> followed by a <DL> of their entries, bookmarks
/// <DT><A HREF="…">name</A>. Read byte by byte, so inline icons stay cheap.
enum BookmarksHTML {
    final class Folder {
        var title: String
        var attributes: [String: String]
        var entries: [Entry] = []
        init(_ title: String, _ attributes: [String: String]) {
            self.title = title
            self.attributes = attributes
        }
    }

    enum Entry {
        case link(title: String, href: String)
        case folder(Folder)
    }

    static let barNames: Set<String> = ["favorites", "favourites", "favoriten", "bookmarks bar", "bookmarksbar",
                                        "lesezeichenleiste", "favoritenleiste", "lesezeichen-symbolleiste", "bookmarks toolbar"]

    /// The tree, and the browser that wrote it when it shows.
    static func parse(_ data: Data) -> (Folder, BrowserKind?)? {
        let bytes = [UInt8](data)
        let head = String(decoding: bytes.prefix(4096), as: UTF8.self).lowercased()
        guard head.contains("netscape-bookmark-file") || head.contains("<dl") else { return nil }
        let root = Folder("", [:])
        var stack = [root]
        var pending: Folder?
        var opened = false
        var firefox = false
        var index = 0
        let count = bytes.count
        func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
        while index < count {
            guard bytes[index] == 0x3C else {
                index += 1
                continue
            }
            var cursor = index + 1
            var closing = false
            if cursor < count, bytes[cursor] == 0x2F {
                closing = true
                cursor += 1
            }
            var name: [UInt8] = []
            while cursor < count, name.count < 8 {
                let byte = lower(bytes[cursor])
                guard (97...122).contains(byte) || (48...57).contains(byte) else { break }
                name.append(byte)
                cursor += 1
            }
            var quote: UInt8 = 0
            let attributeStart = cursor
            while cursor < count {
                let byte = bytes[cursor]
                if quote != 0 {
                    if byte == quote { quote = 0 }
                } else if byte == 0x22 || byte == 0x27 {
                    quote = byte
                } else if byte == 0x3E {
                    break
                }
                cursor += 1
            }
            let tag = String(decoding: name, as: UTF8.self)
            let attributes = !closing && (tag == "a" || tag == "h3")
                ? self.attributes(bytes[attributeStart..<min(cursor, count)]) : [:]
            index = cursor + 1
            func text() -> String {
                var end = index
                while end < count, bytes[end] != 0x3C { end += 1 }
                let string = decodeEntities(String(decoding: bytes[min(index, end)..<end], as: UTF8.self))
                index = end
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            switch (closing, tag) {
            case (false, "h1"):
                if text().lowercased() == "bookmarks menu" { firefox = true }
            case (false, "h3"):
                let folder = Folder(text(), attributes)
                if attributes["unfiled_bookmarks_folder"] != nil { firefox = true }
                stack[stack.count - 1].entries.append(.folder(folder))
                pending = folder
            case (false, "a"):
                let title = text()
                stack[stack.count - 1].entries.append(.link(title: title, href: attributes["href"] ?? ""))
                pending = nil
            case (false, "dl"):
                if let folder = pending {
                    stack.append(stack.count <= BrowserImporter.maxDepth ? folder : stack[stack.count - 1])
                    pending = nil
                } else if !opened {
                    opened = true
                } else {
                    stack.append(stack[stack.count - 1])
                }
            case (true, "dl"):
                if stack.count > 1 { stack.removeLast() }
                pending = nil
            default:
                break
            }
        }
        var kind: BrowserKind? = firefox ? .firefox : nil
        if kind == nil {
            for case .folder(let folder) in root.entries
            where folder.attributes["id"] == "com.apple.ReadingList"
                || (folder.attributes["personal_toolbar_folder"] == nil && folder.title.lowercased() == "favorites") {
                kind = .safari
            }
        }
        return (root, kind)
    }

    /// The bar's entries as pinned tabs and folders, every other top-level
    /// folder as a folder, loose top-level bookmarks in one more. A file has
    /// no IDs: each entry's key is a hash of its path, address and name.
    static func tree(_ root: Folder, firefox: Bool, _ builder: inout BookmarkBuilder) -> [ImportedNode] {
        var occurrences: [String: Int] = [:]
        func key(_ base: String) -> String {
            let seen = occurrences[base, default: 0]
            occurrences[base] = seen + 1
            return seen == 0 ? base : base + "#\(seen)"
        }
        func nodes(_ entries: [Entry], path: String, depth: Int) -> [ImportedNode] {
            guard !builder.tooDeep(depth) else {
                builder.skips.tooDeep += 1
                return []
            }
            var result: [ImportedNode] = []
            for entry in entries {
                switch entry {
                case .link(let title, let href):
                    let entryKey = key(path + "\u{1F}" + href + "\u{1F}" + title)
                    if let tab = builder.tab(id: hash(entryKey), url: href, title: title) { result.append(tab) }
                case .folder(let folder):
                    let folderKey = key(path + "/" + folder.title)
                    let inner = nodes(folder.entries, path: folderKey, depth: depth + 1)
                    result.append(builder.folder(id: hash(folderKey), title: folder.title, children: inner))
                }
            }
            return result
        }
        let top = root.entries
        func isBar(_ entry: Entry, byName: Bool) -> Bool {
            guard case .folder(let folder) = entry else { return false }
            return byName ? barNames.contains(folder.title.lowercased()) : folder.attributes["personal_toolbar_folder"] == "true"
        }
        let barIndex = top.firstIndex { isBar($0, byName: false) } ?? top.firstIndex { isBar($0, byName: true) }
        var result: [ImportedNode] = []
        var folders: [ImportedNode] = []
        var loose: [Entry] = []
        for (position, entry) in top.enumerated() {
            switch entry {
            case .folder(let folder) where position == barIndex:
                result = nodes(folder.entries, path: key("/" + folder.title), depth: 1)
            case .folder(let folder):
                let folderKey = key("/" + folder.title)
                let inner = nodes(folder.entries, path: folderKey, depth: 1)
                folders.append(builder.folder(id: hash(folderKey), title: folder.title, children: inner))
            case .link:
                loose.append(entry)
            }
        }
        if !loose.isEmpty {
            let inner = nodes(loose, path: key("/loose"), depth: 1)
            if !inner.isEmpty {
                folders.insert(builder.folder(id: "root:loose", title: firefox ? "Lesezeichen-Menü" : "Weitere Lesezeichen",
                                              children: inner), at: 0)
            }
        }
        return result + folders
    }

    /// HREF="…" ADD_DATE=… with lowercased names; inline icons are dropped.
    static func attributes(_ slice: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        var index = slice.startIndex
        let end = slice.endIndex
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while index < end {
            while index < end, isSpace(slice[index]) { index += 1 }
            var name: [UInt8] = []
            while index < end, !isSpace(slice[index]), slice[index] != 0x3D, slice[index] != 0x3E {
                let byte = slice[index]
                name.append(byte >= 65 && byte <= 90 ? byte + 32 : byte)
                index += 1
            }
            while index < end, isSpace(slice[index]) { index += 1 }
            var value = ""
            if index < end, slice[index] == 0x3D {
                index += 1
                while index < end, isSpace(slice[index]) { index += 1 }
                if index < end, slice[index] == 0x22 || slice[index] == 0x27 {
                    let quote = slice[index]
                    index += 1
                    let start = index
                    while index < end, slice[index] != quote { index += 1 }
                    if !name.elementsEqual("icon".utf8) {
                        value = String(decoding: slice[start..<index], as: UTF8.self)
                    }
                    index += 1
                } else {
                    let start = index
                    while index < end, !isSpace(slice[index]) { index += 1 }
                    value = String(decoding: slice[start..<index], as: UTF8.self)
                }
            }
            if !name.isEmpty { result[String(decoding: name, as: UTF8.self)] = decodeEntities(value) }
            if name.isEmpty && value.isEmpty { index += 1 }
        }
        return result
    }

    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        var rest = Substring(string)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            guard let semicolon = after.prefix(12).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let entity = after[..<semicolon]
            var decoded: String?
            switch entity.lowercased() {
            case "amp": decoded = "&"
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "quot": decoded = "\""
            case "apos", "#39": decoded = "'"
            case "nbsp": decoded = "\u{A0}"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
            }
            if let decoded {
                result += decoded
                rest = after[after.index(after: semicolon)...]
            } else {
                result += "&"
                rest = after
            }
        }
        return result + rest
    }

    /// FNV-1a 64 as hex: short and stable.
    static func hash(_ string: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return String(value, radix: 16)
    }
}

// MARK: - SQLite

/// Browsers keep their databases open, often locked; OpenArch reads a
/// private copy (with its write-ahead log) and deletes it afterwards.
enum SQLiteCopy {
    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    static func withCopy<T>(of database: URL, _ body: (OpaquePointer) -> T?) -> T? {
        withCopyURL(of: database) { copy in
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
                sqlite3_close(db)
                return nil
            }
            defer { sqlite3_close(db) }
            return body(db)
        }
    }

    /// The private copy's path, for code that opens it itself.
    static func withCopyURL<T>(of database: URL, _ body: (URL) -> T?) -> T? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("openarch-import-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(database.lastPathComponent)
        guard (try? fm.copyItem(at: database, to: copy)) != nil else { return nil }
        for suffix in ["-wal", "-journal"] where fm.fileExists(atPath: database.path + suffix) {
            try? fm.copyItem(atPath: database.path + suffix, toPath: copy.path + suffix)
        }
        return body(copy)
    }

    /// Every row of |sql|, or nil when the query fails (another schema).
    static func rows<T>(_ db: OpaquePointer, _ sql: String, _ make: (Row) -> T) -> [T]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            result.append(make(Row(statement: statement)))
        }
        return result
    }
}
