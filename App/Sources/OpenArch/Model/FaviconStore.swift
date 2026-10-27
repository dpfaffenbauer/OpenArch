import AppKit
import Observation

/// Favicons by host: from loaded pages, cached on disk, and fetched from the
/// site itself (/favicon.ico) for pinned tabs that have not loaded yet.
@MainActor @Observable
final class FaviconStore {
    static let shared = FaviconStore()

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested = Set<String>()
    /// Bumped whenever an icon arrives so views re-read.
    private(set) var version = 0

    private let directory: URL = {
        let url = AppPaths.support.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func image(forURL url: String) -> NSImage? {
        _ = version
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
        if let image = images[host] {
            return image
        }
        let file = directory.appendingPathComponent(host + ".png")
        if let image = NSImage(contentsOf: file) {
            images[host] = image
            return image
        }
        fetch(host: host)
        return nil
    }

    func store(_ image: NSImage, forURL url: String) {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return }
        images[host] = image
        version += 1
        save(image, host: host)
    }

    private func save(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(host + ".png"), options: .atomic)
    }

    private func fetch(host: String) {
        guard !requested.contains(host) else { return }
        requested.insert(host)
        let candidates = ["https://\(host)/favicon.ico", "https://\(host)/apple-touch-icon.png"]
        Task {
            for candidate in candidates {
                guard let url = URL(string: candidate) else { continue }
                let (data, status) = await ChromiumFetch.get(url)
                guard status == 200, let data, let image = NSImage(data: data), image.isValid, image.size.width > 0
                else { continue }
                images[host] = image
                version += 1
                save(image, host: host)
                return
            }
        }
    }
}
