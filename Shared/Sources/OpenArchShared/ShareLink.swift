import Foundation

/// A share link: https://openarch.app/s/#1.l.<id>.k<key>, see docs/sharing.md.
public struct ShareLink: Equatable, Hashable, Sendable {
    public enum Content: Equatable, Hashable, Sendable {
        /// On a relay; |relay| is nil for the default one.
        case live(id: String, relay: URL?)
        /// The encrypted bookmarks themselves.
        case snapshot(blob: Data)
    }

    public enum KeySlot: Equatable, Hashable, Sendable {
        /// The 32-byte content key.
        case key(Data)
        /// The content key behind a password: salt ‖ nonce ‖ wrapped key ‖ tag.
        case password(Data)
    }

    public var content: Content
    public var keySlot: KeySlot

    public init(content: Content, keySlot: KeySlot) {
        self.content = content
        self.keySlot = keySlot
    }

    public static let webBase = "https://openarch.app/s/"
    public static let appBase = "openarch://share"

    public var fragment: String {
        var parts = ["1"]
        switch content {
        case .live(let id, _): parts += ["l", id]
        case .snapshot(let blob): parts += ["s", blob.base64URL]
        }
        switch keySlot {
        case .key(let key): parts.append("k" + key.base64URL)
        case .password(let slot): parts.append("p" + slot.base64URL)
        }
        if case .live(_, let relay?) = content {
            parts.append("r" + Data(relay.absoluteString.utf8).base64URL)
        }
        return parts.joined(separator: ".")
    }

    /// The link to send: opens the web page, or OpenArch where it handles it.
    public var url: URL { URL(string: Self.webBase + "#" + fragment)! }
    /// Opens OpenArch directly.
    public var appURL: URL { URL(string: Self.appBase + "#" + fragment)! }

    public var needsPassword: Bool {
        if case .password = keySlot { return true }
        return false
    }

    public var isLive: Bool {
        if case .live = content { return true }
        return false
    }

    public var shareID: String? {
        if case .live(let id, _) = content { return id }
        return nil
    }

    /// Whether |url| is a share link (https://openarch.app/s/#…, or openarch://share#…).
    public static func isShareURL(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text.hasPrefix(webBase) || text.hasPrefix("https://openarch.app/s#") || text.hasPrefix(appBase)
            || text.hasPrefix("https://www.openarch.app/s")
    }

    public init?(url: URL) {
        guard Self.isShareURL(url), let fragment = url.fragment(percentEncoded: false) else { return nil }
        self.init(fragment: fragment)
    }

    /// Also takes a whole link as typed or pasted.
    public init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), Self.isShareURL(url) {
            self.init(url: url)
        } else {
            self.init(fragment: text.hasPrefix("#") ? String(text.dropFirst()) : text)
        }
    }

    public init?(fragment: String) {
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 || parts.count == 5, parts[0] == "1" else { return nil }
        switch parts[1] {
        case "l":
            guard parts[2].range(of: "^[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil else { return nil }
            var relay: URL?
            if parts.count == 5 {
                guard parts[4].hasPrefix("r"), let data = Data(base64URL: parts[4].dropFirst()),
                      let text = String(data: data, encoding: .utf8), let url = URL(string: text),
                      url.scheme == "https" || url.host() == "localhost", url.host()?.isEmpty == false
                else { return nil }
                relay = url
            }
            content = .live(id: parts[2], relay: relay)
        case "s":
            guard parts.count == 4, let blob = Data(base64URL: parts[2]), blob.count >= 28 else { return nil }
            content = .snapshot(blob: blob)
        default:
            return nil
        }
        let slot = parts[3]
        if slot.hasPrefix("k"), let key = Data(base64URL: slot.dropFirst()), key.count == 32 {
            keySlot = .key(key)
        } else if slot.hasPrefix("p"), let wrapped = Data(base64URL: slot.dropFirst()), wrapped.count == 76 {
            keySlot = .password(wrapped)
        } else {
            return nil
        }
    }

    /// The content key; with a password, this takes about half a second.
    public func contentKey(password: String?) throws -> Data {
        switch keySlot {
        case .key(let key): return key
        case .password(let slot):
            guard let password, !password.isEmpty else { throw ShareError.passwordNeeded }
            return try ShareCrypto.unwrap(slot, password: password)
        }
    }
}
