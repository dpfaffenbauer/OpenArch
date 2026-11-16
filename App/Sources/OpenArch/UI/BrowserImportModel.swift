import AppKit
import OpenArchLocalization
import Observation
import UniformTypeIdentifiers

/// Settings › Import › Aus anderen Browsern: the browsers found, what to
/// take from each, the import's progress and its result. Also the entry
/// point for other code (onboarding): `detect()`, then `run(app:)`.
@MainActor @Observable
final class BrowserImportModel {
    static let shared = BrowserImportModel()

    enum DataKind: String, CaseIterable, Hashable {
        case bookmarks, history, logins

        var title: String {
            switch self {
            case .bookmarks: L("Lesezeichen")
            case .history: L("Verlauf")
            case .logins: L("Logins und Passwörter")
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case running(String, Double)
        case done(BrowserImportReport)
    }

    private(set) var installs: [BrowserInstall] = []
    private(set) var hasDetected = false
    /// "installID|profileID" of the profiles to import.
    var selectedProfiles: Set<String> = []
    /// What to take, per install.
    var kinds: [String: Set<DataKind>] = [:]
    var phase = Phase.idle
    /// Where the browsers are looked for; a test sets a folder of fixtures.
    var home = FileManager.default.homeDirectoryForCurrentUser

    static func key(_ install: BrowserInstall, _ profile: BrowserProfile) -> String { "\(install.id)|\(profile.id)" }

    func detect() {
        let home = home
        Task {
            let found = await Task.detached(priority: .userInitiated) { BrowserImporter.detect(home: home) }.value
            installs = found
            hasDetected = true
            for install in found where kinds[install.id] == nil {
                kinds[install.id] = [.bookmarks, .history]
            }
        }
    }

    func isSelected(_ install: BrowserInstall, _ profile: BrowserProfile) -> Bool {
        selectedProfiles.contains(Self.key(install, profile))
    }

    func setSelected(_ install: BrowserInstall, _ profile: BrowserProfile, _ on: Bool) {
        if on { selectedProfiles.insert(Self.key(install, profile)) } else { selectedProfiles.remove(Self.key(install, profile)) }
    }

    func takes(_ kind: DataKind, from install: BrowserInstall) -> Bool {
        kinds[install.id]?.contains(kind) == true
    }

    func set(_ kind: DataKind, for install: BrowserInstall, _ on: Bool) {
        var set = kinds[install.id] ?? []
        if on { set.insert(kind) } else { set.remove(kind) }
        kinds[install.id] = set
    }

    var canRun: Bool {
        if case .running = phase { return false }
        return installs.contains { install in
            !install.needsAccess && !(kinds[install.id] ?? []).isEmpty && install.profiles.contains { isSelected(install, $0) }
        }
    }

    // MARK: Running

    /// Imports the chosen profiles: bookmarks and history now, logins
    /// (after asking) at the next launch. |askBeforeRelaunch| false: the
    /// logins wait for the next launch without a question (tests).
    func run(app: AppDelegate, askBeforeRelaunch: Bool = true, completion: ((BrowserImportReport) -> Void)? = nil) {
        guard let library = app.library else { return }
        let work = installs.compactMap { install -> (BrowserInstall, [BrowserProfile], Set<DataKind>)? in
            let profiles = install.profiles.filter { isSelected(install, $0) }
            let kinds = kinds[install.id] ?? []
            guard !install.needsAccess, !profiles.isEmpty, !kinds.isEmpty else { return nil }
            return (install, profiles, kinds)
        }
        guard !work.isEmpty else { return }
        Task {
            var report = BrowserImportReport()
            var jobs: [CredentialImport.Job] = []
            for (index, (install, profiles, kinds)) in work.enumerated() {
                phase = .running("Lese \(install.name) …", Double(index) / Double(work.count))
                let read = await Task.detached(priority: .userInitiated) {
                    BrowserImporter.read(install, profiles: profiles, bookmarks: kinds.contains(.bookmarks),
                                         history: kinds.contains(.history))
                }.value
                let applied = BrowserImportApplier.apply(read, to: library, history: app.history)
                report = report + applied.report
                if kinds.contains(.logins), install.canImportLogins {
                    for profile in profiles {
                        let sourceKey = "\(install.id)/\(profile.id.isEmpty ? "_" : profile.id)"
                        guard let target = applied.profileIDs[sourceKey] else { continue }
                        jobs.append(CredentialImport.Job(kind: .browserProfile, source: profile.folder.path,
                                                         safeStorage: install.safeStorage,
                                                         name: profiles.count > 1 ? "\(install.name) (\(profile.name))" : install.name,
                                                         targetProfile: target))
                    }
                }
            }
            report.pendingLogins = jobs.map(\.name)
            phase = .done(report)
            completion?(report)
            guard !jobs.isEmpty else { return }
            if askBeforeRelaunch {
                askAndRelaunch(jobs, installs: work.map(\.0).filter { $0.canImportLogins }, app: app)
            } else {
                CredentialImport.schedule(jobs)
            }
        }
    }

    /// The question before the keychain prompt, and quitting the browsers.
    private func askAndRelaunch(_ jobs: [CredentialImport.Job], installs: [BrowserInstall], app: AppDelegate) {
        let names = installs.map(\.name).joined(separator: ", ")
        let services = Set(installs.compactMap(\.safeStorage)).sorted().map { "„\($0)“" }.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = L("Logins und Passwörter übernehmen?")
        alert.informativeText = L("""
            Lesezeichen und Verlauf sind schon da. Für Logins, Cookies und Passwörter aus %@ startet OpenArch neu; \
            %@ muss dafür beendet sein. macOS fragt dann einmal nach dem Zugriff auf %@ im Schlüsselbund: \
            Mit diesem Schlüssel verschlüsselt der Browser seine Logins. OpenArch liest ihn nur, um sie mit dem eigenen \
            Schlüssel neu zu verschlüsseln. Der andere Browser bleibt unverändert.
            """, names, names, services)
        alert.addButton(withTitle: L("Neu starten und übernehmen"))
        alert.addButton(withTitle: L("Ohne Logins"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for install in installs where !app.quitAppIfNeeded(bundleIDs: install.bundleIDs, name: install.name) {
            return
        }
        CredentialImport.scheduleAndRelaunch(jobs)
    }

    // MARK: Files

    /// A bookmarks HTML file, into a space of its own on the current space's profile.
    func importBookmarksFile(app: AppDelegate) {
        let panel = NSOpenPanel()
        panel.message = L("Wähle eine Lesezeichen-Datei (HTML), wie Safari, Chrome, Firefox oder Edge sie exportieren.")
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importBookmarksFile(url, app: app)
    }

    @discardableResult
    func importBookmarksFile(_ url: URL, app: AppDelegate) -> BrowserImportReport? {
        guard let library = app.library else { return nil }
        do {
            let imported = try BrowserImporter.readBookmarksFile(url)
            let applied = BrowserImportApplier.apply([imported], to: library, history: nil,
                                                     currentProfileID: app.browser?.state.space.profileID)
            phase = .done(applied.report)
            return applied.report
        } catch {
            var report = BrowserImportReport()
            report.errors = [error.localizedDescription]
            phase = .done(report)
            return nil
        }
    }

    /// A passwords CSV file, into |profileID|; the passwords go in at the
    /// next launch, before Chromium starts.
    func importPasswordFile(app: AppDelegate, profileID: String) {
        let panel = NSOpenPanel()
        panel.message = L("Wähle die exportierte Passwort-Datei (CSV) aus Chrome, Firefox, Safari, 1Password oder Bitwarden.")
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file: PasswordFile
        do {
            file = try PasswordFile.read(url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let profileName = app.library.profiles.first { $0.id == profileID }?.name ?? profileID
        let alert = NSAlert()
        alert.messageText = L("%lld Passwörter übernehmen?", file.logins.count)
        var details = [L("Erkannt: Export aus %@. Ziel: Profil „%@“.", file.format.rawValue, profileName)]
        if file.duplicates > 0 { details.append(L("%lld doppelte Einträge werden ausgelassen.", file.duplicates)) }
        if file.incomplete > 0 { details.append(L("%lld Zeilen ohne Adresse oder Passwort werden ausgelassen.", file.incomplete)) }
        if file.notWebsite > 0 { details.append(L("%lld Einträge sind keine Website-Logins und werden ausgelassen.", file.notWebsite)) }
        details.append(L("Dafür startet OpenArch neu. Die Datei liest OpenArch beim Start noch einmal und lässt sie, wie sie ist; lösche sie danach selbst, denn sie enthält deine Passwörter im Klartext."))
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: L("Neu starten und übernehmen"))
        alert.addButton(withTitle: L("Abbrechen"))
        guard !file.logins.isEmpty, alert.runModal() == .alertFirstButtonReturn else { return }
        CredentialImport.scheduleAndRelaunch([CredentialImport.Job(kind: .passwordFile, source: url.path, safeStorage: nil,
                                                                   name: url.lastPathComponent, targetProfile: profileID)])
    }
}
