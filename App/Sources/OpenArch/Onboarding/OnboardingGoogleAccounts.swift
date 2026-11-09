import AppKit
import OpenArchCore

/// A Google account signed in to a profile. It stays on this Mac.
struct GoogleAccount: Equatable {
    var name: String?
    var email: String
    var photoURL: String?
}

/// Which Google accounts a profile is signed in to: Google's ListAccounts
/// answer, the list Chromium itself keeps per profile, fetched with the
/// profile's own cookies.
@MainActor
enum OnboardingGoogleAccounts {
    static let listURL = "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard"

    /// The self-test's answer by profile directory; the self-test never asks
    /// Google.
    static var testAnswer: ((String) -> [GoogleAccount]?)?

    /// nil: no answer; []: nobody is signed in.
    static func read(_ profile: Profile, completion: @escaping @MainActor ([GoogleAccount]?) -> Void) {
        if AppPaths.isSelfTest {
            let answer = testAnswer?(profile.id)
            after(0.2) { completion(answer) }
            return
        }
        let chromium = profile.chromium
        chromium.whenReady {
            chromium.fetchURL(listURL) { data, status in
                MainActor.assumeIsolated {
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    completion(status == 200 ? parse(text) : nil)
                }
            }
        }
    }

    /// `["gaia.l.a.r",[["gaia.l.a",1,"Name","user@example.com","https://…/photo",…],…]]`;
    /// nil when |text| is not that list (an error or sign-in page).
    nonisolated static func parse(_ text: String) -> [GoogleAccount]? {
        guard let start = text.range(of: "[\"gaia.l.a.r\"")?.lowerBound,
              let end = text.range(of: "]", options: .backwards)?.upperBound, start < end,
              let root = try? JSONSerialization.jsonObject(with: Data(text[start..<end].utf8)) as? [Any],
              root.count >= 2, let list = root[1] as? [Any]
        else { return nil }
        return list.compactMap { entry -> GoogleAccount? in
            guard let fields = entry as? [Any], fields.count > 3, let email = fields[3] as? String, email.contains("@")
            else { return nil }
            // Field 9 is 0 for an account that is signed out.
            if fields.count > 9, let valid = fields[9] as? Int, valid == 0 { return nil }
            let name = (fields[2] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let photo = fields.count > 4 ? (fields[4] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil } : nil
            return GoogleAccount(name: name, email: email, photoURL: photo)
        }
    }

    private static var photos: [String: NSImage] = [:]

    /// An account's picture, from Google's image host.
    static func photo(_ address: String?, completion: @escaping @MainActor (NSImage?) -> Void) {
        guard let address, let url = URL(string: address), url.scheme == "https" else { return completion(nil) }
        if let image = photos[address] { return completion(image) }
        Task {
            let (data, status) = await ChromiumFetch.get(url)
            let image = status == 200 ? data.flatMap(NSImage.init(data:)) : nil
            if let image { photos[address] = image }
            completion(image)
        }
    }
}

/// "Mit Google anmelden" for one profile: Google's sign-in page in a small
/// window of that profile, so the login lands in its cookies. It closes by
/// itself once Google shows the account page.
@MainActor
final class GoogleSignInWindow: NSObject, NSWindowDelegate, OACPaneDelegate {
    static let signInURL = "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmyaccount.google.com%2F"

    private let window: NSWindow
    private let pane: OACPane
    private var closed = false
    var onClose: (() -> Void)?

    init(profile: Profile, over parent: NSWindow) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        pane = OACPane(profile: profile.chromium, url: Self.signInURL)
        super.init()
        window.title = "Bei Google anmelden · \(profile.name)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = parent.level
        let frame = parent.frame
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        pane.delegate = self
        pane.toolbarVisible = false
        pane.activatesOnShow = !AppPaths.isSelfTest
        window.makeKeyAndOrderFront(nil)
        pane.show(in: window, frame: window.contentView?.bounds ?? .zero)
    }

    func close() {
        guard !closed else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        pane.delegate = nil
        pane.close()
        onClose?()
    }

    func pane(_ pane: OACPane, addressDidChange url: String) {
        if URL(string: url)?.host == "myaccount.google.com" { close() }
    }

    // Google's own pop-ups (passkeys, another account) stay in this window.
    func pane(_ pane: OACPane, wantsNewTabWithURL url: String, background: Bool) {
        pane.loadURL(url)
    }
}
