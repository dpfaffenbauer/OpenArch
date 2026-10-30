import OpenArchShared
import UIKit
import WebKit

/// A tab's page: a WKWebView, made when the tab is first shown and closed
/// again when many others were shown since.
@MainActor
final class WebTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) weak var item: Item?
    private weak var browser: Browser?
    private var observations: [NSKeyValueObservation] = []

    init(item: Item, browser: Browser) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.item = item
        self.browser = browser
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        // Pull down to reload, as in Safari.
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak webView, weak refresh] _ in
            webView?.reload()
            refresh?.endRefreshing()
        }, for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        observe()
        if let url = URL(string: item.currentURL), !item.currentURL.isEmpty {
            webView.load(URLRequest(url: url))
        }
    }

    func close() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    func load(_ address: String) {
        guard let url = URL(string: address) else { return }
        webView.load(URLRequest(url: url))
    }

    private func observe() {
        func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>) {
            observations.append(webView.observe(keyPath, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        watch(\.title)
        watch(\.url)
        watch(\.estimatedProgress)
        watch(\.isLoading)
        watch(\.canGoBack)
        watch(\.canGoForward)
    }

    private func update() {
        guard let item else { return }
        if let url = webView.url?.absoluteString, url != item.liveURL, !url.isEmpty {
            item.liveURL = url
            browser?.pageDidChange(item)
        }
        if let title = webView.title, !title.isEmpty, title != item.liveTitle {
            item.liveTitle = title
            browser?.pageDidChange(item)
        }
        if item.progress != webView.estimatedProgress { item.progress = webView.estimatedProgress }
        if item.isLoading != webView.isLoading { item.isLoading = webView.isLoading }
        if item.canGoBack != webView.canGoBack { item.canGoBack = webView.canGoBack }
        if item.canGoForward != webView.canGoForward { item.canGoForward = webView.canGoForward }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        // A share link opens the add sheet, not the web page.
        if ShareURL.isShareURL(url), navigationAction.targetFrame?.isMainFrame != false {
            if let link = ShareURL(url: url) {
                browser?.present(.importShare(link))
                return .cancel
            }
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "blob", "data":
            return .allow
        default:
            // mailto:, tel:, maps: and links to other apps.
            _ = await UIApplication.shared.open(url)
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard item != nil, let host = webView.url?.host(), !host.isEmpty else { return }
        Favicons.shared.learn(from: webView, host: host)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: WKUIDelegate

    /// target=_blank and window.open: a new today tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString {
            browser?.openInNewTab(url)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let item { browser?.close(item) }
    }
}
