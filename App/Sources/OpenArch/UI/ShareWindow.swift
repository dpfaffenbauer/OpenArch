import AppKit
import OpenArchShared
import SwiftUI

/// The windows for sharing a folder or space, and for adding a share link.
@MainActor
enum ShareWindows {
    private static var windows: [String: NSWindow] = [:]

    static func share(_ target: ShareTarget, app: AppDelegate) {
        show(key: "share-\(target.id)", title: target.kind == .space ? "Space teilen" : "Ordner teilen",
             view: ShareSheetView(app: app, target: target))
    }

    /// A share link that was opened (from another app, the command bar or
    /// the clipboard).
    static func open(_ link: ShareURL, app: AppDelegate) {
        show(key: "import-\(link.fragment.hashValue)", title: "Geteilte Lesezeichen",
             view: ImportSheetView(app: app, link: link))
    }

    static func close(_ key: String) {
        windows.removeValue(forKey: key)?.close()
    }

    /// The windows' contents, for the self-test to render without showing them.
    static func shareContent(_ target: ShareTarget, app: AppDelegate) -> some View {
        ShareSheetView(app: app, target: target)
    }

    static func importContent(_ link: ShareURL, app: AppDelegate) -> some View {
        ImportSheetView(app: app, link: link)
    }

    private static func show(key: String, title: String, view: some View) {
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.environment(\.closeShareWindow, { close(key) }))
        window.center()
        windows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = windows.removeValue(forKey: key) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// "Geteilten Link öffnen …": the link on the clipboard, or one typed in.
    static func askForLink(app: AppDelegate) {
        if let text = NSPasteboard.general.string(forType: .string), let link = ShareURL(string: text) {
            open(link, app: app)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Geteilten Link öffnen"
        alert.informativeText = "Füge einen OpenArch-Link ein (https://openarch.app/s/#…)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://openarch.app/s/#…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Öffnen")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let link = ShareURL(string: field.stringValue) {
            open(link, app: app)
        } else {
            let error = NSAlert()
            error.messageText = "Das ist kein OpenArch-Link."
            error.runModal()
        }
    }
}

private struct CloseShareWindowKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var closeShareWindow: @MainActor @Sendable () -> Void {
        get { self[CloseShareWindowKey.self] }
        set { self[CloseShareWindowKey.self] = newValue }
    }
}

private extension View {
    /// A form's footer on the left, where its section's text starts.
    func footerStyle() -> some View {
        foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sharing

/// A live link (on the relay, following changes) or a snapshot (the
/// bookmarks inside the link), with an optional password, and the link as a
/// QR code for the iPhone.
private struct ShareSheetView: View {
    let app: AppDelegate
    let target: ShareTarget
    @AppStorage("shareLive") private var live = true
    @State private var usePassword = false
    @State private var password = ""
    @State private var snapshot: ShareURL?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let sharing = Sharing.shared
        let owned = sharing.owned(target.id)
        let payload = sharing.payload(for: target)
        Form {
            Section {
                HStack(spacing: 12) {
                    SpaceIcon(icon: payload.icon ?? (target.kind == .space ? "square.on.square" : "folder.fill"), size: 18)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payload.name).font(.headline)
                        Text(payload.allTabs.count == 1 ? "1 Lesezeichen" : "\(payload.allTabs.count) Lesezeichen")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let owned {
                LinkView(link: owned.link)
                Section {
                    LabeledContent("Stand", value: "Version \(owned.version)")
                    if let date = owned.publishedAt {
                        LabeledContent("Hochgeladen", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Passwort", value: owned.passwordSlot == nil ? "Nein" : "Ja")
                    HStack {
                        Spacer()
                        Button("Teilen beenden …", role: .destructive) { end(owned) }.disabled(busy)
                    }
                } footer: {
                    Text("Änderungen erscheinen bei allen, die den Link hinzugefügt haben. Nur dieser Mac kann die Freigabe ändern. Wer sie schon hat, behält sie, wenn du das Teilen beendest.")
                        .footerStyle()
                }
            } else if let snapshot {
                LinkView(link: snapshot)
                Section {
                    HStack {
                        Text("Eine Momentaufnahme: Der Link enthält die Lesezeichen selbst und ändert sich nicht mehr.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Neuer Link") { self.snapshot = nil }
                    }
                }
            } else {
                Section {
                    Toggle("Aktuell halten", isOn: $live)
                    Toggle("Mit Passwort schützen", isOn: $usePassword)
                    if usePassword {
                        SecureField("Passwort (mindestens 4 Zeichen)", text: $password)
                    }
                } footer: {
                    Text(live
                         ? "Die Lesezeichen liegen verschlüsselt auf dem Teilen-Server; der Schlüssel steht nur im Link. Änderungen erscheinen bei allen mit dem Link."
                         : "Die Lesezeichen reisen verschlüsselt im Link selbst; kein Server ist beteiligt. Spätere Änderungen erscheinen nicht.")
                        .footerStyle()
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Link erstellen") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || (usePassword && password.count < 4))
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
    }

    private func create() {
        busy = true
        error = nil
        let protection = usePassword ? password : nil
        Task {
            do {
                if live {
                    _ = try await Sharing.shared.makeLiveShare(for: target, password: protection)
                } else {
                    snapshot = try await Sharing.shared.snapshotLink(for: target, password: protection)
                }
            } catch {
                self.error = error.localizedDescription + (live ? " Ohne „Aktuell halten“ geht es ganz ohne Server." : "")
            }
            busy = false
        }
    }

    private func end(_ share: OwnedShare) {
        let alert = NSAlert()
        alert.messageText = "Teilen von „\(share.name)“ beenden?"
        alert.informativeText = "Der Link zeigt danach nichts mehr. Wer die Lesezeichen hinzugefügt hat, behält den letzten Stand."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            do {
                try await Sharing.shared.end(share)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The link with its QR code, to copy or send.
private struct LinkView: View {
    let link: ShareURL
    @State private var copied = false

    var body: some View {
        let text = link.url.absoluteString
        Section {
            if let image = QRCode.image(for: text, scale: 8) {
                Image(decorative: image, scale: 2)
                    .interpolation(.none)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR-Code des Links")
            } else {
                Text("Zu viele Lesezeichen für einen QR-Code. Sende den Link stattdessen.")
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Button(copied ? "Kopiert" : "Link kopieren") {
                    copy(text)
                    copied = true
                }
                SwiftUI.ShareLink(item: link.url) { Text("Senden …") }
            }
        } footer: {
            Text("Scanne den Code mit der Kamera oder mit OpenArch auf dem iPhone (Code scannen). Der Schlüssel steht hinter dem # im Link und erreicht nie einen Server.")
                .footerStyle()
        }
    }
}

// MARK: - Adding a share

/// What a share link shows, and adding it as a folder or a space, following
/// the owner's changes or as a copy.
private struct ImportSheetView: View {
    let app: AppDelegate
    let link: ShareURL
    @State private var password = ""
    @State private var opened: ShareReader.Opened?
    @State private var error: String?
    @State private var busy = false
    @State private var asSpace = false
    @Environment(\.closeShareWindow) private var close

    var body: some View {
        let sharing = Sharing.shared
        let ownShare = sharing.records.owned.contains { $0.id == link.shareID }
        let following = sharing.records.subscriptions.contains { $0.id == link.shareID && !$0.ended }
        Form {
            if let opened {
                let payload = opened.payload
                Section {
                    HStack(spacing: 12) {
                        SpaceIcon(icon: payload.icon ?? (payload.kind == .space ? "square.on.square" : "folder.fill"), size: 18)
                            .frame(width: 28)
                            .foregroundStyle(Color(nsColor: NSColor(hex: payload.color ?? "") ?? .controlAccentColor))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payload.name).font(.headline)
                            Text("\(payload.kind == .space ? "Space" : "Ordner") · \(payload.allTabs.count) Lesezeichen · \(opened.version == nil ? "Momentaufnahme" : "aktuell gehalten")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Inhalt") {
                    ForEach(Self.preview(payload.items, depth: 0).prefix(40), id: \.node.id) { row in
                        Label {
                            Text(row.node.title.isEmpty ? (row.node.url ?? "") : row.node.title).lineLimit(1)
                        } icon: {
                            Image(systemName: row.node.isFolder ? "folder" : "globe")
                        }
                        .padding(.leading, CGFloat(row.depth) * 16)
                    }
                }
                Section {
                    Picker("Hinzufügen als", selection: $asSpace) {
                        Text("Ordner im aktuellen Space").tag(false)
                        Text("Eigener Space").tag(true)
                    }
                    HStack {
                        Spacer()
                        Button(opened.version != nil ? "Als Kopie hinzufügen" : "Hinzufügen") { add(opened, follow: false) }
                            .keyboardShortcut(opened.version == nil || ownShare ? KeyboardShortcut.defaultAction : nil)
                        if opened.version != nil && !ownShare {
                            Button("Hinzufügen und folgen") { add(opened, follow: true) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(following)
                        }
                    }
                } footer: {
                    Group {
                        if ownShare {
                            Text("Das ist eine Freigabe dieses Macs.")
                        } else if following {
                            Text("Du folgst dieser Freigabe schon.")
                        } else if opened.version != nil {
                            Text("Beim Folgen erscheinen Änderungen des Besitzers alle fünf Minuten von selbst; was du daran änderst, überschreibt das nächste Update.")
                        }
                    }
                    .footerStyle()
                }
            } else if link.needsPassword {
                Section {
                    SecureField("Passwort", text: $password)
                        .onSubmit { open() }
                } footer: {
                    Text("Diese Lesezeichen sind mit einem Passwort geschützt.").footerStyle()
                }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Öffnen") { open() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || busy)
                }
            } else if error == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Wird entschlüsselt …").foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
        .task {
            if !link.needsPassword { open() }
        }
    }

    private func open() {
        busy = true
        error = nil
        let password = link.needsPassword ? self.password : nil
        Task {
            do {
                let result = try await ShareReader.open(link, password: password)
                opened = result
                asSpace = result.payload.kind == .space
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func add(_ opened: ShareReader.Opened, follow: Bool) {
        guard let browser = app.mainBrowser else { return }
        Sharing.shared.add(opened, asSpace: asSpace, follow: follow, in: browser.state.space, browser: browser)
        browser.showWindow(nil)
        close()
    }

    struct PreviewRow {
        let node: ShareNode
        let depth: Int
    }

    static func preview(_ nodes: [ShareNode], depth: Int) -> [PreviewRow] {
        nodes.flatMap { [PreviewRow(node: $0, depth: depth)] + preview($0.children ?? [], depth: depth + 1) }
    }
}
