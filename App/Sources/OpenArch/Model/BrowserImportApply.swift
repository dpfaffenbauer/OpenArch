import Foundation

/// What an import from other browsers did, in numbers. Never a title, an
/// address or a password.
struct BrowserImportReport: Equatable {
    var profiles = 0
    var spaces = 0
    var bookmarks = 0
    var folders = 0
    /// Already in OpenArch from an import before; not added again.
    var alreadyThere = 0
    var history = 0
    var passwords = 0
    var skips = ImportSkips()
    /// "Chrome (Arbeit): Verlauf" and the like.
    var unreadable: [String] = []
    /// Logins and cookies waiting for the next launch.
    var pendingLogins: [String] = []
    var errors: [String] = []

    static func + (a: BrowserImportReport, b: BrowserImportReport) -> BrowserImportReport {
        var sum = a
        sum.profiles += b.profiles
        sum.spaces += b.spaces
        sum.bookmarks += b.bookmarks
        sum.folders += b.folders
        sum.alreadyThere += b.alreadyThere
        sum.history += b.history
        sum.passwords += b.passwords
        sum.skips = a.skips + b.skips
        sum.unreadable += b.unreadable
        sum.pendingLogins += b.pendingLogins
        sum.errors += b.errors
        return sum
    }

    /// The lines of the result view.
    var lines: [String] {
        var lines: [String] = []
        if profiles > 0 || spaces > 0 { lines.append("\(spaces) neue Spaces, \(profiles) neue Profile") }
        lines.append("\(bookmarks) Lesezeichen und \(folders) Ordner übernommen")
        if alreadyThere > 0 { lines.append("\(alreadyThere) schon von einem früheren Import da, nicht doppelt angelegt") }
        if history > 0 { lines.append("\(history) Seiten aus dem Verlauf, die die Befehlsleiste jetzt findet") }
        if passwords > 0 { lines.append("\(passwords) Passwörter") }
        return lines
    }

    /// What was left out, and why.
    var skippedLines: [String] {
        var lines: [String] = []
        if skips.bookmarklets > 0 { lines.append("\(skips.bookmarklets) Bookmarklets (javascript:-Links) ausgelassen") }
        if skips.noAddress > 0 { lines.append("\(skips.noAddress) Lesezeichen ohne brauchbare Adresse ausgelassen") }
        if skips.tooMany > 0 {
            lines.append("\(skips.tooMany) Lesezeichen über \(BrowserImporter.maxBookmarks) pro Profil ausgelassen")
        }
        if skips.tooDeep > 0 { lines.append("\(skips.tooDeep) Ordner tiefer als \(BrowserImporter.maxDepth) Ebenen abgeschnitten") }
        for part in unreadable { lines.append("Nicht lesbar: \(part)") }
        return lines + errors
    }
}

/// Puts imported browser profiles into the library: each one an OpenArch
/// profile and a space with its name, the bookmarks bar as pinned tabs and
/// folders. Items get IDs from their source keys, so importing again only
/// adds what is new; a folder found again takes new bookmarks into it.
@MainActor
enum BrowserImportApplier {
    struct Applied {
        var report = BrowserImportReport()
        /// Source key → the OpenArch profile its space uses.
        var profileIDs: [String: String] = [:]
    }

    static func apply(_ imported: [ImportedProfile], to library: Library, history: History?,
                      currentProfileID: String? = nil) -> Applied {
        var applied = Applied()
        for source in imported {
            var report = BrowserImportReport()
            let spaceID = BrowserImporter.stableID("space:" + source.sourceKey)
            let space: Space
            if let existing = library.space(id: spaceID) {
                space = existing
            } else {
                let profileID: String
                if source.usesCurrentProfile {
                    profileID = currentProfileID ?? library.profiles[0].id
                } else {
                    profileID = library.addProfile(name: uniqueProfileName(source.name, in: library)).id
                    report.profiles += 1
                }
                space = library.addSpace(id: spaceID, name: source.name, icon: source.icon, colorHex: source.color,
                                         profileID: profileID)
                report.spaces += 1
            }
            applied.profileIDs[source.sourceKey] = space.profileID
            merge(source.items, into: space.pinned, folder: nil, library: library, report: &report)
            if let history, !source.visits.isEmpty {
                report.history += history.importVisits(source.visits)
            }
            report.skips = source.skips
            report.unreadable = source.unreadable.map { "\(source.name): \($0)" }
            applied.report = applied.report + report
        }
        library.setNeedsSave()
        return applied
    }

    /// Adds what is not there yet. An item found anywhere in the library
    /// (the user may have moved it) is left where it is.
    private static func merge(_ nodes: [ImportedNode], into container: Container, folder: Item?, library: Library,
                              report: inout BrowserImportReport) {
        for node in nodes {
            let id = BrowserImporter.stableID(node.key)
            if let existing = library.item(id: id) {
                if node.url == nil, existing.kind == .folder, let home = existing.container {
                    merge(node.children, into: home, folder: existing, library: library, report: &report)
                } else {
                    report.alreadyThere += 1
                }
                continue
            }
            let item = Item(data: data(node, report: &report))
            container.insert(item, into: folder)
        }
    }

    private static func data(_ node: ImportedNode, report: inout BrowserImportReport) -> ItemData {
        let id = BrowserImporter.stableID(node.key)
        if let url = node.url {
            report.bookmarks += 1
            return ItemData(id: id, kind: .tab, title: node.title, url: url, customTitle: nil)
        }
        report.folders += 1
        return ItemData(id: id, kind: .folder, customTitle: node.title,
                        children: node.children.map { data($0, report: &report) }, isExpanded: false)
    }

    private static func uniqueProfileName(_ name: String, in library: Library) -> String {
        let taken = Set(library.profiles.map { $0.name.lowercased() })
        guard taken.contains(name.lowercased()) else { return name }
        var index = 2
        while taken.contains("\(name) \(index)".lowercased()) { index += 1 }
        return "\(name) \(index)"
    }
}
