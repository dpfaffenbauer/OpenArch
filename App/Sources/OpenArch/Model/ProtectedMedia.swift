// Adapted from Cra's ProtectedMedia.swift (https://github.com/VictorKildahl/cra,
// Packages/CraCore), MIT License, Copyright (c) 2026 Victor Kildahl. See NOTICE.

import Foundation
import OpenArchCore

/// Sites that play protected media (DRM) only in WebKit.
///
/// OpenArch's Chromium has no Widevine that these services accept: they want
/// Widevine's Verified Media Path, a signature over the browser's binaries
/// made with a certificate Google licenses through paid partners. WebKit
/// plays them with Apple's FairPlay, which macOS gives every app. So their
/// pages open in a WebKit page (WebKitPage), with Safari's user agent.
///
/// The rules, as a value:
/// - A page OpenArch opens (typed, a new tab, restored, pinned, a link from
///   another app, Little OpenArch, Peek) gets `engine(for:)`: WebKit for a
///   listed site, Chromium for anything else.
/// - A Chromium page's own navigation to a listed site is stopped before its
///   request goes out and opens again in WebKit in the same tab (`handoff`).
///   A POST stays in Chromium: its body cannot move.
/// - A WebKit page stays WebKit for its own navigations (sign-in goes
///   through Google or Apple and has to come back to the same cookies). Only
///   OpenArch's address fields pick again (`engine(forAddress:current:)`).
/// - Sign-in hosts never count: other sites send "Sign in with Spotify"
///   through them, and that has to finish in the engine it started in.
struct ProtectedMediaSites: Equatable {
    /// The services' web players. An entry matches its host and the host's
    /// subdomains; "name.*" stands for any top-level domain (joyn.de,
    /// music.amazon.co.uk); "host/path" also needs the path to start with it
    /// (Prime Video on Amazon's stores; the rest of Amazon stays in Chromium).
    static let defaultEntries = [
        "open.spotify.com",
        "netflix.com",
        "disneyplus.com",
        "max.com", "hbomax.com",
        "primevideo.com",
        "amazon.*/gp/video",
        "music.amazon.*",
        "hulu.com",
        "paramountplus.com",
        "peacocktv.com",
        "tv.apple.com", "music.apple.com",
        "listen.tidal.com",
        "deezer.com",
        "crunchyroll.com",
        "joyn.*",
        "rakuten.tv",
    ]

    /// Sign-in and account hosts under a listed entry that never count.
    static let signInHosts = ["accounts.spotify.com", "login.tidal.com", "connect.deezer.com", "account.deezer.com"]

    /// What the toast and Site Controls call each service.
    static let serviceNames: [String: String] = [
        "open.spotify.com": "Spotify", "netflix.com": "Netflix", "disneyplus.com": "Disney+", "max.com": "Max",
        "hbomax.com": "HBO Max", "primevideo.com": "Prime Video", "amazon.*/gp/video": "Prime Video",
        "music.amazon.*": "Amazon Music", "hulu.com": "Hulu", "paramountplus.com": "Paramount+",
        "peacocktv.com": "Peacock", "tv.apple.com": "Apple TV", "music.apple.com": "Apple Music",
        "listen.tidal.com": "Tidal", "deezer.com": "Deezer", "crunchyroll.com": "Crunchyroll", "joyn.*": "Joyn",
        "rakuten.tv": "Rakuten TV",
    ]

    /// Second-level labels of two-label top-level domains (co.uk, com.au).
    private static let secondLevelLabels: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu", "ne", "or"]

    /// Off: every page is Chromium's.
    var isEnabled = true
    private(set) var entries: [String]

    /// |extraHosts| add to the list (sites sent to WebKit, the self-test's
    /// stand-in), |removedHosts| take entries off it.
    init(isEnabled: Bool = true, extraHosts: [String] = [], removedHosts: [String] = []) {
        self.isEnabled = isEnabled
        let removed = Set(removedHosts.compactMap(Self.normalizedEntry))
        var seen = Set<String>()
        entries = (Self.defaultEntries + extraHosts).compactMap(Self.normalizedEntry)
            .filter { !removed.contains($0) && seen.insert($0).inserted }
    }

    /// The engine a page OpenArch opens at |url| gets. WebKit only: the
    /// browser no longer ships Chromium.
    func engine(for url: String) -> OACPageEngine { .webKit }

    /// An address field's pick: always WebKit, no engine switch remains.
    func engine(forAddress url: String, current: OACPageEngine) -> OACPageEngine { .webKit }

    /// A navigation a page started itself: never moves engines; there is
    /// only one.
    func handsOff(from current: OACPageEngine, to url: String, method: String) -> Bool { false }

    /// The listed entry |url| falls under (nil while off, for a sign-in host
    /// and for anything but http and https).
    func entry(for url: String) -> String? {
        guard isEnabled, let host = Self.webHost(of: url), !Self.isSignInHost(host: host) else { return nil }
        let path = URLComponents(string: url.trimmingCharacters(in: .whitespaces))?.path.lowercased() ?? ""
        return entries.first { Self.matches($0, host: host, path: path) }
    }

    /// "Spotify" for a page on open.spotify.com; a host added by hand names
    /// itself.
    func serviceName(for url: String) -> String? {
        entry(for: url).map { Self.serviceNames[$0] ?? $0 }
    }

    static func isSignInHost(_ url: String) -> Bool {
        webHost(of: url).map { isSignInHost(host: $0) } ?? false
    }

    private static func isSignInHost(host: String) -> Bool {
        signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func matches(_ entry: String, host: String, path: String) -> Bool {
        let (pattern, prefix) = split(entry)
        if let prefix, !(path == prefix || path.hasPrefix(prefix + "/")) { return false }
        guard pattern.hasSuffix(".*") else { return host == pattern || host.hasSuffix("." + pattern) }
        // "name.*": the name's labels right before a top-level domain of one
        // label, or of two (co.uk).
        let name = pattern.dropLast(2).split(separator: ".").map(String.init)
        let labels = host.split(separator: ".").map(String.init)
        for tld in 1...2 {
            guard labels.count >= name.count + tld else { continue }
            if tld == 2, !secondLevelLabels.contains(labels[labels.count - 2]) { continue }
            let end = labels.count - tld
            if Array(labels[(end - name.count)..<end]) == name { return true }
        }
        return false
    }

    private static func split(_ entry: String) -> (host: String, path: String?) {
        guard let slash = entry.firstIndex(of: "/") else { return (entry, nil) }
        return (String(entry[..<slash]), String(entry[slash...]))
    }

    /// The person's own choice for |url|'s site (the switch in Site
    /// Controls): the sites added to WebKit and the listed entries taken off.
    /// |listed| are hosts on the list besides the defaults (the self-test's).
    static func choosing(_ engine: OACPageEngine, for url: String, added: [String], removed: [String],
                         listed: [String] = []) -> (added: [String], removed: [String]) {
        guard let host = webHost(of: url) else { return (added, removed) }
        var added = added.compactMap(normalizedEntry), removed = removed.compactMap(normalizedEntry)
        switch engine {
        case .webKit:
            if let entry = ProtectedMediaSites(extraHosts: listed).entry(for: url) { removed.removeAll { $0 == entry } }
            if ProtectedMediaSites(extraHosts: listed + added, removedHosts: removed).engine(for: url) == .chromium,
               !added.contains(host) {
                added.append(host)
            }
        case .chromium:
            added.removeAll { entry in let h = split(entry).host; return host == h || host.hasSuffix("." + h) }
            if let entry = ProtectedMediaSites(extraHosts: listed, removedHosts: removed).entry(for: url),
               !removed.contains(entry) {
                removed.append(entry)
            }
        @unknown default:
            break
        }
        return (added, removed)
    }

    static func webHost(of url: String) -> String? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    static func normalizedEntry(_ entry: String) -> String? {
        var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.contains("://") {
            guard let host = webHost(of: s) else { return nil }
            s = host
        }
        var (host, path) = split(s)
        while host.hasPrefix(".") { host.removeFirst() }
        while host.hasSuffix(".") { host.removeLast() }
        while path?.hasSuffix("/") == true { path?.removeLast() }
        guard !host.isEmpty, !host.contains(" "), path?.contains(" ") != true, path?.contains("?") != true else { return nil }
        return path.map { $0.isEmpty ? host : host + $0 } ?? host
    }
}

/// Chromium's Widevine. Google's component updater installs the module in
/// every Chromium, OpenArch's too; Settings › „Geschützte Inhalte
/// (Widevine)“ decides whether pages may use it. Off (the default), the
/// built-in extension's protected-content.js tells pages it is not there.
/// The choice takes effect at launch, before Chromium loads the extension.
enum ProtectedContent {
    /// |extensions| are the built-in extensions' folders (their copies in
    /// Application Support). Reads the setting from Library.json.
    static func prepare(extensions: [String]) {
        let library = AppPaths.support.appendingPathComponent("Library.json")
        let settings = (try? Data(contentsOf: library))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["settings"] as? [String: Any]
        let allowed = (settings?["widevine"] as? Bool ?? false)
            || (AppPaths.isSelfTest && CommandLine.arguments.contains("--widevine"))
        for folder in extensions {
            let target = URL(fileURLWithPath: folder).appendingPathComponent("protected-content.js")
            // Never inside the app bundle (its signature), only in the copy.
            guard !folder.hasPrefix(Bundle.main.bundlePath), FileManager.default.fileExists(atPath: target.path),
                  let source = Bundle.main.resourceURL?
                    .appendingPathComponent("BuiltinExtensions/\(target.deletingLastPathComponent().lastPathComponent)/protected-content.js"),
                  let blocking = try? String(contentsOf: source, encoding: .utf8) else { continue }
            let script = allowed ? "// Widevine is allowed (Settings › Allgemein › Geschützte Inhalte).\n" : blocking
            if (try? String(contentsOf: target, encoding: .utf8)) != script {
                try? script.write(to: target, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// protected-media.json in the data folder: the sites sent to WebKit or
/// back to Chromium in Site Controls, and the services whose toast showed.
struct ProtectedMediaChoices: Codable, Equatable {
    var added: [String] = []
    var removed: [String] = []
    var told: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = try c.decodeIfPresent([String].self, forKey: .added) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
        told = try c.decodeIfPresent([String].self, forKey: .told) ?? []
    }
}

/// Which engine OpenArch gives a page: the rules, the setting and the
/// person's choices, in force at once.
@MainActor
enum ProtectedMedia {
    /// Settings › Allgemein › „DRM-Seiten mit Safaris Engine abspielen“.
    static var isEnabled = true {
        didSet { sites = load() }
    }
    /// The self-test's stand-in for a streaming service.
    static var testHosts: [String] = [] {
        didSet { sites = load() }
    }

    private static let file = AppPaths.support.appendingPathComponent("protected-media.json")
    private(set) static var choices: ProtectedMediaChoices = {
        guard let data = try? Data(contentsOf: file) else { return ProtectedMediaChoices() }
        return (try? JSONDecoder().decode(ProtectedMediaChoices.self, from: data)) ?? ProtectedMediaChoices()
    }()
    private(set) static var sites = load()

    private static func load() -> ProtectedMediaSites {
        ProtectedMediaSites(isEnabled: isEnabled, extraHosts: testHosts + choices.added, removedHosts: choices.removed)
    }

    private static func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(choices) { try? data.write(to: file, options: .atomic) }
        sites = load()
    }

    /// The kill switch `drmWebKit` (FeatureSwitches) sends every page to
    /// Chromium, as if the setting were off.
    private static var switchedOff: Bool { !FeatureSwitches.shared.isOn(.drmWebKit) }

    static func engine(for url: String) -> OACPageEngine { .webKit }

    /// A page for |url|: every page OpenArch opens comes from here, WebKit
    /// only.
    static func makePage(url: String, profile: OACProfile) -> any OACPage {
        WebKitPage(profile: profile, url: url, serviceName: sites.serviceName(for: url) ?? "")
    }

    static func makePage(url: String, profile: OACProfile, engine: OACPageEngine) -> any OACPage {
        WebKitPage(profile: profile, url: url, serviceName: sites.serviceName(for: url) ?? "")
    }

    /// An address field's pick: always WebKit.
    static func engine(forAddress url: String, current: OACPageEngine) -> OACPageEngine { .webKit }

    /// No second engine remains, so no navigation moves.
    static func handsOff(from current: OACPageEngine, to url: String, method: String) -> Bool { false }

    /// Kept for Site Controls compatibility; there is no second engine.
    static func choose(_ engine: OACPageEngine, for url: String) {}

    /// Whether |service|'s toast was shown already.
    static func wasTold(_ service: String) -> Bool { choices.told.contains(service) }

    static func told(_ service: String) {
        guard !wasTold(service) else { return }
        choices.told.append(service)
        save()
    }

    /// The self-test starts from nothing.
    static func resetForTesting() {
        choices = ProtectedMediaChoices()
        save()
    }
}
