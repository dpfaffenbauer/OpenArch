// Parts of this file (the Safari product token, the DevTools methods a
// WebKit page answers itself, the page mute, Web Inspector and the
// picture-in-picture preference) are adapted from Cra's WebKitBrowser.swift
// (https://github.com/VictorKildahl/cra), MIT License, Copyright (c) 2026
// Victor Kildahl. See NOTICE.

import AppKit
import OpenArchLocalization
import CryptoKit
import OpenArchCore
import WebKit

/// A tab's page drawn by the Mac's WebKit, for streaming services that play
/// only with FairPlay (ProtectedMedia). It is a page like OACPane: its own
/// borderless window attached over OpenArch's content area, the same
/// delegate, the same commands, so the sidebar, splits, Peek, Little
/// OpenArch, previews, the media player and sleeping tabs need nothing of
/// their own for it.
@MainActor
final class WebKitPage: NSObject, OACPage {
    weak var delegate: (any OACPaneDelegate)?
    let profile: OACProfile
    var engine: OACPageEngine { .webKit }
    /// "Spotify", for the toast and Site Controls.
    let serviceName: String

    private(set) var url: String
    private(set) var title = ""
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isVisible = false
    var isFullScreen: Bool { webView.map { $0.fullscreenState != .notInFullscreen } ?? false }
    var isLoaded: Bool { webView != nil }
    var window: NSWindow? { hostWindow }

    var toolbarVisible = false
    var activatesOnShow = true
    var cornerRadius: CGFloat = 8 {
        didSet { container?.layer?.cornerRadius = cornerRadius }
    }
    var offersAskAboutSelection = false
    var zoomPercent: Int { Int(((webView?.pageZoom ?? 1) * 100).rounded()) }

    private var hostWindow: WebKitPageWindow?
    private var container: WebKitContainerView?
    private(set) var webView: WebKitPageView?
    private weak var parent: NSWindow?
    private var frame = NSRect.zero
    private var closed = false
    private var observations: [NSKeyValueObservation] = []
    private var messages: WebKitMessages?
    private var popups: [WebKitPopup] = []
    /// The configuration WebKit gave for a popup this page shows.
    private var popupConfiguration: WKWebViewConfiguration?

    init(profile: OACProfile, url: String, serviceName: String = "") {
        self.profile = profile
        self.url = url
        self.serviceName = serviceName
        super.init()
    }

    // MARK: The page and its window

    private func create() {
        guard webView == nil, !closed else { return }
        let configuration = popupConfiguration ?? WKWebViewConfiguration()
        if popupConfiguration == nil {
            configuration.websiteDataStore = WebKitStores.store(for: profile)
        }
        let content = WKUserContentController()
        for script in Self.userScripts { content.addUserScript(script) }
        let messages = WebKitMessages(page: self)
        content.add(messages, contentWorld: Self.world, name: "openarch")
        self.messages = messages
        configuration.userContentController = content
        configuration.preferences.isElementFullscreenEnabled = true
        // Off for apps other than Safari: requestPictureInPicture() would
        // answer NotSupportedError.
        if configuration.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) {
            configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        configuration.applicationNameForUserAgent = Self.safariProduct

        let window = WebKitPageWindow()
        let container = WebKitContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = container
        let web = WebKitPageView(frame: container.bounds, configuration: configuration)
        web.page = self
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.isInspectable = true
        container.webView = web
        container.addSubview(web)
        hostWindow = window
        self.container = container
        webView = web
        WebKitPage.pages.setObject(self, forKey: window)
        observe(web)
        if popupConfiguration == nil, let target = URL(string: url) {
            web.load(URLRequest(url: target))
        }
    }

    /// The page WebKit asked for with window.open: shown in a window of its
    /// own (see WebKitPopup).
    fileprivate func makePopupView(configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView? {
        let popup = WebKitPopup(opener: self, configuration: configuration, features: features)
        popups.append(popup)
        popup.onClose = { [weak self, weak popup] in self?.popups.removeAll { $0 === popup } }
        return popup.webView
    }

    private func observe(_ web: WKWebView) {
        observations = [
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.closed, let title = web.title, !title.isEmpty else { return }
                    self.title = title
                    self.delegate?.pane?(self, titleDidChange: title)
                }
            },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.closed, let url = web.url?.absoluteString else { return }
                    self.url = url
                    self.delegate?.pane?(self, addressDidChange: url)
                }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportLoading() }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportLoading() }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reportLoading() }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.closed, web.isLoading else { return }
                    self.delegate?.pane?(self, loadingProgressDidChange: web.estimatedProgress)
                }
            },
        ]
    }

    private func reportLoading() {
        guard let web = webView, !closed else { return }
        guard (web.isLoading, web.canGoBack, web.canGoForward) != (isLoading, canGoBack, canGoForward) else { return }
        isLoading = web.isLoading
        canGoBack = web.canGoBack
        canGoForward = web.canGoForward
        delegate?.pane?(self, loadingStateDidChange: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    func load() {
        create()
    }

    func show(in window: NSWindow, frame: NSRect) {
        parent = window
        self.frame = frame
        guard !closed else { return }
        create()
        guard let hostWindow else { return }
        hostWindow.setFrame(window.convertToScreen(frame), display: false)
        if hostWindow.parent !== window {
            hostWindow.parent?.removeChildWindow(hostWindow)
            window.addChildWindow(hostWindow, ordered: .above)
        }
        if !isVisible {
            hostWindow.order(.above, relativeTo: window.windowNumber)
            isVisible = true
        }
    }

    func setFrame(_ frame: NSRect) {
        self.frame = frame
        guard isVisible, let parent, let hostWindow else { return }
        hostWindow.setFrame(parent.convertToScreen(frame), display: true)
        // Hiding the parent window detaches its child windows; attach again.
        if hostWindow.parent !== parent, parent.isVisible {
            parent.addChildWindow(hostWindow, ordered: .above)
            hostWindow.order(.above, relativeTo: parent.windowNumber)
        }
    }

    func hide() {
        guard isVisible, let hostWindow else { return }
        isVisible = false
        hostWindow.parent?.removeChildWindow(hostWindow)
        hostWindow.orderOut(nil)
    }

    func focus() {
        guard let hostWindow, let webView, isVisible else { return }
        if activatesOnShow { NSApp.activate() }
        hostWindow.makeKey()
        hostWindow.makeFirstResponder(webView)
    }

    func orderFront() {
        guard let hostWindow, let parent = hostWindow.parent else { return }
        parent.removeChildWindow(hostWindow)
        parent.addChildWindow(hostWindow, ordered: .above)
    }

    func close() {
        guard !closed else { return }
        closed = true
        observations.forEach { $0.invalidate() }
        observations = []
        for popup in popups { popup.close() }
        popups = []
        if let web = webView {
            web.closeAllMediaPresentations {}
            web.pauseAllMediaPlayback()
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.userContentController.removeAllScriptMessageHandlers()
            web.page = nil
            web.removeFromSuperview()
        }
        webView = nil
        hide()
        hostWindow?.contentView = nil
        hostWindow = nil
        // As with Chromium, the delegate hears of it a moment later.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { delegate?.paneDidClose?(self) }
        }
    }

    fileprivate func didBecomeActive() {
        delegate?.paneDidBecomeActive?(self)
    }

    // MARK: Navigation and scripts

    func loadURL(_ url: String) {
        self.url = url
        guard let web = webView else { return }
        guard let target = URL(string: url) ?? URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        else { return }
        web.load(URLRequest(url: target))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }

    func executeJavaScript(_ script: String) {
        webView?.evaluateJavaScript(script, in: nil, in: .page) { _ in }
    }

    /// WebKit's evaluateJavaScript always counts as a user gesture, so
    /// play() and requestPictureInPicture() are allowed.
    func executeJavaScript(_ script: String, userGesture: Bool) {
        executeJavaScript(script)
    }

    func checkAsksBeforeLeaving(_ completion: @escaping (Bool) -> Void) {
        guard let web = webView else { return completion(false) }
        web.evaluateJavaScript("typeof window.onbeforeunload === 'function' || window.__openarchBeforeUnload === true",
                               in: nil, in: .page) { result in
            completion((try? result.get()) as? Bool ?? true)
        }
    }

    func callDevToolsMethod(_ method: String, params: [String: Any],
                            completion: (([String: Any]?) -> Void)? = nil) {
        let reply: ([String: Any]?) -> Void = { result in
            DispatchQueue.main.async { completion?(result) }
        }
        guard let web = webView, !closed else { return reply(nil) }
        switch method {
        case "Runtime.evaluate":
            guard let expression = params["expression"] as? String else { return reply(nil) }
            let done: (Result<Any, Error>) -> Void = { result in reply(Self.evaluationResult(result)) }
            if params["awaitPromise"] as? Bool == true {
                web.callAsyncJavaScript("return await (\n\(expression)\n);", arguments: [:], in: nil, in: .page,
                                        completionHandler: done)
            } else {
                web.evaluateJavaScript(expression, in: nil, in: .page, completionHandler: done)
            }
        case "Page.getLayoutMetrics":
            let script = """
                (() => { const e = document.documentElement, v = window.visualViewport;
                  return JSON.stringify({ cssContentSize: { x: 0, y: 0, width: e.scrollWidth, height: e.scrollHeight },
                    cssVisualViewport: { pageX: 0, pageY: 0, clientWidth: v ? v.width : innerWidth,
                      clientHeight: v ? v.height : innerHeight, scale: v ? v.scale : 1 } }); })()
                """
            web.evaluateJavaScript(script, in: nil, in: Self.world) { result in
                let json = (try? result.get()) as? String
                reply(json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
            }
        case "Page.captureScreenshot":
            let config = WKSnapshotConfiguration()
            if let clip = params["clip"] as? [String: Any] {
                // Our layout metrics report the viewport at 0, 0.
                let width = clip["width"] as? Double ?? Double(web.bounds.width)
                let height = clip["height"] as? Double ?? Double(web.bounds.height)
                config.rect = NSRect(x: 0, y: 0, width: width, height: height)
                if let scale = clip["scale"] as? Double { config.snapshotWidth = NSNumber(value: width * scale) }
            }
            let png = (params["format"] as? String ?? "png") == "png"
            let quality = Double(params["quality"] as? Int ?? 80) / 100
            web.takeSnapshot(with: config) { image, _ in
                guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return reply(nil) }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                let data = png ? rep.representation(using: .png, properties: [:])
                    : rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
                reply(data.map { ["data": $0.base64EncodedString()] })
            }
        case "Storage.clearDataForOrigin":
            guard let origin = params["origin"] as? String, let host = URL(string: origin)?.host()?.lowercased() else {
                return reply(nil)
            }
            let store = web.configuration.websiteDataStore
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            store.fetchDataRecords(ofTypes: types) { records in
                let site = records.filter { record in
                    let name = record.displayName.lowercased()
                    return host == name || host.hasSuffix("." + name)
                }
                store.removeData(ofTypes: types, for: site) { reply([:]) }
            }
        default:
            // Input.*, DOMDebugger.* and the rest are Chromium's.
            reply(nil)
        }
    }

    /// Runtime.evaluate's answer as Chromium gives it.
    private static func evaluationResult(_ result: Result<Any, Error>) -> [String: Any] {
        switch result {
        case .success(let value):
            switch value {
            case is NSNull: return ["result": ["type": "object", "subtype": "null", "value": NSNull()]]
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                return ["result": ["type": "boolean", "value": number.boolValue]]
            case let number as NSNumber: return ["result": ["type": "number", "value": number]]
            case let string as String: return ["result": ["type": "string", "value": string]]
            default: return ["result": ["type": "object", "value": value]]
            }
        case .failure(let error):
            let error = error as NSError
            if error.domain == WKErrorDomain, error.code == WKError.javaScriptResultTypeIsUnsupported.rawValue {
                return ["result": ["type": "undefined"]]
            }
            let text = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            return ["exceptionDetails": ["text": text]]
        }
    }

    // MARK: Commands

    func executeChromeCommand(_ commandID: Int) {
        guard let web = webView else { return }
        switch OACChromeCommand(rawValue: commandID) {
        case .back: web.goBack()
        case .forward: web.goForward()
        case .reload: web.reload()
        case .reloadBypassingCache: web.reloadFromOrigin()
        case .stop: web.stopLoading()
        case .find: find(forward: nil)
        case .findNext: find(forward: true)
        case .findPrevious: find(forward: false)
        case .zoomPlus: web.pageZoom = Self.zoomSteps.first { $0 > web.pageZoom + 0.001 } ?? web.pageZoom
        case .zoomMinus: web.pageZoom = Self.zoomSteps.last { $0 < web.pageZoom - 0.001 } ?? web.pageZoom
        case .zoomNormal: web.pageZoom = 1
        case .print: print()
        case .devTools, .devToolsConsole, .devToolsInspect, .devToolsToggle: showDevTools()
        default:
            // Chrome's own commands (its menus, its pages) have nothing to
            // run on a WebKit page; OpenArch's go to the delegate as Chrome's do.
            _ = delegate?.pane?(self, handleChromeCommand: commandID)
        }
    }

    /// Chrome's zoom levels.
    private static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    /// A find bar over the page, with the number of matches, as Chrome's.
    private func find(forward: Bool?) {
        guard let container else { return }
        let bar = container.findBar
        if forward == nil || !container.isFindBarVisible {
            bar.onSearch = { [weak self] text, forward, again in self?.search(text, forward: forward, again: again) }
            bar.onClose = { [weak self] in self?.endFind() }
            container.isFindBarVisible = true
            bar.focus()
        }
        if let forward, !bar.text.isEmpty { search(bar.text, forward: forward, again: true) }
    }

    private var findQuery = ""
    private var findCount = 0
    private var findIndex = 0

    private func search(_ text: String, forward: Bool, again: Bool) {
        guard let web = webView, let bar = container?.findBar else { return }
        guard !text.isEmpty else {
            findQuery = ""
            bar.show(matches: 0, active: 0, empty: true)
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        let fresh = !again || text != findQuery
        findQuery = text
        web.find(text, configuration: configuration) { [weak self] result in
            guard let self else { return }
            guard result.matchFound else {
                self.findCount = 0
                self.findIndex = 0
                bar.show(matches: 0, active: 0, empty: false)
                return
            }
            let step = { (count: Int) in
                self.findCount = max(count, 1)
                if fresh {
                    self.findIndex = forward ? 1 : self.findCount
                } else {
                    self.findIndex = forward ? self.findIndex % self.findCount + 1
                        : (self.findIndex + self.findCount - 2) % self.findCount + 1
                }
                bar.show(matches: self.findCount, active: self.findIndex, empty: false)
            }
            if !fresh, self.findCount > 0 { return step(self.findCount) }
            // WebKit's find does not count: the page's text does.
            web.callAsyncJavaScript(Self.countMatches, arguments: ["q": text], in: nil, in: Self.world) { result in
                step((try? result.get()) as? Int ?? 1)
            }
        }
    }

    private static let countMatches = """
        const t = (document.body ? document.body.innerText : '').toLowerCase(), b = q.toLowerCase();
        let n = 0, i = 0;
        while (b && (i = t.indexOf(b, i)) !== -1) { n++; i += b.length; }
        return n;
        """

    /// Self-test: searches as if typed into the find bar.
    func findForTesting(_ text: String) { search(text, forward: true, again: false) }
    var findMatchCount: Int { findCount }

    private func endFind() {
        container?.isFindBarVisible = false
        findQuery = ""
        findCount = 0
        webView?.evaluateJavaScript("getSelection().removeAllRanges()", in: nil, in: Self.world) { _ in }
        focus()
    }

    /// Whether the find bar shows (self-test).
    var isFindBarVisible: Bool { container?.isFindBarVisible ?? false }

    private func print() {
        guard let web = webView, let window = hostWindow?.parent ?? hostWindow else { return }
        let operation = web.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = web.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// WebKit's Web Inspector, in a window of its own (Chrome's DevTools
    /// are Chromium's). Right-click › Element-Informationen opens it too.
    func showDevTools() {
        guard let web = webView, web.responds(to: NSSelectorFromString("_inspector")),
              let inspector = web.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else { return }
        inspector.perform(NSSelectorFromString("show"))
    }

    func closeDevTools() -> Bool { false }

    /// WebKit's page mute (Safari's tab mute), else every media element.
    func setAudioMuted(_ muted: Bool) {
        guard let web = webView else { return }
        let selector = NSSelectorFromString("_setPageMuted:")
        if let method = class_getInstanceMethod(type(of: web), selector) {
            typealias Function = @convention(c) (AnyObject, Selector, UInt) -> Void
            unsafeBitCast(method_getImplementation(method), to: Function.self)(web, selector, muted ? 1 : 0)
        } else {
            executeJavaScript("document.querySelectorAll('video, audio').forEach((m) => { m.muted = \(muted); })")
        }
    }

    // MARK: Scripts and messages

    /// OpenArch's own world, where media.js runs as it runs in Chrome's
    /// isolated world (the built-in extension).
    static let world = WKContentWorld.world(name: "openarch")

    /// The built-in extension's media scripts, as user scripts: the sidebar's
    /// player and picture-in-picture work as on Chromium pages.
    private static let userScripts: [WKUserScript] = {
        func file(_ name: String) -> String {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("BuiltinExtensions/openarch/\(name)") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        // Reports go through console.debug in Chrome; here to OpenArch's handler.
        let console = """
            (() => { const debug = console.debug.bind(console);
              console.debug = (...args) => { const text = args.map(String).join(' ');
                if (text.startsWith('__openarch_')) window.webkit.messageHandlers.openarch.postMessage(text); else debug(...args); };
            })();
            """
        // Pages that ask before they are left stay awake (sleeping tabs).
        let beforeUnload = """
            (() => { const add = EventTarget.prototype.addEventListener;
              EventTarget.prototype.addEventListener = new Proxy(add, { apply(target, self, args) {
                if (self === window && args[0] === 'beforeunload')
                  Object.defineProperty(window, '__openarchBeforeUnload', { value: true, configurable: true });
                return Reflect.apply(target, self, args); } });
            })();
            """
        return [
            WKUserScript(source: beforeUnload + file("media-session.js"), injectionTime: .atDocumentStart,
                         forMainFrameOnly: true, in: .page),
            WKUserScript(source: console + file("media.js"), injectionTime: .atDocumentStart,
                         forMainFrameOnly: true, in: world),
        ]
    }()

    fileprivate func receive(_ message: String) {
        guard !closed else { return }
        delegate?.pane?(self, consoleMessage: message, source: url, line: 0)
    }

    /// Safari's own product token, so the services see Safari and pick
    /// FairPlay. Safari's version is this Mac's.
    static let safariProduct: String = {
        let paths = ["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        let version = paths.lazy.compactMap { Bundle(path: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }.first
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let parts = (version ?? "\(os.majorVersion).0").split(separator: ".")
        return "Version/\(parts.prefix(2).joined(separator: ".")) Safari/605.1.15"
    }()

    /// The page whose window this is.
    static func page(for window: NSWindow) -> WebKitPage? { pages.object(forKey: window) }
    private static let pages = NSMapTable<NSWindow, WebKitPage>.weakToWeakObjects()

    // MARK: Favicon

    /// The page's icon (the largest it declares, else /favicon.ico), fetched
    /// through Chromium's network stack: URLSession is unreliable in a
    /// process that runs Chromium.
    private func loadFavicon() {
        let script = """
            (() => { const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')];
              const size = (l) => Math.max(0, ...(l.getAttribute('sizes') || '').split(/\\s+/).map((s) => parseInt(s, 10) || 0));
              links.sort((a, b) => size(b) - size(a));
              const plain = links.filter((l) => !/\\.svg(\\?|$)/i.test(l.href));
              return (plain[0] || links[0])?.href || new URL('/favicon.ico', location.href).href; })()
            """
        webView?.evaluateJavaScript(script, in: nil, in: Self.world) { [weak self] result in
            guard let self, let href = (try? result.get()) as? String, href.hasPrefix("http") else { return }
            self.profile.fetchURL(href) { [weak self] data, _ in
                guard let self, !self.closed, let data, let image = NSImage(data: data), image.size.width > 0 else { return }
                image.size = NSSize(width: 16, height: 16)
                self.favicon = image
                self.delegate?.pane?(self, faviconDidChange: image)
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebKitPage: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if action.shouldPerformDownload { return decisionHandler(.download, preferences) }
        guard let url = action.request.url else { return decisionHandler(.allow, preferences) }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "file" { return decisionHandler(.cancel, preferences) }
        if !["http", "https", "about", "blob", "data"].contains(scheme) {
            // spotify:, zoommtg: … belong to an app on the Mac.
            delegate?.pane?(self, wantsToOpenExternalURL: url.absoluteString)
            return decisionHandler(.cancel, preferences)
        }
        guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true else {
            return decisionHandler(.allow, preferences)
        }
        let modifiers = action.modifierFlags
        if modifiers.contains(.command) || action.buttonNumber == 2 {
            delegate?.pane?(self, wantsNewTabWithURL: url.absoluteString, background: !modifiers.contains(.shift))
            return decisionHandler(.cancel, preferences)
        }
        // Peek, for pinned tabs and favorites.
        if delegate?.pane?(self, shouldInterceptNavigationToURL: url.absoluteString) == true {
            return decisionHandler(.cancel, preferences)
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        let attachment = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment")
        decisionHandler(attachment || !response.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        delegate?.pane?(self, mainFrameLoadStarted: true, url: webView.url?.absoluteString ?? url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        delegate?.pane?(self, mainFrameLoadStarted: false, url: webView.url?.absoluteString ?? url)
        loadFavicon()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("WebKit page process ended (\(URL(string: url)?.host() ?? "")), reloading")
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        WebKitDownloads.shared.take(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        WebKitDownloads.shared.take(download)
    }
}

// MARK: - WKUIDelegate

extension WebKitPage: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let target = action.request.url?.absoluteString ?? ""
        // A target=_blank link, or window.open without a size: a tab, as in
        // Chrome. With a size it is a popup and keeps its opener (sign-in
        // windows post back), in WebKit like its opener.
        if action.navigationType == .linkActivated || (windowFeatures.width == nil && windowFeatures.height == nil) {
            let modifiers = action.modifierFlags
            delegate?.pane?(self, wantsNewTabWithURL: target,
                            background: modifiers.contains(.command) && !modifiers.contains(.shift))
            return nil
        }
        return makePopupView(configuration: configuration, features: windowFeatures)
    }

    /// window.close(): the tab goes, as in Chrome.
    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        runAlert(message, frame: frame, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        runAlert(message, frame: frame, buttons: ["OK", "Abbrechen"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        runAlert(prompt, frame: frame, buttons: ["OK", "Abbrechen"], accessory: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    private func runAlert(_ message: String, frame: WKFrameInfo, buttons: [String], accessory: NSView? = nil,
                          done: @escaping (NSApplication.ModalResponse) -> Void) {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? L("Diese Seite meldet") : L("%@ meldet", host)
        alert.informativeText = message
        for button in buttons { alert.addButton(withTitle: L(button)) }
        alert.accessoryView = accessory
        guard let window = hostWindow?.parent ?? hostWindow else { return done(.alertSecondButtonReturn) }
        alert.beginSheetModal(for: window, completionHandler: done)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = hostWindow?.parent ?? hostWindow else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// Camera and microphone: WebKit asks, as Safari does.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

// MARK: - Views and windows

/// The page's window: it takes the keyboard but never becomes main, so
/// OpenArch's window keeps its active window buttons (as Chrome's do).
final class WebKitPageWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Holds the web view and, while it shows, the find bar above it.
final class WebKitContainerView: NSView {
    weak var webView: WKWebView?
    let findBar = WebKitFindBar()
    var isFindBarVisible = false {
        didSet {
            if isFindBarVisible, findBar.superview == nil { addSubview(findBar) }
            findBar.isHidden = !isFindBarVisible
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let top: CGFloat = isFindBarVisible ? WebKitFindBar.height : 0
        findBar.frame = NSRect(x: 0, y: bounds.height - WebKitFindBar.height, width: bounds.width, height: WebKitFindBar.height)
        webView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - top))
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        needsLayout = true
    }
}

/// The find bar: a field, the matches ("2 von 7"), up, down and done.
/// Return goes to the next match, ⇧Return to the previous one, Esc closes.
final class WebKitFindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 36
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    var onSearch: ((String, Bool, Bool) -> Void)?
    var onClose: (() -> Void)?
    var text: String { field.stringValue }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        field.placeholderString = L("Auf der Seite suchen")
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Vorheriger Treffer")!,
                                target: self, action: #selector(previous(_:)))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: L("Nächster Treffer"))!,
                            target: self, action: #selector(next(_:)))
        let done = NSButton(title: L("Fertig"), target: self, action: #selector(close(_:)))
        for button in [previous, next] { button.bezelStyle = .accessoryBarAction; button.isBordered = false }
        done.bezelStyle = .accessoryBarAction
        let stack = NSStackView(views: [field, count, previous, next, done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func show(matches: Int, active: Int, empty: Bool) {
        count.stringValue = empty ? "" : matches == 0 ? L("Keine Treffer") : L("%lld von %lld", active, matches)
    }

    @objc private func changed() { onSearch?(field.stringValue, true, false) }
    @objc private func previous(_ sender: Any?) { onSearch?(field.stringValue, false, true) }
    @objc private func next(_ sender: Any?) { onSearch?(field.stringValue, true, true) }
    @objc private func close(_ sender: Any?) { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearch?(field.stringValue, !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false), true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The web view: tells its page when it gets the focus.
final class WebKitPageView: WKWebView {
    weak var page: WebKitPage?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { MainActor.assumeIsolated { page?.didBecomeActive() } }
        return accepted
    }

    /// "Link in neuem Fenster öffnen" opens a tab in OpenArch.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = L("Link in neuem Tab öffnen")
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = L("Bild in neuem Tab öffnen")
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = L("Video in neuem Tab öffnen")
            default: break
            }
        }
    }
}

/// Messages from OpenArch's world (media reports), held weakly: WebKit
/// keeps its handlers.
private final class WebKitMessages: NSObject, WKScriptMessageHandler {
    weak var page: WebKitPage?
    init(page: WebKitPage) { self.page = page }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        MainActor.assumeIsolated { page?.receive(text) }
    }
}

/// A popup a WebKit page opened with window.open and a size (sign-in
/// windows): a small window of its own that keeps window.opener.
@MainActor
private final class WebKitPopup: NSObject, NSWindowDelegate, WKUIDelegate {
    let webView: WKWebView
    private let window: NSWindow
    var onClose: (() -> Void)?

    init(opener: WebKitPage, configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        let width = CGFloat(features.width?.doubleValue ?? 500), height = CGFloat(features.height?.doubleValue ?? 640)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        super.init()
        webView.autoresizingMask = [.width, .height]
        webView.uiDelegate = self
        window.contentView = webView
        window.delegate = self
        if let parent = opener.window?.parent ?? opener.window {
            window.setFrameTopLeftPoint(NSPoint(x: parent.frame.midX - width / 2, y: parent.frame.maxY - 80))
        } else {
            window.center()
        }
        if !AppPaths.isSelfTest { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        webView.uiDelegate = nil
        webView.stopLoading()
        onClose?()
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
    }
}

// MARK: - Data stores

/// WebKit's cookies, storage and cache: one persistent store per OpenArch
/// profile, like Chromium's profile folders, and one in memory per private
/// window. The stores live under ~/Library/WebKit/<bundle id>/
/// WebsiteDataStore/<uuid>; the uuid comes from the data folder and the
/// profile, so the self-test never shares the real ones.
@MainActor
enum WebKitStores {
    private static var persistent: [String: WKWebsiteDataStore] = [:]
    private static let privateStores = NSMapTable<OACProfile, WKWebsiteDataStore>.weakToStrongObjects()

    static func store(for profile: OACProfile) -> WKWebsiteDataStore {
        let name = profile.directoryName
        if name.isEmpty {
            if let store = privateStores.object(forKey: profile) { return store }
            let store = WKWebsiteDataStore.nonPersistent()
            privateStores.setObject(store, forKey: profile)
            return store
        }
        if let store = persistent[name] { return store }
        let store = WKWebsiteDataStore(forIdentifier: identifier(forProfile: name))
        persistent[name] = store
        return store
    }

    /// Deletes a profile's WebKit data (when the profile goes).
    static func removeStore(forProfile name: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        persistent[name] = nil
        WKWebsiteDataStore.remove(forIdentifier: identifier(forProfile: name)) { error in
            if let error { log("could not remove the WebKit data of \(name): \(error.localizedDescription)") }
            MainActor.assumeIsolated { completion?(error == nil) }
        }
    }

    /// A stable name-based UUID for the data folder plus the profile.
    static func identifier(forProfile name: String) -> UUID {
        let digest = SHA256.hash(data: Data("openarch-webkit|\(AppPaths.support.standardizedFileURL.path)|\(name)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Downloads

/// Downloads from WebKit pages: into the Downloads folder (the self-test's
/// own), reported to the sidebar like Chrome's.
@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    static let shared = WebKitDownloads()
    private var running: [ObjectIdentifier: (id: UInt32, download: WKDownload, name: String, path: String,
                                              observation: NSKeyValueObservation?)] = [:]
    private var nextID: UInt32 = 0x7000_0000

    func take(_ download: WKDownload) {
        download.delegate = self
    }

    /// Cancels a running download; NO when none has that id.
    func cancel(_ id: UInt32) -> Bool {
        guard let entry = running.values.first(where: { $0.id == id }) else { return false }
        entry.download.cancel { _ in }
        return true
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = AppPaths.isSelfTest ? SelfTest.downloadFolder
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        var target = folder.appendingPathComponent(name)
        var index = 1
        while FileManager.default.fileExists(atPath: target.path) {
            index += 1
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)")
        }
        nextID &+= 1
        let id = nextID, key = ObjectIdentifier(download), path = target.path, file = target.lastPathComponent
        let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let percent = progress.totalUnitCount > 0 ? Int(progress.fractionCompleted * 100) : -1
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self?.running[key] != nil else { return }
                    Self.report(id, file, path, percent: percent)
                }
            }
        }
        running[key] = (id, download, file, path, observation)
        Self.report(id, file, path, percent: -1)
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, failed: false)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, failed: true)
    }

    private func finish(_ download: WKDownload, failed: Bool) {
        guard let entry = running.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.observation?.invalidate()
        Self.report(entry.id, entry.name, entry.path, percent: failed ? -1 : 100, complete: !failed, failed: failed)
    }

    private static func report(_ id: UInt32, _ name: String, _ path: String, percent: Int,
                               complete: Bool = false, failed: Bool = false) {
        OACDownload.report(OACDownload(identifier: id, fileName: name, path: path, percentComplete: percent,
                                       isComplete: complete, isFailed: failed))
    }
}
