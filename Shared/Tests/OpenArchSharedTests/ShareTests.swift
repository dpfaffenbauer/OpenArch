import CryptoKit
import Foundation
import XCTest
@testable import OpenArchShared

final class ShareTests: XCTestCase {
    let payload = SharePayload(
        kind: .folder, name: "Design", icon: "paintbrush.fill", updated: Date(timeIntervalSince1970: 1_800_000_000),
        items: [
            .tab(title: "Figma", url: "https://figma.com/"),
            .folder(title: "Inspiration", icon: "star.fill", children: [
                .tab(title: "Dribbble", url: "https://dribbble.com/"),
            ]),
        ])

    // MARK: Building blocks

    func testBase64URL() {
        let data = Data((0..<255).map { UInt8($0) })
        XCTAssertEqual(Data(base64URL: data.base64URL), data)
        XCTAssertFalse(data.base64URL.contains("="))
        XCTAssertNil(Data(base64URL: "ab+c"))
        XCTAssertNil(Data(base64URL: "abc="))
        XCTAssertNil(Data(base64URL: "a"))
    }

    func testPayloadRoundTrip() throws {
        let plaintext = try payload.encoded()
        XCTAssertEqual(plaintext.first, 1, "compressed")
        XCTAssertEqual(try SharePayload.decode(plaintext), payload)
    }

    func testReadersKeepWebLinksOnly() throws {
        var hostile = payload
        hostile.items += [
            .tab(title: "x", url: "javascript:alert(1)"),
            .tab(title: "x", url: "file:///etc/passwd"),
            .tab(title: "x", url: "data:text/html,hi"),
            .tab(title: String(repeating: "a", count: 1000), url: "http://example.com"),
        ]
        hostile.color = "red; background: url(x)"
        let read = try SharePayload.decode(hostile.encoded())
        XCTAssertEqual(read.allTabs.map(\.url), ["https://figma.com/", "https://dribbble.com/", "http://example.com"])
        XCTAssertEqual(read.allTabs.last?.title.count, 300)
        XCTAssertNil(read.color)
    }

    func testDeepTreesAreCut() throws {
        var node = ShareNode.tab(title: "deep", url: "https://example.com/")
        for level in 0..<40 {
            node = .folder(title: "\(level)", children: [node])
        }
        let read = try SharePayload.decode(SharePayload(kind: .folder, name: "n", items: [node]).encoded())
        var depth = 0
        var current = read.items.first
        while let folder = current, let children = folder.children {
            depth += 1
            current = children.first
        }
        XCTAssertLessThanOrEqual(depth, 16)
    }

    func testDecompressionBombIsRefused() throws {
        let huge = Data(count: 8 << 20)
        let bomb = Data([1]) + SharePayload.deflate(huge)!
        XCTAssertThrowsError(try SharePayload.decode(bomb)) { XCTAssertEqual($0 as? ShareError, .tooLarge) }
    }

    func testNewerFormatsAreRefused() throws {
        let json = Data(#"{"v":2,"kind":"folder","name":"x","items":[]}"#.utf8)
        XCTAssertThrowsError(try SharePayload.decode(Data([0]) + json)) {
            XCTAssertEqual($0 as? ShareError, .unsupportedVersion)
        }
    }

    func testStableItemIDs() {
        let node = UUID()
        XCTAssertEqual(UUID(share: "abc", node: node), UUID(share: "abc", node: node))
        XCTAssertNotEqual(UUID(share: "abc", node: node), UUID(share: "abd", node: node))
        XCTAssertNotEqual(UUID(share: "abc", node: node), node)
    }

    // MARK: Snapshot links

    func testSnapshotLink() async throws {
        let link = try ShareReader.snapshotLink(payload)
        let parsed = try XCTUnwrap(ShareURL(url: link.url))
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(ShareURL(url: link.appURL), link)
        XCTAssertEqual(ShareURL(string: "  \(link.url.absoluteString)\n"), link)
        let opened = try await ShareReader.open(parsed)
        XCTAssertEqual(opened.payload, payload)
        XCTAssertNil(opened.version)
        XCTAssertNil(opened.subscription(target: UUID()))
    }

    func testPasswordProtectedSnapshot() async throws {
        let link = try ShareReader.snapshotLink(payload, password: "Grüße")
        XCTAssertTrue(link.needsPassword)
        let parsed = try XCTUnwrap(ShareURL(string: link.url.absoluteString))
        do {
            _ = try await ShareReader.open(parsed)
            XCTFail("opened without a password")
        } catch {
            XCTAssertEqual(error as? ShareError, .passwordNeeded)
        }
        do {
            _ = try await ShareReader.open(parsed, password: "grüße")
            XCTFail("opened with a wrong password")
        } catch {
            XCTAssertEqual(error as? ShareError, .wrongPassword)
        }
        // The same password typed with a combining diaeresis (NFD).
        let opened = try await ShareReader.open(parsed, password: "Gru\u{0308}ße")
        XCTAssertEqual(opened.payload, payload)
    }

    func testTamperedSnapshotIsRefused() async throws {
        let link = try ShareReader.snapshotLink(payload)
        guard case .snapshot(var blob) = link.content else { return XCTFail() }
        blob[blob.count / 2] ^= 1
        let tampered = ShareURL(content: .snapshot(blob: blob), keySlot: link.keySlot)
        do {
            _ = try await ShareReader.open(tampered)
            XCTFail("opened a changed link")
        } catch {
            XCTAssertEqual(error as? ShareError, .damaged)
        }
    }

    func testMalformedLinks() {
        let key = Data(count: 32).base64URL
        let id = String(repeating: "A", count: 22)
        XCTAssertNotNil(ShareURL(fragment: "1.l.\(id).k\(key)"))
        XCTAssertNil(ShareURL(fragment: "2.l.\(id).k\(key)"))
        XCTAssertNil(ShareURL(fragment: "1.l.\(id)x.k\(key)"))
        XCTAssertNil(ShareURL(fragment: "1.l.\(id).k\(key)x"))
        XCTAssertNil(ShareURL(fragment: "1.x.\(id).k\(key)"))
        XCTAssertNil(ShareURL(fragment: "1.l.\(id).q\(key)"))
        XCTAssertNil(ShareURL(fragment: "1.s.AAAA.k\(key)"))
        XCTAssertNil(ShareURL(fragment: ""))
        // A relay must be https.
        let http = Data("http://evil.example".utf8).base64URL
        XCTAssertNil(ShareURL(fragment: "1.l.\(id).k\(key).r\(http)"))
        let https = Data("https://relay.example".utf8).base64URL
        XCTAssertEqual(ShareURL(fragment: "1.l.\(id).k\(key).r\(https)")?.content,
                       .live(id: id, relay: URL(string: "https://relay.example")))
        XCTAssertNil(ShareURL(url: URL(string: "https://example.com/s/#1.l.\(id).k\(key)")!))
    }

    // MARK: Live shares

    func testEnvelopeChecks() throws {
        let share = OwnedShare.make(source: UUID(), kind: .folder, name: "Design")
        XCTAssertEqual(share.id.count, 22)
        let envelope = try share.envelope(for: payload, version: 4)
        let blob = try envelope.verifiedBlob(id: share.id)
        let plaintext = try ShareCrypto.open(blob, key: share.contentKey,
                                             context: ShareCrypto.liveContext(id: share.id, version: 4))
        XCTAssertEqual(try SharePayload.decode(plaintext), payload)

        // Another ID, a changed version or blob, another key: refused.
        let other = OwnedShare.make(source: UUID(), kind: .folder, name: "Other")
        XCTAssertThrowsError(try envelope.verifiedBlob(id: other.id))
        var changed = envelope
        changed.version = 5
        XCTAssertThrowsError(try changed.verifiedBlob(id: share.id))
        changed = envelope
        changed.blob = try other.envelope(for: payload, version: 4).blob
        XCTAssertThrowsError(try changed.verifiedBlob(id: share.id))
        changed = try other.envelope(for: payload, version: 4)
        XCTAssertThrowsError(try changed.verifiedBlob(id: share.id))
        // A version is bound to the ciphertext too.
        XCTAssertThrowsError(try ShareCrypto.open(blob, key: share.contentKey,
                                                  context: ShareCrypto.liveContext(id: share.id, version: 3)))
    }

    func testUploadsOnlyWhenChanged() {
        var share = OwnedShare.make(source: UUID(), kind: .folder, name: "Design")
        XCTAssertTrue(share.needsUpload(payload))
        share.publishedHash = OwnedShare.hash(of: payload)
        share.publishedAt = Date()
        var restamped = payload
        restamped.updated = Date()
        XCTAssertFalse(share.needsUpload(restamped))
        restamped.name = "Design 2"
        XCTAssertTrue(share.needsUpload(restamped))
        XCTAssertTrue(share.needsUpload(payload, now: Date().addingTimeInterval(31 * 86400)))
    }

    func testLiveShareThroughARelay() async throws {
        let session = FakeRelay.session()
        var share = OwnedShare.make(source: UUID(), kind: .space, name: "Arbeit")
        share = try await share.publish(payload, session: session)
        XCTAssertEqual(share.version, 1)

        let link = try XCTUnwrap(ShareURL(url: share.link.url))
        let opened = try await ShareReader.open(link, session: session)
        XCTAssertEqual(opened.payload, payload)
        XCTAssertEqual(opened.version, 1)
        let target = UUID()
        var subscription = try XCTUnwrap(opened.subscription(target: target))
        XCTAssertEqual(subscription.target, target)
        let unchanged = try await subscription.fetchUpdate(session: session)
        XCTAssertNil(unchanged)

        var changed = payload
        changed.items.removeFirst()
        share = try await share.publish(changed, session: session)
        XCTAssertEqual(share.version, 2)
        let update = try await subscription.fetchUpdate(session: session)
        XCTAssertEqual(update?.payload, changed)
        XCTAssertEqual(update?.version, 2)
        subscription.version = 2

        // A device that lost track of the version (a restored backup) moves on.
        var stale = share
        stale.version = 0
        stale = try await stale.publish(payload, session: session)
        XCTAssertEqual(stale.version, 3)

        // A relay handing out an old version is caught.
        subscription.version = 5
        do {
            _ = try await subscription.fetchUpdate(session: session)
            XCTFail("accepted an older version")
        } catch {
            XCTAssertEqual(error as? ShareError, .outdated)
        }

        try await stale.end(session: session)
        do {
            _ = try await ShareReader.open(link, session: session)
            XCTFail("opened an ended share")
        } catch {
            XCTAssertEqual(error as? ShareError, .ended)
        }
    }

    func testPasswordProtectedLiveLink() async throws {
        var share = OwnedShare.make(source: UUID(), kind: .folder, name: "Team")
        try share.setPassword("geheim")
        let session = FakeRelay.session()
        share = try await share.publish(payload, session: session)
        let link = try XCTUnwrap(ShareURL(string: share.link.url.absoluteString))
        XCTAssertTrue(link.needsPassword)
        let opened = try await ShareReader.open(link, password: "geheim", session: session)
        XCTAssertEqual(opened.contentKey, share.contentKey)
        XCTAssertEqual(opened.payload, payload)
    }
}

/// A relay in memory that checks uploads like relay/worker.js does.
final class FakeRelay: URLProtocol {
    private struct Stored { var envelope: ShareEnvelope?; var version: Int }
    private struct Deletion: Decodable { var version: Int; var sig: String }
    private nonisolated(unsafe) static var shares: [String: Stored] = [:]
    private static let lock = NSLock()

    static func session() -> URLSession {
        lock.withLock { shares = [:] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeRelay.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { Self.handle(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func handle(_ request: URLRequest) -> (Int, Data) {
        guard let id = request.url?.lastPathComponent, request.url?.path.hasPrefix("/v1/shares/") == true else {
            return (404, Data())
        }
        let stored = shares[id]
        switch request.httpMethod ?? "GET" {
        case "GET":
            guard let stored else { return (404, Data()) }
            guard let envelope = stored.envelope else { return (410, Data()) }
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"\(envelope.version)\"" { return (304, Data()) }
            return (200, try! JSONEncoder().encode(envelope))
        case "PUT":
            guard let body = body(of: request),
                  let envelope = try? JSONDecoder().decode(ShareEnvelope.self, from: body) else { return (400, Data()) }
            guard (try? envelope.verifiedBlob(id: id)) != nil else { return (403, Data()) }
            if let stored {
                guard stored.envelope != nil else { return (410, Data()) }
                guard envelope.version > stored.version else { return (409, Data()) }
            }
            shares[id] = Stored(envelope: envelope, version: envelope.version)
            return (200, Data(#"{"version":\#(envelope.version)}"#.utf8))
        case "DELETE":
            guard let stored, let publicKey = stored.envelope.flatMap({ Data(base64URL: $0.pk) }),
                  let body = body(of: request),
                  let deletion = try? JSONDecoder().decode(Deletion.self, from: body),
                  let signature = Data(base64URL: deletion.sig),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
                  key.isValidSignature(signature, for: ShareCrypto.deleteMessage(id: id, version: deletion.version))
            else { return (403, Data()) }
            guard deletion.version > stored.version else { return (409, Data()) }
            shares[id] = Stored(envelope: nil, version: deletion.version)
            return (200, Data())
        default:
            return (405, Data())
        }
    }
}
