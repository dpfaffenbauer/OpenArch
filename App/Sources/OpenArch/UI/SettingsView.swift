import OpenArchCore
import SwiftUI

struct SettingsView: View {
    let app: AppDelegate

    var body: some View {
        TabView {
            GeneralSettings(library: app.library)
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            ProfileSettings(app: app, library: app.library)
                .tabItem { Label("Profile", systemImage: "person.2") }
            AboutSettings(app: app)
                .tabItem { Label("Info", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 520, height: 460)
    }
}

private struct GeneralSettings: View {
    @Bindable var library: Library

    var body: some View {
        Form {
            Picker("Suchmaschine", selection: $library.settings.searchEngine) {
                ForEach(Settings.SearchEngine.allCases) { engine in
                    Text(engine.name).tag(engine)
                }
            }
            Toggle("Suchvorschläge in der Befehlsleiste", isOn: $library.settings.searchSuggestions)
            Picker("Tabs unter dem Strich archivieren", selection: $library.settings.archiveAfterHours) {
                Text("nach 12 Stunden").tag(12)
                Text("nach 24 Stunden").tag(24)
                Text("nach 7 Tagen").tag(24 * 7)
                Text("nach 30 Tagen").tag(24 * 30)
                Text("nie").tag(0)
            }
            Toggle("Adresse oben in der Sidebar anzeigen", isOn: $library.settings.showSidebarAddress)
            Toggle("Chrome-Toolbar anzeigen (Adressleiste, Extensions, Downloads)", isOn: Binding(
                get: { library.settings.showChromeToolbar },
                set: { value in
                    if value != library.settings.showChromeToolbar {
                        (NSApp.delegate as? AppDelegate)?.browser?.toggleChromeToolbar()
                    }
                }))
            Slider(value: $library.settings.sidebarWidth, in: 200...420, step: 10) {
                Text("Breite der Sidebar")
            }
            .onChange(of: library.settings.sidebarWidth) {
                (NSApp.delegate as? AppDelegate)?.browser?.layoutContent()
            }
        }
        .formStyle(.grouped)
        .onChange(of: library.settings) { library.setNeedsSave() }
    }
}

private struct ProfileSettings: View {
    let app: AppDelegate
    @Bindable var library: Library

    var body: some View {
        Form {
            Section {
                ForEach(library.profiles) { profile in
                    HStack {
                        TextField("Name", text: Binding(
                            get: { profile.name },
                            set: { library.renameProfile(profile, to: $0) }))
                        Text(spacesUsing(profile)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Profile")
            } footer: {
                Text("Ein Profil hält Logins, Cookies, Verlauf, Passwörter und Extensions getrennt. Welches Profil ein Space nutzt, stellst du im Space ein (Doppelklick auf den Space-Namen).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Neues Profil …") {
                    ProfileDialog.run(library: library, over: NSApp.keyWindow)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func spacesUsing(_ profile: Profile) -> String {
        let names = library.spaces.filter { $0.profileID == profile.id }.map(\.name)
        return names.isEmpty ? "kein Space" : names.joined(separator: ", ")
    }
}

private struct AboutSettings: View {
    let app: AppDelegate

    var body: some View {
        Form {
            LabeledContent("OpenArch", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
            LabeledContent("Chromium", value: OACEngine.versionString)
            LabeledContent("Daten") {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) }
            }
            Section {
                Button("Sidebar aus Arc importieren …") { app.importFromArc(nil) }
                    .disabled(!ArcImporter.isAvailable)
                Button("Extensions aus Arc …") { app.installArcExtensions(nil) }
                Button("Als Standardbrowser festlegen") { app.setAsDefaultBrowser(nil) }
            }
        }
        .formStyle(.grouped)
    }
}
