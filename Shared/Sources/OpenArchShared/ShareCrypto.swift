import CommonCrypto
import CryptoKit
import Foundation

/// Why a share could not be made, opened or updated.
public enum ShareError: Error, Equatable, LocalizedError, Sendable {
    case invalidLink
    case passwordNeeded
    case wrongPassword
    case damaged
    case unsupportedVersion
    case notFound
    case ended
    case outdated
    case tooLarge
    case unreachable
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLink: "Das ist kein gültiger OpenArch-Link."
        case .passwordNeeded: "Dieser Link ist mit einem Passwort geschützt."
        case .wrongPassword: "Das Passwort stimmt nicht."
        case .damaged: "Die geteilten Daten sind beschädigt oder wurden verändert."
        case .unsupportedVersion: "Dieser Link stammt aus einer neueren OpenArch-Version."
        case .notFound: "Diese Freigabe gibt es nicht (mehr)."
        case .ended: "Die Freigabe wurde beendet."
        case .outdated: "Der Server lieferte einen älteren Stand als bekannt."
        case .tooLarge: "Zu viele Lesezeichen für eine Freigabe."
        case .unreachable: "Der Teilen-Server ist nicht erreichbar."
        case .server(let status): "Der Teilen-Server antwortete mit Fehler \(status)."
        }
    }
}

/// The building blocks of docs/sharing.md: AES-256-GCM, Ed25519 and PBKDF2.
public enum ShareCrypto {
    public static let pbkdf2Rounds: UInt32 = 600_000
    static let snapshotContext = "openarch-share-v1 snapshot"
    static let keyContext = "openarch-share-v1 key"

    static func liveContext(id: String, version: Int) -> String {
        "openarch-share-v1 live \(id) \(version)"
    }

    static func putMessage(id: String, version: Int, blob: String) -> Data {
        Data("openarch-share-v1 put \(id) \(version) \(blob)".utf8)
    }

    static func deleteMessage(id: String, version: Int) -> Data {
        Data("openarch-share-v1 delete \(id) \(version)".utf8)
    }

    public static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// nonce ‖ ciphertext ‖ tag.
    static func seal(_ plaintext: Data, key: Data, context: String, nonce: Data? = nil) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                   nonce: nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce(),
                                   authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw ShareError.damaged }
        return combined
    }

    static func open(_ blob: Data, key: Data, context: String) throws -> Data {
        guard key.count == 32, blob.count >= 28 else { throw ShareError.damaged }
        do {
            let box = try AES.GCM.SealedBox(combined: blob)
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(context.utf8))
        } catch {
            throw ShareError.damaged
        }
    }

    /// The share ID: the first 16 bytes of the public key's SHA-256.
    public static func shareID(publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey).prefix(16)).base64URL
    }

    /// PBKDF2-HMAC-SHA256 of the NFC form of |password|. Slow on purpose
    /// (about half a second): call it off the main thread.
    public static func passwordKey(_ password: String, salt: Data, rounds: UInt32 = pbkdf2Rounds) -> Data {
        var passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        let passwordLength = passwordBytes.count
        // An empty password still needs a valid pointer.
        if passwordBytes.isEmpty { passwordBytes = [0] }
        let saltBytes = Array(salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer in
            passwordBuffer.withMemoryRebound(to: CChar.self) { passwordChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordChars.baseAddress, passwordLength,
                                     saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     rounds, &derived, derived.count)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(derived)
    }

    /// salt ‖ nonce ‖ wrapped key ‖ tag: the content key behind a password.
    public static func wrap(key: Data, password: String, salt: Data? = nil, nonce: Data? = nil) throws -> Data {
        let salt = salt ?? randomKey().prefix(16)
        let wrapped = try seal(key, key: passwordKey(password, salt: salt), context: keyContext, nonce: nonce)
        return salt + wrapped
    }

    public static func unwrap(_ slot: Data, password: String) throws -> Data {
        guard slot.count == 16 + 60 else { throw ShareError.invalidLink }
        let wrapKey = passwordKey(password, salt: slot.prefix(16))
        do {
            return try open(Data(slot.dropFirst(16)), key: wrapKey, context: keyContext)
        } catch {
            throw ShareError.wrongPassword
        }
    }
}
