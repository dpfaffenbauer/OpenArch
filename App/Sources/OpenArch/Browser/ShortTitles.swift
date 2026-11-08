// The title rules, the prompt, the queue with its strict timeout and the
// Foundation Models call are adapted from Airc's Tidy Titles
// (github.com/red545/airc, commit 88fb3dd, packages/AircKit/Sources/AircKit/AI/TidyTitles.swift
// and apps/browser/Sources/Airc/AI/AppleIntelligence.swift),
// Copyright 2026 The Airc Authors, Apache License 2.0; changed for OpenArch.
// See NOTICE.
import AppKit
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Short names for tabs with long or noisy titles ("Inbox (3) - x@y.de - Gmail"
/// becomes "Gmail Inbox"), as Arc Max did. Two kinds share one store, kept
/// by page address in ShortTitles.json in the data folder:
/// - on this Mac, from Apple's on-device model, while Einstellungen › KI ›
///   „Tab-Titel kürzen“ is on (`device`);
/// - from Claude, when „Tabs mit KI aufräumen“ is applied (`claude`).
/// Only pinned and today tabs get one; tabs you renamed, favorites, folders,
/// splits and private windows keep their titles. The model sees the title
/// without counts and email addresses, and the host, nothing else.
@MainActor @Observable
final class ShortTitles {
    static let shared = ShortTitles(file: AppPaths.support.appendingPathComponent("ShortTitles.json"))
    static let shortTitleLimit = 60

    enum Source: String, Codable {
        case device, claude
    }

    struct Entry: Codable, Equatable {
        /// `TitleRules.fingerprint` of the title the name was made from.
        var fingerprint: String
        /// The short name; nil when the model had nothing better (that
        /// title isn't asked about again).
        var name: String?
        var source: Source
        var used: Date
    }

    struct Options {
        /// Quiet time after the last request before the queue runs.
        var debounce: TimeInterval = 1.5
        /// One request's limit; an answer after it is thrown away.
        var timeout: TimeInterval = 4
        var batchLimit = 6
        /// A page whose request timed out or failed is asked again after this long.
        var retryAfter: TimeInterval = 600
        /// While you type or scroll, the queue looks again after this long.
        var busyRetry: TimeInterval = 1
        /// After a timeout, while the model still hasn't answered, the queue waits this long.
        var stallRetry: TimeInterval = 15
        var cacheLimit = 1000
        var saveDelay: TimeInterval = 2
    }

    struct Stats: Equatable {
        var requests = 0, named = 0, kept = 0, timeouts = 0, failures = 0
    }

    /// Bumped whenever a name arrives or goes: rows showing names read it.
    private(set) var revision = 0
    /// Whether Apple's model can run here (Settings › KI follows it).
    private(set) var availability: AIAvailability

    @ObservationIgnored var options = Options()
    @ObservationIgnored private(set) var stats = Stats()
    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    /// Addresses waiting for the model, oldest first.
    @ObservationIgnored private(set) var queue: [String] = []
    @ObservationIgnored private var pending: [String: Pending] = [:]
    @ObservationIgnored private var retryAt: [String: Date] = [:]
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    /// A call that timed out and hasn't returned yet: nothing more goes to the model until it does.
    @ObservationIgnored private var stalled: Call?
    /// Bumped when the model changes or names are forgotten: answers from before are dropped.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var model: (any ShortTitleModel)?
    @ObservationIgnored let file: URL

    /// You type, scroll or drag (in any app): the queue waits.
    @ObservationIgnored var isBusy: @MainActor () -> Bool = { ShortTitles.recentInput() }
    /// Self-test: this availability and model instead of the system's.
    @ObservationIgnored var testOverride: (availability: AIAvailability, model: (any ShortTitleModel)?)? {
        didSet { refreshAvailability() }
    }

    private struct Pending {
        let request: ShortTitleRequest
        let title: String
        let fingerprint: String
    }

    init(file: URL) {
        self.file = file
        availability = AppleIntelligence.availability
        model = availability.isAvailable ? AppleIntelligence.titleModel() : nil
        load()
        let center = NotificationCenter.default
        // Apple Intelligence turned on (or its model downloaded) while OpenArch runs.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortTitles.shared.refreshAvailability() }
        })
        // Names of the last seconds before quitting are kept too.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortTitles.shared.save() }
        })
    }

    /// Whether names are made on this Mac now.
    func isActive(enabled: Bool) -> Bool {
        enabled && availability.isAvailable && model != nil
    }

    /// Reads the availability again (on becoming active, and when Settings show).
    func refreshAvailability() {
        let now = testOverride?.availability ?? AppleIntelligence.availability
        let hadModel = model != nil
        if !now.isAvailable {
            model = nil
            clearQueue()
        } else if let testOverride {
            model = testOverride.model
        } else if model == nil {
            model = AppleIntelligence.titleModel()
        }
        // Answers of a model that went (or was swapped in the self-test) are dropped.
        if testOverride != nil || hadModel != (model != nil) { epoch += 1 }
        if now != availability {
            availability = now
            revision += 1
        }
    }

    /// Settings › KI › „Tab-Titel kürzen“ changed: off forgets every name made on this Mac.
    func settingChanged(enabled: Bool) {
        if enabled {
            if testOverride == nil, availability.isAvailable { AppleIntelligence.prewarm() }
        } else {
            forgetDeviceNames()
        }
        revision += 1
    }

    // MARK: What a row shows

    /// The page a tab is named after: its title and address. Nil for what
    /// keeps its title: renamed tabs, favorites, folders, splits, agent
    /// chats, private windows and pages that aren't on the web.
    func subject(of item: Item, isPrivate: Bool) -> (title: String, url: String)? {
        guard !isPrivate, item.kind == .tab, (item.customTitle ?? "").isEmpty,
              item.role == .pinned || item.role == .today, item.parent?.kind != .split else { return nil }
        let url = item.currentURL
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
        let title = (item.liveTitle?.isEmpty == false ? item.liveTitle : nil) ?? item.savedTitle
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (title, url)
    }

    /// The short name the sidebar shows for |item|, or nil for its own
    /// title. A title that needs one and has none yet is queued for the
    /// model; the row shows the name once it arrives.
    func name(for item: Item, isPrivate: Bool, enabled: Bool) -> String? {
        _ = revision
        guard let subject = subject(of: item, isPrivate: isPrivate) else { return nil }
        let fingerprint = TitleRules.fingerprint(subject.title)
        if let entry = entries[subject.url], entry.fingerprint == fingerprint {
            if entry.source == .claude { return entry.name }
            if isActive(enabled: enabled) {
                entries[subject.url]?.used = Date()
                return entry.name
            }
            return nil
        }
        guard isActive(enabled: enabled), TitleRules.needsTidy(subject.title) else { return nil }
        enqueue(url: subject.url, title: subject.title, fingerprint: fingerprint)
        return nil
    }

    /// The title a tab's row shows.
    func title(of item: Item, in browser: BrowserWindowController) -> String {
        name(for: item, isPrivate: browser.isPrivate, enabled: browser.library.settings.tidyTitles) ?? item.displayTitle
    }

    /// The row's tooltip: with previews off, the page's own title over its
    /// address when the row shows a short name (the preview shows both).
    func help(for item: Item, in browser: BrowserWindowController) -> String {
        guard !browser.library.settings.tabPreviews else { return "" }
        guard name(for: item, isPrivate: browser.isPrivate, enabled: browser.library.settings.tidyTitles) != nil
        else { return item.currentURL }
        return item.displayTitle + "\n" + item.currentURL
    }

    // MARK: Claude's names

    /// A short name from Claude („Tabs mit KI aufräumen“) for |item|'s page;
    /// returns what was there before, for undo.
    @discardableResult
    func setClaudeName(_ name: String, for item: Item) -> (url: String, entry: Entry?)? {
        guard let subject = subject(of: item, isPrivate: false) else { return nil }
        let before = entries[subject.url]
        store(url: subject.url, Entry(fingerprint: TitleRules.fingerprint(subject.title),
                                      name: String(name.prefix(Self.shortTitleLimit)), source: .claude, used: Date()))
        revision += 1
        scheduleSave()
        return (subject.url, before)
    }

    /// Puts back what `setClaudeName` replaced.
    func restore(url: String, entry: Entry?) {
        entries[url] = entry
        revision += 1
        scheduleSave()
    }

    // MARK: The queue

    /// Runs the queue now (the debounce timer calls it).
    func runPending() async {
        guard !running else { return }
        guard let model, availability.isAvailable else { return clearQueue() }
        if let stalled, !stalled.isFinished { return schedule(after: options.stallRetry) }
        stalled = nil
        if isBusy() { return schedule(after: options.busyRetry) }
        running = true
        let epoch = self.epoch
        var changed = false
        var done = 0
        while done < options.batchLimit, let url = queue.first {
            if done > 0, isBusy() { break }
            queue.removeFirst()
            guard let request = pending.removeValue(forKey: url) else { continue }
            done += 1
            stats.requests += 1
            let outcome = await Self.ask(model, request.request, timeout: options.timeout)
            guard epoch == self.epoch else { break }
            // A name from Claude since then stays.
            if entries[url]?.source == .claude, entries[url]?.fingerprint == request.fingerprint { continue }
            switch outcome {
            case .answer(let text):
                let name = TitleRules.accept(text, title: request.title, host: request.request.host)
                if name == nil { stats.kept += 1 } else { stats.named += 1 }
                store(url: url, Entry(fingerprint: request.fingerprint, name: name, source: .device, used: Date()))
                changed = true
            case .declined:
                stats.kept += 1
                store(url: url, Entry(fingerprint: request.fingerprint, name: nil, source: .device, used: Date()))
                changed = true
            case .failed:
                stats.failures += 1
                retryAt[url + "\n" + request.fingerprint] = Date().addingTimeInterval(options.retryAfter)
            case .timeout(let call):
                stats.timeouts += 1
                retryAt[url + "\n" + request.fingerprint] = Date().addingTimeInterval(options.retryAfter)
                stalled = call
            }
            if stalled != nil { break }
        }
        running = false
        guard epoch == self.epoch else { return }
        if changed {
            revision += 1
            scheduleSave()
        }
        if !queue.isEmpty { schedule(after: options.debounce) }
    }

    private func enqueue(url: String, title: String, fingerprint: String) {
        if pending[url]?.fingerprint == fingerprint { return }
        if let until = retryAt[url + "\n" + fingerprint], until > Date() { return }
        if retryAt.count >= 1024 { retryAt = retryAt.filter { $0.value > Date() } }
        if pending[url] == nil { queue.append(url) }
        pending[url] = Pending(request: TitlePrompt.request(title: title, url: url), title: title, fingerprint: fingerprint)
        if !running { schedule(after: options.debounce) }
    }

    private func clearQueue() {
        runTask?.cancel()
        runTask = nil
        pending.removeAll()
        queue.removeAll()
    }

    private func schedule(after delay: TimeInterval) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1e9))
            guard !Task.isCancelled else { return }
            await self?.runPending()
        }
    }

    nonisolated static func recentInput() -> Bool {
        let quiet: CFTimeInterval = 0.75
        let kinds: [CGEventType] = [.keyDown, .scrollWheel, .leftMouseDragged, .otherMouseDragged]
        return kinds.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < quiet }
    }

    // MARK: The file

    private struct FileData: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    private func store(url: String, _ entry: Entry) {
        entries[url] = entry
        let limit = max(1, options.cacheLimit)
        guard entries.count > limit else { return }
        // Down to seven eighths of the limit, the least recently used going first.
        let keep = limit - limit / 8
        for (url, _) in entries.sorted(by: { $0.value.used < $1.value.used }).prefix(entries.count - keep) {
            entries[url] = nil
        }
    }

    /// Forgets the names made on this Mac (turning the setting off does
    /// this); Claude's names stay.
    func forgetDeviceNames() {
        epoch += 1
        clearQueue()
        retryAt.removeAll()
        entries = entries.filter { $0.value.source != .device }
        revision += 1
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(FileData.self, from: data) else { return }
        entries = saved.entries
    }

    /// Reads the file again (self-test: as after a restart).
    func reload() {
        entries = [:]
        load()
        revision += 1
    }

    /// Writes the file now (quitting, self-test); no names, no file.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        if let data = try? JSONEncoder().encode(FileData(entries: entries)) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = options.saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    // MARK: One call, with a strict timeout

    enum Outcome: Sendable {
        case answer(String), declined, failed, timeout(Call)
    }

    /// One model call: its answer or the timeout, whichever comes first. A
    /// model that ignores cancellation can't hold the queue past the
    /// timeout; `isFinished` says when it has let go.
    final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        private var finished = false
        private var timer: Task<Void, Never>?

        var isFinished: Bool { lock.withLock { finished } }

        func claim() -> Bool {
            lock.withLock {
                if claimed { return false }
                claimed = true
                return true
            }
        }

        func finish() {
            let timer = lock.withLock {
                finished = true
                return self.timer
            }
            timer?.cancel()
        }

        func setTimer(_ task: Task<Void, Never>) {
            let done = lock.withLock {
                timer = task
                return finished
            }
            if done { task.cancel() }
        }
    }

    nonisolated static func ask(_ model: any ShortTitleModel, _ request: ShortTitleRequest, timeout: TimeInterval) async -> Outcome {
        let call = Call()
        return await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            let work = Task.detached {
                let outcome: Outcome
                do {
                    outcome = .answer(try await model.shortTitle(for: request))
                } catch is ShortTitleDeclined {
                    outcome = .declined
                } catch {
                    outcome = .failed
                }
                call.finish()
                if call.claim() { done.resume(returning: outcome) }
            }
            call.setTimer(Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                guard !Task.isCancelled, call.claim() else { return }
                work.cancel()
                done.resume(returning: .timeout(call))
            })
        }
    }
}

// MARK: - Rules

/// What the model is asked about one page: its title without counts and
/// email addresses, and its host. Never the address's path, the page or
/// anything else.
struct ShortTitleRequest: Hashable, Sendable {
    var title: String
    var host: String
}

/// A language model that names tabs (Apple's on-device model; a stand-in in the self-test).
protocol ShortTitleModel: Sendable {
    func shortTitle(for request: ShortTitleRequest) async throws -> String
}

/// The model won't name this page (a guardrail, a refusal, a language it
/// doesn't support): it keeps its title until the title changes.
struct ShortTitleDeclined: Error {}

enum TitlePrompt {
    static let instructions = """
        You name browser tabs. You get a web page's title and its site. Reply with a short, clean name for the tab: \
        what the page is, the way a person would say it, in at most four words. Keep the site's or app's name when it \
        helps, like "Gmail Inbox" or "GitHub Pull Requests". Leave out counts, email addresses, account names, \
        separators and taglines. Use only words from the title or the site's name, in the title's language.
        """

    static func prompt(for request: ShortTitleRequest) -> String {
        "Title: \(request.title)\nSite: \(request.host)"
    }

    /// The request for a page: the cleaned title (at most 160 characters) and the host without "www.".
    static func request(title: String, url: String) -> ShortTitleRequest {
        var host = URLComponents(string: url)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return ShortTitleRequest(title: String(TitleRules.prepare(title).prefix(TitleRules.promptLength)), host: host)
    }
}

/// Which titles get a short name, what the model sees, and which answers show.
enum TitleRules {
    static let maxWords = 4
    /// An answer may run one word over ("about four"); a longer one is dropped, never cut.
    static let acceptedWords = 5
    static let maxLength = 40
    /// A title this long gets a name even without separators or counts.
    static let longTitle = 32
    static let promptLength = 160

    static let separators = [" - ", " – ", " — ", " | ", " · ", " • ", " / ", " :: ", " » ", " › "]

    private static let email = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    /// "(3)", "(12+)", "[2]": unread counts.
    private static let count = try! NSRegularExpression(pattern: #"[(\[]\d+\+?[)\]]"#)
    /// "3 new messages" and the like.
    private static let newItems = try! NSRegularExpression(
        pattern: #"\b\d+\+? (new |unread |neue |ungelesene )?(items?|messages?|notifications?|Nachrichten|Mitteilungen)\b"#,
        options: [.caseInsensitive])
    private static let divider = try! NSRegularExpression(pattern: #"(\s+[-–—|·•/:»›]+)+\s+"#)
    private static let dividerCharacters = CharacterSet(charactersIn: "-–—|·•/:»›").union(.whitespacesAndNewlines)

    /// Whether a title is long or noisy enough to ask about. Short, clean
    /// titles ("GitHub") and addresses stay, without a model call.
    static func needsTidy(_ title: String) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !looksLikeAddress(text) else { return false }
        if matches(email, text) || matches(count, text) || matches(newItems, text) { return true }
        if separators.contains(where: { text.contains($0) }) { return true }
        return words(text).count > maxWords || text.count >= longTitle
    }

    /// The title the model sees: email addresses, counts and "3 new
    /// messages" taken out, the parts joined with " - ".
    static func prepare(_ title: String) -> String {
        var text = title
        for pattern in [email, count, newItems] { text = replace(pattern, in: text, with: " ") }
        let parts = replace(divider, in: " " + text + " ", with: "\u{1F}").split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: dividerCharacters) }.filter { !$0.isEmpty }
        return parts.joined(separator: " - ")
    }

    /// The model's answer cleaned up, or nil to keep the page's title:
    /// empty, too long, holding an email address, a count or markup, the
    /// title unchanged, or mostly words that are neither in the title nor
    /// in the host.
    static func accept(_ answer: String, title: String, host: String) -> String? {
        var text = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: .whitespaces)
        for prefix in ["title:", "name:", "tab:", "tab name:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let quotes = CharacterSet(charactersIn: "\"'“”‘’`«»„").union(.whitespaces)
        text = text.trimmingCharacters(in: quotes)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!-–—|·•/").union(.whitespaces))
        text = text.trimmingCharacters(in: quotes)
        text = words(text).joined(separator: " ")
        guard !text.isEmpty, text.count <= maxLength, words(text).count <= acceptedWords else { return nil }
        guard !matches(email, text), !matches(count, text), !text.contains(where: { "<>{}[]\\@".contains($0) }) else { return nil }
        guard text.caseInsensitiveCompare(title.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame else { return nil }
        let source = fold(title + " " + host)
        let significant = words(text).map(fold).map { $0.filter(\.isLetter) }.filter { $0.count >= 3 }
        let found = significant.filter { source.contains($0) }.count
        guard significant.isEmpty || found * 2 >= significant.count else { return nil }
        return text
    }

    /// What two titles of one page have in common once counts, numbers and
    /// email addresses are out: a name stays while only those change.
    static func fingerprint(_ title: String) -> String {
        let text = replace(email, in: title, with: " ").lowercased()
        return text.unicodeScalars.map { CharacterSet.letters.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    static func looksLikeAddress(_ text: String) -> Bool {
        !text.contains(where: \.isWhitespace) && (text.contains(".") || text.contains("/") || text.contains(":"))
    }

    static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

// MARK: - Apple Intelligence

/// Whether Apple's on-device model can run here. OpenArch runs on macOS 15,
/// so FoundationModels is weak-linked: before macOS 26 none of it loads.
enum AIAvailability: Equatable {
    case available
    /// macOS before 26.
    case needsNewerMacOS
    /// The Mac can't run Apple Intelligence.
    case deviceNotEligible
    /// Apple Intelligence is off in System Settings.
    case notEnabled
    /// Apple Intelligence is on, but its model is still downloading or getting ready.
    case notReady

    var isAvailable: Bool { self == .available }

    /// Why „Tab-Titel kürzen“ is greyed out.
    var reason: String {
        switch self {
        case .available: ""
        case .needsNewerMacOS: "Braucht Apple Intelligence, also macOS 26 oder neuer."
        case .deviceNotEligible: "Dieser Mac unterstützt Apple Intelligence nicht."
        case .notEnabled: "Apple Intelligence ist aus. Schalte es in den Systemeinstellungen unter „Apple Intelligence & Siri“ ein."
        case .notReady: "Das Modell von Apple Intelligence wird noch geladen. Versuch es später noch einmal."
        }
    }
}

enum AppleIntelligence {
    /// The system model's availability: cheap, fine on the main thread.
    static var availability: AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .notReady
                @unknown default: return .notReady
                }
            }
        }
        #endif
        return .needsNewerMacOS
    }

    static func titleModel() -> (any ShortTitleModel)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available { return FoundationTitleModel() }
        #endif
        return nil
    }

    /// Loads the model ahead of the first request (once the setting is on).
    @MainActor static func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available {
            LanguageModelSession(instructions: TitlePrompt.instructions).prewarm()
        }
        #endif
    }

    /// System Settings › Apple Intelligence & Siri.
    @MainActor static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

#if canImport(FoundationModels)
/// Guided generation: the model fills in one field, so the answer is a name, never a sentence about one.
@available(macOS 26.0, *)
@Generable(description: "A short name for a browser tab")
struct ShortTitleAnswer {
    @Guide(description: "The tab's new name: at most four words, from the page's title or site, with no counts or email addresses")
    var name: String
}

/// One fresh session per page (no title is in another's context), greedy
/// sampling (the same title gets the same name), a few tokens at most.
@available(macOS 26.0, *)
struct FoundationTitleModel: ShortTitleModel {
    func shortTitle(for request: ShortTitleRequest) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: TitlePrompt.instructions)
        do {
            let response = try await session.respond(to: TitlePrompt.prompt(for: request), generating: ShortTitleAnswer.self,
                                                     options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32))
            return response.content.name
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal, .unsupportedLanguageOrLocale, .exceededContextWindowSize: throw ShortTitleDeclined()
            default: throw error
            }
        }
    }
}
#endif
