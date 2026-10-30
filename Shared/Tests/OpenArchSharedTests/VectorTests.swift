import CryptoKit
import Foundation
import XCTest
@testable import OpenArchShared

/// Links and envelopes made by the web page's code (website/s/share-core.js)
/// open in Swift too.
final class VectorTests: XCTestCase {
    func expected() throws -> SharePayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SharePayload.self, from: Data(Vectors.sanitizedPayloadJSON.utf8))
    }

    func testKeys() throws {
        let seed = try XCTUnwrap(Data(base64URL: Vectors.signingSeed))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        XCTAssertEqual(key.publicKey.rawRepresentation.base64URL, Vectors.publicKey)
        XCTAssertEqual(ShareCrypto.shareID(publicKey: key.publicKey.rawRepresentation), Vectors.shareID)
        let salt = try XCTUnwrap(Data(base64URL: Vectors.passwordSalt))
        XCTAssertEqual(ShareCrypto.passwordKey(Vectors.password, salt: salt).base64URL, Vectors.passwordWrapKey)
        let slot = try XCTUnwrap(Data(base64URL: Vectors.passwordSlot))
        XCTAssertEqual(try ShareCrypto.unwrap(slot, password: Vectors.password).base64URL, Vectors.contentKey)
    }

    func testSnapshot() async throws {
        let link = try XCTUnwrap(ShareURL(fragment: Vectors.snapshotFragment))
        let opened = try await ShareReader.open(link)
        XCTAssertEqual(opened.payload, try expected())
        XCTAssertEqual(opened.payload.allTabs.count, 2, "the javascript: tab is gone")
        XCTAssertEqual(link.fragment, Vectors.snapshotFragment)
    }

    func testPasswordSnapshot() async throws {
        let link = try XCTUnwrap(ShareURL(fragment: Vectors.snapshotPasswordFragment))
        XCTAssertTrue(link.needsPassword)
        let opened = try await ShareReader.open(link, password: Vectors.password)
        XCTAssertEqual(opened.payload, try expected())
    }

    func testLiveEnvelope() throws {
        let envelope = try JSONDecoder().decode(ShareEnvelope.self, from: Data(Vectors.liveEnvelopeJSON.utf8))
        XCTAssertEqual(envelope.version, Vectors.liveVersion)
        let blob = try envelope.verifiedBlob(id: Vectors.shareID)
        let key = try XCTUnwrap(Data(base64URL: Vectors.contentKey))
        let plaintext = try ShareCrypto.open(blob, key: key,
                                             context: ShareCrypto.liveContext(id: Vectors.shareID, version: Vectors.liveVersion))
        XCTAssertEqual(try SharePayload.decode(plaintext), try expected())

        let link = try XCTUnwrap(ShareURL(fragment: Vectors.liveFragment))
        XCTAssertEqual(link.content, .live(id: Vectors.shareID, relay: nil))
        XCTAssertEqual(link.keySlot, .key(key))
        let relayed = try XCTUnwrap(ShareURL(fragment: Vectors.liveFragmentWithRelay))
        XCTAssertEqual(relayed.content, .live(id: Vectors.shareID, relay: URL(string: Vectors.liveRelay)))
        XCTAssertEqual(relayed.fragment, Vectors.liveFragmentWithRelay)
    }

    func testDeletionSignature() throws {
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64URL: Vectors.publicKey)))
        let signature = try XCTUnwrap(Data(base64URL: Vectors.deleteSignature))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: ShareCrypto.deleteMessage(id: Vectors.shareID,
                                                                                           version: Vectors.deleteVersion)))
    }

    /// An entry with a broken ID is left out, not the whole share (as on the web page).
    func testBrokenEntriesAreSkipped() throws {
        let json = #"{"v":1,"kind":"folder","name":"x","items":[{"id":"nope","title":"a","url":"https://a.example/"},"#
            + #"{"id":"6F1C2F8E-1D2B-4C1E-9A55-0B1C2D3E4F50","title":"b","url":"https://b.example/"}]}"#
        let read = try SharePayload.decode(Data([0]) + Data(json.utf8))
        XCTAssertEqual(read.allTabs.map(\.title), ["b"])
    }
}
