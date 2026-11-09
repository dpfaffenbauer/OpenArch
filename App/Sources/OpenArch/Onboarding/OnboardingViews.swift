import AppKit
import SwiftUI

/// The onboarding window's content: a card with large corners, the steps
/// sliding through it, dots on top, the import's progress at the bottom.
struct OnboardingRoot: View {
    let model: OnboardingModel
    let library: Library
    let actions: OnboardingController

    var body: some View {
        ZStack {
            OnboardingBackground(step: model.step)
                .gesture(WindowDragGesture())
            VStack(spacing: 0) {
                StepDots(current: model.step.dot)
                    .padding(.top, 22)
                ZStack {
                    page
                        .id(model.step)
                        .transition(.asymmetric(
                            insertion: .move(edge: model.forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: model.forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                HStack {
                    if let progress = model.progress {
                        ProgressPill(progress: progress)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Spacer()
                }
                .frame(height: 28)
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .animation(.easeInOut(duration: 0.25), value: model.progress)
            }
        }
        .frame(width: OnboardingController.size.width, height: OnboardingController.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model, actions: actions)
        case .importing: ImportStep(model: model, actions: actions)
        case .logins: LoginsStep(model: model, actions: actions)
        case .accounts: AccountsStep(model: model, library: library, actions: actions)
        case .appearance: AppearanceStep(model: model, library: library, actions: actions)
        case .defaultBrowser: DefaultBrowserStep(actions: actions)
        case .done: DoneStep(model: model, library: library, actions: actions)
        }
    }
}

private struct OnboardingBackground: View {
    let step: OnboardingStep

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            // The welcome blooms in the Mac's accent color.
            RadialGradient(colors: [Color.accentColor.opacity(step == .welcome ? 0.32 : 0.10), .clear],
                           center: .topLeading, startRadius: 10, endRadius: 620)
            RadialGradient(colors: [Color.purple.opacity(step == .welcome ? 0.22 : 0.06), .clear],
                           center: .bottomTrailing, startRadius: 10, endRadius: 520)
        }
        .animation(.easeInOut(duration: 0.6), value: step)
    }
}

private struct StepDots: View {
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<OnboardingStep.dots, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.primary.opacity(0.7) : Color.primary.opacity(0.16))
                    .frame(width: index == current ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.3), value: current)
    }
}

private struct ProgressPill: View {
    let progress: OnboardingModel.Progress

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: progress.value).progressViewStyle(.circular).controlSize(.mini)
            Text("Import: \(progress.label) · \(Int(progress.value * 100)) %")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Title, text, content and the buttons at the bottom of each step.
private struct StepLayout<Content: View, Side: View>: View {
    let title: String
    let text: String
    var primary: (String, () -> Void)?
    var secondary: (String, () -> Void)?
    var skip: (() -> Void)?
    var skipTitle = "Überspringen"
    @ViewBuilder let content: Content
    @ViewBuilder let side: Side

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 26, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if let primary {
                        Button(action: primary.1) { Text(primary.0).frame(minWidth: 110) }
                            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                    }
                    if let secondary {
                        Button(secondary.0, action: secondary.1).controlSize(.large)
                    }
                    Spacer()
                    if let skip {
                        Button(skipTitle, action: skip).buttonStyle(.link).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            side
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .padding(.bottom, 6)
    }
}

extension StepLayout where Side == EmptyView {
    init(title: String, text: String, primary: (String, () -> Void)? = nil, secondary: (String, () -> Void)? = nil,
         skip: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, text: text, primary: primary, secondary: secondary, skip: skip,
                  content: content, side: { EmptyView() })
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    let model: OnboardingModel
    let actions: OnboardingController

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            Text(model.isRerun ? "OpenArch einrichten" : "Willkommen bei OpenArch")
                .font(.system(size: 34, weight: .bold))
            Text("Ein Browser im Geist von Arc: Spaces mit eigenen Profilen, eine Sidebar statt Tab-Leiste, echte Chrome-Extensions. In zwei Minuten eingerichtet, jeder Schritt lässt sich überspringen.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            Button { actions.next() } label: {
                HStack(spacing: 6) { Text("Los geht’s"); Image(systemName: "arrow.right") }.frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .padding(.top, 6)
            Spacer()
            Text("Open Source · keine Anmeldung, kein Konto").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Import

private struct ImportStep: View {
    @Bindable var model: OnboardingModel
    let actions: OnboardingController

    var body: some View {
        if model.choosing {
            StepLayout(title: "Was soll mit?", text: "Die Spaces, die du mitnehmen willst. Arc selbst bleibt, wie es ist.",
                       primary: ("Übernehmen", actions.importChosen), secondary: ("Zurück", { model.choosing = false })) {
                chooser
            } side: {
                SidebarPreview(model: model)
            }
        } else if model.sidebarImported || model.choice == .fresh || model.pendingLogins {
            StepLayout(title: model.choice == .fresh ? "Neu anfangen" : "Übernommen",
                       text: model.choice == .fresh ? "OpenArch beginnt mit einem leeren Space."
                           : "Deine Sidebar aus Arc ist da. Ein neuer Import ersetzt sie wieder.",
                       primary: ("Weiter", actions.next)) {
                EmptyView()
            } side: {
                if model.preview != nil { SidebarPreview(model: model) }
            }
        } else if model.preview != nil {
            StepLayout(title: "Nimm dein Arc mit", text: "OpenArch hat Arc gefunden und liest seine Sidebar. Arc selbst bleibt, wie es ist.",
                       primary: ("Alles übernehmen", actions.importEverything),
                       secondary: ("Auswählen …", { model.choosing = true }),
                       skip: actions.startFresh, skipTitle: "Neu anfangen") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.countsLine).font(.system(size: 13, weight: .semibold))
                        .contentTransition(.numericText())
                    if model.loginsAvailable {
                        Label("Dazu Logins, Passwörter, Verlauf und Extensions", systemImage: "key")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } side: {
                SidebarPreview(model: model)
            }
        } else if model.searching {
            StepLayout(title: "Nimm dein Arc mit", text: "Suche nach Arc …") { ProgressView().controlSize(.small) }
        } else {
            StepLayout(title: model.others.isEmpty ? "Neu anfangen" : "Aus einem anderen Browser",
                       text: (model.arcError ?? "") + (model.others.isEmpty
                           ? " OpenArch beginnt mit einem leeren Space; Einstellungen › Import holt Arc später."
                           : " Diese Browser hat OpenArch gefunden:"),
                       primary: ("Weiter", actions.startFresh)) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.others) { source in
                        HStack {
                            Text(source.name).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button("Übernehmen") { actions.importOther(source) }
                        }
                    }
                }
            }
        }
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.preview?.spaces ?? [], id: \.id) { space in
                    Toggle(isOn: Binding(
                        get: { model.chosenSpaces.contains(space.id) },
                        set: { if $0 { model.chosenSpaces.insert(space.id) } else { model.chosenSpaces.remove(space.id) } })) {
                        HStack(spacing: 6) {
                            SpaceIcon(icon: space.icon, size: 11).foregroundStyle(Color(nsColor: NSColor(hex: space.colorHex) ?? .purple))
                            Text(space.name)
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                Toggle("Favoriten", isOn: $model.includeFavorites)
                if model.loginsAvailable {
                    Toggle("Logins, Passwörter, Verlauf und Extensions", isOn: $model.includeLogins)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13))
        }
        .frame(maxHeight: 250)
    }
}

extension OnboardingModel {
    /// The sidebar waits on the keychain step.
    var pendingLogins: Bool { step == .importing && progress != nil }
}

/// Arc's sidebar, built again in small while it is read: the space's color,
/// its favorites and pinned tabs, the spaces at the bottom.
struct SidebarPreview: View {
    let model: OnboardingModel

    private var space: SpaceData? {
        let spaces = model.previewSpaces
        return spaces.isEmpty ? nil : spaces[min(model.focusedSpace, spaces.count - 1)]
    }

    var body: some View {
        let theme = SpaceTheme(hex: space?.colorHex ?? "#7B6CF6")
        VStack(alignment: .leading, spacing: 10) {
            let favorites = favoritesOfSpace
            if !favorites.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(favorites.prefix(8), id: \.id) { item in
                        RoundedRectangle(cornerRadius: 8).fill(theme.tile).frame(height: 34)
                            .overlay(Favicon(url: item.url, size: 16))
                    }
                }
                .transition(.opacity)
            }
            if let space {
                HStack(spacing: 6) {
                    SpaceIcon(icon: space.icon, size: 11)
                    Text(space.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(theme.foreground)
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(space.pinned.prefix(9), id: \.id) { item in
                        PreviewRow(item: item, theme: theme)
                    }
                }
                .id(space.id)
                .transition(.opacity)
                if space.pinned.count > 9 {
                    Text("+ \(space.pinned.count - 9)").font(.system(size: 10)).foregroundStyle(theme.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(Array(model.previewSpaces.enumerated()), id: \.element.id) { index, space in
                    Button { withAnimation(.spring(duration: 0.3)) { model.focusedSpace = index } } label: {
                        SpaceIcon(icon: space.icon, size: 10)
                            .foregroundStyle(theme.foreground.opacity(index == model.focusedSpace ? 1 : 0.5))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 236, height: 390)
        .background(LinearGradient(colors: [theme.background, theme.backgroundBottom], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .animation(.easeInOut(duration: 0.35), value: space?.id)
    }

    private var favoritesOfSpace: [ItemData] {
        guard let space, let profile = model.preview?.profiles.first(where: { $0.id == space.profileID }) else { return [] }
        return profile.favorites
    }
}

private struct PreviewRow: View {
    let item: ItemData
    let theme: SpaceTheme

    var body: some View {
        HStack(spacing: 7) {
            if item.kind == .folder {
                Image(systemName: "folder").font(.system(size: 10)).frame(width: 14)
            } else {
                Favicon(url: item.url ?? item.children?.first?.url, size: 12).frame(width: 14)
            }
            Text(item.customTitle ?? item.title ?? item.url ?? "").font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(theme.foreground)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
    }
}

private struct Favicon: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        if let url, let image = FaviconStore.shared.image(forURL: url) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "globe").font(.system(size: size * 0.8)).opacity(0.7)
        }
    }
}

// MARK: - Keychain

private struct LoginsStep: View {
    let model: OnboardingModel
    let actions: OnboardingController

    var body: some View {
        StepLayout(title: "Gleich fragt macOS nach deinem Passwort",
                   text: "Arc schützt Logins und Passwörter mit einem Schlüssel im Schlüsselbund („Arc Safe Storage“). Damit OpenArch sie übernehmen kann, fragt macOS gleich einmal, ob OpenArch ihn lesen darf. Gib dein Mac-Passwort ein und wähle „Erlauben“.",
                   primary: ("Weiter", actions.startLogins),
                   secondary: ("Logins überspringen", actions.skipLogins)) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Die Werte werden auf diesem Mac entschlüsselt und mit OpenArchs Schlüssel neu verschlüsselt. Nichts verlässt den Mac.", systemImage: "lock.shield")
                Label("Arc wird dafür beendet, falls es läuft. Seine Tabs und Daten bleiben unverändert.", systemImage: "arrow.uturn.backward.circle")
                Label("Der Import läuft weiter, während du die nächsten Schritte machst.", systemImage: "clock.arrow.circlepath")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 4)
        } side: {
            KeychainPicture()
        }
    }
}

private struct KeychainPicture: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("OpenArch möchte auf den Schlüssel „Arc Safe Storage“ in deinem Schlüsselbund zugreifen.")
                .font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center)
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)).frame(height: 22)
                .overlay(Text("Passwort").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 6),
                         alignment: .leading)
            HStack {
                Text("Immer erlauben").font(.system(size: 10))
                Spacer()
                Capsule().fill(Color.accentColor).frame(width: 56, height: 20)
                    .overlay(Text("Erlauben").font(.system(size: 10, weight: .medium)).foregroundStyle(.white))
            }
        }
        .padding(16)
        .frame(width: 236)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .padding(.top, 30)
    }
}

// MARK: - Accounts

private struct AccountsStep: View {
    let model: OnboardingModel
    let library: Library
    let actions: OnboardingController

    var body: some View {
        StepLayout(title: "Spaces und Konten",
                   text: "Jedes Profil hat eigene Logins, Cookies und Extensions. Hier siehst du, welche Google-Konten in welchem Profil angemeldet sind.",
                   primary: ("Weiter", actions.next), skip: actions.next) {
            if model.importRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Spaces und Logins kommen gerade aus Arc …").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(actions.profilesInUse) { profile in
                            ProfileRow(profile: profile, spaces: library.spaces.filter { $0.profileID == profile.id },
                                       accounts: model.accounts[profile.id], actions: actions)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            if let failed = model.loginsFailed {
                Label(failed, systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: Profile
    let spaces: [Space]
    let accounts: OnboardingModel.Accounts?
    let actions: OnboardingController

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    ForEach(spaces.prefix(6)) { space in
                        HStack(spacing: 3) {
                            SpaceIcon(icon: space.icon, size: 9)
                            Text(space.name).font(.system(size: 10)).lineLimit(1)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color(nsColor: space.color).opacity(0.22)))
                    }
                }
            }
            Spacer()
            switch accounts {
            case .found(let list) where !list.isEmpty:
                HStack(spacing: -6) {
                    ForEach(list.prefix(4), id: \.email) { AccountAvatar(account: $0) }
                }
                .help(list.map(\.email).joined(separator: "\n"))
            case .searching, nil:
                ProgressView().controlSize(.small)
            default:
                Button { actions.signIn(profile) } label: {
                    Label("Mit Google anmelden", systemImage: "person.crop.circle.badge.plus")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

private struct AccountAvatar: View {
    let account: GoogleAccount
    @State private var photo: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.8))
            if let photo {
                Image(nsImage: photo).resizable().clipShape(Circle())
            } else {
                Text(String((account.name ?? account.email).prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
        .onAppear { GoogleAccounts.photo(account.photoURL) { photo = $0 } }
    }
}

// MARK: - Appearance

private struct AppearanceStep: View {
    let model: OnboardingModel
    let library: Library
    let actions: OnboardingController

    var body: some View {
        StepLayout(title: "Mach es zu deinem",
                   text: "Eine Farbe pro Space, und hell oder dunkel für Seiten und Fenster. Das Fenster dahinter zeigt es sofort.",
                   primary: ("Weiter", actions.next), skip: actions.next) {
            Picker("", selection: Binding(get: { library.settings.appearance }, set: { actions.setAppearance($0) })) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(library.spaces) { space in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                SpaceIcon(icon: space.icon, size: 11)
                                Text(space.name).font(.system(size: 12, weight: .semibold))
                            }
                            .onTapGesture { actions.focus(space) }
                            HStack(spacing: 6) {
                                ForEach(spaceColorPresets, id: \.self) { hex in
                                    Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(
                                            space.colorHex.uppercased() == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                                        .onTapGesture { actions.setColor(hex, of: space) }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4).padding(.vertical, 4)
            }
            .frame(maxHeight: 250)
        }
    }
}

// MARK: - Default browser

private struct DefaultBrowserStep: View {
    let actions: OnboardingController

    var body: some View {
        StepLayout(title: "OpenArch als Standardbrowser",
                   text: "Dann öffnen Links aus Mail, Slack und anderen Apps in OpenArch, nach deinen Link-Regeln im richtigen Space. macOS fragt gleich noch einmal nach.",
                   primary: ("Als Standard festlegen", actions.makeDefaultBrowser),
                   secondary: ("Nicht jetzt", actions.next)) {
            EmptyView()
        }
    }
}

// MARK: - Done

private struct DoneStep: View {
    let model: OnboardingModel
    let library: Library
    let actions: OnboardingController

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            HStack(spacing: 10) {
                ForEach(library.spaces.prefix(8)) { space in
                    Circle().fill(Color(nsColor: space.color)).frame(width: 40, height: 40)
                        .overlay(SpaceIcon(icon: space.icon, size: 15).foregroundStyle(.white))
                }
            }
            Text("Alles bereit").font(.system(size: 32, weight: .bold))
            Text(summary).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 500)
            if let result = model.loginsResult {
                Text("Aus Arc übernommen: \(result)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            } else if model.importRunning {
                Text("Der Import läuft noch und ist gleich fertig.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { actions.finish() } label: { Text("OpenArch öffnen").frame(minWidth: 150) }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(model.importRunning)
                .padding(.top, 4)
            Spacer()
            Text("⌘T öffnet einen Tab, ⌘S blendet die Sidebar aus, ⌃1–9 wechselt den Space. Einstellungen › Allgemein zeigt diese Einführung noch einmal.")
                .font(.system(size: 11)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 560)
        }
        .padding(.horizontal, 40)
    }

    private var summary: String {
        let spaces = library.spaces.count
        let profiles = Set(library.spaces.map(\.profileID)).count
        return "\(spaces) \(spaces == 1 ? "Space" : "Spaces") in \(profiles) \(profiles == 1 ? "Profil" : "Profilen"). Dein Browserfenster wartet."
    }
}
