import Foundation

/// Reads Arc's sidebar (StorableSidebar.json: spaces, favorites, pinned
/// folders, today tabs, split views) into OpenArch's library format. This is
/// the user's own data in a plain JSON file; nothing of Arc itself is used.
enum ArcImporter {
    static let sidebarURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: sidebarURL.path)
    }

    struct Summary {
        var spaces = 0
        var favorites = 0
        var pinned = 0
        var folders = 0
        var today = 0
    }

    enum ImportError: LocalizedError {
        case unreadable, unexpectedFormat
        var errorDescription: String? {
            switch self {
            case .unreadable: "Arcs Sidebar-Datei konnte nicht gelesen werden."
            case .unexpectedFormat: "Arcs Sidebar-Datei hat ein unbekanntes Format."
            }
        }
    }

    /// |currentProfiles|: OpenArch's profiles now, directory by name. An Arc
    /// profile imported before keeps its directory, and its logins; any
    /// other gets one no profile has used. Arc's own profile goes into
    /// |defaultDirectory| ("Default", or a fresh one the onboarding fills
    /// with Arc's logins while Chromium runs).
    static func load(from url: URL = sidebarURL, currentProfiles: [String: String] = [:],
                     defaultDirectory: String = "Default") throws -> (LibraryData, Summary) {
        guard let raw = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { throw ImportError.unreadable }
        guard let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["items"] != nil })
        else { throw ImportError.unexpectedFormat }

        // Arc encodes dictionaries as flat [key, value, key, value] arrays.
        let items = pairs(main["items"]).compactMap { $0.value as? [String: Any] }
        var byID: [String: [String: Any]] = [:]
        for item in items {
            if let id = item["id"] as? String { byID[id] = item }
        }
        let spaceObjects = pairs(main["spaces"]).compactMap { $0.value as? [String: Any] }
        let topApps = pairs(main["topAppsContainerIDs"])

        var summary = Summary()
        var profiles: [ProfileData] = []
        var profileIDsByArcKey: [String: String] = [:]

        func profileID(for arcProfile: Any?) -> String {
            let key = profileKey(arcProfile)
            if let existing = profileIDsByArcKey[key] { return existing }
            let name = key == "default" ? "Persönlich" : "Arc – \(key)"
            let taken = Set(profiles.map(\.id)).union([defaultDirectory])
            let id = if key == "default" {
                defaultDirectory
            } else if let kept = currentProfiles[name], kept != "Default", !taken.contains(kept) {
                kept
            } else {
                AppPaths.unusedProfileDirectory(besides: taken.union(currentProfiles.values))
            }
            profiles.append(ProfileData(id: id, name: name, favorites: []))
            profileIDsByArcKey[key] = id
            return id
        }

        func convert(_ id: String) -> ItemData? {
            guard let item = byID[id], let data = item["data"] as? [String: Any] else { return nil }
            let childIDs = item["childrenIds"] as? [String] ?? []
            let title = item["title"] as? String
            let uuid = UUID(uuidString: id) ?? UUID()
            if let tab = data["tab"] as? [String: Any] {
                guard let url = tab["savedURL"] as? String, !url.isEmpty else { return nil }
                let lastActive = (tab["timeLastActiveAt"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:))
                return ItemData(id: uuid, kind: .tab, title: tab["savedTitle"] as? String ?? "", url: url,
                                customTitle: title, lastActiveAt: lastActive)
            }
            if let list = data["list"] as? [String: Any] {
                summary.folders += 1
                let iconType = (list["customInfo"] as? [String: Any])?["iconType"]
                let folderIcon = iconType.map { icon(from: $0) }.flatMap { $0 == "circle.fill" ? nil : $0 }
                return ItemData(id: uuid, kind: .folder, customTitle: title ?? "Ordner",
                                children: childIDs.compactMap { convert($0) }, isExpanded: false, icon: folderIcon)
            }
            if let split = data["splitView"] as? [String: Any] {
                let children = childIDs.compactMap { convert($0) }.filter { $0.kind == .tab }
                guard children.count > 1 else { return children.first }
                let factors = pairs(split["itemWidthFactors"])
                var fractions = children.map { child in
                    factors.first { ($0.key as? String) == child.id.uuidString }?.value as? Double ?? 1
                }
                let total = fractions.reduce(0, +)
                fractions = fractions.map { $0 / max(total, 0.01) }
                // Arc's "vertical" layout puts the tabs one above the other.
                return ItemData(id: uuid, kind: .split, customTitle: title, children: children,
                                splitFractions: fractions,
                                splitStacked: split["layoutOrientation"] as? String == "vertical" ? true : nil)
            }
            return nil
        }

        var spaces: [SpaceData] = []
        for space in spaceObjects {
            guard let id = space["id"] as? String else { continue }
            let containerIDs = pairs(space["containerIDs"])
            let pinnedID = containerIDs.first { ($0.key as? String) == "pinned" }?.value as? String
            let todayID = containerIDs.first { ($0.key as? String) == "unpinned" }?.value as? String
            let pinned = (pinnedID.flatMap { byID[$0]?["childrenIds"] as? [String] } ?? []).compactMap { convert($0) }
            // Today tabs count as just used, or auto-archiving would take
            // them away on first launch.
            let today = (todayID.flatMap { byID[$0]?["childrenIds"] as? [String] } ?? []).compactMap { convert($0) }
                .map(markActive)
            let info = space["customInfo"] as? [String: Any]
            let theme = theme(from: info?["windowTheme"]) ?? ThemeData(hex: "#7B6CF6")
            spaces.append(SpaceData(
                id: UUID(uuidString: id) ?? UUID(),
                name: space["title"] as? String ?? "Space",
                icon: icon(from: info?["iconType"]),
                colorHex: theme.colors[0],
                profileID: profileID(for: space["profile"]),
                pinned: pinned,
                today: today,
                theme: theme))
            summary.spaces += 1
            summary.pinned += pinned.reduce(0) { $0 + tabCount($1) }
            summary.today += today.reduce(0) { $0 + tabCount($1) }
        }
        guard !spaces.isEmpty else { throw ImportError.unexpectedFormat }

        for (arcProfile, containerID) in topApps {
            guard let containerID = containerID as? String,
                  let childIDs = byID[containerID]?["childrenIds"] as? [String] else { continue }
            let id = profileID(for: arcProfile)
            let favorites = childIDs.compactMap { convert($0) }.filter { $0.kind == .tab }
            if let index = profiles.firstIndex(where: { $0.id == id }) {
                profiles[index].favorites = favorites
                summary.favorites += favorites.count
            }
        }

        return (LibraryData(profiles: profiles, spaces: spaces), summary)
    }

    // MARK: Helpers

    private static func pairs(_ value: Any?) -> [(key: Any, value: Any)] {
        guard let array = value as? [Any] else { return [] }
        return stride(from: 0, to: array.count - 1, by: 2).map { (array[$0], array[$0 + 1]) }
    }

    private static func profileKey(_ profile: Any?) -> String {
        guard let dict = profile as? [String: Any] else { return "default" }
        if dict["default"] != nil { return "default" }
        if let name = findString(in: dict, key: "directoryBasename") { return name }
        return "custom"
    }

    private static func findString(in value: Any, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let string = dict[key] as? String { return string }
            for nested in dict.values {
                if let found = findString(in: nested, key: key) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = findString(in: nested, key: key) { return found }
            }
        }
        return nil
    }

    private static func markActive(_ item: ItemData) -> ItemData {
        var item = item
        item.lastActiveAt = Date()
        item.children = item.children?.map(markActive)
        return item
    }

    private static func tabCount(_ item: ItemData) -> Int {
        item.kind == .tab ? 1 : (item.children ?? []).reduce(0) { $0 + tabCount($1) }
    }

    /// Arc icons are either emoji or names from Arc's own icon set; the
    /// common ones map to SF Symbols.
    private static func icon(from iconType: Any?) -> String {
        guard let dict = iconType as? [String: Any] else { return "circle.fill" }
        for value in dict.values {
            if let string = value as? String, string.count == 1, string.unicodeScalars.first?.properties.isEmoji == true {
                return string
            }
        }
        let names: [String: String] = [
            "server": "server.rack", "flash": "bolt.fill", "star": "star.fill", "heart": "heart.fill",
            "home": "house.fill", "house": "house.fill", "briefcase": "briefcase.fill", "book": "book.fill",
            "code": "chevron.left.forwardslash.chevron.right", "music": "music.note", "bolt": "bolt.fill",
            "globe": "globe", "person": "person.fill", "gamecontroller": "gamecontroller.fill",
            "cart": "cart.fill", "folder": "folder.fill", "leaf": "leaf.fill", "flame": "flame.fill",
            "moon": "moon.fill", "sun": "sun.max.fill", "cloud": "cloud.fill", "camera": "camera.fill",
            "paintbrush": "paintbrush.fill", "terminal": "terminal.fill", "graduationcap": "graduationcap.fill",
        ]
        if let name = dict["icon"] as? String {
            return names[name] ?? "circle.fill"
        }
        return "circle.fill"
    }

    /// A space's theme as Arc keeps it (customInfo.windowTheme): under
    /// background.single, a `blendedSingleColor` (one color) or a
    /// `blendedGradient` (baseColors, then overlayColors), each with
    /// modifiers.intensityFactor and noiseFactor, and translucencyStyle light
    /// or dark. Arc wraps values in {"_0": …}. Older files only have
    /// primaryColorPalette.midTone, which becomes a single color.
    static func theme(from windowTheme: Any?) -> ThemeData? {
        guard let windowTheme = windowTheme as? [String: Any] else { return nil }
        if let (kind, style) = find(["blendedGradient", "blendedSingleColor"], in: windowTheme["background"]) {
            let node = unwrap(style)
            var colors: [String] = []
            if kind == "blendedGradient" {
                colors = list(node["baseColors"]).compactMap(hex) + list(node["overlayColors"]).compactMap(hex)
            } else if let single = hex(node["color"]) ?? hex(node) {
                colors = [single]
            }
            let modifiers = unwrap(node["modifiers"])
            if !colors.isEmpty {
                return ThemeData(colors: Array(colors.prefix(ThemeData.maxColors)),
                                 intensity: number(modifiers["intensityFactor"]) ?? ThemeData.defaultIntensity,
                                 grain: number(modifiers["noiseFactor"]) ?? 0,
                                 appearance: appearance(node["translucencyStyle"] ?? modifiers["translucencyStyle"]))
            }
        }
        let palette = unwrap(windowTheme["primaryColorPalette"])
        return hex(palette["midTone"]).map { ThemeData(hex: $0) }
    }

    /// {"_0": x} → x, however deep.
    private static func unwrap(_ value: Any?) -> [String: Any] {
        var dict = value as? [String: Any] ?? [:]
        while dict.count == 1, let inner = dict["_0"] as? [String: Any] { dict = inner }
        return dict
    }

    private static func list(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        return []
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// {red, green, blue} from 0 to 1 (extended sRGB may go beyond), or
    /// such a color under "color".
    private static func hex(_ value: Any?) -> String? {
        let dict = unwrap(value)
        if dict["red"] == nil, let inner = dict["color"] { return hex(inner) }
        guard let red = number(dict["red"]), let green = number(dict["green"]), let blue = number(dict["blue"]) else { return nil }
        return RGB(red, green, blue).hex
    }

    private static func appearance(_ value: Any?) -> ThemeAppearance {
        let label = (value as? String) ?? (value as? [String: Any])?.keys.first ?? ""
        if label.lowercased().contains("dark") { return .dark }
        if label.lowercased().contains("light") { return .light }
        return .auto
    }

    /// The first of |keys| found, depth first, with its value.
    private static func find(_ keys: [String], in value: Any?, depth: Int = 0) -> (String, Any)? {
        guard depth < 12 else { return nil }
        if let dict = value as? [String: Any] {
            for key in keys { if let found = dict[key] { return (key, found) } }
            for key in dict.keys.sorted() {
                if let found = find(keys, in: dict[key], depth: depth + 1) { return found }
            }
        } else if let array = value as? [Any] {
            for element in array {
                if let found = find(keys, in: element, depth: depth + 1) { return found }
            }
        }
        return nil
    }
}
