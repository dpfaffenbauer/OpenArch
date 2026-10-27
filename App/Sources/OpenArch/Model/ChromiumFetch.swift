import Foundation
import OpenArchCore

/// Small downloads (favicons, search suggestions) through Chromium's network
/// stack. URLSession loses its connections in a process that runs Chromium.
@MainActor
enum ChromiumFetch {
    static func get(_ url: URL, profile: OACProfile = .default) async -> (Data?, Int) {
        await withCheckedContinuation { continuation in
            profile.fetchURL(url.absoluteString) { data, status in
                continuation.resume(returning: (data, status))
            }
        }
    }
}
