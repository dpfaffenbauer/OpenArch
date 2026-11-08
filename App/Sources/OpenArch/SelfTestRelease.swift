import AppKit
import OpenArchCore

/// Checks for what keeps releases safe: the update channels (and that
/// nothing older is ever installed), the feature switches, crash reports
/// and the daily backup. `--selftest --release-test` runs only these, plus a
/// real renderer crash.
extension SelfTest {
    func releaseQuality(crashRenderer: Bool, then done: @escaping () -> Void) {
        featureSwitchesTest()
        crashReportsTest()
        backupTest()
        updateChannelsTest {
            self.remoteSwitchesFallBackTest {
                guard crashRenderer else { return done() }
                self.rendererCrashTest(then: done)
            }
        }
    }

    private func temporaryFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Update channels

    /// A zip with a fake OpenArch of build |build|, and its SHA-256.
    private func fakeBuild(_ build: Int, in folder: URL) -> (URL, String) {
        let app = folder.appendingPathComponent("build-\(build)/OpenArch.app")
        try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": Bundle.main.bundleIdentifier ?? "", "CFBundleVersion": "\(build)"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        let zip = folder.appendingPathComponent("OpenArch-\(build).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        return (zip, (try? Updater.sha256(of: zip)) ?? "")
    }

    private func manifest(_ build: Int, version: String?, in folder: URL) -> URL {
        let (zip, sha) = fakeBuild(build, in: folder)
        let url = folder.appendingPathComponent("latest-\(build).json")
        let versionField = version.map { #""version": "\#($0)", "# } ?? ""
        let json = #"{"build": \#(build), \#(versionField)"commit": "test", "sha256": "\#(sha)", "url": "\#(zip.absoluteString)"}"#
        try? json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, manifest: URL? = nil) -> [String: Any] {
        ["tag_name": tag, "prerelease": prerelease, "draft": draft,
         "assets": manifest.map { [["name": "latest.json", "browser_download_url": $0.absoluteString]] } ?? []]
    }

    private func testUpdater(build: Int, channel: Updater.Channel, folder: URL, list: URL, nightly: URL) -> Updater {
        let updater = Updater(build: build, channel: channel)
        updater.allowsLocalFiles = true
        updater.requiresDeveloperID = false
        updater.releaseListURL = list.absoluteString
        updater.manifestURL = nightly.absoluteString
        return updater
    }

    /// Stable takes the newest version tag; Nightly the nightly release;
    /// switching from Nightly back to Stable installs nothing older and
    /// drops the Nightly build that was waiting.
    private func updateChannelsTest(then done: @escaping () -> Void) {
        let folder = temporaryFolder("channels")
        let stable = manifest(999, version: "0.3.0", in: folder)
        let nightly = manifest(1100, version: nil, in: folder)
        let releases: [[String: Any]] = [
            release("nightly", prerelease: true, manifest: nightly),
            release("cef-156.0.15-codecs"),
            release("v0.3.0", manifest: stable),
            release("v0.2.0"),
            release("v0.4.0", draft: true, manifest: nightly),
            release("v1.0.0-beta", manifest: nightly),
        ]
        let list = folder.appendingPathComponent("releases.json")
        try? JSONSerialization.data(withJSONObject: releases).write(to: list)
        let decoded = (try? JSONDecoder().decode([Updater.Release].self, from: Data(contentsOf: list))) ?? []
        expect(Updater.newestStable(in: decoded)?.tag_name == "v0.3.0",
               "Stable is the newest version tag, not nightly, a Chromium release, a draft or a beta (\(Updater.newestStable(in: decoded)?.tag_name ?? "none"))")
        let tens = [release("v0.9.0"), release("v0.10.0"), release("v0.2.1")]
        let tensData = (try? JSONSerialization.data(withJSONObject: tens)) ?? Data()
        let tensDecoded = (try? JSONDecoder().decode([Updater.Release].self, from: tensData)) ?? []
        expect(Updater.newestStable(in: tensDecoded)?.tag_name == "v0.10.0", "v0.10.0 is newer than v0.9.0")

        // One updater at a time: they share the download folder.
        let older = testUpdater(build: 500, channel: .stable, folder: folder, list: list, nightly: nightly)
        older.check()
        after(3) {
            self.expect(older.phase == .ready(999) && older.readyVersion == "OpenArch 0.3.0",
                        "on Stable, an older build updates to the newest Stable release (\(older.phase))")
            let newer = self.testUpdater(build: 1200, channel: .stable, folder: folder, list: list, nightly: nightly)
            newer.check()
            after(2) {
                self.expect(newer.phase == .upToDate && newer.aheadOfChannel == 999 && newer.pendingApp == nil,
                            "Stable never installs an older build than the one running (\(newer.phase))")
                let switching = self.testUpdater(build: 1000, channel: .nightly, folder: folder, list: list, nightly: nightly)
                switching.check()
                after(3) {
                    self.expect(switching.phase == .ready(1100) && switching.readyVersion == "Nightly 1100",
                                "on Nightly, the nightly build installs (\(switching.phase))")
                    switching.channel = .stable
                    self.expect(switching.pendingApp == nil, "switching to Stable drops the waiting Nightly build")
                    if switching.phase == .idle { switching.check() }
                    after(2) {
                        self.expect(switching.phase == .upToDate && switching.aheadOfChannel == 999 && switching.pendingApp == nil,
                                    "back on Stable, Nightly 1000 waits for Stable to catch up instead of going back to 999 (\(switching.phase))")
                        let noStable = folder.appendingPathComponent("none.json")
                        try? JSONSerialization.data(withJSONObject: [self.release("nightly", prerelease: true, manifest: nightly)])
                            .write(to: noStable)
                        let lonely = self.testUpdater(build: 500, channel: .stable, folder: folder, list: noStable, nightly: nightly)
                        lonely.check()
                        after(1.5) {
                            if case .failed(let message) = lonely.phase, message.contains("keine Stable") {
                                self.expect(true, "without a Stable release, Stable says so and installs nothing")
                            } else {
                                self.expect(false, "without a Stable release, Stable says so (\(lonely.phase))")
                            }
                            try? FileManager.default.removeItem(at: folder)
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: Feature switches

    private func featureSwitchesTest() {
        let chromium = OACEngine.versionString
        let file = """
            {"disabled": [
              {"feature": "peek", "reason": "kaputt"},
              {"feature": "boosts", "maxBuild": 10},
              {"feature": "agentChats", "minBuild": 100, "maxBuild": 200, "chromium": "\(chromium.prefix(5))"},
              {"feature": "tabPreviews", "chromium": "1."},
              {"feature": "somethingNew"}
            ]}
            """
        let parsed = FeatureSwitches.parse(Data(file.utf8), build: 150, chromium: chromium)
        expect(parsed == [.peek: "kaputt", .agentChats: "vorübergehend abgeschaltet"],
               "the remote list switches off by feature, build range and Chromium version (\(parsed))")
        expect(FeatureSwitches.parse(Data("<html>not json".utf8), build: 150, chromium: chromium).isEmpty,
               "a remote list that does not parse switches nothing off")

        let switches = FeatureSwitches.shared
        let pinned = browser.state.space.pinned.allTabs.first { $0.currentURL.contains("example.com") }
        if let pinned, pinned.pane == nil { browser.select(pinned) }
        guard let pinned, let pane = pinned.pane else {
            return expect(false, "a pinned example.com tab with a page for the feature switches")
        }
        let wasAgentChats = library.settings.agentChats
        library.settings.agentChats = true
        switches.setLocalForTesting([.peek, .agentChats, .boosts])
        expect(!switches.isOn(.peek) && switches.isOn(.tabPreviews), "the hidden default switches single features off")
        let peeked = browser.pane(pane, shouldInterceptNavigationToURL: "https://www.iana.org/")
        expect(!peeked && !browser.peek.isOpen, "with Peek switched off, a pinned tab's link to another site does not peek")
        expect(!library.settings.agentChatsOn, "with agent chats switched off, they are off even when the setting is on")
        browser.select(pinned)
        browser.editBoost()
        expect(BoostPanelController.current == nil, "with Boosts switched off, the boost editor does not open")
        switches.setLocalForTesting([])
        expect(library.settings.agentChatsOn, "switched on again, agent chats follow their setting")
        let peeksAgain = browser.pane(pane, shouldInterceptNavigationToURL: "https://www.iana.org/")
        expect(peeksAgain, "switched on again, Peek opens the link")
        browser.peek.close()
        library.settings.agentChats = wasAgentChats
        switches.setLocalForTesting(nil)
    }

    /// The real address: whatever it answers (nothing yet, or an empty
    /// list), a remote switch from before is gone.
    private func remoteSwitchesFallBackTest(then done: @escaping () -> Void) {
        let switches = FeatureSwitches.shared
        switches.setLocalForTesting([])
        switches.setRemote([.peek: "test"])
        switches.refresh(build: Updater.shared.currentBuild, chromium: OACEngine.versionString)
        after(6) {
            self.expect(switches.isOn(.peek), "a failed or empty remote list leaves every feature on (\(switches.disabled))")
            switches.setRemote([:])
            switches.setLocalForTesting(nil)
            done()
        }
    }

    // MARK: Crash reports

    private func ipsFile(process: String, path: String, bugType: String = "309") -> String {
        let header = #"{"app_name":"\#(process)","bug_type":"\#(bugType)","name":"\#(process)"}"#
        let body: [String: Any] = [
            "procName": process, "procPath": path,
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "asi": ["CoreFoundation": ["https://secret.example/private?token=1"]],
            "faultingThread": 0,
            "threads": [["frames": [["imageIndex": 0, "imageOffset": 4096, "symbol": "content::RenderFrameImpl::Crash()"],
                                    ["imageIndex": 1, "imageOffset": 8192]]]],
            "usedImages": [["name": "Chromium Embedded Framework", "path": "/Users/someone/secret"], ["name": "libsystem_c.dylib"]],
        ]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(), as: UTF8.self)
        return header + "\n" + json
    }

    private func crashReportsTest() {
        let root = temporaryFolder("crashes")
        let reports = root.appendingPathComponent("DiagnosticReports")
        try? FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let bundle = "/Applications/OpenArch.app"
        let crashes = CrashReports(folder: root.appendingPathComponent("CrashReports"))
        crashes.persistsSetting = false
        crashes.diagnosticReports = reports
        crashes.bundlePath = bundle
        // The first launch looks at nothing older than itself.
        try? ipsFile(process: "OpenArch Helper (GPU)", path: bundle + "/Contents/Frameworks/OpenArch Helper (GPU).app/x")
            .write(to: reports.appendingPathComponent("OpenArch Helper (GPU)-old.ips"), atomically: true, encoding: .utf8)
        crashes.collectAtLaunch(now: Date().addingTimeInterval(60))
        expect(crashes.pending.isEmpty, "crash reports start with the first launch: older reports are not collected")

        let files: [(String, String, String)] = [
            ("OpenArch Helper (Renderer)", bundle + "/Contents/Frameworks/OpenArch Helper (Renderer).app/Contents/MacOS/x", "309"),
            ("OpenArch Helper (GPU)", bundle + "/Contents/Frameworks/OpenArch Helper (GPU).app/Contents/MacOS/x", "309"),
            ("OpenArch Helper", bundle + "/Contents/Frameworks/OpenArch Helper.app/Contents/MacOS/x", "309"),
            ("OpenArch", "/Users/someone/Downloads/OpenArch.app/Contents/MacOS/OpenArch", "309"),  // another copy
            ("OpenArch", bundle + "/Contents/MacOS/OpenArch", "288"),  // a hang, not a crash
        ]
        for (index, (process, path, bugType)) in files.enumerated() {
            try? ipsFile(process: process, path: path, bugType: bugType)
                .write(to: reports.appendingPathComponent("\(process)-\(index).ips"), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                                   ofItemAtPath: reports.appendingPathComponent("\(process)-\(index).ips").path)
        }
        try? Data([UInt8(SIGSEGV)]).write(to: crashes.signalFile)
        crashes.rendererGone(status: "crashed", code: 11, now: Date().addingTimeInterval(110))
        crashes.rendererGone(status: "crashed", code: 11, now: Date().addingTimeInterval(110.5))
        crashes.collectAtLaunch(now: Date().addingTimeInterval(200))
        let events = crashes.pending
        let kinds = events.map { "\($0.process)/\($0.source)" }.sorted()
        expect(kinds == ["App/signal", "GPU/ips", "Renderer/ips", "Utility/ips"],
               "crashes of the app, renderers, GPU and utility processes are collected once each, only of this copy (\(kinds))")
        expect(!FileManager.default.fileExists(atPath: crashes.signalFile.path), "the app's own crash record is read once")

        let text = crashes.reportText(events)
        let url = crashes.issueURL(for: events)?.absoluteString ?? ""
        expect(text.contains("Chromium Embedded Framework content::RenderFrameImpl::Crash()") && text.contains("SIGSEGV")
               && text.contains("libsystem_c.dylib +0x2000"),
               "a crash report has the process, how it ended and the crashing thread's functions")
        expect(!text.contains("secret") && !text.contains("http") && !text.contains("/Users/") && !text.contains(bundle),
               "a crash report has no addresses, paths or page content")
        expect(url.hasPrefix(CrashReports.issueURL + "?title=Crash") && url.count < 7600,
               "a crash report becomes a prefilled GitHub issue (\(url.count) characters)")

        crashes.isEnabled = false
        crashes.rendererGone(status: "oom", code: 0, now: Date().addingTimeInterval(400))
        expect(crashes.pending.isEmpty, "with crash reports off, nothing is kept or collected")
        try? FileManager.default.removeItem(at: root)
    }

    /// chrome://crash in a tab: CEF reports the renderer's crash.
    private func rendererCrashTest(then done: @escaping () -> Void) {
        let root = temporaryFolder("renderer-crash")
        let crashes = CrashReports(folder: root)
        crashes.persistsSetting = false
        let handler = OACPane.renderProcessGoneHandler
        OACPane.renderProcessGoneHandler = { status, code in
            MainActor.assumeIsolated { crashes.rendererGone(status: status, code: code) }
        }
        let previous = browser.state.activeItem
        let tab = browser.openInNewTab("https://example.com/about-to-crash")
        after(3) {
            tab.pane?.loadURL("chrome://crash")
            after(4) {
                let event = crashes.pending.first
                self.expect(event?.process == "Renderer" && event?.kind.hasPrefix("crashed") == true,
                            "a renderer that crashes is noted for a crash report (\(event?.kind ?? "nothing"))")
                OACPane.renderProcessGoneHandler = handler
                self.browser.close(tab)
                if let previous { self.browser.select(previous) }
                try? FileManager.default.removeItem(at: root)
                done()
            }
        }
    }

    // MARK: Backups

    private func backupTest() {
        library.save()
        let support = temporaryFolder("backup-support")
        let files = FileManager.default
        try? files.copyItem(at: AppPaths.support.appendingPathComponent("Library.json"),
                            to: support.appendingPathComponent("Library.json"))
        try? Data("[]".utf8).write(to: support.appendingPathComponent("Boosts.json"))
        let backups = Backups(support: support)
        backups.persistsSettings = false
        let folder = support.appendingPathComponent("iCloud Drive/OpenArch", isDirectory: true)
        backups.folder = folder
        try? files.createDirectory(at: folder.appendingPathComponent("Notizen"), withIntermediateDirectories: true)
        try? files.createDirectory(at: folder.appendingPathComponent("OpenArch Export 2020-01-01 1200"), withIntermediateDirectories: true)

        let start = Calendar.current.date(from: DateComponents(year: 2030, month: 3, day: 1, hour: 9))!
        for day in 0..<16 {
            let date = Calendar.current.date(byAdding: .day, value: day, to: start)!
            backups.backUpIfDue(library: nil, now: date)
            // Later the same day: nothing new.
            backups.backUpIfDue(library: nil, now: date.addingTimeInterval(3600))
        }
        let names = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let daily = names.filter { $0.hasPrefix(Backups.dailyPrefix) }
        expect(daily.count == 14 && daily.first == "OpenArch Backup 2030-03-03" && daily.last == "OpenArch Backup 2030-03-16",
               "the daily backup keeps the newest 14 days (\(daily.first ?? "-") … \(daily.last ?? "-"), \(daily.count))")
        expect(names.contains("Notizen") && names.contains("OpenArch Export 2020-01-01 1200"),
               "rotating backups leaves everything else in the folder alone")
        let newest = folder.appendingPathComponent("OpenArch Backup 2030-03-16")
        let contents = Set((try? files.contentsOfDirectory(atPath: newest.path)) ?? [])
        expect(contents == ["Library.json", "Boosts.json", "Settings.plist", "Backup.json"],
               "a backup has the library, boosts and settings (\(contents.sorted()))")

        // Import: into another data folder, settings into their own defaults.
        let target = temporaryFolder("backup-restore")
        try? Data("old".utf8).write(to: target.appendingPathComponent("Library.json"))
        let settings: [String: Any] = ["selfTestBackupKey": "aus der Sicherung", "NSWindow Frame Settings": "0 0 10 10"]
        try? PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
            .write(to: newest.appendingPathComponent("Settings.plist"))
        let suite = "dev.openarch.selftest.backup"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        do {
            try Backups.restore(from: newest, into: target, defaults: defaults)
            let restored = try? Data(contentsOf: target.appendingPathComponent("Library.json"))
            let original = try? Data(contentsOf: support.appendingPathComponent("Library.json"))
            let kept = ((try? files.contentsOfDirectory(atPath: target.path)) ?? []).contains { $0.hasPrefix("Library (vor Import") }
            expect(restored == original && kept && files.fileExists(atPath: target.appendingPathComponent("Boosts.json").path),
                   "importing a backup puts its library and boosts back and keeps the replaced library")
            expect(defaults.string(forKey: "selfTestBackupKey") == "aus der Sicherung"
                   && defaults.object(forKey: "NSWindow Frame Settings") == nil,
                   "importing a backup restores OpenArch's settings, not window positions")
        } catch {
            expect(false, "importing a backup (\(error.localizedDescription))")
        }
        let broken = temporaryFolder("backup-broken")
        try? Data("{".utf8).write(to: broken.appendingPathComponent("Library.json"))
        expect((try? Backups.validate(broken)) == nil && (try? Backups.validate(support)) != nil,
               "a folder whose Library.json does not read is refused for import")
        defaults.removePersistentDomain(forName: suite)
        for url in [support, target, broken] { try? files.removeItem(at: url) }
    }
}
