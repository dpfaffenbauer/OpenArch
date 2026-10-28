import AppKit
import OpenArchCore
import SwiftUI

/// Arc's Site Control Center: what the site in front may do, its zoom, its
/// data and its boost. Opens from the sidebar's top bar.
struct SiteControls: View {
    let browser: BrowserWindowController
    let item: Item
    @State private var values: [OACSitePermission: OACPermissionValue] = [:]
    @State private var zoom = 100
    @State private var confirmingClear = false
    @State private var cleared = false

    private var origin: String? { SiteControls.origin(of: item.currentURL) }
    private var profile: OACProfile? { item.pane?.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let origin, let profile {
                Divider()
                VStack(spacing: 2) {
                    ForEach(SitePermission.all) { permission in
                        PermissionRow(permission: permission, value: binding(permission, origin: origin, profile: profile))
                    }
                }
            }
            Divider()
            zoomRow
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320)
        .onAppear(perform: load)
    }

    private var header: some View {
        let secure = item.currentURL.hasPrefix("https://")
        let web = origin != nil
        return HStack(spacing: 10) {
            FaviconView(item: item, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: item.currentURL)?.host() ?? item.displayTitle)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if web {
                    Label(secure ? "Verbindung ist sicher" : "Verbindung ist nicht sicher",
                          systemImage: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(secure ? Color.secondary : Color.orange)
                } else {
                    Text("Eine Seite von OpenArch").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").frame(width: 20).foregroundStyle(.secondary)
            Text("Zoom").font(.system(size: 13))
            Spacer()
            if zoom != 100 {
                Button("Zurücksetzen") { zoomCommand(.zoomNormal) }
                    .buttonStyle(.borderless).font(.system(size: 12))
            }
            ControlGroup {
                Button { zoomCommand(.zoomMinus) } label: { Image(systemName: "minus") }
                Text("\(zoom) %").font(.system(size: 12).monospacedDigit()).frame(width: 46)
                Button { zoomCommand(.zoomPlus) } label: { Image(systemName: "plus") }
            }
            .fixedSize()
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            ActionRow(symbol: "paintbrush", title: "Boost bearbeiten …") {
                browser.state.siteControlsVisible = false
                BoostPanelController.show(for: item, browser: browser)
            }
            .disabled(origin == nil)
            ActionRow(symbol: "link", title: "URL kopieren") {
                browser.copyURL()
                browser.state.siteControlsVisible = false
            }
            ActionRow(symbol: cleared ? "checkmark" : "trash", title: cleared ? "Website-Daten gelöscht" : "Website-Daten löschen …",
                      isDestructive: !cleared) {
                confirmingClear = true
            }
            .disabled(origin == nil || cleared)
            .confirmationDialog("Cookies und gespeicherte Daten dieser Website löschen?", isPresented: $confirmingClear) {
                Button("Löschen", role: .destructive, action: clearData)
            } message: {
                Text("Du wirst auf \(URL(string: item.currentURL)?.host() ?? "der Website") abgemeldet. Die Seite lädt danach neu.")
            }
        }
    }

    private func binding(_ permission: SitePermission, origin: String, profile: OACProfile) -> Binding<OACPermissionValue> {
        Binding(
            get: { values[permission.kind] ?? .default },
            set: { value in
                values[permission.kind] = value
                profile.setPermission(permission.kind, forSite: origin, value: value)
            })
    }

    private func load() {
        zoom = item.pane?.zoomPercent ?? 100
        guard let origin, let profile else { return }
        for permission in SitePermission.all {
            values[permission.kind] = profile.permission(permission.kind, forSite: origin)
        }
    }

    private func zoomCommand(_ command: OACChromeCommand) {
        item.pane?.executeChromeCommand(command.rawValue)
        after(0.1) { zoom = item.pane?.zoomPercent ?? 100 }
    }

    private func clearData() {
        guard let origin, let pane = item.pane else { return }
        pane.callDevToolsMethod("Storage.clearDataForOrigin", params: ["origin": origin, "storageTypes": "all"]) { result in
            guard result != nil else { return NSSound.beep() }
            cleared = true
            pane.reload()
        }
    }

    /// "https://example.com" for a web page, nil for OpenArch's and Chrome's
    /// own pages.
    static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme,
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (components.port.map { ":\($0)" } ?? "")
    }
}

/// A permission the Site Control Center offers, and what Chrome does when
/// nothing is chosen.
struct SitePermission: Identifiable {
    let kind: OACSitePermission
    let title: String
    let symbol: String
    let defaultTitle: String
    /// Whether the site can be made to ask each time.
    var canAsk = true
    var id: Int { kind.rawValue }

    static let all: [SitePermission] = [
        SitePermission(kind: .camera, title: "Kamera", symbol: "camera", defaultTitle: "Fragen"),
        SitePermission(kind: .microphone, title: "Mikrofon", symbol: "mic", defaultTitle: "Fragen"),
        SitePermission(kind: .location, title: "Standort", symbol: "location", defaultTitle: "Fragen"),
        SitePermission(kind: .notifications, title: "Mitteilungen", symbol: "bell", defaultTitle: "Fragen"),
        SitePermission(kind: .popups, title: "Pop-ups", symbol: "macwindow.on.rectangle", defaultTitle: "Blockieren", canAsk: false),
        SitePermission(kind: .sound, title: "Ton", symbol: "speaker.wave.2", defaultTitle: "Erlauben", canAsk: false),
        SitePermission(kind: .automaticDownloads, title: "Mehrere Downloads", symbol: "arrow.down.circle", defaultTitle: "Fragen"),
        SitePermission(kind: .clipboard, title: "Zwischenablage", symbol: "doc.on.clipboard", defaultTitle: "Fragen"),
        SitePermission(kind: .javaScript, title: "JavaScript", symbol: "curlybraces", defaultTitle: "Erlauben", canAsk: false),
    ]
}

private struct PermissionRow: View {
    let permission: SitePermission
    @Binding var value: OACPermissionValue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: permission.symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(permission.title).font(.system(size: 13))
            Spacer()
            Picker("", selection: $value) {
                Text("Standard (\(permission.defaultTitle))").tag(OACPermissionValue.default)
                Divider()
                if permission.canAsk { Text("Fragen").tag(OACPermissionValue.ask) }
                Text("Erlauben").tag(OACPermissionValue.allow)
                Text("Blockieren").tag(OACPermissionValue.block)
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .frame(height: 26)
    }
}

private struct ActionRow: View {
    let symbol: String
    let title: String
    var isDestructive = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer()
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, 4)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering && isEnabled ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}
