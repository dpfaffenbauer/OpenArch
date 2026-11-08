import AppKit
import Security

/// The key Chromium encrypts saved passwords, cookies, card numbers and a few
/// other values with ("v10" values). It is the password of the item
/// "OpenArch Safe Storage" in the login keychain; Chromium reads it once per
/// launch (CefSettings.keychain_service_name).
///
/// Why OpenArch used Chromium's mock keychain (a fixed password) before: the
/// keychain lets the app that made an item read it without asking and asks
/// about every other app. An ad-hoc signed build is "another app" after every
/// rebuild, so macOS asked at every launch. An item made by a Developer ID
/// build trusts that build's designated requirement (bundle identifier and
/// team), so every later build signed the same way, updates included, reads it
/// without asking. So:
///   - Developer ID builds use the login keychain. They make the item
///     themselves, before Chromium starts; making it never asks.
///   - Ad-hoc builds (local builds, the self-test) keep the mock keychain,
///     unless `--login-keychain` asks for the real one or their data folder
///     was already moved to it (the marker file below): then the mock key
///     would make Chromium throw the data away.
///   - When the item exists but this build may not read it silently (it was
///     made by another signing identity), OpenArch explains, macOS asks once,
///     and a Developer ID build puts the same secret into an item of its own,
///     so the question does not come back (adapted from Airc's
///     SafeStorageKey, Apache-2.0, see NOTICE).
///   - Data encrypted with the mock key is re-encrypted with the real one
///     before Chromium opens it (SafeStorageMigration).
enum SafeStorage {
    /// The mock keychain's password (Chromium's MockAppleKeychain).
    static let mockPassword = Data("mock_password".utf8)
    /// Next to the profiles: present once the folder's data uses the login
    /// keychain's key.
    static let markerName = "OpenArch Keychain.json"
    private static let copySuffix = ".new"

    static var service: String { AppPaths.isSelfTest ? "OpenArch SelfTest Safe Storage" : "OpenArch Safe Storage" }
    static var account: String { AppPaths.isSelfTest ? "OpenArch SelfTest" : "OpenArch" }

    /// This launch: does Chromium use the login keychain, and with which
    /// password. Set by prepare(), before Chromium starts.
    nonisolated(unsafe) private(set) static var usesLoginKeychain = false
    nonisolated(unsafe) private(set) static var password = mockPassword
    nonisolated(unsafe) private(set) static var migration: SafeStorageMigration.Outcome = .notNeeded
    /// What happened with the keychain item at this launch (for the log and
    /// the self-test).
    nonisolated(unsafe) private(set) static var itemOutcome = "unused"

    /// The AES key Chromium derives from the password.
    static var key: Data { ArcProfileImport.derivedKey(password: password) }
    static var mockKey: Data { ArcProfileImport.derivedKey(password: mockPassword) }

    // MARK: Before Chromium starts

    /// Picks the keychain for this launch, reads or makes the key and moves
    /// data encrypted with the mock key over. May ask (dialogs) and may quit.
    @MainActor
    static func prepare(chromiumData: URL, arguments: [String]) {
        let marker = chromiumData.appendingPathComponent(markerName)
        let moved = FileManager.default.fileExists(atPath: marker.path)
        let teamSigned = signingTeam() != nil
        var wanted = arguments.contains("--login-keychain") || (teamSigned && !arguments.contains("--mock-keychain"))
        if moved && !wanted {
            log("Safe Storage: this data folder uses the login keychain, so this launch does too")
            wanted = true
        }
        guard wanted else {
            itemOutcome = "mock keychain"
            return
        }
        if let pid = SafeStorageMigration.chromiumOwner(of: chromiumData) {
            // Another OpenArch has the folder; Chromium hands this launch over
            // to it. Touch nothing.
            log("Safe Storage: the data folder is in use by \(pid), not touching it")
            usesLoginKeychain = moved
            return
        }

        guard let secret = loadOrCreate(dataMoved: moved, teamSigned: teamSigned) else {
            if moved {
                // The mock key would make Chromium throw the data away.
                let alert = NSAlert()
                alert.messageText = "OpenArch kann seinen Schlüssel nicht anlegen."
                alert.informativeText = "Der Schlüsselbund hat „\(service)“ nicht angenommen (\(itemOutcome)). Starte OpenArch bitte noch einmal."
                NSApp.activate()
                alert.runModal()
                exit(1)
            }
            // Without the key: the data stays on the mock key for now.
            log("Safe Storage: no key (\(itemOutcome)), mock keychain for this launch")
            return
        }

        if moved {
            migration = .alreadyDone
            SafeStorageMigration.removeBackup(in: chromiumData)
        } else {
            migration = SafeStorageMigration.run(chromiumData: chromiumData, from: mockKey,
                                                 to: ArcProfileImport.derivedKey(password: secret))
            switch migration {
            case .failed(let reason):
                // Everything was put back; Chromium opens the data with the
                // mock key, as before. Tried again next launch.
                log("Safe Storage: moving the data to the new key failed (\(reason)), mock keychain for this launch")
                return
            default:
                let info: [String: Any] = ["keychainItem": service, "since": ISO8601DateFormatter().string(from: Date())]
                guard let data = try? JSONSerialization.data(withJSONObject: info),
                      (try? data.write(to: marker, options: .atomic)) != nil else {
                    // Without the marker the next launch would redo the move
                    // on data already moved: put the old data back.
                    SafeStorageMigration.restoreBackup(in: chromiumData)
                    migration = .failed("could not write \(markerName)")
                    log("Safe Storage: could not write the marker, mock keychain for this launch")
                    return
                }
            }
        }
        usesLoginKeychain = true
        password = secret
        log("Safe Storage: login keychain (\(itemOutcome)), data: \(migration)")
    }

    /// The item's secret: read silently, made when missing, or asked for once.
    @MainActor
    private static func loadOrCreate(dataMoved: Bool, teamSigned: Bool) -> Data? {
        recoverInterruptedCopy()
        while true {
            let (status, secret) = silently { read(account) }
            if status == errSecSuccess, let secret, !secret.isEmpty {
                itemOutcome = "read"
                return secret
            }
            if status == errSecItemNotFound {
                if dataMoved && !askToStartOver() { exit(0) }
                // Chromium's own format: 16 random bytes, base64.
                var bytes = [UInt8](repeating: 0, count: 16)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
                let secret = Data(Data(bytes).base64EncodedString().utf8)
                let added = add(account, secret)
                let (back, stored) = silently { read(account) }
                guard added == errSecSuccess, back == errSecSuccess, stored == secret else {
                    itemOutcome = "could not make the item (\(added), \(back))"
                    return nil
                }
                itemOutcome = "made"
                return secret
            }
            // The item exists, but this build would be asked.
            explainQuestion(teamSigned: teamSigned)
            let (asked, answer) = read(account)
            if asked == errSecSuccess, let answer, !answer.isEmpty {
                itemOutcome = "asked"
                if teamSigned { takeOver(answer) }
                return answer
            }
            itemOutcome = "declined (\(asked))"
            // Data still on the mock key can wait for the next launch; data
            // already on this key can't be opened without it.
            guard dataMoved else { return nil }
            if !askToRetry() { exit(0) }
        }
    }

    // MARK: Dialogs

    @MainActor
    private static func explainQuestion(teamSigned: Bool) {
        let alert = NSAlert()
        alert.messageText = "macOS fragt gleich nach dem Schlüssel von OpenArch"
        alert.informativeText = """
            Deine gespeicherten Passwörter und Logins sind mit dem Schlüssel „\(service)“ aus deinem \
            Anmelde-Schlüsselbund verschlüsselt. Diese OpenArch-Version darf ihn noch nicht lesen, deshalb fragt \
            macOS gleich nach deinem Mac-Passwort. Gib es ein und wähle „Immer erlauben“.
            """ + (teamSigned ? " OpenArch übernimmt den Schlüssel danach, auch Updates fragen nicht mehr." : "")
        alert.addButton(withTitle: "Weiter")
        NSApp.activate()
        alert.runModal()
    }

    /// The key of data already moved to the keychain is gone.
    @MainActor
    private static func askToStartOver() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Der Schlüssel „\(service)“ fehlt im Schlüsselbund."
        alert.informativeText = """
            Mit ihm sind deine gespeicherten Passwörter und Logins verschlüsselt. Wenn du ihn aus einem Backup \
            deines Schlüsselbunds zurückholen kannst, beende OpenArch und tu das zuerst. Mit einem neuen Schlüssel \
            lassen sich die bisherigen Passwörter und Logins nicht mehr lesen.
            """
        alert.addButton(withTitle: "Beenden")
        let startOver = alert.addButton(withTitle: "Neuen Schlüssel anlegen")
        startOver.hasDestructiveAction = true
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    @MainActor
    private static func askToRetry() -> Bool {
        let alert = NSAlert()
        alert.messageText = "OpenArch kann seinen Schlüssel nicht lesen."
        alert.informativeText = """
            Ohne den Schlüssel „\(service)“ aus deinem Anmelde-Schlüsselbund lassen sich deine Passwörter und \
            Logins nicht öffnen. Versuch es noch einmal und wähle „Immer erlauben“, oder beende OpenArch.
            """
        alert.addButton(withTitle: "Erneut versuchen")
        alert.addButton(withTitle: "Beenden")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Taking the item over (Developer ID builds)

    /// Puts |secret| into an item made by this build, in place of one made by
    /// another signing identity, so this build and its updates read it
    /// without asking. The copy is read back before the old item goes; a copy
    /// left by an interrupted take-over is put back at the next launch.
    private static func takeOver(_ secret: Data) {
        let copy = account + copySuffix
        _ = delete(copy)
        guard add(copy, secret) == errSecSuccess else { return }
        let (back, stored) = silently { read(copy) }
        guard back == errSecSuccess, stored == secret else {
            _ = delete(copy)
            return
        }
        guard delete(account) == errSecSuccess else {
            _ = delete(copy)
            return
        }
        if rename(from: copy, to: account) != errSecSuccess {
            // The secret is still here: add it under the real name.
            if add(account, secret) == errSecSuccess { _ = delete(copy) }
        }
        let (check, again) = silently { read(account) }
        itemOutcome = check == errSecSuccess && again == secret ? "asked, taken over" : "asked, take-over failed (\(check))"
    }

    /// The original is gone but a copy waits: rename it back.
    private static func recoverInterruptedCopy() {
        let copy = account + copySuffix
        guard silently({ read(account).0 }) == errSecItemNotFound else { return }
        let (status, secret) = silently { read(copy) }
        guard status == errSecSuccess, let secret else { return }
        if rename(from: copy, to: account) == errSecSuccess || add(account, secret) == errSecSuccess {
            _ = delete(copy)
        }
    }

    // MARK: Keychain calls (the login keychain, as Chromium uses it)

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecMatchLimit as String: kSecMatchLimitOne]
    }

    private static func read(_ account: String) -> (OSStatus, Data?) {
        var q = query(account)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        return (status, result as? Data)
    }

    /// As Chromium makes it (KeychainV2::AddGenericPassword).
    private static func add(_ account: String, _ secret: Data) -> OSStatus {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecValueData as String: secret,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecAttrLabel as String: service]
        return SecItemAdd(q as CFDictionary, nil)
    }

    /// Deleting never reads the secret, so it never asks.
    @discardableResult
    static func delete(_ account: String) -> OSStatus {
        var q = query(account)
        q[kSecReturnRef as String] = true
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &ref)
        guard status == errSecSuccess, let ref else { return status }
        return SecKeychainItemDelete(ref as! SecKeychainItem)
    }

    private static func rename(from: String, to: String) -> OSStatus {
        var q = query(from)
        q.removeValue(forKey: kSecMatchLimit as String)
        return SecItemUpdate(q as CFDictionary, [kSecAttrAccount as String: to] as CFDictionary)
    }

    /// |body| with the keychain's questions off: what would ask fails
    /// instead. Process-wide, so only before Chromium starts.
    private static func silently<T>(_ body: () -> T) -> T {
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }

    /// The self-test's item, read without asking (nil when missing).
    static func readSilently() -> Data? {
        let (status, secret) = silently { read(account) }
        return status == errSecSuccess ? secret : nil
    }

    /// The team that signed this build; nil for ad-hoc signatures.
    static func signingTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
