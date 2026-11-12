import Foundation
import OpenArchCore
import WebKit

/// Small downloads (favicons, search suggestions, live folders) with the
/// profile's WebKit cookies. The engine is WebKit now, so URLSession is
/// reliable here; the old Chromium-network shortcut is gone.
@MainActor
enum WebFetch {
    /// GET |url| with |headers| and the profile's cookies. Status 0 when
    /// the request failed.
    static func get(_ url: URL, profile: OACProfile? = nil, headers: [String: String] = [:]) async -> (Data?, Int) {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let profile {
            let store = WebKitStores.store(for: profile)
            let cookies = await store.httpCookieStore.allCookies()
            let fields = HTTPCookie.requestHeaderFields(with: cookies)
            for (field, value) in fields { request.setValue(value, forHTTPHeaderField: field) }
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            return (nil, 0)
        }
    }
}
