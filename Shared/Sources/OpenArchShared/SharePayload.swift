import Compression
import Foundation

/// What a share holds: a folder's or a space's tabs and folders.
public struct SharePayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case folder, space
    }

    public var v = 1
    public var kind: Kind
    public var name: String
    /// An SF Symbol name or an emoji.
    public var icon: String?
    /// Spaces: #RRGGBB.
    public var color: String?
    public var updated: Date?
    public var items: [ShareNode]

    public init(kind: Kind, name: String, icon: String? = nil, color: String? = nil, updated: Date? = Date(),
                items: [ShareNode]) {
        self.kind = kind
        self.name = name
        self.icon = icon
        self.color = color
        self.updated = updated
        self.items = items
    }

    static let maxNodes = 5000
    static let maxDepth = 16
    static let maxTitle = 300
    static let maxDecompressed = 4 << 20

    /// Every tab, depth first.
    public var allTabs: [ShareNode] {
        func tabs(_ nodes: [ShareNode]) -> [ShareNode] {
            nodes.flatMap { $0.children.map(tabs) ?? [$0] }
        }
        return tabs(items)
    }

    /// What a reader keeps: http and https links only, shortened titles,
    /// at most 16 levels and 5000 entries.
    public func sanitized() -> SharePayload {
        var budget = Self.maxNodes
        func clean(_ nodes: [ShareNode], depth: Int) -> [ShareNode] {
            var result: [ShareNode] = []
            for node in nodes {
                guard budget > 0 else { break }
                var copy = node
                copy.title = String(node.title.prefix(Self.maxTitle))
                copy.icon = node.icon.map { String($0.prefix(64)) }
                if let children = node.children {
                    guard depth < Self.maxDepth else { continue }
                    budget -= 1
                    copy.url = nil
                    copy.children = clean(children, depth: depth + 1)
                } else {
                    guard let url = node.url, ShareNode.isAllowed(url) else { continue }
                    budget -= 1
                }
                result.append(copy)
            }
            return result
        }
        var copy = self
        copy.name = String(name.prefix(Self.maxTitle))
        copy.icon = icon.map { String($0.prefix(64)) }
        copy.color = color.flatMap { $0.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil ? $0 : nil }
        copy.items = clean(items, depth: 1)
        return copy
    }

    // MARK: Bytes

    /// The plaintext that gets encrypted: 0x01 and the compressed JSON.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(self)
        guard let compressed = Self.deflate(json) else { return Data([0]) + json }
        return Data([1]) + compressed
    }

    public static func decode(_ plaintext: Data) throws -> SharePayload {
        guard let format = plaintext.first else { throw ShareError.damaged }
        let body = Data(plaintext.dropFirst())
        let json: Data
        switch format {
        case 0: json = body
        case 1:
            guard let inflated = inflate(body) else { throw ShareError.tooLarge }
            json = inflated
        default: throw ShareError.unsupportedVersion
        }
        guard json.count <= maxDecompressed else { throw ShareError.tooLarge }
        struct Version: Decodable { var v: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: json) else { throw ShareError.damaged }
        guard version.v == 1 else { throw ShareError.unsupportedVersion }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SharePayload.self, from: json).sanitized()
        } catch {
            throw ShareError.damaged
        }
    }

    /// Raw DEFLATE (RFC 1951), what the web page's DecompressionStream reads.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { input in
            compression_encode_buffer(&output, capacity, input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        return written == 0 ? nil : Data(output.prefix(written))
    }

    /// nil when damaged, or larger than 4 MiB (a decompression bomb).
    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = maxDecompressed + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { input in
            compression_decode_buffer(&output, capacity, input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written < capacity else { return nil }
        return Data(output.prefix(written))
    }
}

/// A tab (with |url|) or a folder (with |children|).
public struct ShareNode: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var url: String?
    public var icon: String?
    public var children: [ShareNode]?

    public static func tab(id: UUID = UUID(), title: String, url: String) -> ShareNode {
        ShareNode(id: id, title: title, url: url)
    }

    public static func folder(id: UUID = UUID(), title: String, icon: String? = nil, children: [ShareNode]) -> ShareNode {
        ShareNode(id: id, title: title, icon: icon, children: children)
    }

    public var isFolder: Bool { children != nil }

    static func isAllowed(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host?.isEmpty == false else { return false }
        return url.count <= 8192
    }
}
