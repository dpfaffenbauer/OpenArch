import Foundation
import OpenArchCore

/// A page's back/forward history as its engine wrote it down
/// (OACPage.sessionState), for the page that takes the tab's place later: a
/// closed tab that comes back, a sleeping one that wakes up.
struct PageSession: Codable {
    /// The tab's address when the history was taken. A tab sent somewhere
    /// else since then starts there, not in its old history.
    var url: String
    /// WebKit's history, which only a WebKit page reads; else Chromium's.
    var webKit: Bool
    var state: Data

    @MainActor
    init?(of page: any OACPage, at url: String) {
        guard let state = page.sessionState, !state.isEmpty else { return nil }
        self.url = url
        self.webKit = page.engine == .webKit
        self.state = state
    }

    /// Hands the history to |page|, a new page at |url| that has not loaded
    /// yet, if it is still that tab's address and that engine's history.
    @MainActor
    func restore(into page: any OACPage, at url: String) {
        guard url == self.url, webKit == (page.engine == .webKit) else { return }
        page.restoreSessionState(state)
    }
}

/// The histories of the tabs in the archive, one file each in "Closed Tabs"
/// beside the library: together they are too much for Library.json, which is
/// written again after every change.
@MainActor
enum ClosedTabSessions {
    private static let directory = AppPaths.support.appendingPathComponent("Closed Tabs", isDirectory: true)

    private static func file(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString)
    }

    /// Writes |session| down; nil if that failed (the tab then comes back
    /// with its address only).
    static func save(_ session: PageSession) -> UUID? {
        let id = UUID()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(session).write(to: file(id), options: .atomic)
            return id
        } catch {
            log("could not save a closed tab's history: \(error)")
            return nil
        }
    }

    /// The history saved as |id|, which is gone from the disk after this:
    /// its tab is open again.
    static func take(_ id: UUID?) -> PageSession? {
        guard let id else { return nil }
        defer { delete(id) }
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? PropertyListDecoder().decode(PageSession.self, from: data)
    }

    static func delete(_ id: UUID?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: file(id))
    }

    /// Removes every history but those of |keep|: the archive was emptied or
    /// replaced, or a history was left behind (a crash before the library
    /// was saved).
    static func deleteAll(besides keep: Set<UUID> = []) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where UUID(uuidString: file.lastPathComponent).map(keep.contains) != true {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
