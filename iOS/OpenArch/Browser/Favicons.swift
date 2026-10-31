import SwiftUI
import UIKit
import WebKit

/// Site icons by host: what a page names as its icon once it has loaded,
/// otherwise the site's apple-touch-icon or favicon.ico. Kept in Caches.
@MainActor @Observable
final class Favicons {
    static let shared = Favicons()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(for host: String) -> UIImage? {
        images[host]
    }

    #if DEBUG
    func seed(_ host: String, _ image: UIImage) {
        images[host] = image
    }
    #endif

    /// Loads the icon for |host| unless it is there or on its way.
    func request(_ host: String) {
        guard !host.isEmpty, images[host] == nil, !requested.contains(host) else { return }
        requested.insert(host)
        let file = file(for: host)
        Task {
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                images[host] = image
                return
            }
            for path in ["/apple-touch-icon.png", "/favicon.ico"] {
                if let url = URL(string: "https://\(host)\(path)"), await fetch(url, host: host) { return }
            }
        }
    }

    /// The icon a loaded page names, the largest one.
    func learn(from webView: WKWebView, host: String) {
        let script = """
            [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')]
              .map(l => [l.href, l.rel.includes('apple') ? 180 : parseInt((l.sizes && l.sizes.value) || '16')])
              .filter(l => l[0].startsWith('https:'))
              .sort((a, b) => b[1] - a[1]).map(l => l[0]).slice(0, 1)
            """
        webView.evaluateJavaScript(script) { result, _ in
            MainActor.assumeIsolated {
                guard let href = (result as? [String])?.first, let url = URL(string: href) else {
                    self.request(host)
                    return
                }
                self.requested.insert(host)
                Task { _ = await self.fetch(url, host: host) }
            }
        }
    }

    private func fetch(_ url: URL, host: String) async -> Bool {
        guard let result = try? await URLSession.shared.data(from: url), case let (data, response) = result,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1 << 20,
              let image = UIImage(data: data), image.size.width >= 16 else { return false }
        images[host] = image
        if let png = image.pngData() {
            try? png.write(to: file(for: host), options: .atomic)
        }
        return true
    }

    private func file(for host: String) -> URL {
        directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }
}

/// A site's icon, or its first letter on a tile while there is none.
struct FaviconView: View {
    let host: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = Favicons.shared.image(for: host) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: size / 4.5)
                    .fill(Color.secondary.opacity(0.25))
                    .overlay {
                        Text(host.replacingOccurrences(of: "www.", with: "").prefix(1).uppercased())
                            .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4.5))
        .onAppear { Favicons.shared.request(host) }
        .onChange(of: host) { _, new in Favicons.shared.request(new) }
    }
}
