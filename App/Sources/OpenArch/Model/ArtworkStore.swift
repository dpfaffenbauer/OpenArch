import AppKit
import Observation
import OpenArchCore

/// Covers for the player in the sidebar, by address. Fetched once through
/// the playing tab's profile (its cookies; a private window's stay in
/// memory) and kept in memory only.
@MainActor @Observable
final class ArtworkStore {
    static let shared = ArtworkStore()

    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested = Set<String>()
    /// Bumped whenever a cover arrives so views re-read.
    private(set) var version = 0

    func image(for address: String, profile: OACProfile?) -> NSImage? {
        _ = version
        guard !address.isEmpty else { return nil }
        if let image = images[address] {
            return image
        }
        guard let profile, !requested.contains(address) else { return nil }
        requested.insert(address)
        Task {
            var data: Data?
            if address.hasPrefix("data:") {
                data = Self.decode(dataURL: address)
            } else if let url = URL(string: address) {
                let (body, status) = await WebFetch.get(url, profile: profile)
                data = status == 200 ? body : nil
            }
            guard let data, let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return }
            // A few dozen songs' worth; then start over.
            if images.count >= 64 {
                images.removeAll()
                requested = [address]
            }
            images[address] = image
            version += 1
        }
        return nil
    }

    /// data:image/png;base64,… (the page may hand over its cover like that).
    private static func decode(dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[..<comma]
        let payload = String(dataURL[dataURL.index(after: comma)...])
        if header.hasSuffix(";base64") {
            return Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }
}
