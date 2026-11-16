import CommonCrypto
import Darwin
import Foundation
import SQLite3

/// Moves a data folder from the mock keychain's key to the login keychain's:
/// every "v10" value in the profiles' databases (cookies, saved passwords and
/// their notes, card numbers, the search engines' integrity hashes) is
/// decrypted with the old key and encrypted with the new one, before Chromium
/// opens the folder.
///
/// Nothing is lost: the databases are copied to a backup first. If anything
/// fails, the backup goes back and Chromium keeps the mock key for that
/// launch. A backup left by an interrupted move (OpenArch quit or crashed in
/// between) goes back at the next launch, before the move starts again. The
/// backup is removed at the launch after a finished move.
///
/// Local State holds no key on macOS (os_crypt lives in the keychain only),
/// so it stays as it is. Chromium's own session files (Sessions_Encrypted)
/// are not moved: OpenArch restores its tabs from Library.json.
enum SafeStorageMigration {
    enum Outcome: Equatable, CustomStringConvertible {
        /// No databases yet (a new data folder).
        case notNeeded
        /// The folder already uses the login keychain.
        case alreadyDone
        case moved(values: Int, databases: Int, skipped: Int)
        case failed(String)

        var description: String {
            switch self {
            case .notNeeded: "nothing to move"
            case .alreadyDone: "already on the keychain key"
            case let .moved(values, databases, skipped): "moved \(values) values in \(databases) databases (\(skipped) not readable with the old key, left as they were)"
            case .failed(let reason): "failed: \(reason)"
            }
        }
    }

    /// Profile databases with encrypted values, relative to a profile folder.
    static let databases = [
        "Cookies", "Network/Cookies", "Extension Cookies",
        "Login Data", "Login Data For Account",
        "Web Data", "Account Web Data",
    ]
    static let backupName = "OpenArch Keychain Backup"
    private static let backupComplete = ".complete"
    private static let companions = ["", "-journal", "-wal", "-shm"]

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func run(chromiumData: URL, from oldKey: Data, to newKey: Data) -> Outcome {
        let fm = FileManager.default
        let backup = chromiumData.appendingPathComponent(backupName, isDirectory: true)
        // A move that did not finish: its backup holds the data as it was.
        if fm.fileExists(atPath: backup.path) {
            restoreBackup(in: chromiumData)
        }
        let files = existingDatabases(in: chromiumData)
        guard !files.isEmpty else { return .notNeeded }
        do {
            try makeBackup(of: files, in: chromiumData)
        } catch {
            try? fm.removeItem(at: backup)
            return .failed("backup: \(error)")
        }
        var values = 0
        var skipped = 0
        do {
            for file in files {
                let (moved, left) = try reencrypt(database: file, from: oldKey, to: newKey)
                values += moved
                skipped += left
            }
        } catch {
            restoreBackup(in: chromiumData)
            return .failed("\(error)")
        }
        return .moved(values: values, databases: files.count, skipped: skipped)
    }

    /// The databases of every profile folder (Default, Profile 2, …).
    static func existingDatabases(in chromiumData: URL) -> [URL] {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: chromiumData.path)) ?? []).sorted()
        var found: [URL] = []
        for folder in folders where folder != backupName {
            let profile = chromiumData.appendingPathComponent(folder, isDirectory: true)
            for name in databases {
                let url = profile.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    found.append(url)
                }
            }
        }
        return found
    }

    // MARK: Backup

    private static func relativePath(_ url: URL, in root: URL) -> String {
        String(url.path.dropFirst(root.path.count + 1))
    }

    private static func makeBackup(of files: [URL], in chromiumData: URL) throws {
        let fm = FileManager.default
        let backup = chromiumData.appendingPathComponent(backupName, isDirectory: true)
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for file in files {
            for suffix in companions {
                let source = URL(fileURLWithPath: file.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = backup.appendingPathComponent(relativePath(source, in: chromiumData))
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A clone where APFS can, a copy elsewhere.
                guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) == 0 else {
                    throw Failure("\(source.lastPathComponent): \(String(cString: strerror(errno)))")
                }
            }
        }
        // Only a complete backup is ever put back.
        guard fm.createFile(atPath: backup.appendingPathComponent(backupComplete).path, contents: Data()) else {
            throw Failure("marking the backup complete")
        }
    }

    /// Puts the backed-up databases back and removes the backup. An
    /// incomplete backup (the move had not started) is only removed.
    static func restoreBackup(in chromiumData: URL) {
        let fm = FileManager.default
        let backup = chromiumData.appendingPathComponent(backupName, isDirectory: true)
        guard fm.fileExists(atPath: backup.appendingPathComponent(backupComplete).path) else {
            try? fm.removeItem(at: backup)
            return
        }
        let saved = (fm.enumerator(atPath: backup.path)?.allObjects as? [String] ?? [])
            .filter { path in
                var isDirectory: ObjCBool = false
                return path != backupComplete && fm.fileExists(atPath: backup.appendingPathComponent(path).path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }
        // Each database as it was, without journals written since.
        let mains = saved.filter { path in !companions.dropFirst().contains { path.hasSuffix($0) } }
        var complete = true
        for main in mains {
            for suffix in companions {
                let target = chromiumData.appendingPathComponent(main + suffix)
                try? fm.removeItem(at: target)
                let source = backup.appendingPathComponent(main + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                if copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE)) != 0 {
                    complete = false
                }
            }
        }
        // Keep the backup if anything could not go back.
        if complete { try? fm.removeItem(at: backup) }
        log("Safe Storage: put back \(mains.count) databases from the backup\(complete ? "" : ", some failed: kept the backup")")
    }

    static func removeBackup(in chromiumData: URL) {
        try? FileManager.default.removeItem(at: chromiumData.appendingPathComponent(backupName, isDirectory: true))
    }

    // MARK: Re-encryption

    /// Re-encrypts every "v10" value of every table in |database|, in one
    /// transaction, and reads them back. Values the old key does not open are
    /// left as they are (Chromium could not read them before either).
    static func reencrypt(database: URL, from oldKey: Data, to newKey: Data) throws -> (moved: Int, skipped: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure("\(database.lastPathComponent): cannot open")
        }
        defer { sqlite3_close(db) }
        func fail(_ what: String) -> Failure {
            Failure("\(database.lastPathComponent): \(what): \(String(cString: sqlite3_errmsg(db)))")
        }
        let prefix = Data("v10".utf8)
        let tables = try strings(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw fail("begin") }
        var moved: [(table: String, column: String, rowid: Int64, plain: Data)] = []
        var skipped = 0
        do {
            for table in tables {
                for column in try strings(db, "SELECT name FROM pragma_table_info(\(literal(table)))") {
                    let filter = "typeof(\(quoted(column))) = 'blob' AND substr(\(quoted(column)), 1, 3) = x'763130'"
                    var select: OpaquePointer?
                    let sql = "SELECT rowid, \(quoted(column)) FROM \(quoted(table)) WHERE \(filter)"
                    guard sqlite3_prepare_v2(db, sql, -1, &select, nil) == SQLITE_OK else {
                        sqlite3_finalize(select)
                        // A table without rowid: fine as long as it holds no encrypted values.
                        let count = try strings(db, "SELECT count(*) FROM \(quoted(table)) WHERE \(filter)").first
                        if count != "0" { throw Failure("\(database.lastPathComponent): \(table).\(column) has encrypted values but no rowid") }
                        continue
                    }
                    var rows: [(Int64, Data)] = []
                    while sqlite3_step(select) == SQLITE_ROW {
                        let bytes = sqlite3_column_blob(select, 1)
                        let value = bytes.map { Data(bytes: $0, count: Int(sqlite3_column_bytes(select, 1))) } ?? Data()
                        rows.append((sqlite3_column_int64(select, 0), value))
                    }
                    sqlite3_finalize(select)
                    var update: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "UPDATE \(quoted(table)) SET \(quoted(column)) = ?1 WHERE rowid = ?2",
                                             -1, &update, nil) == SQLITE_OK else { throw fail("update \(table)") }
                    defer { sqlite3_finalize(update) }
                    for (rowid, value) in rows {
                        guard (value.count - prefix.count) % kCCBlockSizeAES128 == 0,
                              let plain = ArcProfileImport.aes(CCOperation(kCCDecrypt), value.dropFirst(prefix.count), key: oldKey),
                              let encrypted = ArcProfileImport.aes(CCOperation(kCCEncrypt), plain, key: newKey) else {
                            skipped += 1
                            continue
                        }
                        let data = prefix + encrypted
                        sqlite3_reset(update)
                        _ = data.withUnsafeBytes {
                            sqlite3_bind_blob(update, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        }
                        sqlite3_bind_int64(update, 2, rowid)
                        guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw fail("update \(table)") }
                        moved.append((table, column, rowid, plain))
                    }
                }
            }
            // Read back what was written before it counts.
            for entry in moved {
                var select: OpaquePointer?
                defer { sqlite3_finalize(select) }
                guard sqlite3_prepare_v2(db, "SELECT \(quoted(entry.column)) FROM \(quoted(entry.table)) WHERE rowid = ?1",
                                         -1, &select, nil) == SQLITE_OK else { throw fail("check \(entry.table)") }
                sqlite3_bind_int64(select, 1, entry.rowid)
                guard sqlite3_step(select) == SQLITE_ROW, let bytes = sqlite3_column_blob(select, 0) else {
                    throw fail("check \(entry.table)")
                }
                let stored = Data(bytes: bytes, count: Int(sqlite3_column_bytes(select, 0)))
                guard stored.starts(with: prefix),
                      ArcProfileImport.aes(CCOperation(kCCDecrypt), stored.dropFirst(prefix.count), key: newKey) == entry.plain else {
                    throw Failure("\(database.lastPathComponent): \(entry.table).\(entry.column) does not read back")
                }
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            let failure = fail("commit")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw failure
        }
        return (moved.count, skipped)
    }

    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func strings(_ db: OpaquePointer?, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure("\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return result
    }

    // MARK: Is Chromium using the folder?

    /// The process of another OpenArch whose Chromium holds |chromiumData|
    /// (its SingletonLock points to "host-pid"), or nil.
    static func chromiumOwner(of chromiumData: URL) -> pid_t? {
        let lock = chromiumData.appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let dash = target.lastIndex(of: "-"), let pid = pid_t(target[target.index(after: dash)...]),
              pid != getpid(), kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return pid
    }
}
