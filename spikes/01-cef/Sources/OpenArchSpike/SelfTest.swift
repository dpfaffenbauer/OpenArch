import AppKit
import OpenArchCore
import SwiftUI

/// `--selftest`: opens three Spaces (Chromium's default profile and two
/// isolated ones), checks profile isolation and which extension APIs reach
/// embedded browsers, logs everything to stdout and quits.
@MainActor
final class SelfTest {
    private let model: BrowserModel
    private var tabs: [(name: String, tab: Tab)] = []
    private var loaded = Set<String>()
    private var running = false

    init(model: BrowserModel) {
        self.model = model
    }

    func start() {
        let spaces: [(String, Color, OACProfile)] = [
            ("Default", .gray, .default),
            ("A", .purple, OACProfile(identifier: "selftest-a")),
            ("B", .blue, OACProfile(identifier: "selftest-b")),
        ]
        for (name, color, profile) in spaces {
            let space = model.addSpace(name: "Space \(name)", color: color, profile: profile)
            guard let tab = model.openTab(url: "https://example.com/", in: space) else { continue }
            tab.onConsoleMessage = { message in log("console[\(name)] \(message)") }
            tab.onFinishLoading = { [weak self] in self?.didLoad(name) }
            tabs.append((name, tab))
        }
        after(30) {
            log("SELFTEST TIMEOUT")
            NSApp.terminate(nil)
        }
    }

    private func didLoad(_ name: String) {
        loaded.insert(name)
        guard !running, loaded.count == tabs.count else { return }
        running = true
        // Give content scripts and the service worker time to answer.
        after(3) { self.writeStorageInSpaceA() }
    }

    private func writeStorageInSpaceA() {
        tabs.first { $0.name == "A" }?.tab.browserView.executeJavaScript("""
            document.cookie = 'openarch_probe=A; max-age=600';
            localStorage.setItem('openarch_probe', 'A');
            console.log('[selftest] wrote cookie + localStorage');
            """)
        after(1) { self.report() }
    }

    private func report() {
        let script = """
            (() => {
              const d = document.documentElement.dataset;
              console.log('[selftest] ' + JSON.stringify({
                cookie: document.cookie,
                localStorage: localStorage.getItem('openarch_probe'),
                contentScript: d.openarchProbe ?? null,
                extensionChecks: JSON.parse(d.openarchProbeChecks ?? 'null'),
              }));
            })();
            """
        for (_, tab) in tabs {
            tab.browserView.executeJavaScript(script)
        }
        Task {
            await logDevToolsTargets()
            // Same probe in a window with Chrome's own UI, for comparison.
            OACBrowserView.openChromeStyleWindow(withURL: "https://example.com/", profile: .default)
            after(8) { NSApp.terminate(nil) }
        }
    }

    private func logDevToolsTargets() async {
        guard let url = URL(string: "http://127.0.0.1:9222/json/list"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            log("devtools: target list unavailable")
            return
        }
        for target in targets {
            log("devtools target: \(target["type"] ?? "?") \(target["url"] ?? "")")
        }
    }
}
