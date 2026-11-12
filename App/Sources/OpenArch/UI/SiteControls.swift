import AppKit
import OpenArchCore
import OpenArchLocalization
import SwiftUI

/// Arc's Site Control Center: what the site in front may do, its zoom, its
/// data and its boost. Opens beside Copy URL in the sidebar's address bar.
struct SiteControls: View {
    let browser: BrowserWindowController
    let item: Item
    @State private var values: [OACSitePermission: OACPermissionValue] = [:]
    @State private var zoom = 100
    @State private var confirmingClear = false
    @State private var cleared = false

    private var origin: String? { SiteControls.origin(of: item.currentURL) }
    /// Chromium's site settings; a WebKit page has its own (WebKit asks).
    private var profile: OACProfile? { item.pane?.engine == .chromium ? item.pane?.profile : nil }
    private var isWebKit: Bool { item.pane?.engine == .webKit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if origin != nil, item.pane != nil {
                Divider()
                engineRow
            }
            if let origin, let profile {
                Divider()
                VStack(spacing: 2) {
                    ForEach(SitePermission.all) { permission in
                        PermissionRow(permission: permission, value: binding(permission, origin: origin, profile: profile))
                    }
                    if let host = KeepAwakeSites.host(of: item.currentURL) {
                        pictureInPictureRow(host)
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
                    Label(L(secure ? "Verbindung ist sicher" : "Verbindung ist nicht sicher"),
                          systemImage: secure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(secure ? Color.secondary : Color.orange)
                } else {
                    Text("Eine Seite von OpenArch").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Whether the site's videos and calls float by themselves when you
    /// leave the tab (Settings › Allgemein › Tabs › Ohne Bild-in-Bild).
    private func pictureInPictureRow(_ host: String) -> some View {
        let library = browser.library
        return HStack(spacing: 8) {
            Image(systemName: "pip").frame(width: 20).foregroundStyle(.secondary)
            Text("Bild-in-Bild beim Verlassen").font(.system(size: 13))
            Spacer()
            Toggle("", isOn: Binding(
                get: { !KeepAwakeSites.listed(item.currentURL, in: library.settings.pictureInPictureExceptions) },
                set: { on in
                    var sites = library.settings.pictureInPictureExceptions
                    if on {
                        sites.removeAll { KeepAwakeSites.listed(item.currentURL, in: [$0]) }
                    } else {
                        sites.append(host)
                    }
                    library.settings.pictureInPictureExceptions = sites
                    library.setNeedsSave()
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .frame(height: 26)
    }
    /// Safari's engine for this site, both ways: the page opens again in
    /// the other engine at once.
    private var engineRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "safari").frame(width: 20).foregroundStyle(.secondary)
                Text("Safaris Engine").font(.system(size: 13))
                Spacer()
                Toggle("", isOn: Binding(get: { isWebKit }, set: { switchEngine(toWebKit: $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .frame(height: 26)
            if isWebKit {
                let service = (item.pane as? WebKitPage)?.serviceName ?? ""
                Text(L("%@ spielt geschützte Videos und Musik nur mit Apples FairPlay, darum läuft sie mit Safaris Engine. Chrome-Erweiterungen und Chromes DevTools gibt es hier nicht (⌥⌘I öffnet den Web Inspector), und Logins aus Chromium gelten hier nicht: Du meldest dich einmal neu an.", service.isEmpty ? L("Diese Seite") : service))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func switchEngine(toWebKit: Bool) {
        let engine: OACPageEngine = toWebKit ? .webKit : .chromium
        ProtectedMedia.choose(engine, for: item.currentURL)
        browser.replacePage(of: item, with: item.currentURL, engine: engine)
        browser.state.siteControlsVisible = false
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
                Text(L("Du wirst auf %@ abgemeldet. Die Seite lädt danach neu.", URL(string: item.currentURL)?.host() ?? L("der Website")))
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
        SitePermission(kind: .camera, title: L("Kamera"), symbol: "camera", defaultTitle: L("Fragen")),
        SitePermission(kind: .microphone, title: L("Mikrofon"), symbol: "mic", defaultTitle: L("Fragen")),
        SitePermission(kind: .location, title: L("Standort"), symbol: "location", defaultTitle: L("Fragen")),
        SitePermission(kind: .notifications, title: L("Mitteilungen"), symbol: "bell", defaultTitle: L("Fragen")),
        SitePermission(kind: .popups, title: L("Pop-ups"), symbol: "macwindow.on.rectangle", defaultTitle: L("Blockieren"), canAsk: false),
        SitePermission(kind: .sound, title: L("Ton"), symbol: "speaker.wave.2", defaultTitle: L("Erlauben"), canAsk: false),
        SitePermission(kind: .automaticDownloads, title: L("Mehrere Downloads"), symbol: "arrow.down.circle", defaultTitle: L("Fragen")),
        SitePermission(kind: .clipboard, title: L("Zwischenablage"), symbol: "doc.on.clipboard", defaultTitle: L("Fragen")),
        SitePermission(kind: .javaScript, title: L("JavaScript"), symbol: "curlybraces", defaultTitle: L("Erlauben"), canAsk: false),
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
                Text(L("Standard (%@)", permission.defaultTitle)).tag(OACPermissionValue.default)
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
                Text(L(title)).font(.system(size: 13))
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
