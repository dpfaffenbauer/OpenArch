import OpenArchShared
import SwiftUI
import VisionKit

/// Sharing a folder or a space: a live link (on the relay, following
/// changes) or a snapshot (the bookmarks inside the link), with an optional
/// password; the link as a QR code for another device.
struct ShareView: View {
    let browser: Browser
    let target: ShareTarget
    @AppStorage("shareLive") private var live = true
    @State private var usePassword = false
    @State private var password = ""
    @State private var snapshot: ShareURL?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmEnd = false

    var body: some View {
        let owned = browser.sharing.owned(target.id)
        let payload = browser.sharing.payload(for: target)
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        SymbolOrEmoji(icon: payload.icon ?? (target.kind == .space ? "square.on.square" : "folder.fill"), size: 20)
                            .frame(width: 30)
                            .foregroundStyle(Color(uiColor: UIColor(hex: payload.color ?? "") ?? .tintColor))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payload.name).font(.headline)
                            Text(payload.allTabs.count == 1 ? "1 Lesezeichen" : "\(payload.allTabs.count) Lesezeichen")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let owned {
                    LinkSection(browser: browser, link: owned.link)
                    Section {
                        LabeledContent("Stand", value: "Version \(owned.version)")
                        if let date = owned.publishedAt {
                            LabeledContent("Hochgeladen", value: date.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("Passwort", value: owned.passwordSlot == nil ? "Nein" : "Ja")
                        Button("Teilen beenden", role: .destructive) { confirmEnd = true }
                    } footer: {
                        Text("Änderungen erscheinen bei allen, die den Link hinzugefügt haben. Nur dieses Gerät kann die Freigabe ändern. Wer sie schon hat, behält sie, wenn du das Teilen beendest.")
                    }
                } else if let snapshot {
                    LinkSection(browser: browser, link: snapshot)
                    Section {
                        Button("Neuen Link erstellen") { self.snapshot = nil }
                    } footer: {
                        Text("Eine Momentaufnahme: Der Link enthält die Lesezeichen selbst, verschlüsselt, und ändert sich nicht mehr.")
                    }
                } else {
                    Section {
                        Toggle("Aktuell halten", isOn: $live)
                        Toggle("Mit Passwort schützen", isOn: $usePassword.animation())
                        if usePassword {
                            SecureField("Passwort (mindestens 4 Zeichen)", text: $password)
                                .textContentType(.newPassword)
                        }
                    } footer: {
                        Text(live
                             ? "Die Lesezeichen liegen verschlüsselt auf dem Teilen-Server; der Schlüssel steht nur im Link. Änderungen erscheinen bei allen mit dem Link."
                             : "Die Lesezeichen reisen verschlüsselt im Link selbst; kein Server ist beteiligt. Spätere Änderungen erscheinen nicht.")
                    }
                    Section {
                        Button {
                            create()
                        } label: {
                            HStack {
                                Text("Link erstellen")
                                if busy {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(busy || (usePassword && password.count < 4))
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(target.kind == .space ? "Space teilen" : "Ordner teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { browser.sheet = nil }
                }
            }
            .confirmationDialog("Teilen beenden?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("Teilen beenden", role: .destructive) {
                    if let owned { end(owned) }
                }
            } message: {
                Text("Der Link zeigt danach nichts mehr. Wer die Lesezeichen hinzugefügt hat, behält den letzten Stand.")
            }
        }
        #if DEBUG
        .onChange(of: browser.demoCreatesLink) { _, creates in
            if creates {
                live = false
                create()
            }
        }
        #endif
    }

    private func create() {
        busy = true
        error = nil
        let protection = usePassword ? password : nil
        Task {
            do {
                if live {
                    _ = try await browser.sharing.makeLiveShare(for: target, password: protection)
                } else {
                    snapshot = try await browser.sharing.snapshotLink(for: target, password: protection)
                }
            } catch {
                self.error = error.localizedDescription
                    + (live ? " Ohne „Aktuell halten“ geht es ganz ohne Server." : "")
            }
            busy = false
            #if DEBUG
            browser.demoLinkIsReady = true
            #endif
        }
    }

    private func end(_ share: OwnedShare) {
        busy = true
        Task {
            do {
                try await browser.sharing.end(share)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// A link with its QR code, to copy or send.
struct LinkSection: View {
    let browser: Browser
    let link: ShareURL

    var body: some View {
        let text = link.url.absoluteString
        Section {
            if let image = QRCode.image(for: text) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 230)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("QR-Code des Links")
            } else {
                Text("Zu viele Lesezeichen für einen QR-Code. Sende den Link stattdessen.")
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.footnote.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Link kopieren", systemImage: "doc.on.doc") { browser.copy(text) }
            SwiftUI.ShareLink(item: link.url) {
                Label("Link senden …", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text("Scanne den Code mit OpenArch auf dem iPhone oder Mac (Code scannen), oder öffne den Link dort. Der Schlüssel steht hinter dem # und erreicht nie einen Server.")
        }
    }
}

// MARK: - Adding a share

/// A share link that was opened: what it shows, and adding it as a folder
/// or a space, following the owner's changes or as a copy.
struct ImportView: View {
    let browser: Browser
    let link: ShareURL
    @State private var password = ""
    @State private var opened: ShareReader.Opened?
    @State private var error: String?
    @State private var busy = false
    @State private var asSpace = false

    var body: some View {
        let ownShare = browser.sharing.records.owned.contains { $0.id == link.shareID }
        let following = browser.sharing.records.subscriptions.contains { $0.id == link.shareID && !$0.ended }
        NavigationStack {
            Form {
                if let opened {
                    let payload = opened.payload
                    Section {
                        HStack(spacing: 12) {
                            SymbolOrEmoji(icon: payload.icon ?? (payload.kind == .space ? "square.on.square" : "folder.fill"), size: 20)
                                .frame(width: 30)
                                .foregroundStyle(Color(uiColor: UIColor(hex: payload.color ?? "") ?? .tintColor))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(payload.name).font(.headline)
                                Text("\(payload.kind == .space ? "Space" : "Ordner") · \(payload.allTabs.count) Lesezeichen · \(opened.version == nil ? "Momentaufnahme" : "aktuell gehalten")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Inhalt") {
                        ForEach(Self.preview(payload.items, depth: 0).prefix(40), id: \.node.id) { row in
                            HStack(spacing: 8) {
                                if row.node.isFolder {
                                    Image(systemName: "folder.fill").foregroundStyle(.secondary).frame(width: 18)
                                } else {
                                    FaviconView(host: URL(string: row.node.url ?? "")?.host() ?? "", size: 18)
                                }
                                Text(row.node.title.isEmpty ? (row.node.url ?? "") : row.node.title).lineLimit(1)
                            }
                            .padding(.leading, CGFloat(row.depth) * 18)
                        }
                    }
                    Section {
                        Picker("Hinzufügen als", selection: $asSpace) {
                            Text("Ordner").tag(false)
                            Text("Space").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if opened.version != nil && !ownShare {
                            Button("Hinzufügen und folgen") { add(opened, follow: true) }
                                .disabled(following)
                        }
                        Button(opened.version != nil ? "Als Kopie hinzufügen" : "Hinzufügen") { add(opened, follow: false) }
                    } footer: {
                        if ownShare {
                            Text("Das ist deine eigene Freigabe.")
                        } else if following {
                            Text("Du folgst dieser Freigabe schon.")
                        } else if opened.version != nil {
                            Text("Beim Folgen erscheinen Änderungen des Besitzers von selbst; was du daran änderst, überschreibt das nächste Update.")
                        }
                    }
                } else if link.needsPassword {
                    Section {
                        SecureField("Passwort", text: $password)
                            .onSubmit { open() }
                        Button {
                            open()
                        } label: {
                            HStack {
                                Text("Öffnen")
                                if busy {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(password.isEmpty || busy)
                    } footer: {
                        Text("Diese Lesezeichen sind mit einem Passwort geschützt.")
                    }
                } else if error == nil {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Wird entschlüsselt …").foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Geteilte Lesezeichen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { browser.sheet = nil }
                }
            }
        }
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
        browser.sharing.add(opened, asSpace: asSpace, follow: follow)
        browser.sheet = nil
        browser.showToast(follow ? "„\(opened.payload.name)“ hinzugefügt, folgt Änderungen" : "„\(opened.payload.name)“ hinzugefügt")
    }

    struct PreviewRow {
        let node: ShareNode
        let depth: Int
    }

    static func preview(_ nodes: [ShareNode], depth: Int) -> [PreviewRow] {
        nodes.flatMap { [PreviewRow(node: $0, depth: depth)] + preview($0.children ?? [], depth: depth + 1) }
    }
}

// MARK: - Scanning

/// Scans the QR code of a share link (or any web address) with the camera.
struct ScannerSheet: View {
    let browser: Browser

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScanner { handle($0) }
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("Scannen nicht möglich", systemImage: "qrcode.viewfinder",
                                           description: Text("Erlaube OpenArch die Kamera in den Einstellungen, oder öffne den Link auf diesem Gerät."))
                }
            }
            .navigationTitle("Code scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { browser.sheet = nil }
                }
            }
        }
    }

    private func handle(_ text: String) {
        if let link = ShareURL(string: text) {
            browser.present(.importShare(link))
        } else if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            browser.openInNewTab(url.absoluteString)
        } else {
            browser.sheet = nil
            browser.showToast("Kein Link in diesem Code")
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(found: found)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) {
            self.found = found
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    done = true
                    found(text)
                    return
                }
            }
        }
    }
}
