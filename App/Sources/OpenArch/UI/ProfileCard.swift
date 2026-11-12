import OpenArchLocalization
import SwiftUI

/// Over a space's name: the profile it uses and the Google account signed
/// in to that profile.
struct ProfileCard: View {
    let browser: BrowserWindowController
    let space: Space

    var body: some View {
        let library = browser.library
        let profile = library.profile(id: space.profileID)
        let others = library.spaces.filter { $0 !== space && $0.profileID == profile.id }.map(\.name)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color(nsColor: library.color(for: profile))).frame(width: 10, height: 10)
                Text(L("Profil: %@", profile.name)).font(.system(size: 13, weight: .semibold))
            }
            account(GoogleAccounts.shared.state(for: profile.id))
            if !others.isEmpty {
                Text(L("Auch in: %@", others.joined(separator: ", ")))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    @ViewBuilder
    private func account(_ state: GoogleAccounts.State?) -> some View {
        switch state {
        case .accounts(let accounts) where !accounts.isEmpty:
            ForEach(accounts.prefix(3), id: \.email) { account in
                HStack(spacing: 9) {
                    avatar(account)
                    VStack(alignment: .leading, spacing: 1) {
                        if let name = account.name {
                            Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        }
                        Text(account.email).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        case .accounts:
            Text("Nicht bei Google angemeldet").font(.system(size: 12)).foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Google-Konto wird geprüft …").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .unknown, nil:
            Text("Google-Konto unbekannt (offline?)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func avatar(_ account: GoogleAccounts.Account) -> some View {
        Group {
            if let address = account.photoURL, let photo = GoogleAccounts.shared.photos[address] {
                Image(nsImage: photo).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Color.accentColor.opacity(0.8))
                    .overlay(Text(String((account.name ?? account.email).prefix(1)).uppercased())
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }
}
