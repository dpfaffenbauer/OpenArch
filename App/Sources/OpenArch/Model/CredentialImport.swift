import AppKit
import CommonCrypto
import Foundation
import SQLite3

/// A saved password, from a CSV file. Never logged.
struct ImportedLogin: Sendable {
    var origin: String
    var signonRealm: String
    var username: String
    var password: String
}

/// Saved passwords from a CSV file the user exported and chose. Columns
/// are found by name, so the order does not matter:
///   Chrome (Edge, Brave …): name,url,username,password,note
///   Firefox: "url","username","password","httpRealm","formActionOrigin",…
///   Safari / Passwords: Title,URL,Username,Password,Notes,OTPAuth
///   1Password: Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes
///   Bitwarden: folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
/// The file is only read; nothing of it is logged.
struct PasswordFile: Sendable {
    enum Format: String, Sendable {
        case chrome = "Chrome", firefox = "Firefox", safari = "Safari", onePassword = "1Password",
             bitwarden = "Bitwarden", other = "CSV"
    }

    var format: Format
    var logins: [ImportedLogin] = []
    var rows = 0
    /// The same site and username twice in the file.
    var duplicates = 0
    /// Rows without a password or an address.
    var incomplete = 0
    /// App logins, notes, cards: not for a website.
    var notWebsite = 0
    var unreadable = 0

    static let maxRows = 100_000

    static func read(_ url: URL) throws -> PasswordFile {
        try parse(BrowserImporter.readLimited(url, limit: 64 << 20))
    }

    static func parse(_ data: Data) throws -> PasswordFile {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw ImportReadError.notPasswords }
        var records = records(bytes)
        guard !records.isEmpty else { throw ImportReadError.notPasswords }
        let header = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let urlColumn = column(["url", "login_uri", "website", "web site", "login url", "origin", "hostname", "address", "urls"]),
              let passwordColumn = column(["password", "login_password"]) else { throw ImportReadError.notPasswords }
        let usernameColumn = column(["username", "login_username", "user name", "login", "user", "email"])
        let typeColumn = header.contains("login_uri") ? column(["type"]) : nil
        let format: Format =
            header.contains("login_uri") ? .bitwarden
            : header.contains("formactionorigin") || header.contains("httprealm") ? .firefox
            : header.contains("archived") || header.contains("tags") || header.contains("favorite") ? .onePassword
            : header.contains("otpauth") || header.first == "title" ? .safari
            : header.first == "name" ? .chrome : .other
        var file = PasswordFile(format: format)
        var seen = Set<String>()
        for (index, record) in records.enumerated() {
            if record.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            file.rows += 1
            guard index < maxRows, record.count > max(urlColumn, passwordColumn) else {
                file.unreadable += 1
                continue
            }
            if let typeColumn, typeColumn < record.count, !record[typeColumn].isEmpty, record[typeColumn].lowercased() != "login" {
                file.notWebsite += 1
                continue
            }
            let password = record[passwordColumn]
            // 1Password and Bitwarden may list several addresses; the first counts.
            let address = record[urlColumn].split(whereSeparator: { $0 == "\n" || $0 == "," }).first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !password.isEmpty, !address.isEmpty else {
                file.incomplete += 1
                continue
            }
            guard let site = origin(address) else {
                file.notWebsite += 1
                continue
            }
            let username = usernameColumn.flatMap { $0 < record.count ? record[$0] : nil } ?? ""
            guard seen.insert(site.realm + "\u{1F}" + site.origin + "\u{1F}" + username).inserted else {
                file.duplicates += 1
                continue
            }
            file.logins.append(ImportedLogin(origin: site.origin, signonRealm: site.realm, username: username, password: password))
        }
        return file
    }

    /// The page a login is for as Chromium keeps it, and its realm
    /// ("https://host[:port]/"). Nil for anything but http(s).
    static func origin(_ raw: String) -> (origin: String, realm: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), !text.contains(":"), text.contains("."), !text.contains(" ") { text = "https://" + text }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) { components.port = nil }
        if components.path.isEmpty { components.path = "/" }
        let port = components.port.map { ":\($0)" } ?? ""
        let realm = "\(scheme)://\(host)\(port)/"
        return (components.string ?? realm, realm)
    }

    /// RFC 4180: commas, quotes doubled inside quotes, LF, CRLF or CR.
    static func records(_ bytes: [UInt8]) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = 0
        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
        }
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(byte)
                }
            } else {
                switch byte {
                case 0x22 where field.isEmpty: quoted = true
                case 0x2C: endField()
                case 0x0D:
                    endRecord()
                    if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
                case 0x0A: endRecord()
                default: field.append(byte)
                }
            }
            index += 1
            if records.count > maxRows + 1 { return records }
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}

/// Logins, cookies and passwords that go into a Chromium profile of
/// OpenArch's. Chromium keeps its databases locked while it runs, so these
/// wait for the next launch and run before Chromium starts, as the full
/// Arc import does. What waits is only where to read from: a browser's
/// profile folder, or the path of the CSV file (read again then, never
/// changed).
enum CredentialImport {
    struct Job: Codable, Equatable {
        enum Kind: String, Codable { case browserProfile, passwordFile }
        var kind: Kind
        /// The other browser's profile folder, or the CSV file.
        var source: String
        /// The keychain item the browser encrypts with ("Chrome Safe Storage").
        var safeStorage: String?
        var name: String
        /// OpenArch's profile directory.
        var targetProfile: String
    }

    private static let pendingKey = "pendingCredentialImports"
    private static let resultKey = "credentialImportResult"

    static var pending: [Job] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([Job].self, from: data)) ?? []
    }

    static func schedule(_ jobs: [Job]) {
        var all = pending
        for job in jobs where !all.contains(job) { all.append(job) }
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: pendingKey)
        UserDefaults.standard.synchronize()
    }

    static func takeResult() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: resultKey) }
        return UserDefaults.standard.string(forKey: resultKey)
    }

    /// Runs what waits, into |chromiumData|. Call before Chromium starts.
    static func runIfPending(chromiumData: URL) {
        let jobs = pending
        guard !jobs.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        var lines: [String] = []
        for job in jobs {
            let target = chromiumData.appendingPathComponent(job.targetProfile, isDirectory: true)
            let template = chromiumData.appendingPathComponent("Default", isDirectory: true)
            do {
                switch job.kind {
                case .browserProfile:
                    guard let service = job.safeStorage else { continue }
                    let key = try ArcProfileImport.keychainKey(service: service)
                    let summary = mergeProfile(from: URL(fileURLWithPath: job.source), key: key, into: target, template: template)
                    lines.append("""
                        \(job.name): \(summary.cookies) Cookies (Logins) und \(summary.passwords) Passwörter übernommen.\
                        \(summary.undecryptable > 0 ? " \(summary.undecryptable) Werte ließen sich nicht entschlüsseln." : "")
                        """)
                case .passwordFile:
                    let file = try PasswordFile.read(URL(fileURLWithPath: job.source))
                    let (added, existing) = insertLogins(file.logins, into: target, template: template)
                    lines.append("\(job.name): \(added) Passwörter übernommen\(existing > 0 ? ", \(existing) waren schon gespeichert" : "").")
                }
            } catch {
                lines.append("\(job.name): \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(lines.joined(separator: "\n"), forKey: resultKey)
    }

    /// Asks for the import at the next launch and restarts OpenArch.
    @MainActor
    static func scheduleAndRelaunch(_ jobs: [Job]) {
        schedule(jobs)
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Browser profiles

    struct Summary: Equatable {
        var cookies = 0
        var passwords = 0
        var undecryptable = 0
    }

    /// The databases that hold logins: file, table, encrypted column, and
    /// whether an entry found again replaces the one there (cookies) or
    /// stays (passwords).
    static let databases: [(file: String, table: String, column: String, replace: Bool)] = [
        ("Cookies", "cookies", "encrypted_value", true),
        ("Login Data", "logins", "password_value", false),
        ("Login Data For Account", "logins", "password_value", false),
    ]

    /// Copies the other browser's cookies and passwords into |target|: from
    /// a private copy, decrypted with the browser's key and encrypted again
    /// with OpenArch's, then merged row by row into OpenArch's own database
    /// (made from |template|'s, the Default profile, when the profile has
    /// none yet). Merging by column name keeps OpenArch's schema even when
    /// the other browser's Chromium is newer, and importing again adds
    /// nothing twice.
    static func mergeProfile(from source: URL, key: Data, into target: URL, template: URL) -> Summary {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let openArchKey = SafeStorage.key  // SafeStorage.prepare runs first (main.swift)
        var summary = Summary()
        for database in databases {
            // Newer Chromium keeps cookies under Network/.
            let candidates = [source.appendingPathComponent(database.file),
                              source.appendingPathComponent("Network").appendingPathComponent(database.file)]
            guard let file = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            let merged: (Int, Int)? = SQLiteCopy.withCopyURL(of: file) { copy in
                let (_, failed) = ArcProfileImport.reencryptColumn(database: copy, table: database.table, column: database.column,
                                                                   from: key, to: openArchKey)
                let destination = target.appendingPathComponent(database.file)
                guard prepare(destination, template: template.appendingPathComponent(database.file), fallback: copy) else {
                    return (0, failed)
                }
                return (mergeRows(from: copy, into: destination, table: database.table, replace: database.replace), failed)
            }
            guard let (added, failed) = merged else { continue }
            if database.table == "cookies" { summary.cookies += added } else { summary.passwords += added }
            summary.undecryptable += failed
        }
        return summary
    }

    /// Makes sure |database| exists: an empty copy of |template| (OpenArch's
    /// own schema), or else of |fallback|.
    static func prepare(_ database: URL, template: URL, fallback: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: database.path) { return true }
        let source = fm.fileExists(atPath: template.path) ? template : fallback
        guard (try? fm.copyItem(at: source, to: database)) != nil else { return false }
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        let tables = SQLiteCopy.rows(db!, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'meta'") {
            $0.text(0) ?? ""
        } ?? []
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for table in tables where !table.isEmpty {
            sqlite3_exec(db, "DELETE FROM \"\(table)\"", nil, nil, nil)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_exec(db, "VACUUM", nil, nil, nil)
        return true
    }

    /// Copies |table|'s rows from |source| into |target| by the columns
    /// both have. Returns how many rows went in.
    static func mergeRows(from source: URL, into target: URL, table: String, replace: Bool) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(target.path, &db) == SQLITE_OK, let db else { return 0 }
        defer { sqlite3_close(db) }
        let escaped = source.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(db, "ATTACH DATABASE '\(escaped)' AS src", nil, nil, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_exec(db, "DETACH DATABASE src", nil, nil, nil) }
        func columns(_ schema: String) -> [String] {
            SQLiteCopy.rows(db, "PRAGMA \(schema).table_info(\"\(table)\")") { $0.text(1) ?? "" } ?? []
        }
        let theirs = Set(columns("src"))
        // The row ID is the database's own.
        let shared = columns("main").filter { theirs.contains($0) && $0 != "id" }
        guard !shared.isEmpty else { return 0 }
        let list = shared.map { "\"\($0)\"" }.joined(separator: ", ")
        let sourceList = shared.map { "s.\"\($0)\"" }.joined(separator: ", ")
        // A login counts as there when site, user and fields match; empty
        // and missing fields are the same (SQLite's UNIQUE lets NULLs repeat).
        let loginKey = ["origin_url", "username_element", "username_value", "password_element", "signon_realm"]
        let same = table == "logins" && !replace
            ? " WHERE NOT EXISTS (SELECT 1 FROM main.\"\(table)\" m WHERE "
                + loginKey.filter(shared.contains).map { "coalesce(m.\"\($0)\", '') = coalesce(s.\"\($0)\", '')" }
                    .joined(separator: " AND ") + ")"
            : ""
        let before = sqlite3_total_changes(db)
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        sqlite3_exec(db, "INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO main.\"\(table)\" (\(list)) SELECT \(sourceList) FROM src.\"\(table)\" s\(same)",
                     nil, nil, nil)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return Int(sqlite3_total_changes(db) - before)
    }

    // MARK: Passwords from a file

    /// Puts |logins| into the profile's Login Data, encrypted with OpenArch's
    /// key. A login already saved (same site, user and fields) stays as it
    /// is. Returns how many were added and how many were there already.
    static func insertLogins(_ logins: [ImportedLogin], into target: URL, template: URL) -> (Int, Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let database = target.appendingPathComponent("Login Data")
        if !fm.fileExists(atPath: database.path) {
            guard fm.fileExists(atPath: template.appendingPathComponent("Login Data").path),
                  prepare(database, template: template.appendingPathComponent("Login Data"), fallback: database) else {
                return (0, 0)
            }
        }
        let key = ArcProfileImport.derivedKey(password: Data("mock_password".utf8))
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else { return (0, 0) }
        defer { sqlite3_close(db) }
        struct Column { var name: String, type: String, notNull: Bool, hasDefault: Bool }
        let columns = SQLiteCopy.rows(db, "PRAGMA table_info(logins)") {
            Column(name: $0.text(1) ?? "", type: ($0.text(2) ?? "").uppercased(), notNull: $0.int(3) != 0,
                   hasDefault: sqlite3_column_type($0.statement, 4) != SQLITE_NULL)
        } ?? []
        guard columns.contains(where: { $0.name == "password_value" }) else { return (0, 0) }
        // Chromium's time: microseconds since 1601.
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        var added = 0
        var existing = 0
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for login in logins {
            guard let encrypted = ArcProfileImport.aes(CCOperation(kCCEncrypt), Data(login.password.utf8), key: key) else { continue }
            var values: [String: Any] = [
                "origin_url": login.origin, "action_url": "", "username_element": "", "username_value": login.username,
                "password_element": "", "password_value": Data("v10".utf8) + encrypted, "submit_element": "",
                "signon_realm": login.signonRealm, "date_created": now, "blacklisted_by_user": 0, "scheme": 0,
                "password_type": 0, "times_used": 0, "date_password_modified": now,
            ]
            // Whatever else this Chromium wants filled.
            for column in columns where values[column.name] == nil && column.notNull && !column.hasDefault && column.name != "id" {
                values[column.name] = column.type.contains("INT") ? 0 : column.type.contains("BLOB") ? Data() : ""
            }
            let names = columns.map(\.name).filter { values[$0] != nil }
            let sql = "INSERT OR IGNORE INTO logins (\(names.map { "\"\($0)\"" }.joined(separator: ", "))) VALUES (\(names.indices.map { "?\($0 + 1)" }.joined(separator: ", ")))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, name) in names.enumerated() {
                let position = Int32(index + 1)
                switch values[name] {
                case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
                case let number as Int: sqlite3_bind_int64(statement, position, Int64(number))
                case let number as Int64: sqlite3_bind_int64(statement, position, number)
                case let data as Data:
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), transient) }
                default: sqlite3_bind_null(statement, position)
                }
            }
            if sqlite3_step(statement) == SQLITE_DONE {
                if sqlite3_changes(db) > 0 { added += 1 } else { existing += 1 }
            }
            sqlite3_finalize(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return (added, existing)
    }
}
