import AppKit
import OpenArchCore
import SwiftUI

/// Settings in Arc's style: a tab bar with icons, options in rounded cards.
struct SettingsView: View {
    let app: AppDelegate
    @State private var page: SettingsPage

    init(app: AppDelegate, page: SettingsPage = .general) {
        self.app = app
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    SettingsTab(page: item, isSelected: page == item) { page = item }
                }
            }
            // Just under the window buttons: the view runs under the
            // transparent title bar instead of starting below it.
            .padding(.top, 38)
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch page {
                    case .general: GeneralPage(app: app, library: app.library)
                    case .profiles: ProfilesPage(app: app, library: app.library)
                    case .links: LinksPage(app: app, library: app.library)
                    case .ai: AIPage(app: app)
                    case .importing: ImportPage(app: app)
                    case .about: AboutPage(app: app)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: 640, height: 580)
        .background(.background)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, profiles, links, ai, importing, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Allgemein"
        case .profiles: "Profile"
        case .links: "Links"
        case .ai: "KI"
        case .importing: "Import"
        case .about: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .profiles: "person.2"
        case .links: "link"
        case .ai: "sparkles"
        case .importing: "square.and.arrow.down"
        case .about: "info.circle"
        }
    }
}

private struct SettingsTab: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: page.symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(page.title).font(.system(size: 11, weight: .medium))
            }
            .frame(width: 78, height: 50)
            .background(RoundedRectangle(cornerRadius: 9).fill(
                isSelected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear)))
            .foregroundStyle(isSelected ? Color.accentColor : .primary.opacity(0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One setting: colored icon, title, explanation, control on the right.
private struct Row<Control: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    var showsDivider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(color.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if showsDivider {
                Divider().padding(.leading, 54).opacity(0.6)
            }
        }
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
            DefaultBrowserRow(app: app, showsDivider: false)
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
                detail: "Tabs, die du so lange nicht angesehen hast, geben ihren Speicher frei und laden neu, wenn du zurückkommst. Tabs mit Ton oder ungespeicherten Eingaben bleiben wach.") {
                Picker("", selection: $library.settings.sleepAfterMinutes) {
                    Text("nach 30 Minuten").tag(30)
                    Text("nach 1 Stunde").tag(60)
                    Text("nach 2 Stunden").tag(120)
                    Text("nach 6 Stunden").tag(360)
                    Text("nie").tag(0)
                }
                .labelsHidden().fixedSize()
            }
            Row(symbol: "eye", color: .teal, title: "Peek",
                detail: "Links aus angehefteten Tabs und Favoriten zu anderen Seiten öffnen als Vorschau über der Seite.") {
                Toggle("", isOn: $library.settings.peek).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "pip", color: .pink, title: "Bild-in-Bild beim Tab-Wechsel",
                detail: "Ein laufendes Video mit Ton spielt in einem kleinen Fenster weiter, wenn du den Tab verlässt.") {
                Toggle("", isOn: $library.settings.autoPictureInPicture).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "menubar.rectangle", color: .indigo, title: "Chrome-Toolbar in Tabs",
                detail: "Adressleiste, Extension-Symbole und Downloads über der Seite (⌘⇧D).") {
                Toggle("", isOn: Binding(
                    get: { library.settings.showChromeToolbar },
                    set: { if $0 != library.settings.showChromeToolbar { app.browser?.toggleChromeToolbar() } }))
                    .labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "character.textbox", color: .gray, title: "Adresse oben in der Sidebar", showsDivider: false) {
                Toggle("", isOn: $library.settings.showSidebarAddress).labelsHidden().toggleStyle(.switch)
            }
        }
        Section(title: "Sicherheit") {
            Row(symbol: "lock", color: .green, title: "Nur HTTPS",
                detail: "Adressen mit http:// werden zuerst verschlüsselt geladen. Geht das nicht, fragt OpenArch, bevor die Seite unverschlüsselt öffnet.", showsDivider: false) {
                Toggle("", isOn: $library.settings.httpsOnly).labelsHidden().toggleStyle(.switch)
                    .onChange(of: library.settings.httpsOnly) { library.settings.applyToChromium() }
            }
        }
        Section(title: "Sidebar") {
            Row(symbol: "sidebar.left", color: .purple, title: "Breite",
                detail: "Auch durch Ziehen am Rand der Sidebar; ganz nach links zieht sie zu.") {
                Slider(value: $library.settings.sidebarWidth, in: 200...440, step: 10).frame(width: 160)
                    .onChange(of: library.settings.sidebarWidth) { app.browsers.forEach { $0.layoutContent() } }
            }
            Row(symbol: "rectangle.on.rectangle", color: .cyan, title: "Glas-Effekt",
                detail: "Der Schreibtisch scheint verschwommen durch die Sidebar, getönt in der Farbe des Space. Die Seiten liegen als Karten darauf.") {
                Toggle("", isOn: $library.settings.glass).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "drop.halffull", color: .cyan, title: "Farbe über dem Glas",
                detail: "Wenig lässt mehr vom Schreibtisch durch, viel hält die Schrift gut lesbar.", showsDivider: false) {
                Slider(value: $library.settings.glassTint, in: 0.15...0.9).frame(width: 160)
                    .disabled(!library.settings.glass)
            }
        }
        .onChange(of: library.settings.glass) { app.browsers.forEach { $0.applyTheme() } }
        .onChange(of: library.settings.glassTint) { app.browsers.forEach { $0.applyTheme() } }
        AppIconSection()
        SiteSearchSection(library: library)
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

/// The Dock icon, like Arc's icon choice.
struct AppIconSection: View {
    @State private var selection = AppIcons.style

    var body: some View {
        Section(title: "App-Symbol",
                footer: "Zwölf Wege durch den Bogen; Tunnel ist OpenArchs eigenes. „Space-Farbe“ nimmt im Dock die Farbe des Space an, in dem du gerade bist, „Jeden Tag“ nimmt jeden Tag ein anderes. Die festen Symbole gelten auch für OpenArch im Finder.") {
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
                    detail: spacesUsing(profile), showsDivider: index < library.profiles.count - 1) {
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
        panel.prompt = "Wählen"
        panel.directoryURL = URL(fileURLWithPath: library.settings.agentFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            library.settings.agentFolder = url.path
        }
    }
}

private struct AIPage: View {
    let app: AppDelegate
    @State private var enabled = AIControl.isEnabled
    @State private var port = AIControl.configuredPort
    @State private var copied = false

    var body: some View {
        let running = OACEngine.remoteDebuggingPort
        AskAISection(library: app.library)
        AgentChatsSection(library: app.library)
        Section(title: "KI-Steuerung",
                footer: "OpenArch öffnet dafür Chromes DevTools-Protokoll auf 127.0.0.1. Solange das an ist, kann jedes Programm auf diesem Mac den Browser steuern, auch eingeloggte Tabs. Schalte es nur ein, wenn du es brauchst.") {
            Row(symbol: "sparkles", color: .orange, title: "KI-Steuerung erlauben",
                detail: "Für Claude Code, Playwright oder Puppeteer: Seiten öffnen, klicken, Formulare ausfüllen, Screenshots, Konsole und Netzwerk.") {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                    .onChange(of: enabled) { AIControl.isEnabled = enabled }
            }
            Row(symbol: "number", color: .gray, title: "Port", showsDivider: false) {
                TextField("9222", value: $port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                    .onChange(of: port) { AIControl.configuredPort = port }
            }
        }
        if (enabled ? port : 0) != running {
            HStack {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                Text(enabled ? "Wird nach einem Neustart von OpenArch aktiv." : "Wird nach einem Neustart abgeschaltet.")
                    .font(.system(size: 12))
                Spacer()
                Button("Jetzt neu starten") { app.relaunch() }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        } else if running > 0 {
            Label("Aktiv auf 127.0.0.1:\(running)", systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
        }
        Section(title: "Mit Claude Code verbinden",
                footer: "Einmal im Terminal ausführen. Danach kann Claude in jedem Projekt OpenArch steuern, etwa um eine lokale Seite zu testen. Nutzt Googles MCP-Server chrome-devtools-mcp.") {
            HStack(alignment: .top) {
                Text(AIControl.claudeCommand(port: port))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(copied ? "Kopiert" : "Kopieren") {
                    copy(AIControl.claudeCommand(port: port))
                    copied = true
                }
            }
            .padding(14)
        }
    }
}

private struct ImportPage: View {
    let app: AppDelegate

    var body: some View {
        Section(title: "Aus Arc", footer: ArcImporter.isAvailable ? nil : "Auf diesem Mac wurden keine Arc-Daten gefunden.") {
            Row(symbol: "square.and.arrow.down.on.square", color: .purple, title: "Sidebar und alles andere",
                detail: "Spaces, Favoriten, Ordner und Tabs, dazu Logins und Cookies, Passwörter, Verlauf, Website-Daten und Extensions. OpenArch startet dafür neu.") {
                Button("Importieren …") { app.importFromArc(nil) }.disabled(!ArcImporter.isAvailable)
            }
            Row(symbol: "puzzlepiece.extension", color: .green, title: "Extensions aus Arc",
                detail: "Ein Ordner mit je einem Web-Store-Link pro Extension, falls du sie lieber neu installierst.", showsDivider: false) {
                Button("Ordner anlegen") { app.installArcExtensions(nil) }
            }
        }
    }
}

private struct AboutPage: View {
    let app: AppDelegate
    @Bindable var updater = Updater.shared

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                .onTapGesture { AboutWindowController.shared.show() }
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenArch").font(.system(size: 22, weight: .bold))
                Text("Version \(updater.versionDescription) · Chromium \(OACEngine.versionString)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("von Dominik Pfaffenbauer").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Über OpenArch …") { AboutWindowController.shared.show() }
        }
        Section(title: "Updates",
                footer: "OpenArch lädt neue Nightly-Builds von GitHub, prüft ihre Prüfsumme und tauscht sich beim nächsten Beenden aus.") {
            Row(symbol: "arrow.down.circle", color: .green, title: "Automatisch aktualisieren",
                detail: "Sucht beim Start und alle sechs Stunden nach einer neuen Version.") {
                Toggle("", isOn: $updater.isEnabled).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "clock.arrow.circlepath", color: .gray, title: updateTitle, detail: updateDetail, showsDivider: false) {
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
        case .idle: "Updates"
        case .checking: "Suche nach Updates …"
        case .upToDate: "OpenArch ist aktuell"
        case .downloading(let progress): "Lade Update … \(Int(progress * 100)) %"
        case .ready(let build): "Nightly \(build) ist bereit"
        case .failed: "Update nicht möglich"
        }
    }

    private var updateDetail: String? {
        switch updater.phase {
        case .ready: "Wird beim Neustart oder beim nächsten Beenden installiert."
        case .failed(let message): message
        default: updater.lastCheck.map { "Zuletzt geprüft: \($0.formatted(date: .omitted, time: .shortened))" }
        }
    }
}
