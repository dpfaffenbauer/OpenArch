import AppKit

/// The daily backup: once a day, Library.json (spaces, tabs, link rules and
/// the settings kept with them), Boosts.json and OpenArch's other settings
/// (its defaults, as Settings.plist) go into a folder of their own,
/// "OpenArch Backup <date>", in a folder you choose (iCloud Drive works).
/// The newest 14 stay. Exports are the same folder, made by hand; importing
/// one replaces the sidebar, boosts and settings at the next launch, after
/// a backup of what was there.
///
/// Not in it: Chromium's profiles (logins, cookies, passwords, history),
/// shares and their keys, agent chats.
@MainActor
final class Backups {
    static let shared = Backups(support: AppPaths.support)
    static let keep = 14
    static let dailyPrefix = "OpenArch Backup "
    /// Files of the data folder that go into a backup.
    static let files = ["Library.json", "Boosts.json"]
    static let settingsFile = "Settings.plist"
    static let manifestFile = "Backup.json"
    private static let pendingKey = "pendingBackupImport"
    private static let resultKey = "backupImportResult"

    struct Manifest: Codable {
        var date: Date
        var version: String
        var build: Int
    }

    struct BackupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    let support: URL
    /// The self-test's instance changes no setting of the user's.
    var persistsSettings = true
    private var memory: [String: Any] = [:]
    private var timer: Timer?

    init(support: URL) {
        self.support = support
    }

    private func value(_ key: String) -> Any? {
        persistsSettings ? UserDefaults.standard.object(forKey: key) : memory[key]
    }

    private func set(_ value: Any?, _ key: String) {
        if persistsSettings { UserDefaults.standard.set(value, forKey: key) } else { memory[key] = value }
    }

    /// Settings › Info › Sicherung.
    var isEnabled: Bool {
        get { value("dailyBackup") as? Bool ?? true }
        set { set(newValue, "dailyBackup") }
    }

    var folder: URL {
        get { (value("backupFolder") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder }
        set { set(newValue.path == defaultFolder.path ? nil : newValue.path, "backupFolder") }
    }

    var defaultFolder: URL { support.appendingPathComponent("Backups", isDirectory: true) }

    var lastBackup: Date? {
        get { value("lastBackup") as? Date }
        set { set(newValue, "lastBackup") }
    }

    // MARK: The daily backup

    /// A minute after launch, then every hour: a backup when today has none.
    func start(library: Library) {
        after(60) { [weak self] in self?.backUpIfDue(library: library) }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.backUpIfDue(library: library) }
        }
    }

    func backUpIfDue(library: Library?, now: Date = Date()) {
        guard isEnabled else { return }
        if let lastBackup, Calendar.current.isDate(lastBackup, inSameDayAs: now) { return }
        do {
            try backUp(library: library, now: now)
        } catch {
            log("daily backup failed: \(error.localizedDescription)")
        }
    }

    /// Today's backup (made again if there is one), then the oldest beyond
    /// 14 removed.
    @discardableResult
    func backUp(library: Library?, now: Date = Date()) throws -> URL {
        let backup = try write(library: library, into: folder, named: Self.dailyName(now), date: now)
        lastBackup = now
        rotate(in: folder)
        return backup
    }

    static func dailyName(_ date: Date) -> String {
        dailyPrefix + stamp(date, "yyyy-MM-dd")
    }

    /// |date| in the Mac's time zone.
    static func stamp(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Only OpenArch's daily backups ("OpenArch Backup 2026-11-08"), the
    /// newest |keep| kept; anything else in the folder is left alone.
    func rotate(in folder: URL, keep: Int = Backups.keep) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let daily = names.filter { name in
            name.hasPrefix(Self.dailyPrefix)
                && name.dropFirst(Self.dailyPrefix.count).wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
        }.sorted(by: >)
        for name in daily.dropFirst(keep) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Writes a backup folder |name| into |folder|, replacing one of that name.
    @discardableResult
    func write(library: Library?, into folder: URL, named name: String, date: Date = Date()) throws -> URL {
        library?.save()
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name, isDirectory: true)
        let partial = folder.appendingPathComponent(".\(name)-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            for file in Self.files where files.fileExists(atPath: support.appendingPathComponent(file).path) {
                try files.copyItem(at: support.appendingPathComponent(file), to: partial.appendingPathComponent(file))
            }
            let settings = Self.exportableSettings(
                UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:])
            let plist = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            try plist.write(to: partial.appendingPathComponent(Self.settingsFile))
            let info = Bundle.main.infoDictionary ?? [:]
            let manifest = Manifest(date: date, version: info["CFBundleShortVersionString"] as? String ?? "",
                                    build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0)
            try JSONEncoder.iso.encode(manifest).write(to: partial.appendingPathComponent(Self.manifestFile))
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.moveItem(at: partial, to: target)
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
        return target
    }

    /// OpenArch's own settings, without what belongs to this Mac's moment
    /// (window positions, a pending import, when the last backup ran).
    static func exportableSettings(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { key, _ in
            !key.hasPrefix("NS") && !key.hasPrefix("com.apple") && !key.hasPrefix("Apple")
                && ![pendingKey, resultKey, "lastBackup"].contains(key)
        }
    }

    // MARK: Export and import

    /// Settings › Info › Sicherung › Exportieren …
    func exportInteractively(library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Hier sichern"
        panel.message = "Wohin soll die Sicherung von Sidebar, Boosts und Einstellungen?"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let name = "OpenArch Export " + Self.stamp(Date(), "yyyy-MM-dd HHmm")
        do {
            let backup = try write(library: library, into: folder, named: name)
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Settings › Info › Sicherung › Importieren …: checks the backup, makes
    /// one of what is there now, and restarts into the import.
    func importInteractively(library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = "Importieren"
        panel.message = "Wähle einen Sicherungsordner („OpenArch Backup …“ oder „OpenArch Export …“)."
        guard panel.runModal() == .OK, let backup = panel.url else { return }
        do {
            try Self.validate(backup)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sicherung importieren?"
        alert.informativeText = """
            Sidebar, Boosts und Einstellungen werden durch die aus „\(backup.lastPathComponent)“ ersetzt. \
            Was jetzt da ist, wird vorher gesichert. Logins, Passwörter und Verlauf bleiben, wie sie sind. OpenArch startet dafür neu.
            """
        alert.addButton(withTitle: "Importieren und neu starten")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try write(library: library, into: folder, named: "OpenArch Backup vor Import "
                      + Self.stamp(Date(), "yyyy-MM-dd HHmmss"))
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        UserDefaults.standard.set(backup.path, forKey: Self.pendingKey)
        UserDefaults.standard.synchronize()
        let pid = ProcessInfo.processInfo.processIdentifier
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                              Bundle.main.bundleURL.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// A backup folder whose Library.json OpenArch can read.
    static func validate(_ backup: URL) throws {
        guard let data = try? Data(contentsOf: backup.appendingPathComponent("Library.json")) else {
            throw BackupError("In diesem Ordner ist keine Sicherung von OpenArch (Library.json fehlt).")
        }
        guard let library = try? JSONDecoder.iso.decode(LibraryData.self, from: data), !library.spaces.isEmpty else {
            throw BackupError("Die Library.json dieser Sicherung lässt sich nicht lesen.")
        }
    }

    /// At launch, before the library loads: an import asked for by
    /// importInteractively.
    static func restorePendingIfAny() {
        guard let path = UserDefaults.standard.string(forKey: pendingKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        let message: String
        do {
            try restore(from: URL(fileURLWithPath: path, isDirectory: true), into: AppPaths.support, defaults: .standard)
            message = "Sidebar, Boosts und Einstellungen kommen jetzt aus „\(URL(fileURLWithPath: path).lastPathComponent)“."
        } catch {
            message = "Der Import ist fehlgeschlagen; es ist alles, wie es war. \(error.localizedDescription)"
        }
        UserDefaults.standard.set(message, forKey: resultKey)
    }

    /// The summary of an import that ran at this launch, once.
    static func takeResult() -> String? {
        defer { UserDefaults.standard.removeObject(forKey: resultKey) }
        return UserDefaults.standard.string(forKey: resultKey)
    }

    /// Puts |backup|'s files into |support| (the replaced Library.json kept
    /// as "Library (vor Import <time>).json") and its settings into |defaults|.
    static func restore(from backup: URL, into support: URL, defaults: UserDefaults) throws {
        try validate(backup)
        let files = FileManager.default
        let library = support.appendingPathComponent("Library.json")
        if files.fileExists(atPath: library.path) {
            let name = "Library (vor Import \(stamp(Date(), "yyyy-MM-dd-HHmmss"))).json"
            try? files.copyItem(at: library, to: support.appendingPathComponent(name))
        }
        for file in Self.files {
            let source = backup.appendingPathComponent(file)
            let target = support.appendingPathComponent(file)
            guard files.fileExists(atPath: source.path) else {
                if file != "Library.json" { try? files.removeItem(at: target) }
                continue
            }
            _ = try files.replaceItemAt(target, withItemAt: try copyAside(source, next: target))
        }
        if let data = try? Data(contentsOf: backup.appendingPathComponent(settingsFile)),
           let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in exportableSettings(settings) {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// A copy of |source| beside |target|, to swap in with replaceItemAt.
    private static func copyAside(_ source: URL, next target: URL) throws -> URL {
        let copy = target.deletingLastPathComponent().appendingPathComponent(".import-\(UUID().uuidString)-\(target.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }
}
