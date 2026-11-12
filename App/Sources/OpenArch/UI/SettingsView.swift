import AppKit
import OpenArchCore
import OpenArchLocalization
import OpenArchShared
import SwiftUI

/// A native-material sidebar beside the settings pages, like System Settings.
struct SettingsView: View {
    let app: AppDelegate
    @State private var navigation: SettingsNavigation
    @State private var query = ""
    @State private var searchTarget: String?
    @FocusState private var searchFocused: Bool

    private var page: SettingsPage { navigation.page }

    init(app: AppDelegate, page: SettingsPage = .general, query: String = "") {
        self.app = app
        _navigation = State(initialValue: SettingsNavigation(page: page))
        _query = State(initialValue: query)
    }

    private func open(_ page: SettingsPage, target: String? = nil) {
        navigation.visit(page)
        searchTarget = target
        query = ""
        searchFocused = false
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                searchField
                    .padding(.top, 64)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(SettingsPage.allCases) { item in
                                SettingsSidebarRow(page: item, isSelected: page == item) { open(item) }
                            }
                        } else {
                            let results = SettingsSearchResult.matching(query)
                            if results.isEmpty {
                                Text(L("Keine Treffer"))
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .padding(12)
                            }
                            ForEach(results) { result in
                                SettingsSidebarRow(page: result.page, isSelected: false,
                                                   title: result.title, subtitle: result.page.title) {
                                    open(result.page, target: result.target)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            .frame(width: 230)
            .background(SettingsSidebarMaterial())
            .overlay(alignment: .top) {
                if searchFocused && query.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(navigation.recentPages) { item in
                            SettingsSidebarRow(page: item, isSelected: false) { open(item) }
                        }
                    }
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .padding(.horizontal, 8)
                    .padding(.top, 104)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            switch page {
                            case .general: GeneralPage(app: app, library: app.library)
                            case .profiles: ProfilesPage(app: app, library: app.library)
                            case .links: LinksPage(app: app, library: app.library)
                            case .sharing: SharingPage(app: app, library: app.library)
                            case .ai: AIPage(app: app)
                            case .keyboard: ShortcutsPage(app: app, library: app.library)
                            case .importing: ImportPage(app: app)
                            case .about: AboutPage(app: app)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .id(page)
                    }
                    .task(id: page.rawValue + (searchTarget ?? "")) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if let searchTarget { proxy.scrollTo(searchTarget, anchor: .top) }
                        else { proxy.scrollTo(page, anchor: .top) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 600)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Suchen"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel(L("Suchen"))
                .onSubmit {
                    if let first = SettingsSearchResult.matching(query).first {
                        open(first.page, target: first.target)
                    }
                }
                .onExitCommand { query = ""; searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Zurücksetzen"))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(searchFocused ? 0.4 : 0.14), lineWidth: searchFocused ? 2 : 1))
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button {
                    navigation.back()
                    searchTarget = nil
                } label: {
                    Image(systemName: "chevron.left").frame(width: 34, height: 34)
                }
                .disabled(!navigation.canGoBack)
                .help(L("Zurück"))
                .accessibilityLabel(L("Zurück"))
                Rectangle().fill(.primary.opacity(0.16)).frame(width: 1, height: 20)
                Button {
                    navigation.forward()
                    searchTarget = nil
                } label: {
                    Image(systemName: "chevron.right").frame(width: 34, height: 34)
                }
                .disabled(!navigation.canGoForward)
                .help(L("Vorwärts"))
                .accessibilityLabel(L("Vorwärts"))
            }
            .font(.system(size: 15, weight: .medium))
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            Text(page.title).font(.system(size: 16, weight: .semibold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
    }
}

private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SettingsNavigation {
    private(set) var history: [SettingsPage]
    private(set) var index = 0
    var page: SettingsPage { history[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < history.count }
    var recentPages: [SettingsPage] {
        history.reversed().reduce(into: [SettingsPage]()) { pages, page in
            if !pages.contains(page) { pages.append(page) }
        }
    }

    init(page: SettingsPage) { history = [page] }

    mutating func visit(_ page: SettingsPage) {
        guard page != self.page else { return }
        history = Array(history.prefix(index + 1)) + [page]
        index = history.count - 1
    }

    mutating func back() { if canGoBack { index -= 1 } }
    mutating func forward() { if canGoForward { index += 1 } }
}

private struct SettingsSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    var title: String?
    var subtitle: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsIcon(symbol: page.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? page.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(2)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, subtitle == nil ? 5 : 9)
            .frame(minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(
                isSelected ? Color.primary.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .onHover { hovering = $0 }
    }
}

private struct SettingsIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color(red: 0.82, green: 0.77, blue: 0.94))
            .frame(width: 23, height: 23)
            .background(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, profiles, links, sharing, ai, keyboard, importing, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("Allgemein")
        case .profiles: L("Profile")
        case .links: L("Links (Webseiten)")
        case .sharing: L("Teilen")
        case .ai: L("KI")
        case .keyboard: L("Tastatur")
        case .importing: L("Import")
        case .about: L("Info")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .profiles: "person.2"
        case .links: "link"
        case .sharing: "person.2.wave.2"
        case .ai: "sparkles"
        case .keyboard: "keyboard"
        case .importing: "square.and.arrow.down"
        case .about: "info.circle"
        }
    }

    /// Search destinations use the same keys as the rendered rows and sections.
    var searchTargets: [String] {
        switch self {
        case .general:
            ["Standardbrowser", "Erscheinungsbild", "Einführung", "Sprache", "Suchmaschine", "Suchvorschläge",
             "Tabs", "Sidebar", "Kalender", "Sicherheit", "Nur HTTPS", "App-Symbol", "Seitensuche"]
        case .profiles: []
        case .links: ["Peek", "Link-Regeln", "Links aus anderen Apps", "In Little OpenArch öffnen"]
        case .sharing: ["Von diesem Mac geteilt", "Mit dir geteilt", "Teilen-Server"]
        case .ai: ["Tab-Titel kürzen", "Fragen in der Befehlsleiste", "Agent-Chats", "Morning Brief", "KI-Steuerung"]
        case .keyboard: []
        case .importing: ["Aus Arc", "Aus anderen Browsern", "Aus Dateien", "Lesezeichen-Datei (HTML)", "Passwörter (CSV)"]
        case .about: ["Updates", "Update-Kanal", "Automatisch aktualisieren", "Daten", "Sicherung", "Absturzberichte", "Projekt"]
        }
    }
}

struct SettingsSearchResult: Identifiable {
    let page: SettingsPage
    let target: String?
    var title: String { target.map { L($0) } ?? page.title }
    var id: String { page.rawValue + ":" + (target ?? "") }

    static func matching(_ query: String) -> [Self] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return SettingsPage.allCases.flatMap { page in
            [Self(page: page, target: nil)] + page.searchTargets.map { Self(page: page, target: $0) }
        }.filter { result in
            words.allSatisfy { (result.title + " " + result.page.title).localizedStandardContains($0) }
        }
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title)).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
            if let footer {
                Text(L(footer)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
        }
        .id(title)
    }
}

/// Text-led preference rows; personal items retain their identifying icon.
private struct Row<Control: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    var showsDivider = true
    /// User data (a profile's or share's name) is not a localization key.
    var localizes = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !localizes {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(color)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizes ? L(title) : title).font(.system(size: 13))
                    if let detail {
                        Text(localizes ? L(detail) : detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .frame(minHeight: 24)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if showsDivider {
                Divider().padding(.horizontal, 14).opacity(0.5)
            }
        }
        .id(title)
    }
}

// MARK: - Pages

/// Whether OpenArch is the Mac's browser, and the button to make it so.
private struct DefaultBrowserRow: View {
    let app: AppDelegate
    var showsDivider = true
    @State private var isDefault = DefaultBrowser.isDefault

    var body: some View {
        Row(symbol: "globe", color: .blue, title: "Standardbrowser",
            detail: isDefault ? "OpenArch ist dein Standardbrowser: Links aus anderen Apps öffnen hier."
                : "Damit Links aus Mail, Slack und anderen Apps in OpenArch öffnen.",
            showsDivider: showsDivider) {
            if isDefault {
                Label("Aktiv", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12, weight: .semibold))
            } else {
                Button("Als Standard festlegen") {
                    DefaultBrowser.makeDefault { _ in isDefault = DefaultBrowser.isDefault }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefault = DefaultBrowser.isDefault
        }
    }
}

private struct GeneralPage: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
        Section(title: "Browser") {
            DefaultBrowserRow(app: app, showsDivider: true)
            Row(symbol: "circle.lefthalf.filled", color: .gray, title: "Erscheinungsbild",
                detail: "Hell oder dunkel für Seiten, Chats und Einstellungen. Die Sidebar trägt die Farbe ihres Space.") {
                Picker("", selection: $library.settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: library.settings.appearance) { library.settings.appearance.apply() }
            }
            Row(symbol: "sparkles", color: .purple, title: "Einführung",
                detail: "Die Schritte vom ersten Start noch einmal: Import aus Arc, Konten, Farben, Standardbrowser.",
                showsDivider: false) {
                Button("Erneut zeigen") { app.showOnboarding(nil) }
            }
        }
        Section(title: "Sprache") {
            Row(symbol: "globe", color: .blue, title: "Sprache",
                detail: "Die Sprache von OpenArch. „System“ folgt macOS und nimmt Englisch, wenn macOS eine Sprache wählt, die OpenArch nicht hat. Die Änderung gilt nach einem Neustart.",
                showsDivider: false) {
                Picker("", selection: $library.settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.endonym).tag($0) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: library.settings.language) { _, language in
                    Localization.setSelection(language)
                    library.setNeedsSave()
                    let alert = NSAlert()
                    alert.messageText = L("Sprache geändert")
                    alert.informativeText = L("OpenArch übernimmt die neue Sprache beim nächsten Start. Tabs und Fenster bleiben dabei erhalten.")
                    alert.addButton(withTitle: L("Jetzt neu starten"))
                    alert.addButton(withTitle: L("Später"))
                    if alert.runModal() == .alertFirstButtonReturn { app.relaunch() }
                }
            }
        }
        Section(title: "Suchen") {
            Row(symbol: "magnifyingglass", color: .blue, title: "Suchmaschine",
                detail: "Für Suchen aus der Befehlsleiste (⌘T).") {
                Picker("", selection: $library.settings.searchEngine) {
                    ForEach(Settings.SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Row(symbol: "text.bubble", color: .teal, title: "Suchvorschläge",
                detail: "Die Befehlsleiste fragt die Suchmaschine beim Tippen nach Vorschlägen.", showsDivider: false) {
                Toggle("", isOn: $library.settings.searchSuggestions).labelsHidden().toggleStyle(.switch)
            }
        }
        Section(title: "Tabs") {
            Row(symbol: "archivebox", color: .orange, title: "Tabs unter dem Strich archivieren",
                detail: "Nicht angeheftete Tabs, die so lange nicht benutzt wurden, wandern ins Archiv (⌘⇧T holt sie zurück).") {
                Picker("", selection: $library.settings.archiveAfterHours) {
                    Text("nach 12 Stunden").tag(12)
                    Text("nach 24 Stunden").tag(24)
                    Text("nach 7 Tagen").tag(24 * 7)
                    Text("nach 30 Tagen").tag(24 * 30)
                    Text("nie").tag(0)
                }
                .labelsHidden().fixedSize()
            }
            Row(symbol: "moon.zzz", color: .indigo, title: "Schlafende Tabs",
                detail: "Tabs, die du so lange nicht angesehen hast, geben ihren Speicher frei und laden neu, wenn du zurückkommst. Tabs mit Ton, ungespeicherten Eingaben oder in einem Anruf bleiben wach.") {
                Picker("", selection: $library.settings.sleepAfterMinutes) {
                    Text("nach 30 Minuten").tag(30)
                    Text("nach 1 Stunde").tag(60)
                    Text("nach 2 Stunden").tag(120)
                    Text("nach 6 Stunden").tag(360)
                    Text("nie").tag(0)
                }
                .labelsHidden().fixedSize()
            }
            Row(symbol: "bubble.left.and.bubble.right", color: .green, title: "Chat und Mail wach halten",
                detail: "Angeheftete Tabs und Favoriten von Slack, Gmail, Outlook, WhatsApp, Telegram, Discord, Teams, Google Chat und ähnlichen Diensten schlafen nie ein, damit Nachrichten und Anrufe ankommen.") {
                Toggle("", isOn: $library.settings.keepChatSitesAwake).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "plus.bubble", color: .green, title: "Weitere Seiten wach halten",
                detail: "Adressen, durch Kommas getrennt, z. B. „chat.firma.de, linear.app“.") {
                SiteListField(sites: $library.settings.keepAwakeSites, placeholder: "chat.firma.de")
                    .disabled(!library.settings.keepChatSitesAwake)
            }
            Row(symbol: "pip", color: .pink, title: "Bild-in-Bild beim Tab-Wechsel",
                detail: "Ein laufendes Video mit Ton spielt in einem kleinen Fenster weiter, wenn du den Tab verlässt.") {
                Toggle("", isOn: $library.settings.autoPictureInPicture).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "video.bubble", color: .pink, title: "Anrufe in Bild-in-Bild",
                detail: "Verlässt du einen Anruf (Kamera oder Mikrofon in Benutzung), schwebt er unten rechts weiter: Google Meet mit seinem eigenen Fenster, andere Dienste mit den Videos und Knöpfen für Mikrofon, Kamera und Auflegen. Zurück im Tab schließt es sich.") {
                Toggle("", isOn: $library.settings.callPictureInPicture).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "pip.remove", color: .pink, title: "Ohne Bild-in-Bild",
                detail: "Seiten, deren Videos und Anrufe nie von selbst schweben, durch Kommas getrennt. Auch im Site Control Center (⌃⌘I).") {
                SiteListField(sites: $library.settings.pictureInPictureExceptions, placeholder: "youtube.com")
            }
            Row(symbol: "menubar.rectangle", color: .indigo, title: "Chrome-Toolbar in Tabs",
                detail: "Adressleiste, Extension-Symbole und Downloads über der Seite (⌘⇧D).") {
                Toggle("", isOn: Binding(
                    get: { library.settings.showChromeToolbar },
                    set: { if $0 != library.settings.showChromeToolbar { app.browser?.toggleChromeToolbar() } }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
        MeetingSection(library: library)
        Section(title: "Sicherheit") {
            Row(symbol: "lock", color: .green, title: "Nur HTTPS",
                detail: "Adressen mit http:// werden zuerst verschlüsselt geladen. Geht das nicht, fragt OpenArch, bevor die Seite unverschlüsselt öffnet.", showsDivider: false) {
                Toggle("", isOn: $library.settings.httpsOnly).labelsHidden().toggleStyle(.switch)
                    .onChange(of: library.settings.httpsOnly) { library.settings.applyToChromium() }
            }
        }
        Section(title: "Geschützte Inhalte",
                footer: "Spotify, Netflix, Disney+, Prime Video und andere Streamingdienste spielen ihre Videos und Musik nur mit Apples FairPlay. Ihre Seiten öffnen deshalb mit Safaris Engine (WebKit), im selben Tab; Chrome-Erweiterungen laufen dort nicht. Pro Website änderst du das im Site Control Center.") {
            Row(symbol: "safari", color: .blue, title: "DRM-Seiten mit Safaris Engine abspielen",
                detail: "Gilt für Seiten, die du ab jetzt öffnest.") {
                Toggle("", isOn: $library.settings.protectedMediaWebKit).labelsHidden().toggleStyle(.switch)
                    .onChange(of: library.settings.protectedMediaWebKit) { library.settings.applyToChromium() }
            }
            Row(symbol: "lock.rectangle", color: .gray, title: "Geschützte Inhalte (Widevine)",
                detail: "Chromiums Widevine für Seiten, die es ohne Zertifizierung annehmen; Netflix und Spotify gehören nicht dazu. Gilt nach einem Neustart von OpenArch.",
                showsDivider: false) {
                Toggle("", isOn: $library.settings.widevine).labelsHidden().toggleStyle(.switch)
                    .onChange(of: library.settings.widevine) { library.setNeedsSave() }
            }
        }
        Section(title: "Sidebar") {
            Row(symbol: library.settings.sidebarOnRight ? "sidebar.right" : "sidebar.left", color: .purple, title: "Sidebar-Position",
                detail: "Links wie in Arc, oder rechts. Gilt für alle Fenster; die Ampel bleibt oben links.") {
                Picker("", selection: $library.settings.sidebarOnRight) {
                    Text("Links").tag(false)
                    Text("Rechts").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            Row(symbol: "arrow.left.and.right", color: .purple, title: "Breite",
                detail: "Auch durch Ziehen am inneren Rand der Sidebar; ganz an den Fensterrand gezogen, klappt sie zu.") {
                Slider(value: $library.settings.sidebarWidth, in: 200...440, step: 10).frame(width: 160)
                    .onChange(of: library.settings.sidebarWidth) { app.browsers.forEach { $0.layoutContent() } }
            }
            Row(symbol: "rectangle.on.rectangle", color: .cyan, title: "Glas-Effekt",
                detail: "Der Schreibtisch scheint durch das Fenster. Ab macOS 26 schwebt die Sidebar als Liquid Glass darüber, davor als Milchglas; die Seiten liegen als Karten daneben.") {
                Toggle("", isOn: $library.settings.glass).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "drop.halffull", color: .cyan, title: "Tönung",
                detail: "Wie viel von der Farbe des Space im Glas liegt: wenig lässt mehr vom Schreibtisch durch, viel hält die Schrift gut lesbar.") {
                Slider(value: $library.settings.glassTint, in: 0...0.9).frame(width: 160)
                    .disabled(!library.settings.glass)
            }
            Row(symbol: "rectangle.on.rectangle.angled", color: .blue, title: "Vorschau beim Überfahren",
                detail: "Ruht der Zeiger auf einem Tab in der Sidebar, zeigt OpenArch ein Bild der Seite daneben.",
                showsDivider: false) {
                Toggle("", isOn: $library.settings.tabPreviews).labelsHidden().toggleStyle(.switch)
            }
        }
        .onChange(of: library.settings.glass) { app.browsers.forEach { $0.applyTheme() } }
        .onChange(of: library.settings.glassTint) { app.browsers.forEach { $0.applyTheme() } }
        .onChange(of: library.settings.sidebarOnRight) { app.browsers.forEach { $0.sidebarSideChanged() } }
        AppIconSection()
        SiteSearchSection(library: library)
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

/// A list of sites typed as text, separated by commas; what you type stays
/// as typed while the list is updated.
private struct SiteListField: View {
    @Binding var sites: [String]
    let placeholder: String
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .onAppear { text = sites.joined(separator: ", ") }
            .onChange(of: text) {
                let parsed = KeepAwakeSites.parse(text)
                if parsed != sites { sites = parsed }
            }
    }
}

/// The next meeting from the Mac's calendar in the sidebar.
private struct MeetingSection: View {
    @Bindable var library: Library

    var body: some View {
        Section(title: "Kalender") {
            Row(symbol: "calendar", color: .red, title: "Nächstes Meeting in der Sidebar",
                detail: detail, showsDivider: false) {
                HStack {
                    if library.settings.meetingBar, Meetings.shared.access == .denied {
                        Button("Zugriff erlauben …") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                    Toggle("", isOn: $library.settings.meetingBar).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onChange(of: library.settings.meetingBar) { Meetings.shared.start(enabled: library.settings.meetingBar) }
    }

    private var detail: String {
        if library.settings.meetingBar, Meetings.shared.access == .denied {
            return "OpenArch darf den Kalender nicht lesen. Erlaube es unter Systemeinstellungen › Datenschutz & Sicherheit › Kalender."
        }
        return "Aus den Kalendern der Kalender-App: wann es losgeht und ein Knopf zum Beitreten. Der Call öffnet in einem eigenen Ordner, mit den Links, die du währenddessen öffnest. Beim Einschalten fragt macOS nach dem Zugriff."
    }
}

/// The Dock icon, like Arc's icon choice.
struct AppIconSection: View {
    @State private var selection = AppIcons.style

    var body: some View {
        Section(title: "App-Symbol",
                footer: "Zwölf Wege durch den Bogen; Tunnel ist OpenArchs eigenes. „Space-Farbe“ nimmt im Dock die Farbe des Space an, in dem du gerade bist, „Jeden Tag“ nimmt jeden Tag ein anderes. Im Finder bleibt es der Tunnel: Die App selbst wird nie verändert, damit ihre Signatur gültig bleibt.") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 10) {
                ForEach(AppIconStyle.allCases) { style in
                    Button {
                        selection = style
                        AppIcons.choose(style)
                    } label: {
                        VStack(spacing: 4) {
                            Image(nsImage: AppIcons.image(for: style, size: 128))
                                .resizable()
                                .frame(width: 48, height: 48)
                                .overlay(alignment: .bottomTrailing) {
                                    if style == .daily {
                                        // Today's design, marked as the changing one.
                                        Image(systemName: "shuffle")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 18, height: 18)
                                            .background(Circle().fill(Color.accentColor))
                                    }
                                }
                                .padding(3)
                                .background(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.accentColor, lineWidth: selection == style ? 2.5 : 0))
                            Text(style.name).font(.system(size: 10.5, weight: selection == style ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }
}

/// Sites to search straight from the command bar: keyword, Tab, query.
private struct SiteSearchSection: View {
    @Bindable var library: Library

    var body: some View {
        Section(title: "Seitensuche",
                footer: "In der Befehlsleiste das Kürzel oder den Namen tippen und Tab drücken, dann den Suchbegriff. %s steht für den Suchbegriff.") {
            ForEach($library.settings.siteSearches) { $site in
                HStack(spacing: 8) {
                    TextField("Name", text: $site.name).frame(width: 110)
                    TextField("Kürzel", text: $site.keyword).frame(width: 56)
                    TextField("https://…?q=%s", text: $site.url)
                    Button {
                        library.settings.siteSearches.removeAll { $0.id == site.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Entfernen")
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            HStack {
                Button("Seite hinzufügen") {
                    library.settings.siteSearches.append(SiteSearch(name: "", keyword: "", url: "https://"))
                }
                Spacer()
                Button("Standard wiederherstellen") { library.settings.siteSearches = SiteSearch.defaults }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct ProfilesPage: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
        Section(title: "Profile",
                footer: "Ein Profil hält Logins, Cookies, Verlauf, Passwörter und Extensions getrennt, etwa für ein zweites Google-Konto. Welches Profil ein Space nutzt, stellst du im Space ein (Doppelklick auf seinen Namen).") {
            ForEach(Array(library.profiles.enumerated()), id: \.element.id) { index, profile in
                Row(symbol: "person.crop.circle", color: profileColor(index), title: profile.name,
                    detail: spacesUsing(profile), showsDivider: index < library.profiles.count - 1, localizes: false) {
                    TextField("Name", text: Binding(get: { profile.name }, set: { library.renameProfile(profile, to: $0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 160)
                }
            }
        }
        Button {
            ProfileDialog.run(library: library, over: NSApp.keyWindow)
        } label: {
            Label("Neues Profil …", systemImage: "plus")
        }
    }

    private func profileColor(_ index: Int) -> Color {
        [Color.blue, .purple, .orange, .green, .pink, .teal][index % 6]
    }

    private func spacesUsing(_ profile: Profile) -> String {
        let names = library.spaces.filter { $0.profileID == profile.id }.map(\.name)
        return names.isEmpty ? "Von keinem Space benutzt" : "Spaces: " + names.joined(separator: ", ")
    }
}

private struct LinksPage: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
        Section(title: "Links in Tabs") {
            Row(symbol: "eye", color: .teal, title: "Peek",
                detail: "Links aus angehefteten Tabs und Favoriten zu anderen Seiten und ⇧-Klicks auf Links öffnen als Vorschau über der Seite. ⌘Z oder ⇧⌘T öffnet eine gerade geschlossene Vorschau wieder.",
                showsDivider: false) {
                Toggle("", isOn: $library.settings.peek).labelsHidden().toggleStyle(.switch)
            }
        }
        LinkRulesSection(library: library)
        Section(title: "Links aus anderen Apps") {
            Row(symbol: "macwindow.on.rectangle", color: .pink, title: "In Little OpenArch öffnen",
                detail: "Aus: Links aus Mail, Slack & Co. öffnen als neuer Tab im Fenster. An: in einem kleinen Fenster, aus dem du sie mit einem Klick in einen Space holst.") {
                Toggle("", isOn: $library.settings.linksInLittleOpenArch).labelsHidden().toggleStyle(.switch)
            }
            DefaultBrowserRow(app: app, showsDivider: false)
        }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

/// Link rules: links from other apps go straight to a space by address.
private struct LinkRulesSection: View {
    @Bindable var library: Library

    var body: some View {
        Section(title: "Link-Regeln",
                footer: "Links aus anderen Apps, die zu einer Regel passen, öffnen direkt im gewählten Space. Die erste passende Regel gilt. Beispiele: github.com (mit Subdomains), *.atlassian.net, docs.google.com/spreadsheets.") {
            if library.settings.linkRules.isEmpty {
                Text("Noch keine Regeln.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach($library.settings.linkRules) { $rule in
                HStack(spacing: 8) {
                    TextField("github.com", text: $rule.pattern).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $rule.spaceID) {
                        Text("Little OpenArch").tag(UUID?.none)
                        ForEach(library.spaces) { space in
                            Text(space.name).tag(UUID?.some(space.id))
                        }
                    }
                    .labelsHidden().frame(width: 170)
                    Button {
                        library.settings.linkRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Regel entfernen")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            HStack {
                Button("Regel hinzufügen") {
                    library.settings.linkRules.append(LinkRule(pattern: "", spaceID: library.spaces.first?.id))
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Short names for long tab titles, from Apple's model on this Mac; greyed
/// out with the reason while Apple Intelligence isn't there.
private struct TabTitlesSection: View {
    @Bindable var library: Library
    let titles = ShortTitles.shared

    var body: some View {
        let availability = titles.availability
        Section(title: "Tabs",
                footer: "Die Namen macht Apples Modell auf diesem Mac. Es bekommt nur den Titel ohne Zähler und E-Mail-Adressen und den Host der Seite, nie ihren Inhalt, den Verlauf oder den Rest der Adresse. Umbenannte Tabs, Favoriten, Ordner, Splits und private Fenster bleiben, wie sie sind. Ausschalten löscht die Namen.") {
            Row(symbol: "textformat.size.smaller", color: .teal, title: "Tab-Titel kürzen",
                detail: availability.isAvailable
                    ? "Angeheftete und heutige Tabs mit langem Titel bekommen einen kurzen Namen wie „Gmail Inbox“. Den ganzen Titel zeigt die Vorschau des Tabs."
                    : availability.reason,
                showsDivider: false) {
                HStack {
                    if availability == .notEnabled {
                        Button("Systemeinstellungen …") { AppleIntelligence.openSettings() }
                    }
                    Toggle("", isOn: Binding(get: { availability.isAvailable && library.settings.tidyTitles },
                                             set: { library.settings.tidyTitles = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!availability.isAvailable)
                }
            }
        }
        .onAppear { titles.refreshAvailability() }
        .onChange(of: library.settings.tidyTitles) { titles.settingChanged(enabled: library.settings.tidyTitles) }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

/// Questions from the command bar go to a new chat on Claude or ChatGPT,
/// signed in as you there.
private struct AskAISection: View {
    @Bindable var library: Library

    var body: some View {
        Section(title: "Fragen in der Befehlsleiste",
                footer: "Ein Satz oder eine Frage in der Befehlsleiste (⌘T) öffnet mit Enter einen neuen Chat, mit deinem Login dort und damit deinem Abo, ganz ohne API-Schlüssel. Kurze Suchen bleiben bei der Suchmaschine, der Chat steht eine Zeile darunter.") {
            Row(symbol: "bubble.left.and.text.bubble.right", color: .purple, title: "Fragen an",
                detail: "Claude öffnet claude.ai, ChatGPT öffnet chatgpt.com.", showsDivider: false) {
                Picker("", selection: $library.settings.askAI) {
                    ForEach(AIChat.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

/// Agent chats: Claude Code in the sidebar, on the login of the claude
/// command line tool.
private struct AgentChatsSection: View {
    @Bindable var library: Library
    @State private var claude: String?
    @State private var looking = true

    var body: some View {
        Section(title: "Agents in der Sidebar",
                footer: "Ein Agent-Chat steht in der Sidebar wie ein Tab. Claude Code arbeitet darin in einem Ordner auf diesem Mac, mit dem Login von claude im Terminal und damit deinem Abo, ganz ohne API-Schlüssel. Ist die KI-Steuerung an, kann der Agent auch deine Tabs bedienen.") {
            Row(symbol: "bubble.left.and.bubble.right", color: .indigo, title: "Agent-Chats",
                detail: "„Neuer Agent-Chat“ im Plus-Menü der Sidebar, in der Befehlsleiste (⌘T) und unter Ablage.") {
                Toggle("", isOn: $library.settings.agentChats).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "folder", color: .blue, title: "Ordner für neue Chats",
                detail: (library.settings.agentFolderPath as NSString).abbreviatingWithTildeInPath) {
                Button("Wählen …") { chooseFolder() }
            }
            Row(symbol: "terminal", color: .gray, title: "Claude Code", detail: status, showsDivider: false) {
                Button("Erneut suchen") {
                    AgentEnvironment.forget()
                    Task { await lookUp() }
                }
                .disabled(looking)
            }
        }
        .task { await lookUp() }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }

    private var status: String {
        if looking { return "Wird gesucht …" }
        guard let claude else { return "Nicht gefunden. Installieren: claude.ai/code, dann einmal „claude“ im Terminal zum Anmelden." }
        return "Gefunden: " + (claude as NSString).abbreviatingWithTildeInPath
    }

    private func lookUp() async {
        looking = true
        claude = await AgentEnvironment.resolved().claude
        looking = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Wählen")
        panel.directoryURL = URL(fileURLWithPath: library.settings.agentFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            library.settings.agentFolder = url.path
        }
    }
}

/// The morning brief: a page about the day ahead, once a day.
private struct MorningBriefSection: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
        Section(title: "Morning Brief",
                footer: "Claude Code schaut mit deinen Connectors (MCP-Servern) in Kalender, Mails, Chats und Aufgaben und schreibt daraus eine Seite. Sie öffnet als Tab „Morning Brief“ oben unter dem Strich, mit einem Punkt, bis du sie gelesen hast. Claude darf dabei nur lesen. Läuft mit dem Login von claude im Terminal, ohne API-Schlüssel.") {
            Row(symbol: "sun.horizon", color: .orange, title: "Morning Brief",
                detail: "Jeden Tag zur gewählten Zeit, oder beim ersten Start von OpenArch danach.") {
                Toggle("", isOn: $library.settings.morningBrief).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "clock", color: .blue, title: "Uhrzeit") {
                DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
                    .disabled(!library.settings.morningBrief)
            }
            Row(symbol: "doc.text", color: .gray, title: "Anweisung",
                detail: "Was Claude für den Brief tun soll, als Datei zum Anpassen.", showsDivider: false) {
                HStack {
                    Button("Bearbeiten …") { MorningBrief.editPrompt() }
                    Button("Jetzt erstellen") {
                        guard let browser = app.mainBrowser else { return }
                        MorningBrief.shared.run(in: browser, manual: true)
                        browser.showWindow(nil)
                    }
                }
            }
        }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }

    /// The time of day, as minutes after midnight.
    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(library.settings.morningBriefMinutes) * 60) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                library.settings.morningBriefMinutes = (parts.hour ?? 7) * 60 + (parts.minute ?? 30)
            })
    }
}

private struct AIPage: View {
    let app: AppDelegate

    var body: some View {
        TabTitlesSection(library: app.library)
        AskAISection(library: app.library)
        AgentChatsSection(library: app.library)
        MorningBriefSection(app: app, library: app.library)
        Section(title: "KI-Steuerung",
                footer: "Auf WebKit gibt es kein DevTools-Protokoll, darum entfällt die externe Steuerung (chrome-devtools-mcp, Playwright, Puppeteer). Die Agent-Chats in der Seitenleiste bedienen die Tabs weiter mit OpenArchs eigenen Werkzeugen.") {
            Row(symbol: "sparkles", color: .gray, title: "Externe Steuerung",
                detail: "In dieser Version nicht verfügbar (WebKit).", showsDivider: false) {
                EmptyView()
            }
        }
    }
}

/// Shares of this Mac and shares it follows (docs/sharing.md).
private struct SharingPage: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
        let sharing = Sharing.shared
        Section(title: "Von diesem Mac geteilt",
                footer: "Ohne Konto: Der Link ist der Schlüssel. Ordner und Spaces teilst du über ihr Menü in der Seitenleiste, als Link oder QR-Code fürs iPhone. Live-Freigaben folgen deinen Änderungen; nur dieser Mac kann sie ändern.") {
            if sharing.records.owned.isEmpty {
                Text("Noch nichts geteilt.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            ForEach(sharing.records.owned) { share in
                let target = sharing.target(of: share)
                Row(symbol: share.kind == .space ? "square.on.square" : "folder", color: .blue, title: share.name,
                    detail: target == nil ? L("Gelöscht; der Link zeigt noch den letzten Stand.") : L("Version %@", String(share.version)) + (share.passwordSlot == nil ? "" : L(" · mit Passwort")),
                    showsDivider: share.id != sharing.records.owned.last?.id, localizes: false) {
                    if let target {
                        Button("Link …") { ShareWindows.share(target, app: app) }
                    } else {
                        Button("Beenden") {
                            Task {
                                do {
                                    try await sharing.end(share)
                                } catch {
                                    sharing.lastError = "„\(share.name)“: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                }
            }
        }
        Section(title: "Mit dir geteilt",
                footer: "Geteilte Ordner und Spaces, denen du folgst, aktualisieren sich alle fünf Minuten. Was du daran änderst, überschreibt das nächste Update.") {
            ForEach(sharing.records.subscriptions) { subscription in
                Row(symbol: "person.2", color: .green, title: subscription.name,
                    detail: subscription.ended ? L("Vom Besitzer beendet") : subscription.lastChecked.map {
                        L("Geprüft %@", $0.formatted(.relative(presentation: .named)))
                    } ?? L("Noch nicht geprüft"), localizes: false) {
                    Button("Nicht mehr folgen") { sharing.unsubscribe(subscription.target) }
                }
            }
            HStack {
                Button("Geteilten Link öffnen …") { ShareWindows.askForLink(app: app) }
                Spacer()
                Button("Jetzt aktualisieren") { Task { await sharing.refresh() } }
                    .disabled(sharing.records.subscriptions.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        if let error = sharing.lastError {
            Text(error).font(.system(size: 12)).foregroundStyle(.red)
        }
        Section(title: "Teilen-Server",
                footer: "Er sieht nur verschlüsselte, signierte Daten und wer wann welche Freigabe abruft. Ein eigener Server ist relay/ aus OpenArchs Quellcode.") {
            Row(symbol: "server.rack", color: .gray, title: "Server für neue Live-Freigaben",
                detail: "Leer lassen für share.openarch.app.", showsDivider: false) {
                TextField("share.openarch.app", text: $library.settings.shareRelay)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
        }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

private struct ImportPage: View {
    let app: AppDelegate
    @Bindable var model = BrowserImportModel.shared
    @State private var passwordProfile = ""

    var body: some View {
        Section(title: "Aus Arc", footer: ArcImporter.isAvailable ? nil : "Auf diesem Mac wurden keine Arc-Daten gefunden.") {
            Row(symbol: "square.and.arrow.down.on.square", color: .purple, title: "Sidebar und alles andere",
                detail: "Spaces, Favoriten, Ordner und Tabs, dazu Logins und Cookies, Passwörter, Verlauf, Website-Daten und Extensions. OpenArch startet dafür neu.") {
                Button("Importieren …") { app.importFromArc(nil) }.disabled(!ArcImporter.isAvailable)
            }
            Row(symbol: "puzzlepiece.extension", color: .green, title: "Extensions aus Arc",
                detail: "Ein Ordner mit je einem Web-Store-Link pro Extension, falls du sie lieber neu installierst.") {
                Button("Ordner anlegen") { app.installArcExtensions(nil) }
            }
            Row(symbol: "archivebox", color: .orange, title: "Arc-Daten sichern",
                detail: "Arcs Sidebar, Spaces und Profilliste als ZIP-Datei in „Dokumente“. Arc wird am 22. Dezember 2026 eingestellt; aus der Sicherung lässt sich die Sidebar auch danach noch lesen.",
                showsDivider: false) {
                Button("Sichern") { app.backUpArc(nil) }.disabled(!ArcBackup.isAvailable)
            }
        }
        Section(title: "Aus anderen Browsern",
                footer: "Jedes Profil wird ein Profil in OpenArch und ein Space mit seinem Namen: die Lesezeichenleiste als angeheftete Tabs und Ordner, „Weitere Lesezeichen“ als eigener Ordner. Der Verlauf kommt in die Befehlsleiste. Ein zweiter Import legt nichts doppelt an. Die anderen Browser bleiben unverändert.") {
            if !model.hasDetected {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche Browser …").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(14)
            } else if model.installs.isEmpty {
                Text("Auf diesem Mac wurden keine anderen Browser gefunden.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            }
            ForEach(Array(model.installs.enumerated()), id: \.element.id) { index, install in
                BrowserImportRow(install: install, model: model, showsDivider: index < model.installs.count - 1)
            }
        }
        HStack(spacing: 10) {
            if case .running(let text, let progress) = model.phase {
                ProgressView(value: progress).frame(width: 160)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Importieren") { model.run(app: app) }
                .disabled(!model.canRun)
        }
        if case .done(let report) = model.phase {
            ImportResultView(report: report)
        }
        Section(title: "Aus Dateien",
                footer: "Passwörter liest OpenArch beim nächsten Start aus der Datei, bevor Chromium startet, und lässt die Datei unverändert. Sie enthält deine Passwörter im Klartext: Lösche sie danach.") {
            Row(symbol: "bookmark.fill", color: .blue, title: "Lesezeichen-Datei (HTML)",
                detail: "Wie Safari, Chrome, Firefox oder Edge Lesezeichen exportieren. Kommt in einen eigenen Space im aktuellen Profil.") {
                Button("Datei wählen …") { model.importBookmarksFile(app: app) }
            }
            Row(symbol: "key.fill", color: .gray, title: "Passwörter (CSV)",
                detail: "Export aus Chrome, Edge, Brave, Firefox, Safari (Passwörter-App), 1Password oder Bitwarden.",
                showsDivider: false) {
                HStack {
                    Picker("", selection: $passwordProfile) {
                        ForEach(app.library.profiles) { profile in Text(profile.name).tag(profile.id) }
                    }
                    .labelsHidden().frame(width: 130)
                    Button("Datei wählen …") {
                        model.importPasswordFile(app: app, profileID: passwordProfile.isEmpty ? app.library.profiles[0].id : passwordProfile)
                    }
                }
            }
        }
        .onAppear {
            if passwordProfile.isEmpty { passwordProfile = app.browser?.state.space.profileID ?? app.library.profiles[0].id }
            model.detect()
        }
    }
}

/// One browser: its profiles to tick, what to take, or why it cannot be read.
private struct BrowserImportRow: View {
    let install: BrowserInstall
    @Bindable var model: BrowserImportModel
    var showsDivider = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(install.name).font(.system(size: 13, weight: .medium))
                    if install.needsAccess {
                        Text(install.kind == .safari
                             ? L("Safari schützt Lesezeichen und Verlauf. Gib OpenArch unter Datenschutz & Sicherheit › Festplattenvollzugriff frei, starte OpenArch neu und öffne diese Seite dann noch einmal.")
                             : L("macOS lässt OpenArch den Ordner von %@ nicht lesen. Gib OpenArch unter Datenschutz & Sicherheit › Festplattenvollzugriff frei, starte OpenArch neu und öffne diese Seite dann noch einmal.", install.name))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                if install.needsAccess {
                    Button("Systemeinstellungen …") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if !install.needsAccess {
                HStack(spacing: 14) {
                    ForEach(BrowserImportModel.DataKind.allCases.filter { $0 != .logins || install.canImportLogins }, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { model.takes(kind, from: install) },
                                                         set: { model.set(kind, for: install, $0) }))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }
                .padding(.leading, 40)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(install.profiles) { profile in
                        Toggle(isOn: Binding(get: { model.isSelected(install, profile) },
                                             set: { model.setSelected(install, profile, $0) })) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: NSColor(hex: profile.color ?? install.kind.color) ?? .systemBlue))
                                    .frame(width: 8, height: 8)
                                Text(profile.name).font(.system(size: 12))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        if showsDivider {
            Divider().padding(.leading, 54).opacity(0.6)
        }
    }

    @ViewBuilder private var icon: some View {
        if let image = Self.appIcon(install.bundleIDs) {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: install.kind.icon)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: NSColor(hex: install.kind.color) ?? .systemBlue).gradient))
        }
    }

    static func appIcon(_ bundleIDs: [String]) -> NSImage? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

/// The numbers of the last import, and what was left out.
private struct ImportResultView: View {
    let report: BrowserImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L(report.errors.isEmpty ? "Import abgeschlossen" : "Import nicht möglich"),
                  systemImage: report.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(report.errors.isEmpty ? .green : .orange)
            if report.errors.isEmpty {
                ForEach(report.lines, id: \.self) { Text($0).font(.system(size: 12)) }
            }
            if !report.pendingLogins.isEmpty {
                Text(L("Logins und Passwörter aus %@ kommen beim nächsten Start dazu.", report.pendingLogins.joined(separator: ", ")))
                    .font(.system(size: 12))
            }
            if !report.skippedLines.isEmpty {
                Text("Übersprungen").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                ForEach(report.skippedLines, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}

private struct AboutPage: View {
    let app: AppDelegate
    @Bindable var updater = Updater.shared
    @State private var crashReports = CrashReports.shared.isEnabled

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .onTapGesture { AboutWindowController.shared.show() }
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenArch").font(.system(size: 22, weight: .bold))
                Text(L("Version %@ · WebKit", updater.versionDescription))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("von Dominik Pfaffenbauer").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Über OpenArch …") { AboutWindowController.shared.show() }
        }
        Section(title: "Updates",
                footer: "OpenArch lädt neue Versionen von GitHub, prüft Prüfsumme und Signatur und tauscht sich beim nächsten Beenden aus. Eine ältere Version als deine installiert es nie.") {
            Row(symbol: "point.3.connected.trianglepath.dotted", color: .indigo, title: "Update-Kanal",
                detail: updater.channel == .stable
                    ? "Stable: die veröffentlichten Versionen. Kommst du von Nightly, wartet OpenArch, bis Stable aufholt."
                    : "Nightly: jeder Build von main, mit allem Neuen und manchem Fehler.") {
                Picker("", selection: $updater.channel) {
                    ForEach(Updater.Channel.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Row(symbol: "arrow.down.circle", color: .green, title: "Automatisch aktualisieren",
                detail: "Sucht beim Start und alle sechs Stunden nach einer neuen Version.") {
                Toggle("", isOn: $updater.isEnabled).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "clock.arrow.circlepath", color: .gray, title: updateTitle, detail: updateDetail, showsDivider: false, localizes: false) {
                if case .ready = updater.phase {
                    Button("Neu starten") { updater.installAndRelaunch() }
                } else {
                    Button("Jetzt prüfen") { updater.check() }
                        .disabled(updater.phase == .checking || isDownloading)
                }
            }
        }
        Section(title: "Daten") {
            Row(symbol: "folder", color: .blue, title: "Profile, Sidebar und Verlauf",
                detail: AppPaths.support.path, showsDivider: false) {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) }
            }
        }
        BackupSection(app: app)
        Section(title: "Absturzberichte",
                footer: "Ein Bericht enthält Versionen, die Art des Prozesses und die Stelle im Code, nie Adressen, Titel oder Seiteninhalte. Er geht nur als GitHub-Issue raus, das du selbst abschickst.") {
            Row(symbol: "ant", color: .red, title: "Nach einem Absturz fragen",
                detail: "Merkt sich Abstürze von OpenArch und seinen Prozessen und fragt beim nächsten Start, ob du einen Bericht senden willst.",
                showsDivider: !FeatureSwitches.shared.disabled.isEmpty) {
                Toggle("", isOn: $crashReports).labelsHidden().toggleStyle(.switch)
                    .onChange(of: crashReports) { CrashReports.shared.isEnabled = crashReports }
            }
            let disabled = FeatureSwitches.shared.disabled
            if !disabled.isEmpty {
                Row(symbol: "switch.2", color: .orange, title: "Vorübergehend abgeschaltet",
                    detail: disabled.sorted { $0.key.rawValue < $1.key.rawValue }
                        .map { "\($0.key.title): \($0.value)" }.joined(separator: "\n"),
                    showsDivider: false) { EmptyView() }
            }
        }
        Section(title: "Projekt") {
            Row(symbol: "chevron.left.forwardslash.chevron.right", color: .gray, title: "Quellcode auf GitHub",
                detail: "github.com/dpfaffenbauer/OpenArch", showsDivider: false) {
                Button("Öffnen") { app.browser?.openInNewTab("https://github.com/dpfaffenbauer/OpenArch") }
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = updater.phase { return true }
        return false
    }

    private var updateTitle: String {
        switch updater.phase {
        case .idle: L("Updates")
        case .checking: L("Suche nach Updates …")
        case .upToDate: L("OpenArch ist aktuell")
        case .downloading(let progress): L("Lade Update … %lld %%", Int(progress * 100))
        case .ready(let build): L("%@ ist bereit", updater.readyVersion ?? L("Nightly %lld", build))
        case .failed: L("Update nicht möglich")
        }
    }

    private var updateDetail: String? {
        switch updater.phase {
        case .ready: L("Wird beim Neustart oder beim nächsten Beenden installiert.")
        case .failed(let message): message
        case .upToDate where updater.aheadOfChannel != nil:
            L("Deine Version ist neuer als die neueste auf %@ (Build %lld). Sie bleibt, bis %@ aufholt.", updater.channel.title, updater.aheadOfChannel ?? 0, updater.channel.title)
        default: updater.lastCheck.map { L("Zuletzt geprüft: %@", $0.formatted(date: .omitted, time: .shortened)) }
        }
    }
}

/// Settings › Info › Sicherung: the daily backup, export and import.
private struct BackupSection: View {
    let app: AppDelegate
    @State private var isEnabled = Backups.shared.isEnabled
    @State private var folder = Backups.shared.folder
    @State private var lastBackup = Backups.shared.lastBackup
    @State private var error: String?

    var body: some View {
        Section(title: "Sicherung",
                footer: "Jeden Tag ein Ordner mit Library.json (Spaces, Tabs, Link-Regeln), Boosts und Einstellungen; die letzten \(Backups.keep) bleiben. Logins, Passwörter und Verlauf sind nicht dabei.") {
            Row(symbol: "clock.arrow.2.circlepath", color: .teal, title: "Tägliche Sicherung",
                detail: error ?? lastBackup.map { L("Zuletzt: %@", $0.formatted(date: .abbreviated, time: .shortened)) }
                    ?? "Noch keine Sicherung.") {
                HStack {
                    Button("Jetzt sichern") {
                        do {
                            try Backups.shared.backUp(library: app.library)
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                        lastBackup = Backups.shared.lastBackup
                    }
                    Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
                        .onChange(of: isEnabled) { Backups.shared.isEnabled = isEnabled }
                }
            }
            Row(symbol: "folder.badge.gearshape", color: .blue, title: "Ordner",
                detail: (folder.path as NSString).abbreviatingWithTildeInPath) {
                HStack {
                    Button("Zeigen") {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    }
                    Button("Wählen …") { chooseFolder() }
                }
            }
            Row(symbol: "arrow.up.arrow.down.square", color: .gray, title: "Export und Import",
                detail: "Eine Sicherung in einen Ordner deiner Wahl, oder eine zurückholen (OpenArch startet dafür neu).",
                showsDivider: false) {
                HStack {
                    Button("Exportieren …") { Backups.shared.exportInteractively(library: app.library) }
                    Button("Importieren …") { Backups.shared.importInteractively(library: app.library) }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = L("Wählen")
        panel.message = L("Wohin sollen die täglichen Sicherungen? Ein Ordner in iCloud Drive geht auch.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Backups.shared.folder = url
        folder = Backups.shared.folder
    }
}
