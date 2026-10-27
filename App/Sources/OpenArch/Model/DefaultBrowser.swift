import AppKit
import UniformTypeIdentifiers

/// OpenArch as the Mac's web browser: links from Mail, Slack and other apps,
/// and HTML files, open in OpenArch.
@MainActor
enum DefaultBrowser {
    /// Whether macOS sends http(s) links to OpenArch (any copy of it).
    static var isDefault: Bool {
        guard let url = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Asks macOS to make OpenArch the default browser; macOS confirms with
    /// the user. One after the other, so the user sees one question.
    static func makeDefault(completion: @escaping @MainActor (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            guard error == nil else {
                Task { @MainActor in completion(false) }
                return
            }
            workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { error in
                workspace.setDefaultApplication(at: app, toOpen: .html) { _ in }
                Task { @MainActor in completion(error == nil) }
            }
        }
    }
}
