import AppKit
import Observation
import OpenArchCore

/// Which Google account a profile is signed in to, for the profile shown
/// over the space's name: Google's own list of the accounts in a cookie
/// jar (ListAccounts, which Chrome asks the same way), fetched with that
/// profile's cookies. Only asked when the pointer rests on a space's name,
/// at most every few minutes per profile; nothing is saved or sent anywhere
/// else. The self-test never asks Google.
@MainActor @Observable
final class GoogleAccounts {
    static let shared = GoogleAccounts()

    struct Account: Equatable {
        var name: String?
        var email: String
        var photoURL: String?
    }

    enum State: Equatable {
        case loading
        /// [] when nobody is signed in.
        case accounts([Account])
        /// No answer (offline, or Google answered with something else).
        case unknown
    }

    static let listAccountsURL = "https://accounts.google.com/ListAccounts?gpsia=1&source=ChromiumBrowser&json=standard"
    private static let freshFor: TimeInterval = 300

    /// By profile directory.
    private(set) var states: [String: State] = [:]
    /// Account pictures, by address.
    private(set) var photos: [String: NSImage] = [:]
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]

    func state(for profileID: String) -> State? {
        states[profileID]
    }

    /// Asks Google again unless the last answer is recent.
    func refresh(_ profileID: String) {
        if let date = fetchedAt[profileID], Date().timeIntervalSince(date) < Self.freshFor { return }
        guard !AppPaths.isSelfTest else { return }
        fetchedAt[profileID] = Date()
        if states[profileID] == nil { states[profileID] = .loading }
        OACProfile(directoryName: profileID).fetchURL(Self.listAccountsURL) { [weak self] data, status in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if status == 200, let accounts = Self.accounts(fromListAccounts: text) {
                    self.states[profileID] = .accounts(accounts)
                    for account in accounts { self.loadPhoto(account.photoURL, profileID: profileID) }
                } else {
                    self.states[profileID] = .unknown
                    // Offline: ask again the next time.
                    self.fetchedAt[profileID] = nil
                }
            }
        }
    }

    /// For the self-test: an answer as if Google had given it.
    func setForTesting(_ state: State?, profileID: String) {
        states[profileID] = state
        fetchedAt[profileID] = state == nil ? nil : Date()
    }

    private func loadPhoto(_ address: String?, profileID: String) {
        guard let address, photos[address] == nil, address.hasPrefix("https://") else { return }
        OACProfile(directoryName: profileID).fetchURL(address) { [weak self] data, status in
            MainActor.assumeIsolated {
                if status == 200, let image = data.flatMap(NSImage.init(data:)) {
                    self?.photos[address] = image
                }
            }
        }
    }

    /// The signed-in accounts from Google's ListAccounts answer, first the
    /// primary one; [] when nobody is signed in, nil when |text| is not that
    /// answer (an error or sign-in page). Field 3 of an entry is its email,
    /// 2 the name, 4 the picture; field 9 is 0 for an account signed out.
    nonisolated static func accounts(fromListAccounts text: String) -> [Account]? {
        guard let start = text.range(of: "[\"gaia.l.a.r\"")?.lowerBound,
              let end = text.range(of: "]", options: .backwards)?.upperBound, start < end,
              let data = String(text[start..<end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count >= 2,
              let list = root[1] as? [Any] else { return nil }
        var accounts: [Account] = []
        for case let entry as [Any] in list {
            guard entry.count > 3, let email = entry[3] as? String, email.contains("@") else { continue }
            if entry.count > 9, let valid = entry[9] as? Int, valid == 0 { continue }
            let name = (entry[2] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let photo = entry.count > 4 ? (entry[4] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
            accounts.append(Account(name: name, email: email, photoURL: photo))
        }
        return accounts
    }
}

/// Colors that tell profiles apart: the ring around a space's icon.
let profileColorPresets = ["#3B82F6", "#F59E0B", "#10B981", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#F97316"]

extension Library {
    /// A profile's color, by its place in the list of profiles.
    func color(for profile: Profile) -> NSColor {
        let index = profiles.firstIndex { $0 === profile } ?? 0
        return NSColor(hex: profileColorPresets[index % profileColorPresets.count]) ?? .systemBlue
    }
}
