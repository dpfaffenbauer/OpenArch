import AppKit
import CommonCrypto
import SQLite3

/// The onboarding with an Arc fixture: a first launch asks for it and an
/// older library never does; the window; Esc; the import with its preview,
/// the keychain step and the logins arriving in the background; accounts;
/// colors and light or dark on the real window; finishing into the browser
/// window; starting it again from the settings.
/// `--selftest --onboarding-test` runs only these.
extension SelfTest {
    func onboardingTest(then done: @escaping () -> Void) {
        guard let app = NSApp.delegate as? AppDelegate else { return expect(false, "the app delegate") }
        firstLaunchChecks()
        let arc = writeArcFixture()
        let alex = GoogleAccount(name: "Alex", email: "alex@example.com", photoURL: nil)
        GoogleAccounts.testAnswer = { [library] id in id == library.settings.arcDefaultProfile ? [alex] : [] }

        let onboarding = app.startOnboarding(mode: .firstRun, arc: arc, focus: false)
        let model = onboarding.model
        let window = onboarding.window
        expect(window.frame.size == OnboardingController.size && !window.styleMask.contains(.titled)
               && window.standardWindowButton(.closeButton) == nil && window.isMovableByWindowBackground
               && window.hasShadow && window.isVisible,
               "the onboarding is a floating 760×540 window without title bar or window buttons, moved by its background")
        onboarding.next()
        expect(model.step == .importing && model.summary.spaces == 3, "the import step finds Arc (\(model.summary.spaces) spaces)")
        window.cancelOperation(nil)
        expect(model.step == .welcome, "Esc goes a step back")
        onboarding.next()

        eventually({ model.revealedSpaces == 3 }, timeout: 3) { revealed in
            self.expect(revealed && model.countsLine.hasPrefix("3 Spaces · 2 Profile · 2 Favoriten · 3 angeheftete Tabs"),
                        "the preview builds Arc's sidebar space by space (\(model.countsLine))")
            onboarding.importEverything()
            self.expect(model.step == .logins && self.library.spaces.count == 1,
                        "„Alles übernehmen“ explains the keychain first, and the sidebar waits for the logins")
            onboarding.next()
            self.expect(model.step == .accounts && model.progress != nil,
                        "the logins come over in the background, with a progress pill (\(model.progress?.label ?? "none"))")
            self.eventually({ model.progress == nil && model.sidebarImported }, timeout: 10) { imported in
                self.checkImport(imported, model: model)
                self.eventually({ model.accounts.count == 2 && !model.accounts.values.contains(.searching) }, timeout: 3) { _ in
                    let directory = self.library.settings.arcDefaultProfile ?? "-"
                    let others = model.accounts.filter { $0.key != directory }.map(\.value)
                    self.expect(model.accounts[directory] == .found([alex]) && others == [.found([])],
                                "the accounts step shows each profile's Google accounts, and sign-in where there is none")
                    onboarding.next()
                    self.appearanceStep(onboarding) {
                        self.finishing(onboarding, app: app) {
                            self.rerun(app: app, then: done)
                        }
                    }
                }
            }
        }
    }

    /// Who gets the onboarding: a new library, but never one saved before
    /// it existed.
    private func firstLaunchChecks() {
        expect(library.settings.onboardingPending, "a first launch (no Library.json yet) asks for the onboarding")
        library.save()
        let url = AppPaths.support.appendingPathComponent("Library.json")
        guard let raw = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var settings = json["settings"] as? [String: Any] else { return expect(false, "Library.json readable") }
        settings.removeValue(forKey: "onboardingPending")
        json["settings"] = settings
        try? JSONSerialization.data(withJSONObject: json).write(to: url)
        expect(!Library.load().settings.onboardingPending, "a Library.json from before the onboarding never shows it")
        library.save()
        expect(Library.load().settings.onboardingPending, "quitting during the onboarding brings it back at the next launch")
    }

    private func checkImport(_ imported: Bool, model: OnboardingModel) {
        let directory = library.settings.arcDefaultProfile
        let arcSpaces = library.spaces.filter { $0.profileID == directory }
        expect(imported && directory != nil && directory != "Default" && library.spaces.count == 3 && arcSpaces.count == 2
               && library.profile(id: directory ?? "").favorites.items.count == 2,
               "the sidebar arrives with the logins, Arc's profile in a directory Chromium had not opened (\(directory ?? "none"))")
        let cookies = AppPaths.chromiumData.appendingPathComponent(directory ?? "-").appendingPathComponent("Cookies")
        let openArchKey = ArcProfileImport.derivedKey(password: Data("mock_password".utf8))
        let stored = Self.firstBlob(in: cookies, sql: "SELECT encrypted_value FROM cookies")
        let plain = stored.flatMap { ArcProfileImport.aes(CCOperation(kCCDecrypt), $0.dropFirst(3), key: openArchKey) }
        expect(plain == Data("SID=arc-fixture".utf8) && model.loginsResult?.hasPrefix("1 Cookies") == true,
               "Arc's logins are in that profile, encrypted with OpenArch's key (\(model.loginsResult ?? "-"))")
    }

    private func appearanceStep(_ onboarding: OnboardingController, then next: @escaping () -> Void) {
        expect(onboarding.model.step == .appearance && browser.window?.isVisible == true,
               "the appearance step shows the real window behind it")
        let space = library.spaces[2]
        onboarding.setColor("#E5566A", of: space)
        after(0.4) {
            self.expect(self.browser.state.space === space && self.browser.window?.backgroundColor.hexString == "#E5566A",
                        "a space's new color shows on the window at once (\(self.browser.window?.backgroundColor.hexString ?? "-"))")
            onboarding.setAppearance(.dark)
            let dark = NSApp.appearance?.name == .darkAqua
            onboarding.setAppearance(.system)
            self.expect(dark && NSApp.appearance == nil && self.library.settings.appearance == .system,
                        "light or dark applies to the whole app")
            onboarding.next()
            self.expect(onboarding.model.step == .done, "the default browser step is left out where it does not apply")
            next()
        }
    }

    private func finishing(_ onboarding: OnboardingController, app: AppDelegate, then next: @escaping () -> Void) {
        let window = onboarding.window
        onboarding.onFinish = {
            let url = AppPaths.support.appendingPathComponent("Library.json")
            let saved = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let pending = (saved?["settings"] as? [String: Any])?["onboardingPending"] as? Bool
            self.expect(!window.isVisible && self.browser.window?.isVisible == true && app.onboarding == nil
                        && pending == false && self.library.spaces.count == 3,
                        "finishing goes into the browser window and is remembered (onboardingPending \(pending.map(String.init) ?? "-"))")
            next()
        }
        onboarding.finish()
    }

    /// Settings › Allgemein › Einführung: again, and Esc on its first step
    /// leaves it without changing anything.
    private func rerun(app: AppDelegate, then done: @escaping () -> Void) {
        let again = app.startOnboarding(mode: .rerun, focus: false)
        let spaces = library.spaces.map(\.id)
        expect(again.model.step == .welcome && again.window.isVisible, "the onboarding starts again from the settings")
        again.window.cancelOperation(nil)
        expect(!again.window.isVisible && app.onboarding == nil && library.spaces.map(\.id) == spaces,
               "Esc on its first step leaves it and changes nothing")
        GoogleAccounts.testAnswer = nil
        done()
    }

    /// `--onboarding-test --shots`: every step for a while, with a marker
    /// line and the window's number for screencapture -l.
    func onboardingShots() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let onboarding = app.startOnboarding(mode: .firstRun, arc: writeArcFixture(), focus: false)
        GoogleAccounts.testAnswer = { [library] id in
            id == library.settings.arcDefaultProfile ? [GoogleAccount(name: "Alex", email: "alex@example.com")] : []
        }
        let number = onboarding.window.windowNumber
        let steps: [(Double, String, () -> Void)] = [
            (1, "welcome", {}),
            (3, "import", { onboarding.next() }),
            (6, "choose", { onboarding.model.choosing = true }),
            (8, "logins", { onboarding.importEverything() }),
            (10, "accounts", { onboarding.next() }),
            (13, "appearance", { onboarding.next() }),
            (15, "done", { onboarding.next() }),
        ]
        for (time, name, step) in steps {
            after(time) {
                step()
                after(1.2) { Swift.print("[selftest] STEP onboarding-\(name) window \(number)") }
            }
        }
        after(18) { Self.quit() }
    }

    // MARK: Fixture

    /// Arc's sidebar with three spaces on two profiles, favorites, a folder
    /// and a today tab; Arc's profile with one cookie under a key of its own.
    private func writeArcFixture() -> OnboardingArcSource {
        let folder = AppPaths.support.appendingPathComponent("ArcFixture", isDirectory: true)
        let profile = folder.appendingPathComponent("Default", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let sidebar = folder.appendingPathComponent("StorableSidebar.json")
        func tab(_ id: String, _ url: String, _ title: String) -> String {
            #""\#(id)", {"id": "\#(id)", "data": {"tab": {"savedURL": "\#(url)", "savedTitle": "\#(title)"}}}"#
        }
        func container(_ id: String, _ children: [String], title: String? = nil, list: Bool = false) -> String {
            let data = list ? #"{"list": {}}"# : "{}"
            let titled = title.map { #", "title": "\#($0)""# } ?? ""
            return #""\#(id)", {"id": "\#(id)", "data": \#(data), "childrenIds": [\#(children.map { "\"\($0)\"" }.joined(separator: ", "))]\#(titled)}"#
        }
        func theme(_ red: Double, _ green: Double, _ blue: Double) -> String {
            #"{"primaryColorPalette": {"midTone": {"red": \#(red), "green": \#(green), "blue": \#(blue)}}}"#
        }
        let items = [
            container("fav", ["f1", "f2"]),
            tab("f1", "https://github.com/", "GitHub"), tab("f2", "https://mail.google.com/", "Gmail"),
            container("p1", ["folder", "t3"]), container("folder", ["t1", "t2"], title: "Projekte", list: true),
            tab("t1", "https://example.com/a", "A"), tab("t2", "https://example.com/b", "B"),
            tab("t3", "https://example.com/c", "C"),
            container("u1", ["t4"]), tab("t4", "https://example.com/today", "Heute"),
            container("p2", []), container("u2", []), container("p3", []), container("u3", []),
        ]
        let json = #"""
            {"sidebar": {"containers": [{"global": {}}, {
              "items": [\#(items.joined(separator: ",\n"))],
              "spaces": [
                "s1", {"id": "0B0A0D1E-0000-4000-8000-000000000001", "title": "Zuhause", "containerIDs": ["pinned", "p1", "unpinned", "u1"],
                       "profile": {"default": true}, "customInfo": {"iconType": {"emoji_v2": "🏠"}, "windowTheme": \#(theme(0.2, 0.5, 0.9))}},
                "s2", {"id": "0B0A0D1E-0000-4000-8000-000000000002", "title": "Arbeit", "containerIDs": ["pinned", "p2", "unpinned", "u2"],
                       "profile": {"custom": {"_0": {"directoryBasename": "Profile 1"}}}, "customInfo": {"iconType": {"icon": "briefcase"}}},
                "s3", {"id": "0B0A0D1E-0000-4000-8000-000000000003", "title": "Lesen", "containerIDs": ["pinned", "p3", "unpinned", "u3"],
                       "profile": {"default": true}, "customInfo": {"iconType": {"emoji_v2": "📚"}}}],
              "topAppsContainerIDs": [{"default": true}, "fav"]}]}}
            """#
        try? Data(json.utf8).write(to: sidebar)

        let key = ArcProfileImport.derivedKey(password: Data("arc-fixture".utf8))
        try? Data("{}".utf8).write(to: profile.appendingPathComponent("Preferences"))
        let cookies = profile.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        sqlite3_open(cookies.path, &db)
        sqlite3_exec(db, "CREATE TABLE cookies (host_key TEXT, encrypted_value BLOB)", nil, nil, nil)
        var insert: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES ('.google.com', ?1)", -1, &insert, nil)
        let value = Data("v10".utf8) + (ArcProfileImport.aes(CCOperation(kCCEncrypt), Data("SID=arc-fixture".utf8), key: key) ?? Data())
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withUnsafeBytes { sqlite3_bind_blob(insert, 1, $0.baseAddress, Int32(value.count), transient) }
        sqlite3_step(insert)
        sqlite3_finalize(insert)
        sqlite3_close(db)
        return OnboardingArcSource(sidebar: sidebar, profile: profile, key: key)
    }

    private static func firstBlob(in database: URL, sql: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let blob = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}
