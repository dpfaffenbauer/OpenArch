import AppKit
import OpenArchCore
import SwiftUI

/// The onboarding's steps. Each can be skipped; the keychain step only
/// shows when Arc's logins come along, the default browser step only while
/// OpenArch is not the default browser.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome, importing, logins, accounts, appearance, defaultBrowser, done

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The dot in the step indicator (the keychain step shares the import's).
    var dot: Int {
        switch self {
        case .welcome: 0
        case .importing, .logins: 1
        case .accounts: 2
        case .appearance: 3
        case .defaultBrowser: 4
        case .done: 5
        }
    }

    static let dots = 6
}

/// Where the onboarding's import from Arc reads. The self-test brings a
/// fixture: its own sidebar file, profile and key.
struct OnboardingArcSource {
    var sidebar = ArcImporter.sidebarURL
    /// Arc's profile with its logins, nil without one.
    var profile: URL? = ArcProfileImport.isAvailable ? ArcProfileImport.arcProfile : nil
    /// A key instead of Arc's from the keychain (self-test).
    var key: Data?

    var isFixture: Bool { key != nil || sidebar != ArcImporter.sidebarURL }
}

/// Other browsers the import step offers when there is no Arc on this Mac.
/// The import from other browsers registers its sources here; until it
/// does, the step offers Arc or a fresh start.
@MainActor
enum OnboardingImportSources {
    struct Source: Identifiable {
        let id: String
        let name: String
        /// The sidebar to take over (spaces, favorites, pinned tabs).
        let load: () throws -> LibraryData
    }

    static var others: () -> [Source] = { [] }
}

/// Everything the onboarding's screens show; OnboardingController does the
/// work.
@MainActor @Observable
final class OnboardingModel {
    struct Progress: Equatable {
        var label: String
        var value: Double
    }

    enum Accounts: Equatable {
        case searching
        case found([GoogleAccount])
        /// No answer from Google (offline, or it did not say).
        case unknown
    }

    enum ImportChoice { case everything, chosen, fresh, other }

    var step = OnboardingStep.welcome
    var forward = true
    let isRerun: Bool

    // Import
    var searching = true
    var arcError: String?
    var preview: LibraryData?
    var summary = ArcImporter.Summary()
    /// How many spaces the preview shows so far (they come in one by one).
    var revealedSpaces = 0
    var focusedSpace = 0
    var choosing = false
    var chosenSpaces: Set<UUID> = []
    var includeFavorites = true
    var includeLogins = true
    var loginsAvailable = false
    var others: [OnboardingImportSources.Source] = []
    var choice: ImportChoice?

    // The import in the background
    var progress: Progress?
    var loginsResult: String?
    var loginsFailed: String?
    var sidebarImported = false

    // Accounts
    var accounts: [String: Accounts] = [:]

    // Default browser
    var offersDefaultBrowser = true

    init(isRerun: Bool) {
        self.isRerun = isRerun
    }

    var importRunning: Bool { progress != nil }

    /// "6 Spaces · 3 Profile · 12 Favoriten · 84 angeheftete Tabs"
    var countsLine: String {
        guard let preview else { return "" }
        let profiles = Set(preview.spaces.map(\.profileID)).count
        var parts = ["\(summary.spaces) \(summary.spaces == 1 ? "Space" : "Spaces")",
                     "\(profiles) \(profiles == 1 ? "Profil" : "Profile")"]
        if summary.favorites > 0 { parts.append(summary.favorites == 1 ? "1 Favorit" : "\(summary.favorites) Favoriten") }
        if summary.pinned > 0 {
            parts.append(summary.pinned == 1 ? "1 angehefteter Tab" : "\(summary.pinned) angeheftete Tabs")
        }
        if summary.today > 0 { parts.append(summary.today == 1 ? "1 offener Tab" : "\(summary.today) offene Tabs") }
        return parts.joined(separator: " · ")
    }

    var previewSpaces: [SpaceData] {
        guard let preview else { return [] }
        return Array(preview.spaces.prefix(revealedSpaces))
    }
}

/// The first-run flow: a floating window (no title bar, no window buttons,
/// dragged by its background, Esc goes a step back) with welcome, import
/// from Arc with a live picture of its sidebar, spaces and Google accounts,
/// the keychain explanation for Arc's logins, colors and light or dark,
/// default browser and a last step that grows into the browser window.
/// Settings › Allgemein starts it again.
@MainActor
final class OnboardingController: NSObject {
    enum Mode { case firstRun, rerun }

    let model: OnboardingModel
    let window: OnboardingWindow
    let mode: Mode
    private unowned let app: AppDelegate
    private let arc: OnboardingArcSource
    private let focus: Bool
    /// What the import loaded from Arc (the profile directory of Arc's own
    /// profile is decided when the import starts).
    private var loaded: LibraryData?
    /// The sidebar waiting for Arc's logins to arrive in its profile.
    private var pending: (data: LibraryData, directory: String)?
    private var revealTimer: Timer?
    private var signIn: GoogleSignInWindow?
    private var finished = false
    /// Self-test: called once the window has gone into the browser window.
    var onFinish: (() -> Void)?

    static let size = NSSize(width: 760, height: 540)

    private var library: Library { app.library }

    init(app: AppDelegate, mode: Mode, arc: OnboardingArcSource = OnboardingArcSource(), focus: Bool = true) {
        self.app = app
        self.mode = mode
        self.arc = arc
        self.focus = focus
        model = OnboardingModel(isRerun: mode == .rerun)
        window = OnboardingWindow(size: Self.size)
        super.init()
        model.offersDefaultBrowser = !AppPaths.isSelfTest && !DefaultBrowser.isDefault
        window.onEscape = { [weak self] in self?.back() }
        window.contentView = NSHostingView(rootView: OnboardingRoot(model: model, library: app.library, actions: self))
    }

    func present() {
        window.center()
        if focus {
            window.makeKeyAndOrderFront(nil)
        } else {
            // The self-test never takes the focus.
            window.orderFront(nil)
        }
        window.invalidateShadow()
    }

    // MARK: Moving between steps

    func next() {
        switch model.step {
        case .welcome: go(.importing)
        case .importing:
            // Skipping the import: a fresh start.
            if model.choice == nil { startFresh() } else { go(afterImport) }
        case .logins: startLogins()
        case .accounts: go(.appearance)
        case .appearance: go(model.offersDefaultBrowser ? .defaultBrowser : .done)
        case .defaultBrowser: go(.done)
        case .done: finish()
        }
    }

    func back() {
        guard !finished else { return }
        let target: OnboardingStep? = switch model.step {
        case .welcome: nil
        case .importing: model.choosing ? .importing : .welcome
        case .logins: .importing
        case .accounts: model.importRunning ? nil : .importing
        case .appearance: .accounts
        case .defaultBrowser: .appearance
        case .done: model.offersDefaultBrowser ? .defaultBrowser : .appearance
        }
        if model.step == .importing, model.choosing {
            model.choosing = false
            return
        }
        if model.step == .welcome, mode == .rerun {
            // Started again from the settings: Esc on the first step leaves.
            return close()
        }
        guard let target else { return NSSound.beep() }
        go(target)
    }

    func go(_ step: OnboardingStep) {
        model.forward = step > model.step
        withAnimation(.spring(duration: 0.4)) { model.step = step }
        switch step {
        case .importing: discover()
        case .accounts: readAccounts()
        case .appearance: showBrowserBehind()
        default: break
        }
        Swift.print("[onboarding] step \(step)")
    }

    private var afterImport: OnboardingStep {
        pending != nil && model.loginsAvailable && model.includeLogins && model.loginsResult == nil
            && model.loginsFailed == nil ? .logins : .accounts
    }

    // MARK: Import

    /// Reads Arc's sidebar for the preview; the spaces come in one by one.
    private func discover() {
        guard loaded == nil, model.arcError == nil else { return }
        model.loginsAvailable = arc.profile != nil
        do {
            let (data, summary) = try ArcImporter.load(from: arc.sidebar, currentProfiles: currentProfiles,
                                                       defaultDirectory: arcDefaultDirectory(logins: false))
            loaded = data
            model.preview = data
            model.summary = summary
            model.chosenSpaces = Set(data.spaces.map(\.id))
            if !arc.isFixture {
                ArcFavicons.importIcons(for: (data.profiles.flatMap(\.favorites) + data.spaces.flatMap(\.pinned))
                    .flatMap(Self.urls))
            }
            revealTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.model.revealedSpaces < data.spaces.count else {
                        // All there: back to the first space.
                        self.revealTimer?.invalidate()
                        withAnimation(.easeInOut(duration: 0.35)) { self.model.focusedSpace = 0 }
                        return
                    }
                    withAnimation(.spring(duration: 0.35)) {
                        self.model.revealedSpaces += 1
                        self.model.focusedSpace = self.model.revealedSpaces - 1
                    }
                }
            }
        } catch {
            model.arcError = FileManager.default.fileExists(atPath: arc.sidebar.path)
                ? error.localizedDescription : "Auf diesem Mac wurde kein Arc gefunden."
            model.others = OnboardingImportSources.others()
        }
        model.searching = false
    }

    private static func urls(_ item: ItemData) -> [String] {
        [item.url].compactMap { $0 } + (item.children ?? []).flatMap(urls)
    }

    private var currentProfiles: [String: String] {
        Dictionary(library.profiles.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    /// Arc's own profile: with its logins in a directory Chromium has not
    /// opened yet, so they can arrive while OpenArch runs; otherwise where it
    /// went before.
    private func arcDefaultDirectory(logins: Bool) -> String {
        guard logins else { return library.settings.arcDefaultProfile ?? "Default" }
        return AppPaths.unusedProfileDirectory(besides: Set(library.profiles.map(\.id)))
    }

    /// "Alles übernehmen": every space, favorites and, after the keychain
    /// step, the logins.
    func importEverything() {
        model.chosenSpaces = Set(model.preview?.spaces.map(\.id) ?? [])
        model.includeFavorites = true
        model.choice = .everything
        startImport()
    }

    /// "Auswählen" › "Übernehmen": the spaces ticked.
    func importChosen() {
        guard !model.chosenSpaces.isEmpty else { return NSSound.beep() }
        model.choice = .chosen
        model.choosing = false
        startImport()
    }

    func startFresh() {
        model.choice = .fresh
        model.choosing = false
        go(.accounts)
    }

    func importOther(_ source: OnboardingImportSources.Source) {
        do {
            applySidebar(try source.load())
            model.choice = .other
            go(.accounts)
        } catch {
            model.arcError = error.localizedDescription
        }
    }

    private func startImport() {
        let logins = model.loginsAvailable && model.includeLogins && model.choice != nil
        let directory = arcDefaultDirectory(logins: logins)
        guard var data = try? ArcImporter.load(from: arc.sidebar, currentProfiles: currentProfiles,
                                               defaultDirectory: directory).0 else { return }
        data.spaces = chosen(data.spaces)
        if !model.includeFavorites {
            data.profiles = data.profiles.map { ProfileData(id: $0.id, name: $0.name, favorites: []) }
        }
        let used = Set(data.spaces.map(\.profileID))
        data.profiles = data.profiles.filter { used.contains($0.id) }
        if logins, used.contains(directory) {
            // The sidebar waits for the logins: nothing may open Arc's
            // profile before they are there.
            pending = (data, directory)
            go(.logins)
        } else {
            applySidebar(data)
            go(.accounts)
        }
    }

    /// The spaces ticked in the preview, by position: a space whose Arc ID
    /// is no UUID gets a new one each time Arc's sidebar is read.
    private func chosen(_ spaces: [SpaceData]) -> [SpaceData] {
        let ticked = (model.preview?.spaces ?? []).map { model.chosenSpaces.contains($0.id) }
        return spaces.enumerated().filter { $0.offset < ticked.count && ticked[$0.offset] }.map(\.element)
    }

    private func applySidebar(_ data: LibraryData) {
        guard let browser = app.mainBrowser, !data.spaces.isEmpty else { return }
        for other in app.browsers where other !== browser { other.window?.performClose(nil) }
        if mode == .rerun { library.backUp(before: "Arc-Import") }
        browser.prepareForLibraryReplacement()
        library.replace(with: data)
        if !arc.isFixture { ArcFavicons.importIcons(for: ArcFavicons.urls(in: library)) }
        browser.libraryWasReplaced()
        library.save()
        model.sidebarImported = true
    }

    /// The keychain step's "Weiter": macOS asks for "Arc Safe Storage" right
    /// away, then the profile is copied and its values encrypted again,
    /// in the background, while the next steps go on.
    func startLogins() {
        guard let directory = pending?.directory, let source = arc.profile else { return go(.accounts) }
        if arc.key == nil, !app.quitArcIfNeeded() { return }
        let target = AppPaths.chromiumData.appendingPathComponent(directory)
        let key = arc.key
        let model = model
        model.progress = .init(label: "Logins aus Arc", value: 0.02)
        Task.detached {
            let result = Result {
                try ArcProfileImport.run(into: target, from: source, key: key, progress: { value, label in
                    Task { @MainActor in
                        if model.progress != nil { model.progress = .init(label: label, value: value) }
                    }
                }, history: { _ in 0 })
            }
            await MainActor.run { self.loginsArrived(result, target: target) }
        }
        go(.accounts)
    }

    /// The keychain step's "Logins überspringen": the sidebar without them.
    func skipLogins() {
        guard pending != nil else { return go(.accounts) }
        pending = nil
        model.includeLogins = false
        startImport()
    }

    private func loginsArrived(_ result: Result<ArcProfileImport.Summary, Error>, target: URL) {
        guard let (data, directory) = pending else { return }
        pending = nil
        switch result {
        case .success(var summary):
            summary.historyEntries = app.history.importChromiumHistory(from: target.appendingPathComponent("History"))
            model.loginsResult = summary.text
            applySidebar(data)
            library.settings.arcDefaultProfile = directory
            library.setNeedsSave()
        case .failure(let error):
            model.loginsFailed = error.localizedDescription
            model.includeLogins = false
            // The sidebar still comes, on Arc's profile as before.
            if var plain = try? ArcImporter.load(from: arc.sidebar, currentProfiles: currentProfiles,
                                                 defaultDirectory: arcDefaultDirectory(logins: false)).0 {
                plain.spaces = chosen(plain.spaces)
                let used = Set(plain.spaces.map(\.profileID))
                plain.profiles = plain.profiles.filter { used.contains($0.id) }
                applySidebar(plain)
            }
        }
        model.progress = nil
        if model.step == .accounts { readAccounts() }
    }

    // MARK: Accounts

    /// The profiles the spaces use, in the order of their first space.
    var profilesInUse: [Profile] {
        var seen = Set<String>()
        return library.spaces.compactMap { space in
            seen.insert(space.profileID).inserted ? library.profile(id: space.profileID) : nil
        }
    }

    func readAccounts(force: Bool = false) {
        guard !model.importRunning else { return }
        for profile in profilesInUse where force || model.accounts[profile.id] == nil
            || model.accounts[profile.id] == .unknown {
            model.accounts[profile.id] = .searching
            OnboardingGoogleAccounts.read(profile) { [weak self] accounts in
                self?.model.accounts[profile.id] = accounts.map { .found($0) } ?? .unknown
            }
        }
    }

    func signIn(_ profile: Profile) {
        signIn?.close()
        let window = GoogleSignInWindow(profile: profile, over: self.window)
        window.onClose = { [weak self] in
            self?.signIn = nil
            self?.model.accounts[profile.id] = nil
            self?.readAccounts()
        }
        signIn = window
    }

    // MARK: Appearance

    /// The real window shows behind this one and takes the colors live.
    private func showBrowserBehind() {
        guard let browser = app.mainBrowser, let browserWindow = browser.window else { return }
        if !browserWindow.isVisible {
            browserWindow.order(.below, relativeTo: window.windowNumber)
            browser.layoutContent()
        }
    }

    func focus(_ space: Space) {
        guard let browser = app.mainBrowser else { return }
        if browser.state.space !== space { browser.switchSpace(to: space) }
    }

    func setColor(_ hex: String, of space: Space) {
        space.colorHex = hex
        focus(space)
        library.setNeedsSave()
    }

    func setAppearance(_ appearance: AppAppearance) {
        library.settings.appearance = appearance
        appearance.apply()
        library.setNeedsSave()
    }

    // MARK: Default browser

    func makeDefaultBrowser() {
        DefaultBrowser.makeDefault { [weak self] _ in self?.go(.done) }
    }

    // MARK: Finishing

    /// The window grows into the browser window and fades.
    func finish() {
        guard !finished else { return }
        finished = true
        revealTimer?.invalidate()
        signIn?.close()
        library.settings.onboardingPending = false
        library.save()
        if !AppPaths.isSelfTest {
            // The questions of the time before the onboarding stay away.
            UserDefaults.standard.set(true, forKey: "didOfferArcImport")
            UserDefaults.standard.set(true, forKey: "didOfferDefaultBrowser")
        }
        guard let browser = app.mainBrowser, let target = browser.window else { return close() }
        if !target.isVisible { target.order(.below, relativeTo: window.windowNumber) }
        browser.layoutContent()
        let window = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target.frame, display: true)
            window.animator().alphaValue = 0
        }
        // Not the animation's completion: it never comes while the display sleeps.
        after(0.5) { [weak self] in
            self?.close()
            if AppPaths.isSelfTest { browser.layoutContent() } else { browser.showWindow(nil) }
        }
    }

    private func close() {
        finished = true
        revealTimer?.invalidate()
        signIn?.close()
        window.orderOut(nil)
        app.onboardingDidEnd(self)
        onFinish?()
        onFinish = nil
    }
}

/// The onboarding's window: no title bar, no window buttons, large corners
/// and a shadow, dragged by its background.
final class OnboardingWindow: NSWindow {
    var onEscape: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "Willkommen bei OpenArch"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
