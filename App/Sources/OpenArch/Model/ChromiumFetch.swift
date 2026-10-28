import Foundation
import OpenArchCore

/// Small downloads (favicons, search suggestions) through Chromium's network
/// stack. URLSession loses its connections in a process that runs Chromium.
@MainActor
enum ChromiumFetch {
    static func get(_ url: URL, profile: OACProfile = .default, headers: [String: String] = [:]) async -> (Data?, Int) {
        await withCheckedContinuation { continuation in
            profile.fetchURL(url.absoluteString, headers: headers) { data, status in
                continuation.resume(returning: (data, status))
            }
        }
    }
}
