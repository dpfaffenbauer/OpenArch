import AppKit
import CommonCrypto
import OpenArchCore
import SQLite3

/// `--selftest --keychain-test`: an existing profile moves from the mock
/// keychain to the login keychain. Three launches on one data folder, each
/// its own process (Chromium starts once per process):
///   1. mock keychain, as before: Chromium saves a password and a cookie;
///   2. login keychain ("OpenArch SelfTest Safe Storage", made at this
///      launch): both are moved to the new key, and Chromium reads both;
///   3. login keychain again: nothing is moved again, Chromium still reads both.
/// Between the launches this process checks the databases themselves. The
/// keychain item is removed at the start and at the end.
enum KeychainSelfTest {
    static let username = "openarch-keychain-test"
    static let password = "geheim-passwort-123"
    static let cookieName = "openarch_keychain"
    static let cookieValue = "geheim-cookie"
    static let site = "https://example.com"

    /// The launch this process is (--keychain-test-phase N), or 0.
    static let phase: Int = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--keychain-test-phase"), index + 1 < arguments.count else { return 0 }
        return Int(arguments[index + 1]) ?? 0
    }()

    /// Without touching AppPaths.support, which empties the folder on first use.
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenArch SelfTest", isDirectory: true)
    private static var chromium: URL { folder.appendingPathComponent("Chromium", isDirectory: true) }

    static func report(phase: Int, failures: Int) {
        try? "\(failures)".write(to: folder.appendingPathComponent("keychain-test-\(phase)"), atomically: true, encoding: .utf8)
    }

    nonisolated(unsafe) private static var failures: [String] = []

    private static func expect(_ condition: Bool, _ message: String) {
        Swift.print("[selftest] \(condition ? "ok  " : "FAIL") \(message)")
        if !condition { failures.append(message) }
    }

    /// The three launches; returns the exit status.
    static func runPhases() -> Int32 {
        SafeStorage.delete(SafeStorage.account)
        SafeStorage.delete(SafeStorage.account + ".new")
        defer {
            SafeStorage.delete(SafeStorage.account)
            SafeStorage.delete(SafeStorage.account + ".new")
        }
        Swift.print("[selftest] STEP keychain move rollback")
        rollbackAndResume()
        for phase in 1...3 {
            Swift.print("[selftest] STEP keychain launch \(phase)")
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--selftest", "--keychain-test-phase", "\(phase)"] + (phase > 1 ? ["--keep-data"] : [])
            let result = folder.appendingPathComponent("keychain-test-\(phase)")
            try? FileManager.default.removeItem(at: result)
            do { try process.run() } catch {
                expect(false, "launch \(phase) starts (\(error))")
                break
            }
            process.waitUntilExit()
            let reported = (try? String(contentsOf: result, encoding: .utf8)).flatMap { Int($0) }
            expect(reported == 0, "launch \(phase) passes its checks (\(reported.map { "\($0) failures" } ?? "no result"))")
            checkDatabases(after: phase)
        }
        Swift.print("[selftest] KEYCHAIN DONE failures=\(failures.count) \(failures)")
        return failures.isEmpty ? 0 : 1
    }

    /// What Chromium wrote, read straight from its databases.
    private static func checkDatabases(after phase: Int) {
        let profile = chromium.appendingPathComponent("Default", isDirectory: true)
        let marker = FileManager.default.fileExists(atPath: chromium.appendingPathComponent(SafeStorage.markerName).path)
        let backup = FileManager.default.fileExists(atPath: chromium.appendingPathComponent(SafeStorageMigration.backupName).path)
        let savedPassword = blob(profile.appendingPathComponent("Login Data"),
                                 "SELECT password_value FROM logins WHERE username_value = '\(username)'")
        let cookie = blob(profile.appendingPathComponent("Cookies"),
                          "SELECT encrypted_value FROM cookies WHERE name = '\(cookieName)'")
        func opens(_ value: Data?, with key: Data, as plain: String) -> Bool {
            guard let value, value.starts(with: Data("v10".utf8)),
                  let decrypted = ArcProfileImport.aes(CCOperation(kCCDecrypt), value.dropFirst(3), key: key) else { return false }
            // A cookie's value follows the SHA-256 of its domain.
            return decrypted == Data(plain.utf8) || decrypted.suffix(plain.utf8.count) == Data(plain.utf8)
        }
        if phase == 1 {
            expect(opens(savedPassword, with: SafeStorage.mockKey, as: password),
                   "launch 1 saved the password with the mock key (\(savedPassword?.count ?? 0) bytes)")
            expect(opens(cookie, with: SafeStorage.mockKey, as: cookieValue),
                   "launch 1 saved the cookie with the mock key (\(cookie?.count ?? 0) bytes)")
            expect(!marker && SafeStorage.readSilently() == nil, "launch 1 left the keychain alone")
            return
        }
        guard let secret = SafeStorage.readSilently() else {
            return expect(false, "launch \(phase) made \(SafeStorage.service) in the login keychain")
        }
        let key = ArcProfileImport.derivedKey(password: secret)
        expect(opens(savedPassword, with: key, as: password) && !opens(savedPassword, with: SafeStorage.mockKey, as: password),
               "after launch \(phase) the password is encrypted with the keychain's key, not the mock key")
        expect(opens(cookie, with: key, as: cookieValue) && !opens(cookie, with: SafeStorage.mockKey, as: cookieValue),
               "after launch \(phase) the cookie is encrypted with the keychain's key, not the mock key")
        expect(marker, "the data folder is marked as moved to the keychain")
        expect(backup == (phase == 2), phase == 2 ? "launch 2 kept a backup of the old databases" : "launch 3 removed the backup")
    }

    /// A move that fails puts every byte back; one that was interrupted
    /// (backup still there, no marker) starts over from the backup instead of
    /// encrypting twice. On a throwaway folder, without Chromium.
    private static func rollbackAndResume() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openarch-keychain-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try? fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let database = profile.appendingPathComponent("Login Data")
        let newKey = ArcProfileImport.derivedKey(password: Data("keychain-test".utf8))
        let plain = Data("passwort".utf8)
        guard let encrypted = ArcProfileImport.aes(CCOperation(kCCEncrypt), plain, key: SafeStorage.mockKey) else {
            return expect(false, "test value encrypts")
        }
        let value = Data("v10".utf8) + encrypted
        var db: OpaquePointer?
        sqlite3_open(database.path, &db)
        sqlite3_exec(db, "CREATE TABLE logins (password_value BLOB); CREATE TABLE stuck (k INTEGER PRIMARY KEY, v BLOB) WITHOUT ROWID", nil, nil, nil)
        for sql in ["INSERT INTO logins VALUES (?1)", "INSERT INTO stuck VALUES (1, ?1)"] {
            var insert: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &insert, nil)
            _ = value.withUnsafeBytes { sqlite3_bind_blob(insert, 1, $0.baseAddress, Int32(value.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_step(insert)
            sqlite3_finalize(insert)
        }
        sqlite3_close(db)
        let backup = root.appendingPathComponent(SafeStorageMigration.backupName)
        let before = try? Data(contentsOf: database)

        // The table without rowid can't be moved: the move fails as a whole.
        let failed = SafeStorageMigration.run(chromiumData: root, from: SafeStorage.mockKey, to: newKey)
        if case .failed = failed {} else { expect(false, "a move that can't finish fails (\(failed))") }
        expect(before != nil && (try? Data(contentsOf: database)) == before && !fm.fileExists(atPath: backup.path),
               "a failed move puts the database back byte for byte (\(failed))")

        sqlite3_open(database.path, &db)
        sqlite3_exec(db, "DROP TABLE stuck", nil, nil, nil)
        sqlite3_close(db)
        let first = SafeStorageMigration.run(chromiumData: root, from: SafeStorage.mockKey, to: newKey)
        // Quit before the marker was written: the next launch moves again.
        let second = SafeStorageMigration.run(chromiumData: root, from: SafeStorage.mockKey, to: newKey)
        let stored = blob(database, "SELECT password_value FROM logins")
        let opens = stored.flatMap { ArcProfileImport.aes(CCOperation(kCCDecrypt), $0.dropFirst(3), key: newKey) } == plain
        expect(first == .moved(values: 1, databases: 1, skipped: 0) && second == first && opens,
               "an interrupted move starts again from its backup and encrypts once (\(first), \(second))")
    }

    private static func blob(_ database: URL, _ sql: String) -> Data? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}

extension SelfTest {
    /// One launch of the keychain test, inside Chromium.
    func keychainPhase(_ phase: Int, then done: @escaping () -> Void) {
        switch phase {
        case 1:
            expect(!SafeStorage.usesLoginKeychain, "launch 1 uses the mock keychain, as OpenArch did before")
            keychainSavePassword {
                self.keychainCookie(set: true) { done() }
            }
        case 2:
            expect(SafeStorage.usesLoginKeychain && SafeStorage.itemOutcome == "made",
                   "launch 2 makes its key in the login keychain without asking (\(SafeStorage.itemOutcome))")
            if case let .moved(values, _, skipped) = SafeStorage.migration {
                expect(values >= 2 && skipped == 0, "launch 2 moves the mock-encrypted values to the new key (\(SafeStorage.migration))")
            } else {
                expect(false, "launch 2 moves the mock-encrypted values to the new key (\(SafeStorage.migration))")
            }
            arcCrypto()
            keychainReadPassword {
                self.keychainCookie(set: false) { done() }
            }
        default:
            expect(SafeStorage.usesLoginKeychain && SafeStorage.itemOutcome == "read",
                   "launch 3 reads its key without asking (\(SafeStorage.itemOutcome))")
            expect(SafeStorage.migration == .alreadyDone, "launch 3 does not move the data again (\(SafeStorage.migration))")
            keychainReadPassword {
                self.keychainCookie(set: false) { done() }
            }
        }
    }

    /// Chrome's password manager page, with its passwordsPrivate API.
    private func keychainPasswordPage(_ body: @escaping (Item) -> Void) {
        let tab = browser.openInNewTab("chrome://password-manager/passwords")
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading }, timeout: 10) { _ in
            after(1) { body(tab) }
        }
    }

    private func keychainEvaluate(_ tab: Item, _ script: String, then report: @escaping (Any?) -> Void) {
        guard let pane = tab.pane else { return report(nil) }
        pane.callDevToolsMethod("Runtime.evaluate", params: ["expression": script, "awaitPromise": true, "returnByValue": true]) { result in
            report((result?["result"] as? [String: Any])?["value"] ?? result?["exceptionDetails"].map { "\($0)" })
        }
    }

    private func keychainSavePassword(then next: @escaping () -> Void) {
        keychainPasswordPage { tab in
            let script = """
                chrome.passwordsPrivate.addPassword({url: '\(KeychainSelfTest.site)', username: '\(KeychainSelfTest.username)',
                    password: '\(KeychainSelfTest.password)', note: '', useAccountStore: false})
                  .then(() => new Promise(done => setTimeout(done, 1500)))  // the list follows the store
                  .then(() => chrome.passwordsPrivate.getSavedPasswordList())
                  .then(list => list.filter(e => e.username === '\(KeychainSelfTest.username)').length)
                  .catch(e => 'error: ' + e.message)
                """
            self.keychainEvaluate(tab, script) { value in
                self.expect((value as? Int) == 1, "Chromium saves a password (\(value ?? "no answer"))")
                self.browser.close(tab)
                next()
            }
        }
    }

    private func keychainReadPassword(then next: @escaping () -> Void) {
        keychainPasswordPage { tab in
            let script = """
                chrome.passwordsPrivate.getSavedPasswordList()
                  .then(list => list.filter(e => e.username === '\(KeychainSelfTest.username)').length)
                  .catch(e => 'error: ' + e.message)
                """
            self.keychainEvaluate(tab, script) { value in
                self.expect((value as? Int) == 1, "Chromium reads the moved password (\(value ?? "no answer"))")
                self.browser.close(tab)
                next()
            }
        }
    }

    private func keychainCookie(set: Bool, then next: @escaping () -> Void) {
        let tab = browser.openInNewTab(KeychainSelfTest.site + "/keychain-test")
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading }, timeout: 10) { _ in
            let cookie = "\(KeychainSelfTest.cookieName)=\(KeychainSelfTest.cookieValue)"
            let script = set
                ? "document.cookie = '\(cookie); max-age=86400; path=/; Secure'; document.cookie"
                : "document.cookie"
            self.keychainEvaluate(tab, script) { value in
                let cookies = value as? String ?? ""
                self.expect(cookies.contains(cookie), set ? "Chromium sets a cookie (\(cookies))" : "Chromium reads the moved cookie (\(cookies))")
                self.browser.close(tab)
                next()
            }
        }
    }
}
