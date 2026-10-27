import AppKit
import Darwin
import CommonCrypto
import Security
import SQLite3

/// The full import from Arc: logins and cookies, saved passwords, autofill,
/// history, website data (local storage, IndexedDB, service workers) and the
/// installed extensions with their settings.
///
/// Arc and OpenArch are both Chromium 156, so Arc's profile files can be used
/// as they are, except for values Chromium encrypts with a key from the macOS
/// keychain. Those are decrypted with Arc's key ("Arc Safe Storage") and
/// encrypted again with OpenArch's. Chromium must not run while its profile
/// changes, so the import runs at the next launch, before Chromium starts.
enum ArcProfileImport {
    static let arcProfile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/User Data/Default")
    static let arcBundleID = "company.thebrowser.Browser"
    private static let pendingKey = "pendingArcProfileImport"
    private static let resultKey = "arcProfileImportResult"

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: arcProfile.appendingPathComponent("Preferences").path)
    }

    static var isPending: Bool {
        UserDefaults.standard.bool(forKey: pendingKey)
    }

    /// The summary of an import that ran at this launch, once.
    static func takeResult() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: resultKey) }
        return UserDefaults.standard.string(forKey: resultKey)
    }

    /// Asks for the import at the next launch and restarts OpenArch.
    @MainActor
    static func scheduleAndRelaunch() {
        UserDefaults.standard.set(true, forKey: pendingKey)
        UserDefaults.standard.synchronize()
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Running the import (before Chromium starts)

    struct Summary {
        var cookies = 0
        var passwords = 0
        var cards = 0
        var historyEntries = 0
        var extensions = 0
        var undecryptable = 0
    }

    enum ImportError: LocalizedError {
        case noKeychainAccess(OSStatus)
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .noKeychainAccess(let status):
                "Der Schlüssel „Arc Safe Storage“ konnte nicht aus dem Schlüsselbund gelesen werden (\(status)). Ohne ihn lassen sich Logins und Passwörter nicht übernehmen."
            case .copyFailed(let detail):
                "Das Arc-Profil konnte nicht kopiert werden: \(detail)"
            }
        }
    }

    /// Profile entries that are caches, or that would make Chromium restore
    /// Arc's own windows.
    private static let skipped: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "GrShaderCache", "ShaderCache",
        "Sessions", "Sessions_Encrypted", "Current Session", "Current Tabs", "Last Session", "Last Tabs",
        "WebRTC Logs", "GCM Store", "LOCK", "LOG", "LOG.old", "SingletonLock", "SingletonCookie", "SingletonSocket",
    ]

    /// Runs a scheduled import into |chromiumData|/Default. Call before
    /// Chromium starts.
    static func runIfPending(chromiumData: URL, history: (URL) -> Int) {
        guard isPending else { return }
        UserDefaults.standard.set(false, forKey: pendingKey)
        let message: String
        do {
            let summary = try run(into: chromiumData.appendingPathComponent("Default"), history: history)
            message = """
                Aus Arc übernommen: \(summary.cookies) Cookies (Logins), \(summary.passwords) Passwörter, \
                \(summary.historyEntries) Verlaufseinträge und \(summary.extensions) Extensions mit ihren Einstellungen.\
                \(summary.undecryptable > 0 ? " \(summary.undecryptable) Werte ließen sich nicht entschlüsseln und wurden ausgelassen." : "")
                """
        } catch {
            message = "Der vollständige Import ist fehlgeschlagen. \(error.localizedDescription)"
        }
        UserDefaults.standard.set(message, forKey: resultKey)
    }

    static func run(into target: URL, history: (URL) -> Int) throws -> Summary {
        let arcKey = try keychainKey(service: "Arc Safe Storage")
        let openArchKey = derivedKey(password: Data("mock_password".utf8))
        let fm = FileManager.default

        // Keep what OpenArch had, just in case.
        if fm.fileExists(atPath: target.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let backup = target.deletingLastPathComponent()
                .appendingPathComponent("Default (vor Arc-Import \(formatter.string(from: Date())))")
            try? fm.moveItem(at: target, to: backup)
        }
        try cloneProfile(into: target)

        var summary = Summary()
        let reencrypt: [(file: String, table: String, column: String, count: WritableKeyPath<Summary, Int>)] = [
            ("Cookies", "cookies", "encrypted_value", \.cookies),
            ("Login Data", "logins", "password_value", \.passwords),
            ("Login Data For Account", "logins", "password_value", \.passwords),
            ("Web Data", "credit_cards", "card_number_encrypted", \.cards),
        ]
        for entry in reencrypt {
            let url = target.appendingPathComponent(entry.file)
            guard fm.fileExists(atPath: url.path) else { continue }
            let (converted, failed) = reencryptColumn(database: url, table: entry.table, column: entry.column,
                                                      from: arcKey, to: openArchKey)
            summary[keyPath: entry.count] += converted
            summary.undecryptable += failed
        }
        summary.historyEntries = history(target.appendingPathComponent("History"))
        summary.extensions = ((try? fm.contentsOfDirectory(atPath: target.appendingPathComponent("Extensions").path)) ?? [])
            .filter { $0.count == 32 }.count
        return summary
    }

    /// Copies Arc's profile without caches and session files. APFS clones:
    /// instant, and no extra space until files change.
    static func cloneProfile(into target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let entries = (try? fm.contentsOfDirectory(atPath: arcProfile.path)) ?? []
        for name in entries where !skipped.contains(name) && !name.hasPrefix(".") {
            let source = arcProfile.appendingPathComponent(name).path
            let destination = target.appendingPathComponent(name).path
            // Clone file by file (copy-on-write); copies only where APFS
            // cannot clone.
            let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
            guard copyfile(source, destination, nil, flags) == 0 else {
                throw ImportError.copyFailed("\(name): \(String(cString: strerror(errno)))")
            }
        }
    }

    // MARK: Chromium's encryption (OSCrypt on macOS)

    /// The keychain password Chromium uses for |service|; macOS asks the
    /// user once whether OpenArch may read it.
    private static func keychainKey(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            throw ImportError.noKeychainAccess(status)
        }
        return derivedKey(password: password)
    }

    /// PBKDF2-SHA1 with Chromium's fixed salt and iteration count.
    static func derivedKey(password: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        _ = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return key
    }

    /// AES-128-CBC with PKCS#7 padding and an IV of 16 spaces.
    static func aes(_ operation: CCOperation, _ data: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                dataBytes.baseAddress, data.count, outputBytes.baseAddress, outputCount, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    /// Re-encrypts Chromium's "v10" values in one column. Returns how many
    /// values were converted and how many could not be decrypted (those are
    /// cleared, so Chromium does not choke on them).
    static func reencryptColumn(database: URL, table: String, column: String, from oldKey: Data, to newKey: Data) -> (Int, Int) {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { return (0, 0) }
        defer { sqlite3_close(db) }
        var select: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rowid, \(column) FROM \(table)", -1, &select, nil) == SQLITE_OK else {
            return (0, 0)
        }
        var updates: [(Int64, Data)] = []
        var failed = 0
        let prefix = Data("v10".utf8)
        while sqlite3_step(select) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(select, 0)
            guard let bytes = sqlite3_column_blob(select, 1) else { continue }
            let value = Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 1)))
            guard value.starts(with: prefix) else { continue }
            if let plain = aes(CCOperation(kCCDecrypt), value.dropFirst(3), key: oldKey),
               let encrypted = aes(CCOperation(kCCEncrypt), plain, key: newKey) {
                updates.append((rowid, prefix + encrypted))
            } else {
                updates.append((rowid, Data()))
                failed += 1
            }
        }
        sqlite3_finalize(select)

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var update: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE \(table) SET \(column) = ?1 WHERE rowid = ?2", -1, &update, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (rowid, data) in updates {
            _ = data.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32(data.count), transient) }
            sqlite3_bind_int64(update, 2, rowid)
            sqlite3_step(update)
            sqlite3_reset(update)
        }
        sqlite3_finalize(update)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return (updates.count - failed, failed)
    }
}
