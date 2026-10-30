import CryptoKit
import Foundation

/// What a relay stores for a live share: the encrypted bookmarks, signed by
/// the share's key.
public struct ShareEnvelope: Codable, Equatable, Sendable {
    public var v = 1
    /// The Ed25519 public key.
    public var pk: String
    public var version: Int
    public var blob: String
    public var sig: String

    /// The encrypted bookmarks, once ID, signature and version check out.
    public func verifiedBlob(id: String) throws -> Data {
        guard v == 1 else { throw ShareError.unsupportedVersion }
        guard let publicKeyData = Data(base64URL: pk), publicKeyData.count == 32,
              ShareCrypto.shareID(publicKey: publicKeyData) == id,
              let signature = Data(base64URL: sig), signature.count == 64,
              let blobData = Data(base64URL: blob),
              (1...Self.maxVersion).contains(version),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: ShareCrypto.putMessage(id: id, version: version, blob: blob))
        else { throw ShareError.damaged }
        return blobData
    }

    /// The largest integer a JavaScript number holds exactly.
    public static let maxVersion = (1 << 53) - 1
}

/// The relay that passes live shares on (docs/sharing.md, relay/). It only
/// ever sees encrypted, signed data.
public struct ShareRelay: Sendable {
    public static let defaultURL = URL(string: "https://share.openarch.app")!

    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL ?? Self.defaultURL
        self.session = session
    }

    private func url(for id: String) -> URL {
        baseURL.appending(path: "v1/shares/\(id)")
    }

    /// The share's envelope, or nil when it has not changed since |knownVersion|.
    public func fetch(id: String, knownVersion: Int? = nil) async throws -> ShareEnvelope? {
        var request = URLRequest(url: url(for: id), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let knownVersion {
            request.setValue("\"\(knownVersion)\"", forHTTPHeaderField: "If-None-Match")
        }
        let (data, status) = try await send(request)
        switch status {
        case 200:
            guard let envelope = try? JSONDecoder().decode(ShareEnvelope.self, from: data) else { throw ShareError.damaged }
            return envelope
        case 304: return nil
        default: throw Self.error(for: status)
        }
    }

    public func put(id: String, envelope: ShareEnvelope) async throws {
        var request = URLRequest(url: url(for: id), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(envelope)
        let (_, status) = try await send(request)
        guard status == 200 else { throw Self.error(for: status) }
    }

    public func delete(id: String, version: Int, signature: Data) async throws {
        struct Body: Encodable { var version: Int; var sig: String }
        var request = URLRequest(url: url(for: id), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(version: version, sig: signature.base64URL))
        let (_, status) = try await send(request)
        // Already gone counts as done.
        guard status == 200 || status == 404 || status == 410 else { throw Self.error(for: status) }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ShareError.unreachable
        }
    }

    static func error(for status: Int) -> ShareError {
        switch status {
        case 404: .notFound
        case 410: .ended
        case 413: .tooLarge
        default: .server(status)
        }
    }
}
