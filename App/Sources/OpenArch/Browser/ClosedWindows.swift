import AppKit

/// Windows closed for good, newest first. ⌘⇧T brings the last one back,
/// tabs and all, when it closed after the last tab did (as in Chrome and
/// Dia); Ablage › Geschlossenes Fenster wieder öffnen always does.
@MainActor
final class ClosedWindows {
    static let shared = ClosedWindows()

    struct Entry {
        let date: Date
        let frame: NSRect
        /// The space a normal window showed, or a separate window's home space.
        let spaceID: UUID?
        let isSeparate: Bool
        /// A separate window's tabs, top to bottom, as they went into the
        /// archive. A normal window's tabs stay in the sidebar anyway.
        let tabs: [ArchivedTab]
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    func forget() { entries.removeAll() }

    func remember(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > 10 { entries.removeLast() }
    }

    /// Whether ⌘⇧T means the window: it closed after the newest closed tab.
    /// (A separate window's own tabs were archived just before it.)
    func lastIsNewer(than archive: [ArchivedTab]) -> Bool {
        guard let entry = entries.first else { return false }
        guard let tab = archive.first else { return true }
        return entry.date >= tab.date
    }

    /// Opens the newest window that can still come back; false if none can.
    @discardableResult
    func reopen(app: AppDelegate) -> Bool {
        while !entries.isEmpty {
            if reopen(entries.removeFirst(), app: app) { return true }
        }
        return false
    }

    private func reopen(_ entry: Entry, app: AppDelegate) -> Bool {
        guard let library = app.library, let space = library.space(id: entry.spaceID) else { return false }
        if entry.isSeparate {
            // Tabs brought back one by one since then are not taken twice.
            let tabs = entry.tabs.filter { library.archive.contains($0) }
            guard !tabs.isEmpty, let source = app.mainBrowser ?? app.browsers.first else { return false }
            let browser = app.openSeparateWindow(home: space, from: source, at: nil)
            browser.window?.setFrame(entry.frame, display: false)
            for tab in tabs { library.removeArchived(tab) }
            browser.adoptArchived(tabs)
        } else {
            let browser = app.openWindow(isPrivate: false, showingCommandBar: false)
            browser.window?.setFrame(entry.frame, display: true)
            browser.switchSpace(to: space)
        }
        return true
    }
}
