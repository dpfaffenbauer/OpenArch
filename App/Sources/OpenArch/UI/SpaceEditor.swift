import SwiftUI

/// Popover for a space: name, icon, color and profile.
struct SpaceEditor: View {
    let browser: BrowserWindowController
    @Bindable var space: Space
    @State private var emoji = ""

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 5), count: 9)

    var body: some View {
        let library = browser.library
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: $space.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .semibold))
                .onChange(of: space.name) { library.setNeedsSave() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Symbol").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(spaceIconPresets, id: \.self) { icon in
                        SpaceIcon(icon: icon, size: 12)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(space.icon == icon ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06)))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                space.icon = icon
                                library.setNeedsSave()
                            }
                    }
                }
                HStack {
                    Text("oder Emoji").font(.caption).foregroundStyle(.secondary)
                    TextField("😀", text: $emoji)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .onChange(of: emoji) { _, value in
                            if let first = value.first(where: { $0.unicodeScalars.first?.properties.isEmoji == true && !$0.isNumber }) {
                                space.icon = String(first)
                                library.setNeedsSave()
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Farbe").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(spaceColorPresets, id: \.self) { hex in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(space.colorHex == hex ? 0.8 : 0), lineWidth: 2))
                            .onTapGesture {
                                space.colorHex = hex
                                library.setNeedsSave()
                            }
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: space.color) },
                        set: { color in
                            space.colorHex = NSColor(color).hexString
                            library.setNeedsSave()
                        }), supportsOpacity: false)
                        .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Profil").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { space.profileID },
                    set: { browser.setProfile($0, for: space) })) {
                    ForEach(library.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                Text("Jedes Profil hat eigene Logins, Cookies, Verlauf und Extensions. Spaces können sich ein Profil teilen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Neues Profil …") {
                    // Close the popover first; the dialog is modal.
                    browser.state.editingSpaceID = nil
                    let browser = self.browser, space = self.space
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let profile = ProfileDialog.run(library: browser.library, over: browser.window) {
                                browser.setProfile(profile.id, for: space)
                            }
                        }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

}

/// Shown in the content area when no tab is open.
struct EmptyContentView: View {
    let browser: BrowserWindowController

    var body: some View {
        let space = browser.state.space
        let theme = SpaceTheme(hex: space.colorHex)
        RoundedRectangle(cornerRadius: 8)
            .fill(theme.foreground.opacity(0.06))
            .overlay {
                VStack(spacing: 12) {
                    SpaceIcon(icon: space.icon, size: 30).opacity(0.5)
                    Text(space.name).font(.system(size: 18, weight: .semibold))
                    Button {
                        browser.commandBar.show(mode: .newTab)
                    } label: {
                        Text("Neuer Tab   ⌘T").padding(.horizontal, 6)
                    }
                    .controlSize(.large)
                }
                .foregroundStyle(theme.foreground)
            }
            .environment(\.colorScheme, theme.colorScheme)
    }
}
