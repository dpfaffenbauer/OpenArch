import AppKit
import SQLite3

/// Takes the favicons Arc already has (its Chromium "Favicons" database) for
/// the tabs in OpenArch's sidebar, so pinned tabs look right before they are
/// ever loaded.
enum ArcFavicons {
    static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc/User Data/Default/Favicons")

    /// Returns how many hosts got an icon.
    @MainActor @discardableResult
    static func importIcons(for urls: [String]) -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else { return 0 }
        // Arc keeps the database open; read a copy.
        let copy = fm.temporaryDirectory.appendingPathComponent("OpenArch-ArcFavicons-\(UUID().uuidString).db")
        guard (try? fm.copyItem(at: databaseURL, to: copy)) != nil else { return 0 }
        defer { try? fm.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        let base = "SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id"
        let exactSQL = base + " WHERE m.page_url = ?1 ORDER BY b.width DESC LIMIT 1"
        let prefixSQL = base + " WHERE m.page_url >= ?1 AND m.page_url < ?2 ORDER BY b.width DESC LIMIT 1"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        func image(_ sql: String, _ values: [String]) -> NSImage? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
            }
            guard sqlite3_step(statement) == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            return NSImage(data: data)
        }

        var done = Set<String>()
        for url in urls {
            guard let parsed = URL(string: url), let host = parsed.host(), let scheme = parsed.scheme,
                  !done.contains(host) else { continue }
            // Any page of the same site; "0" sorts right after "/".
            let prefix = "\(scheme)://\(host)/"
            let found = image(exactSQL, [url]) ?? image(prefixSQL, [prefix, "\(scheme)://\(host)0"])
            if let found {
                FaviconStore.shared.store(found, forURL: url)
                done.insert(host)
            }
        }
        return done.count
    }

    /// URLs of every tab in the library.
    @MainActor
    static func urls(in library: Library) -> [String] {
        library.allContainers.flatMap(\.allTabs).flatMap { [$0.savedURL, $0.currentURL] }
    }
}
