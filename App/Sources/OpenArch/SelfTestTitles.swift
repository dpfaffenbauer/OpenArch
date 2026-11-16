import AppKit

/// The self-test of „Tab-Titel kürzen“ (ShortTitles), with a stand-in for
/// Apple's model, so it runs the same with or without Apple Intelligence:
/// the rules (counts, email addresses), greyed out without Apple
/// Intelligence, what the model sees, what keeps its title, the cache
/// (also after a restart), the timeout, the tooltip, and off forgetting the
/// names. Last, with Apple Intelligence here, one request to the real model.
extension SelfTest {
    func shortTitlesTest(then next: @escaping () -> Void) {
        let titles = ShortTitles.shared
        guard let space = library.spaces.first, let profile = library.profiles.first else { return next() }
        browser.switchSpace(to: space)
        let savedOptions = titles.options
        let savedBusy = titles.isBusy
        let savedPreviews = library.settings.tabPreviews
        var options = titles.options
        options.debounce = 0.2
        options.timeout = 0.8
        options.busyRetry = 0.1
        options.stallRetry = 0.3
        options.saveDelay = 0.2
        titles.options = options
        titles.isBusy = { false }

        // The rules.
        expect(TitleRules.prepare("Inbox (3) - someone@example.com - Gmail") == "Inbox - Gmail"
               && TitleRules.prepare("(12) Home / X") == "Home - X"
               && TitleRules.prepare("Slack | 3 new messages | Team") == "Slack - Team",
               "the model's title has no counts and no email addresses (\(TitleRules.prepare("Inbox (3) - someone@example.com - Gmail")))")
        expect(!TitleRules.needsTidy("GitHub") && !TitleRules.needsTidy("Figma") && !TitleRules.needsTidy("example.com/path")
               && TitleRules.needsTidy("Inbox (3) - someone@example.com - Gmail") && TitleRules.needsTidy("Pull requests · example/repo · GitHub"),
               "short titles and addresses aren't asked about, long and noisy ones are")
        expect(TitleRules.fingerprint("Inbox (3) - a@b.de - Gmail") == TitleRules.fingerprint("Inbox (41) - a@b.de - Gmail")
               && TitleRules.fingerprint("Inbox (3) - Gmail") != TitleRules.fingerprint("Sent - Gmail"),
               "a title's fingerprint stays while only a count changes")
        expect(TitleRules.accept("\"Gmail Inbox.\"", title: "Inbox - Gmail", host: "mail.google.com") == "Gmail Inbox"
               && TitleRules.accept("Inbox someone@example.com", title: "Inbox - Gmail", host: "mail.google.com") == nil
               && TitleRules.accept("Wonderful Shopping Bargains", title: "Inbox - Gmail", host: "mail.google.com") == nil
               && TitleRules.accept("Your new short name for this browser tab is", title: "Inbox - Gmail", host: "mail.google.com") == nil,
               "answers with email addresses, other words or too many words are dropped")

        let model = TitleModelStandIn([
            "Inbox - Gmail": "Gmail Inbox",
            "Pull requests - example-org/example-repo - GitHub": "GitHub Pull Requests",
            "Slow Page - Example Reports": "Slow Reports",
            "Private - Mail": "Private Mail",
            "Release Notes - Example Blog": "Release Notes",
        ], slow: ["Slow Page - Example Reports"])
        let gmail = Item.tab(url: "https://mail.google.com/mail/u/0/?tab=inbox#inbox", title: "Inbox (3) - someone@example.com - Gmail")
        let pulls = Item.tab(url: "https://github.com/example-org/example-repo/pulls", title: "Pull requests · example-org/example-repo · GitHub")
        let plain = Item.tab(url: "https://www.figma.com/files", title: "Figma")
        let renamed = Item.tab(url: "https://www.example.com/renamed", title: "Release Notes (4) - Example Blog")
        renamed.customTitle = "Meine Notizen"
        let favorite = Item.tab(url: "https://www.example.com/favorite", title: "Release Notes (4) - Example Blog")
        let left = Item.tab(url: "https://www.example.com/left", title: "Release Notes (4) - Example Blog")
        let right = Item.tab(url: "https://www.example.com/right", title: "Figma")
        let split = Item(kind: .split, children: [left, right])
        let folder = Item.folder("Release Notes (4) - Example Blog - Ordner mit langem Namen")
        let slow = Item.tab(url: "https://reports.example.com/slow", title: "Slow Page (2) – Example Reports")
        let privateTab = Item.tab(url: "https://mail.example.com/private", title: "Private (5) - secret@example.com - Mail")
        space.today.insert(gmail, at: 0)
        space.today.insert(plain, at: 0)
        space.today.insert(renamed, at: 0)
        space.today.insert(split, at: 0)
        space.today.insert(folder, at: 0)
        space.pinned.insert(pulls)
        profile.favorites.insert(favorite)
        // A private window's today tabs: a section of its own, never in the library.
        let privateToday = Container(role: .today)
        privateToday.insert(privateTab)
        let added = [gmail, plain, renamed, split, folder, pulls, favorite]
        func shown(_ item: Item, isPrivate: Bool = false) -> String {
            titles.name(for: item, isPrivate: isPrivate, enabled: library.settings.tidyTitles) ?? item.displayTitle
        }
        func finish() {
            for item in added + [slow] where item.container != nil { item.detach() }
            privateToday.replace(with: [])
            library.settings.tabPreviews = savedPreviews
            library.settings.tidyTitles = false
            titles.settingChanged(enabled: false)
            titles.testOverride = nil
            titles.options = savedOptions
            titles.isBusy = savedBusy
            library.setNeedsSave()
            next()
        }

        // Off by default.
        expect(!library.settings.tidyTitles && shown(gmail) == gmail.displayTitle && titles.queue.isEmpty,
               "„Tab-Titel kürzen“ is off by default and nothing is asked")

        // Without Apple Intelligence: greyed out, and an earlier „on“ names nothing.
        titles.testOverride = (.notEnabled, nil)
        library.settings.tidyTitles = true
        titles.settingChanged(enabled: true)
        expect(!titles.isActive(enabled: true) && shown(gmail) == gmail.displayTitle && titles.queue.isEmpty
               && !titles.availability.reason.isEmpty && AIAvailability.needsNewerMacOS.reason.contains("macOS 26"),
               "without Apple Intelligence every tab keeps its title, and Settings say why (\(titles.availability.reason))")
        let app = NSApp.delegate as? AppDelegate
        app?.showSettings(page: .ai)
        shot("tab titles unavailable", of: app?.settingsWindow) {
            app?.settingsWindow?.close()

            // With it (the stand-in).
            titles.testOverride = (.available, model)
            titles.settingChanged(enabled: true)
            let excluded = [plain, renamed, favorite, left, right, split, folder]
            for item in [gmail, pulls] + excluded { _ = shown(item) }
            _ = shown(privateTab, isPrivate: true)
            let queued = Set(titles.queue)
            self.expect(queued.isSuperset(of: [gmail.currentURL, pulls.currentURL])
                        && queued.isDisjoint(with: (excluded + [privateTab]).map(\.currentURL)),
                        "only the long titles of today and pinned tabs are queued (\(titles.queue))")
            self.eventually({ shown(gmail) == "Gmail Inbox" && shown(pulls) == "GitHub Pull Requests" }, timeout: 5) { named in
                self.expect(named, "long titles get short names: \(shown(gmail)), \(shown(pulls))")
                let asked = model.asked.filter { ["mail.google.com", "github.com"].contains($0.host) }
                let others = model.asked.filter { ["example.com", "mail.example.com", "figma.com"].contains($0.host) }
                let leaks = model.asked.filter { request in
                    ["someone", "@", "(3)", "/mail", "pulls", "inbox#", "secret", "Release"].contains { request.title.contains($0) || request.host.contains($0) }
                }
                self.expect(asked.map(\.title).sorted() == ["Inbox - Gmail", "Pull requests - example-org/example-repo - GitHub"]
                            && leaks.isEmpty && others.isEmpty,
                            "the model sees only the cleaned titles and hosts: \(asked.map { "\($0.title) @ \($0.host)" })")
                self.expect(excluded.allSatisfy { shown($0) == $0.displayTitle } && shown(privateTab, isPrivate: true) == privateTab.displayTitle,
                            "short titles, renamed tabs, favorites, folders, splits and private windows keep their titles")

                // The original title on hover: the preview shows it; with previews off, the tooltip.
                self.library.settings.tabPreviews = false
                let help = titles.help(for: gmail, in: self.browser)
                self.expect(help.hasPrefix(gmail.displayTitle) && help.contains(gmail.currentURL)
                            && titles.help(for: plain, in: self.browser) == plain.currentURL,
                            "with previews off, a tidied tab's tooltip shows its own title")
                self.library.settings.tabPreviews = true
                self.expect(titles.help(for: gmail, in: self.browser) == "", "with previews on, the preview shows the title, not a tooltip")
                self.shot("tab titles") {
                    // The cache: another count, another tab on the page, and after a restart.
                    let requests = model.asked.count
                    gmail.liveTitle = "Inbox (4) - someone@example.com - Gmail"
                    let twin = Item.tab(url: gmail.currentURL, title: "Inbox (7) - someone@example.com - Gmail")
                    space.today.insert(twin, at: 0)
                    let fromCache = shown(gmail) == "Gmail Inbox" && shown(twin) == "Gmail Inbox"
                    twin.detach()
                    titles.save()
                    let file = (try? String(contentsOf: titles.file, encoding: .utf8)) ?? ""
                    titles.reload()
                    self.expect(fromCache && shown(gmail) == "Gmail Inbox" && model.asked.count == requests && titles.queue.isEmpty,
                                "a changed count, a second tab and a restart are cache hits, without asking again")
                    self.expect(file.contains("Gmail Inbox") && file.contains("mail.google.com") && !file.contains("someone")
                                && !file.contains("Inbox (") && !file.contains("secret"),
                                "ShortTitles.json keeps names by address, never titles or private pages")
                    gmail.liveTitle = "Sent - someone@example.com - Gmail"
                    _ = shown(gmail)
                    self.expect(shown(gmail) == gmail.displayTitle && titles.queue == [gmail.currentURL],
                                "a new title shows itself and is asked about again")

                    // A model too slow: cut off after the timeout, the title stays.
                    space.today.insert(slow, at: 0)
                    _ = shown(slow)
                    self.eventually({ titles.stats.timeouts > 0 }, timeout: 5) { timedOut in
                        self.expect(timedOut && shown(slow) == slow.displayTitle,
                                    "a request past its timeout keeps the title (\(titles.stats))")

                        // Claude's names share the store, and win over the model's.
                        titles.setClaudeName("Gesendet", for: gmail)
                        self.expect(shown(gmail) == "Gesendet", "a name from „Tabs mit KI aufräumen“ goes into the same store")
                        self.expect(titles.isActive(enabled: self.library.settings.tidyTitles)
                                    && !TabTidy.prompt(for: [gmail, pulls], titles: false).contains("\"titles\"")
                                    && TabTidy.prompt(for: [gmail, pulls]).contains("\"titles\""),
                                    "while Apple's model names tabs, Claude only sorts them into folders")

                        // Off: the names from this Mac go, Claude's stay.
                        self.library.settings.tidyTitles = false
                        titles.settingChanged(enabled: false)
                        self.expect(shown(pulls) == pulls.displayTitle && !titles.entries.values.contains { $0.source == .device }
                                    && shown(gmail) == "Gesendet",
                                    "turning it off forgets the names made on this Mac")
                        self.realModelCheck(finish)
                    }
                }
            }
        }
    }

    /// With Apple Intelligence on this Mac: one request to the real model.
    private func realModelCheck(_ next: @escaping () -> Void) {
        guard AppleIntelligence.availability.isAvailable, let model = AppleIntelligence.titleModel() else {
            Swift.print("[selftest] skip the real model (\(AppleIntelligence.availability))")
            return next()
        }
        let request = TitlePrompt.request(title: "Inbox (3) - someone@example.com - Gmail", url: "https://mail.google.com/mail/u/0/")
        let start = Date()
        Task { @MainActor in
            let outcome = await ShortTitles.ask(model, request, timeout: 15)
            let took = String(format: "%.1f s", Date().timeIntervalSince(start))
            if case .answer(let text) = outcome {
                let name = TitleRules.accept(text, title: "Inbox (3) - someone@example.com - Gmail", host: request.host)
                self.expect(name != nil, "Apple's model names a Gmail inbox: „\(text)“ in \(took)")
            } else {
                Swift.print("[selftest] note: Apple's model gave no name (\(outcome)) in \(took)")
            }
            next()
        }
    }
}

/// Apple's model in the self-test: answers from a table, keeps what it was
/// asked, and takes 3 s for the slow ones.
final class TitleModelStandIn: ShortTitleModel, @unchecked Sendable {
    private let answers: [String: String]
    private let slow: Set<String>
    private let lock = NSLock()
    private var requests: [ShortTitleRequest] = []

    init(_ answers: [String: String], slow: Set<String> = []) {
        self.answers = answers
        self.slow = slow
    }

    var asked: [ShortTitleRequest] { lock.withLock { requests } }

    func shortTitle(for request: ShortTitleRequest) async throws -> String {
        lock.withLock { requests.append(request) }
        if slow.contains(request.title) { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        guard let answer = answers[request.title] else { throw ShortTitleDeclined() }
        return answer
    }
}
