import AppKit
import OpenArchCore
import SwiftUI

/// Settings in Arc's style: a tab bar with icons, options in rounded cards.
struct SettingsView: View {
    let app: AppDelegate
    @State private var page = SettingsPage.general

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    SettingsTab(page: item, isSelected: page == item) { page = item }
                }
            }
            .padding(.top, 34)
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

private struct GeneralPage: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
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
        SiteSearchSection(library: library)
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
        Section(title: "Sidebar") {
            Row(symbol: "sidebar.left", color: .purple, title: "Breite",
                detail: "Auch durch Ziehen am Rand der Sidebar; ganz nach links zieht sie zu.", showsDivider: false) {
                Slider(value: $library.settings.sidebarWidth, in: 200...440, step: 10).frame(width: 160)
                    .onChange(of: library.settings.sidebarWidth) { app.browser?.layoutContent() }
            }
        }
        .onChange(of: library.settings) { library.setNeedsSave() }
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
        Section(title: "Links aus anderen Apps") {
            Row(symbol: "macwindow.on.rectangle", color: .pink, title: "In Little OpenArch öffnen",
                detail: "Links aus Mail, Slack & Co. öffnen in einem kleinen Fenster. Von dort holst du sie mit einem Klick in einen Space.") {
                Toggle("", isOn: $library.settings.openLinksInLittleOpenArch).labelsHidden().toggleStyle(.switch)
            }
            Row(symbol: "globe", color: .blue, title: "Standardbrowser",
                detail: "Damit Links aus anderen Apps in OpenArch landen.", showsDivider: false) {
                Button("Als Standard festlegen") { app.setAsDefaultBrowser(nil) }
            }
        }
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

private struct AIPage: View {
    let app: AppDelegate
    @State private var enabled = AIControl.isEnabled
    @State private var port = AIControl.configuredPort
    @State private var copied = false

    var body: some View {
        let running = OACEngine.remoteDebuggingPort
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
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenArch").font(.system(size: 22, weight: .bold))
                Text("Version \(updater.versionDescription) · Chromium \(OACEngine.versionString)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
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
