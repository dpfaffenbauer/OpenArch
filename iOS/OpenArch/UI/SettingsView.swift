import OpenArchShared
import SwiftUI

struct SettingsView: View {
    @Bindable var browser: Browser

    var body: some View {
        @Bindable var library = browser.library
        let sharing = browser.sharing
        NavigationStack {
            Form {
                Section("Suche") {
                    Picker("Suchmaschine", selection: $library.settings.searchEngine) {
                        ForEach(Settings.SearchEngine.allCases) { engine in
                            Text(engine.name).tag(engine)
                        }
                    }
                    Toggle("Suchvorschläge", isOn: $library.settings.searchSuggestions)
                }
                Section {
                    Picker("Heute-Tabs archivieren", selection: $library.settings.archiveAfterHours) {
                        Text("Nach 12 Stunden").tag(12)
                        Text("Nach 24 Stunden").tag(24)
                        Text("Nach 7 Tagen").tag(24 * 7)
                        Text("Nie").tag(0)
                    }
                    NavigationLink("Archiv") { ArchiveList(browser: browser) }
                } footer: {
                    Text("Tabs unter der Linie, die du so lange nicht angesehen hast, kommen ins Archiv, wie auf dem Mac.")
                }

                Section {
                    ForEach(sharing.records.owned) { share in
                        let target = sharing.target(of: share)
                        Button {
                            if let target { browser.present(.share(target)) }
                        } label: {
                            LabeledContent {
                                Text(target == nil ? "Gelöscht" : "Version \(share.version)")
                            } label: {
                                Label(share.name, systemImage: share.kind == .space ? "square.on.square" : "folder")
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Beenden", role: .destructive) { Task { try? await sharing.end(share) } }
                        }
                    }
                    ForEach(sharing.records.subscriptions) { subscription in
                        LabeledContent {
                            if subscription.ended {
                                Text("Beendet")
                            } else if let date = subscription.lastChecked {
                                Text(date.formatted(.relative(presentation: .named)))
                            }
                        } label: {
                            Label(subscription.name, systemImage: "person.2")
                        }
                        .swipeActions {
                            Button("Nicht mehr folgen", role: .destructive) { sharing.unsubscribe(subscription.target) }
                        }
                    }
                    Button("Code scannen", systemImage: "qrcode.viewfinder") { browser.present(.scanner) }
                    PasteButton(payloadType: String.self) { strings in
                        let link = strings.lazy.compactMap { ShareURL(string: $0) }.first
                        Task { @MainActor in
                            if let link {
                                browser.present(.importShare(link))
                            } else {
                                browser.showToast("Kein OpenArch-Link in der Zwischenablage")
                            }
                        }
                    }
                    if let error = sharing.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Teilen")
                } footer: {
                    Text("Ordner und Spaces teilst du über ihr Menü. Ohne Konto: Der Link ist der Schlüssel, und der Server sieht nur verschlüsselte Daten. Geteilte Ordner und Spaces, denen du folgst, aktualisieren sich alle fünf Minuten, solange OpenArch offen ist.")
                }

                Section {
                    TextField("share.openarch.app", text: $library.settings.relay)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Teilen-Server")
                } footer: {
                    Text("Für neue Live-Freigaben. Leer lassen für share.openarch.app; ein eigener Server muss relay/ aus OpenArchs Quellcode sein und https sprechen.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link("OpenArch auf GitHub", destination: URL(string: "https://github.com/dpfaffenbauer/OpenArch")!)
                    Link("openarch.app", destination: URL(string: "https://openarch.app")!)
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { browser.sheet = nil }
                }
            }
            .onChange(of: library.settings) { browser.library.setNeedsSave() }
        }
    }
}

private struct ArchiveList: View {
    let browser: Browser

    var body: some View {
        List {
            ForEach(browser.library.archive) { tab in
                Button {
                    browser.reopen(tab)
                } label: {
                    HStack(spacing: 12) {
                        FaviconView(host: URL(string: tab.url)?.host() ?? "", size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.title).lineLimit(1)
                            Text(tab.date.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { offsets in
                browser.library.archive.remove(atOffsets: offsets)
                browser.library.setNeedsSave()
            }
        }
        .overlay {
            if browser.library.archive.isEmpty {
                ContentUnavailableView("Archiv leer", systemImage: "archivebox")
            }
        }
        .navigationTitle("Archiv")
        .toolbar {
            if !browser.library.archive.isEmpty {
                Button("Leeren", role: .destructive) {
                    browser.library.archive.removeAll()
                    browser.library.setNeedsSave()
                }
            }
        }
    }
}

/// A space's name, icon and color.
struct SpaceEditor: View {
    let browser: Browser
    @Bindable var space: Space

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $space.name)
                }
                Section("Farbe") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(spaceColorPresets, id: \.self) { hex in
                            Circle()
                                .fill(Color(uiColor: UIColor(hex: hex) ?? .gray))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if space.colorHex == hex {
                                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { space.colorHex = hex }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(spaceIconPresets, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .background(space.icon == icon ? Color.accentColor.opacity(0.25) : .clear, in: Circle())
                                .onTapGesture { space.icon = icon }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(.vertical, 4)
                    TextField("Oder ein Emoji", text: Binding(
                        get: { UIImage(systemName: space.icon) == nil ? space.icon : "" },
                        set: { if let first = $0.first { space.icon = String(first) } }))
                }
            }
            .navigationTitle("Space bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        browser.library.setNeedsSave()
                        browser.sheet = nil
                    }
                }
            }
        }
    }
}
