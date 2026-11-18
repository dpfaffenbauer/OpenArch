import AppKit
import OpenArchCore
import OpenArchProtectedVideo

/// Netflix and Disney+ in a Chromium page, played with Apple's FairPlay
/// (Settings › Allgemein › Geschützte Inhalte › „Streamingdienste in
/// Chromium abspielen“; Spotify's music is FairPlay.swift).
///
/// The three parts: protected-video.js in the built-in extension makes the
/// page look like Safari to the site's player and hands over what the
/// player appends to its MediaSource and asks of its key system;
/// OpenArchProtectedVideo (Objective-C++, adapted from Ardia) decodes and
/// draws that with Apple's sample-buffer player in a view over the page's
/// <video>, with a copy of the site's controls on top; and this class
/// carries the messages between them and knows where the page is in the
/// window.
///
/// From the page: megabytes of video a second do not go through the
/// console. The page's script keeps its messages in a queue and says
/// "nudge" through the console when the first one waits; OpenArch then
/// fetches the queue with the DevTools protocol (Runtime.evaluate, which
/// the bridge already has), telling how far it got, until it is empty. To
/// the page: an "openarch-pv" DOM event.
@MainActor
final class ProtectedVideo {
    static let shared = ProtectedVideo()

    static let marker = "__openarch_pv__ "
    /// The pages protected-video.js runs in. Their entries in the WebKit
    /// list: ProtectedMediaSites.inChromiumGroups.
    static let origins: Set<String> = ["https://www.netflix.com", "https://www.disneyplus.com"]
    /// The self-test's page: its origin, served like the services'.
    static var testOrigins: Set<String> = []

    /// Whether these services stay in Chromium and play here: FairPlay's
    /// setting, and the kill switches `fairPlay` and `fairPlayVideo`.
    static var isOn: Bool {
        FairPlay.isEnabled && FeatureSwitches.shared.isOn(.fairPlay) && FeatureSwitches.shared.isOn(.fairPlayVideo)
    }

    /// Netflix picks its player by the user agent of the requests
    /// themselves, which only an extension with declarativeNetRequest can
    /// change. That permission sends every page's requests through
    /// Chromium's web request proxy, so the extension that has it
    /// (OptionalExtensions/safari-user-agent) is not part of the built-in
    /// one: main.swift loads it at launch, only while the setting is on.
    /// Until the launch after the setting was turned on, Netflix keeps
    /// Safari's engine.
    static var safariUserAgentLoaded = false

    static var playsNetflix: Bool { isOn && safariUserAgentLoaded }

    private static let netflix = "https://www.netflix.com"

    /// Whether a page of |origin| plays here.
    static func isOn(for origin: String) -> Bool {
        origin == netflix ? playsNetflix : isOn
    }

    /// Whether the setting was on when OpenArch was last quit (Library.json;
    /// read at launch, before the library is), and no kill switch of this
    /// Mac is against it.
    static func wasOnAtLaunch() -> Bool {
        let library = AppPaths.support.appendingPathComponent("Library.json")
        let settings = (try? Data(contentsOf: library))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["settings"] as? [String: Any]
        return settings?["fairPlayInChromium"] as? Bool == true
            && FeatureSwitches.shared.isOn(.fairPlay) && FeatureSwitches.shared.isOn(.fairPlayVideo)
    }

    static func serves(_ origin: String) -> Bool {
        origins.contains(origin) || testOrigins.contains(origin)
    }

    /// One page that plays, or may: what OpenArchProtectedVideo asks of it,
    /// and how far its queue has been fetched.
    private final class Page: NSObject, OAPVPage {
        weak var pane: (any OACPage)?
        var origin: String
        /// The document the messages come from (its script's name for it).
        var document = ""
        /// How much was fetched, in characters (the self-test measures).
        var received = 0
        /// The last message fetched, and whether a fetch is on its way.
        var fetched = 0
        var isFetching = false
        var lastFetch = Date.distantPast
        var isGone = false
        /// The page's viewport in CSS pixels and its devicePixelRatio, which
        /// tell its view from DevTools docked beside it.
        var viewport: (width: Double, height: Double, scale: Double)?

        init(pane: any OACPage, origin: String) {
            self.pane = pane
            self.origin = origin
        }

        private var host: FairPlayHost? { pane?.delegate as? FairPlayHost }

        var isClosed: Bool { isGone || pane?.isLoaded != true }

        var isMuted: Bool { pane.map { host?.fairPlayIsMuted($0) ?? false } ?? false }

        func deliver(_ kind: String, json: String) {
            guard !isClosed, kind == "protectedVideo" || kind == "videoMirror" else { return }
            pane?.executeJavaScript(
                "document.dispatchEvent(new CustomEvent('openarch-pv', {detail: {kind: '\(kind)', message: \(json)}}))")
        }

        func playingChanged() {
            guard let pane else { return }
            host?.fairPlay(pane, isPlaying: OAProtectedVideo.plays(self))
        }

        func report(_ payload: [String: Any]) {
            guard let pane, payload["event"] as? String == "failed" else { return }
            log("Protected video: did not play (\(payload["step"] as? String ?? "playback"))")
            host?.fairPlayFailed(pane)
        }

        func backToTab() {
            if let pane { host?.fairPlayBackToTab(pane) }
        }

        /// The page's view: the bridge does not hand it out, so it is the
        /// Chromium page view at the pane's place on screen. That is in the
        /// window that shows the pane or, while the page is full screen, in
        /// the window of its own that the engine gives it then.
        var pageView: NSView? {
            guard let pane = pane as? OACPane, pane.isVisible, let host = pane.window else { return nil }
            let place = pane.screenFrame
            guard !place.isEmpty else { return nil }
            func onScreen(_ view: NSView) -> NSRect {
                view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } ?? .zero
            }
            func pageViews(in window: NSWindow) -> [NSView] {
                (window.contentView?.subviews ?? []).filter {
                    !$0.isHidden && NSStringFromClass(type(of: $0)).contains("WebContentsView")
                }
            }
            // Full screen (or on its way there or back): a plain window for
            // the page alone, which the page fills. Of two such windows on
            // one screen, the one with the page's title.
            let own = NSApp.windows.filter { window in
                window !== host && window.isVisible && window.windowController == nil && type(of: window) == NSWindow.self
                    && window.collectionBehavior.contains(.fullScreenPrimary)
            }.compactMap { window in
                pageViews(in: window).first { Self.near(onScreen($0), place) }
            }
            if let view = own.first(where: { $0.window?.title == pane.title }) ?? own.first { return view }
            // In the window that shows the pane. Its place is the page with
            // OpenArch's toolbar; with DevTools or a side panel docked beside
            // the page, the page is the view of the viewport's size (else
            // the lowest: Chrome's other views lie above it).
            let inPlace = pageViews(in: host).filter { place.insetBy(dx: -1, dy: -1).contains(onScreen($0)) }
            guard inPlace.count > 1, let viewport, viewport.scale > 0 else { return inPlace.first }
            let points = viewport.scale / (host.backingScaleFactor > 0 ? host.backingScaleFactor : 2)
            return inPlace.first {
                abs($0.frame.width - viewport.width * points) < 2 && abs($0.frame.height - viewport.height * points) < 2
            } ?? inPlace.first
        }

        private static func near(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
        }
    }

    private var pages: [ObjectIdentifier: Page] = [:]
    private var watchdog: Timer?

    private init() {
        OAVideoMirror.applierSource = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("ProtectedVideo/video_mirror.js") }
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        // OPENARCH_FAIRPLAY_TRACE=1: what the player does goes to the log.
        OAProtectedVideo.traces = FairPlay.traces
        OAVideoMirror.traces = FairPlay.traces
        // A kill switch that goes off while a film plays: the film stops,
        // and its page offers Safari's engine.
        NotificationCenter.default.addObserver(forName: FeatureSwitches.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !ProtectedVideo.isOn else { return }
                let shared = ProtectedVideo.shared
                for page in shared.pages.values where OAProtectedVideo.isActive(page) {
                    if let pane = page.pane { (pane.delegate as? FairPlayHost)?.fairPlayFailed(pane) }
                }
                shared.switchedOff()
            }
        }
    }

    /// Whether the player plays |pane|'s video right now.
    func isPlaying(in pane: any OACPage) -> Bool {
        pages[ObjectIdentifier(pane)].map { OAProtectedVideo.plays($0) } ?? false
    }

    /// The self-test: how many characters were fetched from |pane|.
    func received(from pane: any OACPage) -> Int {
        pages[ObjectIdentifier(pane)]?.received ?? 0
    }

    /// The self-test: how many frames Apple's player has shown for |pane|.
    func shownFrames(in pane: any OACPage) -> Int {
        pages[ObjectIdentifier(pane)].map { OAProtectedVideo.shownFrames($0) } ?? 0
    }

    // MARK: From the page

    /// A page's console message: true when it was protected-video.js's or
    /// its relay's.
    func receive(_ message: String, from pane: any OACPage) -> Bool {
        guard message.hasPrefix(Self.marker) else { return false }
        guard pane.engine == .chromium, let origin = FairPlay.origin(of: pane.url), Self.serves(origin) else { return true }
        switch message.dropFirst(Self.marker.count) {
        case "hello":
            // The extension's relay asks whether the setting is on.
            let answer = Self.isOn(for: origin) ? "on" : "off"
            pane.executeJavaScript("document.dispatchEvent(new CustomEvent('openarch-pv-config', {detail: '\(answer)'}))")
        case "start":
            // A new document with protected-video.js in it.
            forget(pane)
            _ = page(for: pane, origin: origin)
        case "nudge":
            if let page = page(for: pane, origin: origin) { fetch(page) }
        default:
            break
        }
        return true
    }

    /// What OpenArch keeps for |pane|, made on its first message.
    private func page(for pane: any OACPage, origin: String) -> Page? {
        if let page = pages[ObjectIdentifier(pane)], page.origin == origin { return page }
        forget(pane)
        guard Self.isOn(for: origin) else { return nil }
        let page = Page(pane: pane, origin: origin)
        pages[ObjectIdentifier(pane)] = page
        startWatchdog()
        return page
    }

    /// Fetches what waits in the page's queue, and again while there is
    /// more.
    private func fetch(_ page: Page) {
        guard !page.isFetching, !page.isGone, let pane = page.pane, Self.isOn(for: page.origin) else { return }
        page.isFetching = true
        page.lastFetch = Date()
        let expression = "(() => { const d = { ack: \(page.fetched), doc: '\(page.document)' }; "
            + "document.dispatchEvent(new CustomEvent('openarch-pv-take', { detail: d })); return d.out || ''; })()"
        pane.callDevToolsMethod("Runtime.evaluate", params: ["expression": expression, "returnByValue": true]) { [weak self, weak page] result in
            guard let self, let page, !page.isGone else { return }
            page.isFetching = false
            guard let text = (result?["result"] as? [String: Any])?["value"] as? String, !text.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                  let batch = object as? [String: Any], let from = batch["from"] as? Int,
                  let messages = batch["messages"] as? [[String: Any]],
                  let document = batch["doc"] as? String, document.count <= 32,
                  document.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return }
            if document != page.document {
                // Another document in the tab (its "start" did not arrive):
                // what played for the one before is over.
                if !page.document.isEmpty {
                    OAProtectedVideo.pageGone(page)
                    OAVideoMirror.pageGone(page)
                }
                page.document = document
            }
            page.received += text.utf16.count
            if let viewport = batch["viewport"] as? [Double], viewport.count == 3 {
                page.viewport = (viewport[0], viewport[1], viewport[2])
            }
            page.fetched = from + messages.count - 1
            for message in messages {
                guard !page.isGone, let data = message["data"] as? [String: Any] else { continue }
                switch message["kind"] as? String {
                case "protectedVideo": OAProtectedVideo.page(page, message: data)
                case "videoMirror": OAVideoMirror.page(page, origin: page.origin, message: data)
                default: break
                }
            }
            // An empty answer tells the page that OpenArch waits for a nudge.
            if !messages.isEmpty { self.fetch(page) }
        }
    }

    /// A nudge or an answer can get lost (the DevTools session reattaches):
    /// once a second, a page that was not fetched from is.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ProtectedVideo.shared.checkPages() }
        }
    }

    private func checkPages() {
        for (key, page) in pages {
            guard let pane = page.pane, pane.isLoaded, FairPlay.origin(of: pane.url) == page.origin else {
                // The page closed, or went somewhere else in its tab.
                close(page)
                pages[key] = nil
                continue
            }
            if page.isFetching, Date().timeIntervalSince(page.lastFetch) > 5 { page.isFetching = false }
            if !page.isFetching, Date().timeIntervalSince(page.lastFetch) >= 1 { fetch(page) }
        }
        if pages.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
        }
    }

    // MARK: From the app

    /// |pane| closes or its tab goes to sleep.
    func pageGone(_ pane: any OACPage) {
        forget(pane)
    }

    /// The tab's speaker was switched.
    func muteChanged(in pane: any OACPage) {
        if let page = pages[ObjectIdentifier(pane)] { OAProtectedVideo.muteChanged(page) }
    }

    /// The setting or a kill switch went off: every video stops.
    func switchedOff() {
        for page in pages.values { close(page) }
        pages.removeAll()
    }

    private func forget(_ pane: any OACPage) {
        guard let page = pages.removeValue(forKey: ObjectIdentifier(pane)) else { return }
        close(page)
    }

    private func close(_ page: Page) {
        let wasPlaying = OAProtectedVideo.plays(page)
        OAProtectedVideo.pageGone(page)
        OAVideoMirror.pageGone(page)
        if wasPlaying, let pane = page.pane { (pane.delegate as? FairPlayHost)?.fairPlay(pane, isPlaying: false) }
        page.isGone = true
    }
}
