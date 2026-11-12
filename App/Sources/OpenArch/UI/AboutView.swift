import AppKit
import OpenArchCore
import OpenArchLocalization
import SwiftUI

/// Über OpenArch: a centered app portrait, version details and links,
/// sized to its content like Ghostty's and the About My Mac window.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private(set) var window: NSWindow?

    func show(selfTest: Bool = false) {
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = L("Über OpenArch")
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = true
            window.backgroundColor = NSColor(Color(red: 0.24, green: 0.23, blue: 0.22))
            self.window = window
            return window
        }()
        let host = NSHostingView(rootView: AboutView())
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        // Like Ghostty's 300-pt XIB window: fixed 8-pt-inset width and
        // height from the content, never the other way around.
        let size = NSSize(width: 308, height: host.fittingSize.height)
        window.setContentSize(size)
        window.center()
        if selfTest {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

struct AboutView: View {
    @Environment(\.openURL) private var openURL

    private let githubURL = URL(string: "https://github.com/dpfaffenbauer/OpenArch")
    private let releasesURL = URL(string: "https://github.com/dpfaffenbauer/OpenArch/releases")
    private let docsURL = URL(string: "https://docs.openarch.app")

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var build: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return value.isEmpty || value == "0" ? L("Eigenbau") : value
    }

    private var commit: String { Updater.shared.currentCommit }

    private var commitURL: URL? {
        commit.isEmpty ? nil : URL(string: "https://github.com/dpfaffenbauer/OpenArch/commit/\(commit)")
    }

    // This creates a background style similar to the Apple "About My Mac" Window.
    // In-window (not behind-window) so it frosts toward the window's own
    // opaque background instead of the desktop.
    private struct VisualEffectBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .withinWindow
            view.state = .active
            view.autoresizingMask = [.width, .height]
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }

    var body: some View {
        VStack(alignment: .center) {
            appIcon
                .frame(height: 128)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("OpenArch")
                        .bold()
                        .font(.title)
                    Text(L("Ein schneller, nativer Browser für macOS\nmit Spaces, WebKit und Agent-Chats."))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .tint(.secondary)
                        .opacity(0.8)
                }

                VStack(spacing: 2) {
                    PropertyRow(label: L("Version"), text: version, url: releasesURL)
                    PropertyRow(label: L("Build"), text: build)
                    if let commitURL {
                        PropertyRow(label: L("Commit"), text: AboutView.shortCommit(commit), url: commitURL)
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    if let docsURL { Button(L("Doku")) { openURL(docsURL) } }
                    if let githubURL { Button("GitHub") { openURL(githubURL) } }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(width: 308)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    static func shortCommit(_ commit: String) -> String { String(commit.prefix(9)) }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
    }
}

private struct PropertyRow: View {
    private let label: String
    private let text: String
    private let url: URL?

    init(label: String, text: String, url: URL? = nil) {
        self.label = label
        self.text = text
        self.url = url
    }

    @ViewBuilder private var textView: some View {
        if let url {
            Link(text, destination: url)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .foregroundStyle(Color(red: 0.35, green: 0.62, blue: 1))
                .monospaced()
        } else {
            Text(text)
                .frame(width: 125, alignment: .leading)
                .padding(.leading, 2)
                .tint(.secondary)
                .opacity(0.8)
                .monospaced()
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 126, alignment: .trailing)
                .padding(.trailing, 2)
            textView
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}
