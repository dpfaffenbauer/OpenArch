import CryptoKit
import Foundation

/// A live share this device made: its keys, and what it shows. The signing
/// key never leaves the device; it is what lets only this device change the
/// share.
public struct OwnedShare: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The folder's or space's ID in the library.
    public var source: UUID
    public var kind: SharePayload.Kind
    public var name: String
    public var signingKey: Data
    public var contentKey: Data
    /// Set when the link is protected with a password: the link's key slot.
    public var passwordSlot: Data?
    /// nil: the default relay.
    public var relay: URL?
    /// The last version uploaded, and the SHA-256 of what it showed.
    public var version: Int
    public var publishedHash: String?
    public var publishedAt: Date?
    public var created: Date

    /// A new share; nothing is uploaded yet.
    public static func make(source: UUID, kind: SharePayload.Kind, name: String, relay: URL? = nil) -> OwnedShare {
        let signingKey = Curve25519.Signing.PrivateKey()
        return OwnedShare(id: ShareCrypto.shareID(publicKey: signingKey.publicKey.rawRepresentation),
                          source: source, kind: kind, name: name, signingKey: signingKey.rawRepresentation,
                          contentKey: ShareCrypto.randomKey(), passwordSlot: nil, relay: relay, version: 0,
                          publishedHash: nil, publishedAt: nil, created: Date())
    }

    public var link: ShareURL {
        ShareURL(content: .live(id: id, relay: relay == ShareRelay.defaultURL ? nil : relay),
                 keySlot: passwordSlot.map(ShareURL.KeySlot.password) ?? .key(contentKey))
    }

    /// Protects the link with |password| (nil: no password). Slow: call it
    /// off the main thread.
    public mutating func setPassword(_ password: String?) throws {
        passwordSlot = try password.map { try ShareCrypto.wrap(key: contentKey, password: $0) }
    }

    public static func hash(of payload: SharePayload) -> String {
        var unstamped = payload
        unstamped.updated = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(unstamped)) ?? Data()
        return Data(SHA256.hash(data: json)).base64URL
    }

    /// Whether |payload| differs from what was last uploaded, or a month has
    /// passed (the relay forgets shares after 400 days without an upload).
    public func needsUpload(_ payload: SharePayload, now: Date = Date()) -> Bool {
        guard let publishedHash, let publishedAt else { return true }
        return publishedHash != Self.hash(of: payload) || now.timeIntervalSince(publishedAt) > 30 * 86400
    }

    /// The next version, encrypted and signed.
    public func envelope(for payload: SharePayload, version: Int) throws -> ShareEnvelope {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        let blob = try ShareCrypto.seal(payload.encoded(), key: contentKey,
                                        context: ShareCrypto.liveContext(id: id, version: version)).base64URL
        let signature = try key.signature(for: ShareCrypto.putMessage(id: id, version: version, blob: blob))
        return ShareEnvelope(pk: key.publicKey.rawRepresentation.base64URL, version: version, blob: blob,
                             sig: signature.base64URL)
    }

    /// Uploads |payload| as the next version and returns the share as it is
    /// now. A version conflict (another upload got there first, say from a
    /// restored backup) moves on to a higher version.
    public func publish(_ payload: SharePayload, session: URLSession = .shared) async throws -> OwnedShare {
        let relay = ShareRelay(baseURL: self.relay, session: session)
        var next = version + 1
        for _ in 0..<3 {
            do {
                try await relay.put(id: id, envelope: envelope(for: payload, version: next))
                var copy = self
                copy.version = next
                copy.publishedHash = Self.hash(of: payload)
                copy.publishedAt = Date()
                return copy
            } catch ShareError.server(409) {
                // The relay has a newer version than this device knows of.
                let current = (try? await relay.fetch(id: id))?.version ?? 0
                next = max(next + 1, current + 1)
            }
        }
        throw ShareError.server(409)
    }

    /// Ends the share on the relay; those who added it keep what they have.
    public func end(session: URLSession = .shared) async throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
        let next = version + 1
        let signature = try key.signature(for: ShareCrypto.deleteMessage(id: id, version: next))
        try await ShareRelay(baseURL: relay, session: session).delete(id: id, version: next, signature: signature)
    }
}

/// A live share someone else made, which this device follows.
public struct ShareSubscription: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var contentKey: Data
    public var relay: URL?
    /// The newest version seen; older ones are refused.
    public var version: Int
    /// The folder or space it fills.
    public var target: UUID
    public var name: String
    public var lastChecked: Date?
    /// Set when the owner has ended the share.
    public var ended = false

    public init(id: String, contentKey: Data, relay: URL?, version: Int, target: UUID, name: String) {
        self.id = id
        self.contentKey = contentKey
        self.relay = relay
        self.version = version
        self.target = target
        self.name = name
    }

    /// The share's content if it changed since |version|.
    public func fetchUpdate(session: URLSession = .shared) async throws -> (payload: SharePayload, version: Int)? {
        try await ShareReader.fetchLive(id: id, key: contentKey, relay: relay, knownVersion: version, session: session)
    }
}

/// Opens share links.
public enum ShareReader {
    /// What a share shows, with what it takes to follow it (live shares).
    public struct Opened: Sendable {
        public var payload: SharePayload
        public var link: ShareURL
        public var contentKey: Data
        /// Live shares: the version read.
        public var version: Int?

        /// For adding the share so that it stays up to date.
        public func subscription(target: UUID) -> ShareSubscription? {
            guard case .live(let id, let relay) = link.content, let version else { return nil }
            return ShareSubscription(id: id, contentKey: contentKey, relay: relay, version: version, target: target,
                                     name: payload.name)
        }
    }

    /// Opens |link|: a snapshot locally, a live share from its relay. A
    /// password takes about half a second.
    public static func open(_ link: ShareURL, password: String? = nil, session: URLSession = .shared) async throws -> Opened {
        let key = try link.contentKey(password: password)
        switch link.content {
        case .snapshot(let blob):
            let plaintext = try ShareCrypto.open(blob, key: key, context: ShareCrypto.snapshotContext)
            return Opened(payload: try SharePayload.decode(plaintext), link: link, contentKey: key, version: nil)
        case .live(let id, let relay):
            guard let latest = try await fetchLive(id: id, key: key, relay: relay, knownVersion: nil, session: session) else {
                throw ShareError.damaged
            }
            return Opened(payload: latest.0, link: link, contentKey: key, version: latest.1)
        }
    }

    /// The newest content of a live share, or nil if it is still |knownVersion|.
    public static func fetchLive(id: String, key: Data, relay: URL?, knownVersion: Int?,
                                 session: URLSession = .shared) async throws -> (SharePayload, Int)? {
        guard let envelope = try await ShareRelay(baseURL: relay, session: session)
            .fetch(id: id, knownVersion: knownVersion) else { return nil }
        let blob = try envelope.verifiedBlob(id: id)
        if let knownVersion {
            guard envelope.version >= knownVersion else { throw ShareError.outdated }
            if envelope.version == knownVersion { return nil }
        }
        let plaintext = try ShareCrypto.open(blob, key: key, context: ShareCrypto.liveContext(id: id, version: envelope.version))
        return (try SharePayload.decode(plaintext), envelope.version)
    }

    /// A snapshot link: the bookmarks travel inside it. With a password,
    /// this takes about half a second.
    public static func snapshotLink(_ payload: SharePayload, password: String? = nil) throws -> ShareURL {
        let key = ShareCrypto.randomKey()
        let blob = try ShareCrypto.seal(payload.encoded(), key: key, context: ShareCrypto.snapshotContext)
        let slot: ShareURL.KeySlot
        if let password {
            slot = .password(try ShareCrypto.wrap(key: key, password: password))
        } else {
            slot = .key(key)
        }
        return ShareURL(content: .snapshot(blob: blob), keySlot: slot)
    }
}

/// The shares this device made and follows, kept apart from the library in a
/// file only the user can read (it holds the keys).
public struct ShareRecords: Codable, Equatable, Sendable {
    public var owned: [OwnedShare] = []
    public var subscriptions: [ShareSubscription] = []

    public init() {}

    public static func load(from url: URL) -> ShareRecords {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let records = try? decoder.decode(ShareRecords.self, from: data) else { return ShareRecords() }
        return records
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func owned(source: UUID) -> OwnedShare? {
        owned.first { $0.source == source }
    }

    public func subscription(target: UUID) -> ShareSubscription? {
        subscriptions.first { $0.target == target }
    }
}

extension UUID {
    /// A UUID made from a share's ID and an entry's ID: the same entry gets
    /// the same local item with every update, and two copies of one share do
    /// not collide.
    public init(share: String, node: UUID) {
        var bytes = Array(SHA256.hash(data: Data("\(share) \(node.uuidString)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = NSUUID(uuidBytes: bytes) as UUID
    }
}
