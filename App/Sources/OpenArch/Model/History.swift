import Foundation
import SQLite3

/// Pages visited, for the command bar. Chromium keeps its own full history
/// per profile (chrome://history); this is a small cross-profile index that
/// OpenArch can search instantly.
@MainActor
final class History {
    struct Entry: Hashable {
        var url: String
        var title: String
        var visitCount: Int
        var lastVisit: Date
    }

    private var db: OpaquePointer?

    init(url: URL = AppPaths.support.appendingPathComponent("History.sqlite")) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            log("could not open history database")
            return
        }
        exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS visits (
              url TEXT PRIMARY KEY,
              title TEXT NOT NULL DEFAULT '',
              visit_count INTEGER NOT NULL DEFAULT 0,
              last_visit REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS visits_last_visit ON visits(last_visit);
            """)
    }

    func recordVisit(url: String, title: String?) {
        guard Self.isRecordable(url) else { return }
        run("""
            INSERT INTO visits (url, title, visit_count, last_visit) VALUES (?1, coalesce(?2, ''), 1, ?3)
            ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, last_visit = ?3,
              title = CASE WHEN ?2 IS NULL OR ?2 = '' THEN title ELSE ?2 END
            """, [url, title as Any, Date().timeIntervalSince1970])
    }

    func updateTitle(url: String, title: String) {
        guard Self.isRecordable(url), !title.isEmpty else { return }
        run("UPDATE visits SET title = ?2 WHERE url = ?1", [url, title])
    }

    /// Entries whose URL or title contains every word of |query|, best first.
    func search(_ query: String, limit: Int = 8) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let conditions = words.indices.map { "(lower(url) LIKE ?\($0 + 1) OR lower(title) LIKE ?\($0 + 1))" }
        let sql = """
            SELECT url, title, visit_count, last_visit FROM visits
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY (visit_count * 2 + (last_visit - strftime('%s','now') + 2592000) / 86400.0) DESC
            LIMIT \(limit)
            """
        return fetch(sql, words.map { "%\($0)%" })
    }

    /// Chrome's inline autocompletion: the address the command bar fills in
    /// as you type. Until a "/" it is the most visited site whose name starts
    /// with |typed|; after it, the most visited page. Addresses are compared
    /// without "https://" and "www.".
    func inlineCompletion(for typed: String) -> (text: String, url: String)? {
        let typed = typed.lowercased()
        guard !typed.isEmpty, !typed.contains(" "), !typed.contains("://") else { return nil }
        let candidates = fetch("""
            SELECT url, title, visit_count, last_visit FROM visits
            WHERE lower(url) LIKE ?1 ORDER BY visit_count DESC, last_visit DESC LIMIT 400
            """, ["%\(typed)%"])
        if !typed.contains("/") {
            var visits: [String: (count: Int, url: String)] = [:]
            for entry in candidates {
                guard let components = URLComponents(string: entry.url), let host = components.host?.lowercased() else { continue }
                let name = Self.withoutWWW(host) + (components.port.map { ":\($0)" } ?? "")
                guard name.hasPrefix(typed), name != typed else { continue }
                let site = "\(components.scheme ?? "https")://\(host)\(components.port.map { ":\($0)" } ?? "")/"
                visits[name, default: (0, site)].count += entry.visitCount
            }
            return visits.max { $0.value.count < $1.value.count }.map { ($0.key, $0.value.url) }
        }
        for entry in candidates {
            let text = Self.display(entry.url)
            if text.lowercased().hasPrefix(typed), text.count > typed.count {
                return (text, entry.url)
            }
        }
        return nil
    }

    /// An address as the command bar completes it: no scheme, no "www.",
    /// no "/" after the site alone.
    static func display(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        text = withoutWWW(text)
        if text.hasSuffix("/"), text.firstIndex(of: "/") == text.index(before: text.endIndex) {
            text.removeLast()
        }
        return text
    }

    private static func withoutWWW(_ text: String) -> String {
        text.lowercased().hasPrefix("www.") ? String(text.dropFirst(4)) : text
    }

    func recent(limit: Int = 8) -> [Entry] {
        fetch("SELECT url, title, visit_count, last_visit FROM visits ORDER BY last_visit DESC LIMIT \(limit)", [])
    }

    /// Adds a Chromium history database (e.g. Arc's) to the command bar's
    /// index. Returns how many pages were added or updated.
    func importChromiumHistory(from url: URL) -> Int {
        var source: OpaquePointer?
        guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(source) }
        var statement: OpaquePointer?
        let sql = "SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT 50000"
        guard sqlite3_prepare_v2(source, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        exec("BEGIN")
        var count = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlText = sqlite3_column_text(statement, 0) else { continue }
            let page = String(cString: urlText)
            guard Self.isRecordable(page) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let visits = Int(sqlite3_column_int64(statement, 2))
            // Chromium counts microseconds since 1601.
            let lastVisit = Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - 11_644_473_600
            run("""
                INSERT INTO visits (url, title, visit_count, last_visit) VALUES (?1, ?2, ?3, ?4)
                ON CONFLICT(url) DO UPDATE SET visit_count = max(visit_count, ?3),
                  last_visit = max(last_visit, ?4), title = CASE WHEN title = '' THEN ?2 ELSE title END
                """, [page, title, max(1, visits), lastVisit])
            count += 1
        }
        exec("COMMIT")
        return count
    }

    static func isRecordable(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://")
    }

    // MARK: SQLite

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ values: [Any]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let string as String: sqlite3_bind_text(statement, position, string, -1, transient)
            case let double as Double: sqlite3_bind_double(statement, position, double)
            case let int as Int: sqlite3_bind_int64(statement, position, Int64(int))
            default: sqlite3_bind_null(statement, position)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Any]) {
        guard let statement = prepare(sql, values) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func fetch(_ sql: String, _ values: [Any]) -> [Entry] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(Entry(
                url: String(cString: sqlite3_column_text(statement, 0)),
                title: String(cString: sqlite3_column_text(statement, 1)),
                visitCount: Int(sqlite3_column_int64(statement, 2)),
                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
        }
        return entries
    }
}
