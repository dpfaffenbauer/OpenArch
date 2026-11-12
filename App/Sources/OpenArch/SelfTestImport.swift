import AppKit
import OpenArchLocalization
import CommonCrypto
import SQLite3

/// Checks the import from other browsers with made-up profiles: Chrome's
/// Bookmarks JSON and History, Firefox's places.sqlite, a bookmarks HTML
/// file, password CSV files, the merge of logins and cookies, and the Arc
/// backup. Nothing of the user's real browsers is read.
/// `--selftest --import-test` runs only these.
extension SelfTest {
    /// A home folder with fixture browsers, under the self-test's data.
    static var importFixtures: URL { AppPaths.support.appendingPathComponent("import-fixtures", isDirectory: true) }

    func browserImport(then done: @escaping () -> Void) {
        let home = Self.importFixtures.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.removeItem(at: Self.importFixtures)
        makeChromeFixture(home: home)
        makeFirefoxFixture(home: home)

        importDetection(home: home)
        importStructureAndIdempotence(home: home)
        bookmarksFileImport()
        passwordFiles()
        loginMerge()
        historyBulkTest()
        arcBackupTest()
        if CommandLine.arguments.contains("--import-test") {
            importThroughModel(home: home, then: done)
        } else {
            done()
        }
    }

    // MARK: Fixtures

    private func makeChromeFixture(home: URL) {
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: chrome.appendingPathComponent("Default"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: chrome.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: chrome.appendingPathComponent("Guest Profile"), withIntermediateDirectories: true)
        let localState: [String: Any] = ["profile": [
            "info_cache": [
                "Default": ["name": "Person 1", "is_using_default_name": true],
                "Profile 1": ["name": "Kunden", "is_using_default_name": false, "profile_highlight_color": -16744320],
            ],
            "profiles_order": ["Default", "Profile 1"],
        ]]
        try? JSONSerialization.data(withJSONObject: localState).write(to: chrome.appendingPathComponent("Local State"))
        writeChromeBookmarks(chrome.appendingPathComponent("Default/Bookmarks"), extra: false)
        let work: [String: Any] = ["roots": [
            "bookmark_bar": ["children": [["type": "url", "guid": "w1", "name": "Wiki", "url": "https://example.com/wiki"]]],
            "other": ["children": []],
        ]]
        try? JSONSerialization.data(withJSONObject: work).write(to: chrome.appendingPathComponent("Profile 1/Bookmarks"))
        try? JSONSerialization.data(withJSONObject: work).write(to: chrome.appendingPathComponent("Guest Profile/Bookmarks"))
        // Chromium's History: urls with times in microseconds since 1601.
        sqlite(chrome.appendingPathComponent("Default/History"), """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER,
                               last_visit_time INTEGER, hidden INTEGER);
            INSERT INTO urls VALUES (1, 'https://example.com/chrome-history', 'Aus Chrome', 7, 0, 13380000000000000, 0);
            INSERT INTO urls VALUES (2, 'chrome://settings', 'Einstellungen', 1, 0, 13380000000000000, 0);
            """)
    }

    /// The bookmarks bar with a tab and a folder whose two bookmarks share
    /// one GUID (a hand-edited file), a bookmarklet, and "Other bookmarks".
    /// |extra| adds a bookmark to the folder, as if made after an import.
    private func writeChromeBookmarks(_ url: URL, extra: Bool) {
        var folderChildren: [[String: Any]] = [
            ["type": "url", "guid": "dup", "name": "Erster", "url": "https://example.com/first"],
            ["type": "url", "guid": "dup", "name": "Zweiter", "url": "https://example.com/second"],
            ["type": "url", "guid": "js", "name": "Bookmarklet", "url": "javascript:alert(1)"],
        ]
        if extra {
            folderChildren.append(["type": "url", "guid": "new", "name": "Neu", "url": "https://example.com/new"])
        }
        let bookmarks: [String: Any] = ["roots": [
            "bookmark_bar": ["name": "Lesezeichenleiste", "children": [
                ["type": "url", "guid": "a", "name": "Start", "url": "https://example.com/start"],
                ["type": "folder", "guid": "f", "name": "Projekte", "children": folderChildren],
            ]],
            "other": ["name": "Weitere Lesezeichen", "children": [
                ["type": "url", "guid": "o", "name": "Später", "url": "https://example.com/later"],
            ]],
            "synced": ["children": []],
        ]]
        try? JSONSerialization.data(withJSONObject: bookmarks).write(to: url)
    }

    private func makeFirefoxFixture(home: URL) {
        let firefox = home.appendingPathComponent("Library/Application Support/Firefox", isDirectory: true)
        let profile = firefox.appendingPathComponent("Profiles/test.default-release", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try? """
            [Install4F96D1932A9F858E]
            Default=Profiles/test.default-release

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/test.default-release
            """.write(to: firefox.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        // Firefox's places: the roots by GUID, a bookmark and a folder on the
        // toolbar, one in "Other Bookmarks"; times in microseconds since 1970.
        sqlite(profile.appendingPathComponent("places.sqlite"), """
            CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER,
                                     typed INTEGER, last_visit_date INTEGER);
            CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER,
                                        title TEXT, guid TEXT);
            INSERT INTO moz_places VALUES (1, 'https://example.org/fx', 'Fx', 3, 0, 0, 1762000000000000);
            INSERT INTO moz_places VALUES (2, 'https://example.org/fx-folder', 'In Ordner', 0, 0, 0, NULL);
            INSERT INTO moz_places VALUES (3, 'https://example.org/fx-other', 'Anderes', 0, 0, 0, NULL);
            INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________');
            INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'menu', 'menu________');
            INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'toolbar', 'toolbar_____');
            INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____');
            INSERT INTO moz_bookmarks VALUES (10, 1, 1, 3, 0, 'Fx-Seite', 'fxbookmark01');
            INSERT INTO moz_bookmarks VALUES (11, 2, NULL, 3, 1, 'Fx-Ordner', 'fxfolder0001');
            INSERT INTO moz_bookmarks VALUES (12, 1, 2, 11, 0, 'Im Ordner', 'fxbookmark02');
            INSERT INTO moz_bookmarks VALUES (13, 3, NULL, 3, 2, NULL, 'fxseparator1');
            INSERT INTO moz_bookmarks VALUES (14, 1, 3, 5, 0, 'Anderes', 'fxbookmark03');
            """)
    }

    private func sqlite(_ url: URL, _ sql: String) {
        var db: OpaquePointer?
        try? FileManager.default.removeItem(at: url)
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    private func count(_ url: URL, _ sql: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : -1
    }

    // MARK: Checks

    private func importDetection(home: URL) {
        let installs = BrowserImporter.detect(home: home)
        let chrome = installs.first { $0.id == "chrome" }
        let firefox = installs.first { $0.id == "firefox" }
        expect(chrome?.profiles.map(\.name) == ["Chrome", "Kunden"] && chrome?.profiles.last?.color == "#008080",
               "other browsers: Chrome's profiles from Local State, a default name becomes the browser's, the color comes along (\(chrome?.profiles.map(\.name) ?? []))")
        expect(firefox?.profiles.count == 1 && firefox?.profiles.first?.name == "Firefox" && firefox?.profiles.first?.isDefault == true,
               "other browsers: Firefox's profile from profiles.ini")
        expect(!installs.contains { $0.kind == .safari }, "other browsers: no Safari in a home without one")
    }

    private func importStructureAndIdempotence(home: URL) {
        guard let app = NSApp.delegate as? AppDelegate,
              let chrome = BrowserImporter.detect(home: home).first(where: { $0.id == "chrome" }),
              let firefox = BrowserImporter.detect(home: home).first(where: { $0.id == "firefox" }) else {
            return expect(false, "other browsers: fixtures found")
        }
        let spacesBefore = library.spaces.count
        let profilesBefore = library.profiles.count
        let read = BrowserImporter.read(chrome, profiles: chrome.profiles, bookmarks: true, history: true)
            + BrowserImporter.read(firefox, profiles: firefox.profiles, bookmarks: true, history: true)
        let first = BrowserImportApplier.apply(read, to: library, history: app.history)
        let created = library.spaces.suffix(library.spaces.count - spacesBefore)
        let chromeSpace = created.first { $0.name == "Chrome" }
        let pinned = chromeSpace?.pinned.items ?? []
        let projects = pinned.first { $0.kind == .folder && $0.customTitle == "Projekte" }
        let other = pinned.first { $0.kind == .folder && $0.customTitle == L("Weitere Lesezeichen") }
        expect(created.map(\.name) == ["Chrome", "Kunden", "Firefox"] && library.profiles.count == profilesBefore + 3
               && Set(created.map(\.profileID)).count == 3,
               "other browsers: each profile becomes a profile and a space with its name (\(created.map(\.name)))")
        expect(pinned.first?.savedURL == "https://example.com/start" && projects?.children.count == 2
               && other?.children.first?.savedURL == "https://example.com/later",
               "other browsers: the bookmarks bar becomes pinned tabs and folders, „Weitere Lesezeichen“ a folder of its own")
        expect(Set(projects?.children.map(\.savedURL) ?? []) == ["https://example.com/first", "https://example.com/second"],
               "other browsers: two bookmarks with one ID in the source stay two")
        expect(first.report.skips.bookmarklets == 1 && first.report.bookmarks == 8 && first.report.folders == 4,
               "other browsers: the result counts bookmarks, folders and the bookmarklet left out (\(first.report.bookmarks), \(first.report.folders), \(first.report.skips.bookmarklets))")
        let firefoxSpace = created.first { $0.name == "Firefox" }
        let fxItems = firefoxSpace?.pinned.items ?? []
        expect(fxItems.first?.savedURL == "https://example.org/fx" && fxItems.dropFirst().first?.children.first?.savedURL == "https://example.org/fx-folder"
               && fxItems.last?.customTitle == L("Weitere Lesezeichen"),
               "other browsers: Firefox's toolbar from places.sqlite, its folders, and „Weitere Lesezeichen“")
        expect(app.history.entry(for: "https://example.com/chrome-history")?.visitCount == 7
               && app.history.entry(for: "https://example.org/fx") != nil && app.history.entry(for: "chrome://settings") == nil,
               "other browsers: Chrome's and Firefox's history goes to the command bar")

        // Again: nothing new. Then with one bookmark more in the folder.
        let again = BrowserImportApplier.apply(BrowserImporter.read(chrome, profiles: chrome.profiles, bookmarks: true, history: true),
                                               to: library, history: app.history)
        expect(again.report.bookmarks == 0 && again.report.spaces == 0 && again.report.profiles == 0
               && library.spaces.count == spacesBefore + 3 && projects?.children.count == 2,
               "other browsers: importing again adds nothing twice (\(again.report.bookmarks) new, \(again.report.alreadyThere) there)")
        let chromeDefault = chrome.profiles[0].folder.appendingPathComponent("Bookmarks")
        writeChromeBookmarks(chromeDefault, extra: true)
        let third = BrowserImportApplier.apply(BrowserImporter.read(chrome, profiles: [chrome.profiles[0]], bookmarks: true, history: false),
                                               to: library, history: nil)
        expect(third.report.bookmarks == 1 && projects?.children.count == 3 && projects?.children.last?.savedURL == "https://example.com/new",
               "other browsers: a bookmark added since goes into the folder already imported")
        writeChromeBookmarks(chromeDefault, extra: false)
        for space in created { library.removeSpace(space) }
    }

    private func bookmarksFileImport() {
        let file = Self.importFixtures.appendingPathComponent("bookmarks.html")
        try? """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>
                <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Lesezeichenleiste</H3>
                <DL><p>
                    <DT><A HREF="https://example.com/html-bar" ICON="data:image/png;base64,AAAA">Bar &amp; mehr</A>
                    <DT><H3>Ordner</H3>
                    <DL><p>
                        <DT><A HREF="https://example.com/html-inner">Innen</A>
                        <DT><A HREF="https://example.com/html-inner">Innen</A>
                    </DL><p>
                </DL><p>
                <DT><A HREF="https://example.com/html-loose">Lose</A>
            </DL><p>
            """.write(to: file, atomically: true, encoding: .utf8)
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let spacesBefore = library.spaces.count
        let first = BrowserImportModel.shared.importBookmarksFile(file, app: app)
        let space = library.spaces.count > spacesBefore ? library.spaces.last : nil
        let items = space?.pinned.items ?? []
        expect(space?.name == L("Lesezeichen") && space?.profileID == browser.state.space.profileID
               && items.first?.savedTitle == "Bar & mehr" && items.dropFirst().first?.children.count == 2
               && items.last?.customTitle == L("Weitere Lesezeichen") && first?.bookmarks == 4,
               "bookmarks HTML: the toolbar folder becomes pinned tabs, folders stay folders, loose bookmarks a folder")
        let again = BrowserImportModel.shared.importBookmarksFile(file, app: app)
        expect(again?.bookmarks == 0 && library.spaces.count == spacesBefore + 1 && space?.pinned.allTabs.count == 4,
               "bookmarks HTML: the same file again adds nothing")
        BrowserImportModel.shared.phase = .idle
        if let space { library.removeSpace(space) }
    }

    private func passwordFiles() {
        let files: [(PasswordFile.Format, String)] = [
            (.chrome, "name,url,username,password,note\nEx,https://example.com/login,anna,geheim1,\nEx,https://example.com/login,anna,geheim1,\nOhne,https://example.com/x,bob,,\n"),
            (.firefox, "\"url\",\"username\",\"password\",\"httpRealm\",\"formActionOrigin\",\"guid\",\"timeCreated\"\n\"https://example.org\",\"carl\",\"p,w\"\"1\",,\"https://example.org\",\"{x}\",\"1\"\n"),
            (.onePassword, "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nBank,example.net,dora,pw2,,false,false,,\n"),
            (.bitwarden, "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,Site,,,0,https://example.com:443/a?b=c,eve,pw3,\n,,note,Notiz,text,,0,,,,\n,,login,App,,,0,androidapp://com.example,fritz,pw4,\n"),
        ]
        var results: [String] = []
        var ok = true
        for (format, text) in files {
            guard let file = try? PasswordFile.parse(Data(text.utf8)) else {
                ok = false
                continue
            }
            results.append("\(file.format.rawValue): \(file.logins.count)")
            ok = ok && file.format == format
            switch format {
            case .chrome: ok = ok && file.logins.count == 1 && file.duplicates == 1 && file.incomplete == 1
            case .firefox: ok = ok && file.logins.first?.password == "p,w\"1" && file.logins.first?.signonRealm == "https://example.org/"
            case .onePassword: ok = ok && file.logins.first?.origin == "https://example.net/"
            case .bitwarden: ok = ok && file.logins.count == 1 && file.logins.first?.origin == "https://example.com/a" && file.notWebsite == 2
            default: break
            }
        }
        expect(ok, "passwords CSV: Chrome, Firefox, 1Password and Bitwarden columns are recognized (\(results))")
        expect((try? PasswordFile.parse(Data("a,b\n1,2\n".utf8))) == nil, "passwords CSV: a file without address and password columns is refused")

        // Into a profile's Login Data, made from the Default profile's schema;
        // a second time adds nothing.
        let folder = Self.importFixtures.appendingPathComponent("logins", isDirectory: true)
        let template = folder.appendingPathComponent("Default", isDirectory: true)
        let target = folder.appendingPathComponent("Profile 9", isDirectory: true)
        try? FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        sqlite(template.appendingPathComponent("Login Data"), Self.loginSchema + "INSERT INTO logins (origin_url, username_value, password_value, signon_realm, date_created) VALUES ('https://old.example/', 'x', x'00', 'https://old.example/', 1);")
        let logins = (try? PasswordFile.parse(Data(files[0].1.utf8)))?.logins ?? []
        let (added, _) = CredentialImport.insertLogins(logins, into: target, template: template)
        let (again, existing) = CredentialImport.insertLogins(logins, into: target, template: template)
        let database = target.appendingPathComponent("Login Data")
        let stored = storedPassword(database)
        expect(added == 1 && again == 0 && existing == 1 && count(database, "SELECT count(*) FROM logins") == 1
               && count(database, "SELECT count(*) FROM meta") == 1 && stored == "geheim1",
               "passwords CSV: into Login Data, encrypted with OpenArch's key, not twice (\(added), \(again))")
    }

    static let loginSchema = """
        CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES ('version', '43');
        CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
          password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL,
          date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL DEFAULT 0, scheme INTEGER NOT NULL DEFAULT 0,
          password_type INTEGER, times_used INTEGER, form_data BLOB, display_name VARCHAR, icon_url VARCHAR,
          federation_url VARCHAR, skip_zero_click INTEGER, generation_upload_status INTEGER, possible_username_pairs BLOB,
          id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0, moving_blocked_for BLOB,
          date_password_modified INTEGER NOT NULL DEFAULT 0, sender_email VARCHAR, sender_name VARCHAR,
          date_received INTEGER, sharing_notification_displayed INTEGER NOT NULL DEFAULT 0, keychain_identifier BLOB,
          sender_profile_image_url VARCHAR, date_last_filled INTEGER NOT NULL DEFAULT 0, actor_login_approved INTEGER NOT NULL,
          UNIQUE (origin_url, username_element, username_value, password_element, signon_realm));
        """

    private func storedPassword(_ database: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT password_value FROM logins LIMIT 1", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let value = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let key = SafeStorage.key
        guard value.starts(with: Data("v10".utf8)),
              let plain = ArcProfileImport.aes(CCOperation(kCCDecrypt), value.dropFirst(3), key: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// A Chromium browser's logins and cookies, encrypted with its key, go
    /// into an OpenArch profile with OpenArch's key; a second time adds no
    /// second copy.
    private func loginMerge() {
        let folder = Self.importFixtures.appendingPathComponent("merge", isDirectory: true)
        let source = folder.appendingPathComponent("Chrome Default", isDirectory: true)
        let target = folder.appendingPathComponent("Profile 8", isDirectory: true)
        let template = folder.appendingPathComponent("Default", isDirectory: true)
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        let browserKey = ArcProfileImport.derivedKey(password: Data("chrome-test-password".utf8))
        guard let encrypted = ArcProfileImport.aes(CCOperation(kCCEncrypt), Data("pw-aus-chrome".utf8), key: browserKey),
              let cookie = ArcProfileImport.aes(CCOperation(kCCEncrypt), Data("sid=1".utf8), key: browserKey) else {
            return expect(false, "login merge: test values encrypt")
        }
        let hexPassword = (Data("v10".utf8) + encrypted).map { String(format: "%02x", $0) }.joined()
        let hexCookie = (Data("v10".utf8) + cookie).map { String(format: "%02x", $0) }.joined()
        let cookieSchema = """
            CREATE TABLE meta (key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES ('version', '24');
            CREATE TABLE cookies (creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
              path TEXT NOT NULL, encrypted_value BLOB NOT NULL, UNIQUE (host_key, name, path));
            """
        sqlite(template.appendingPathComponent("Login Data"), Self.loginSchema)
        sqlite(template.appendingPathComponent("Cookies"), cookieSchema)
        // The other browser's schema has a column OpenArch's does not.
        sqlite(source.appendingPathComponent("Login Data"), Self.loginSchema.replacingOccurrences(of: "actor_login_approved INTEGER NOT NULL,", with: "actor_login_approved INTEGER NOT NULL, newer_column INTEGER,")
            + "INSERT INTO logins (origin_url, username_value, password_value, signon_realm, date_created, actor_login_approved) VALUES ('https://example.com/', 'anna', x'\(hexPassword)', 'https://example.com/', 1, 0);")
        sqlite(source.appendingPathComponent("Cookies"), cookieSchema
            + "INSERT INTO cookies VALUES (1, '.example.com', 'sid', '', '/', x'\(hexCookie)');")
        let first = CredentialImport.mergeProfile(from: source, key: browserKey, into: target, template: template)
        let second = CredentialImport.mergeProfile(from: source, key: browserKey, into: target, template: template)
        let logins = target.appendingPathComponent("Login Data")
        expect(first.passwords == 1 && first.cookies == 1 && first.undecryptable == 0 && second.passwords == 0
               && count(logins, "SELECT count(*) FROM logins") == 1
               && count(target.appendingPathComponent("Cookies"), "SELECT count(*) FROM cookies") == 1
               && storedPassword(logins) == "pw-aus-chrome",
               "browser logins: re-encrypted with OpenArch's key into OpenArch's schema, not twice (\(first), \(second))")
        expect(count(source.appendingPathComponent("Login Data"), "SELECT count(*) FROM logins") == 1
               && storedPassword(source.appendingPathComponent("Login Data")) == nil,
               "browser logins: the other browser's database stays as it was")
    }

    /// The library's history bulk actions: deleting selected pages and
    /// clearing, on a throwaway index.
    private func historyBulkTest() {
        let url = Self.importFixtures.appendingPathComponent("bulk-history.sqlite")
        try? FileManager.default.removeItem(at: url)
        let history = History(url: url)
        history.recordVisit(url: "https://example.com/a", title: "A")
        history.recordVisit(url: "https://example.com/b", title: "B")
        history.recordVisit(url: "https://example.org/c", title: "C")
        expect(history.urls(onHost: "example.com").count == 2 && history.urls(onHost: "EXAMPLE.com").count == 2,
               "history bulk: pages are found by their website, whatever the case")
        history.remove(urls: ["https://example.com/a"])
        expect(history.entry(for: "https://example.com/a") == nil && history.entry(for: "https://example.com/b") != nil,
               "history bulk: deleting selected pages removes only them")
        history.remove(urls: [])
        expect(history.recent(limit: 10).count == 2, "history bulk: deleting nothing keeps the rest")
        history.remove(urls: history.urls(onHost: "example.org"))
        expect(history.entry(for: "https://example.org/c") == nil, "history bulk: a whole website goes at once")
        history.clear()
        expect(history.recent(limit: 10).isEmpty, "history bulk: clearing removes everything")
    }

    private func arcBackupTest() {
        let arc = Self.importFixtures.appendingPathComponent("Arc", isDirectory: true)
        let documents = Self.importFixtures.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: arc.appendingPathComponent("User Data"), withIntermediateDirectories: true)
        try? "{\"sidebar\": {}}".write(to: arc.appendingPathComponent("StorableSidebar.json"), atomically: true, encoding: .utf8)
        try? "{}".write(to: arc.appendingPathComponent("StorableSpaces.json"), atomically: true, encoding: .utf8)
        try? "{}".write(to: arc.appendingPathComponent("User Data/Local State"), atomically: true, encoding: .utf8)
        try? "x".write(to: arc.appendingPathComponent("Cache.bin"), atomically: true, encoding: .utf8)
        do {
            let zip = try ArcBackup.make(from: arc, into: documents)
            let list = Process()
            let pipe = Pipe()
            list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            list.arguments = ["-Z1", zip.path]
            list.standardOutput = pipe
            try list.run()
            list.waitUntilExit()
            let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init).sorted()
            expect(names == ["StorableSidebar.json", "StorableSpaces.json", "User Data/Local State"]
                   && zip.lastPathComponent.hasPrefix("Arc-Sicherung "),
                   "Arc backup: Arc's JSON files and Local State in a zip (\(names))")
        } catch {
            expect(false, "Arc backup: \(error.localizedDescription)")
        }
    }

    /// Settings › Import's model: finds the fixtures, imports the ticked
    /// profiles, shows the numbers.
    private func importThroughModel(home: URL, then done: @escaping () -> Void) {
        guard let app = NSApp.delegate as? AppDelegate else { return done() }
        let model = BrowserImportModel.shared
        model.home = home
        model.detect()
        eventually({ model.hasDetected }, timeout: 5) { found in
            guard found, let firefox = model.installs.first(where: { $0.id == "firefox" }) else {
                self.expect(false, "import model: finds the fixture browsers")
                return done()
            }
            let spacesBefore = self.library.spaces.count
            model.setSelected(firefox, firefox.profiles[0], true)
            model.set(.history, for: firefox, false)
            var result: BrowserImportReport?
            model.run(app: app, askBeforeRelaunch: false) { result = $0 }
            self.eventually({ result != nil }, timeout: 5) { _ in
                let added = self.library.spaces.count > spacesBefore ? self.library.spaces.last : nil
                self.expect(added?.name == "Firefox" && result?.bookmarks == 3 && model.phase == .done(result ?? BrowserImportReport()),
                            "import model: the ticked profile becomes a space, the result view has its numbers (\(result?.lines ?? []))")
                if let added { self.library.removeSpace(added) }
                model.phase = .idle
                model.selectedProfiles = []
                model.home = FileManager.default.homeDirectoryForCurrentUser
                done()
            }
        }
    }
}
