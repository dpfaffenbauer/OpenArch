import AppKit
import SwiftUI
import OpenArchLocalization

/// „Spaces verwalten …“: a card over the page with a row per space, to
/// sort them by dragging, rename them with a click on the name, change
/// icon, color and profile with the space editor, and delete them (which
/// asks first and says what happens to the tabs). From the space menu, a
/// space icon's menu and the library.
@MainActor
final class ManageSpacesController {
    private unowned let browser: BrowserWindowController
    private var panel: ManageSpacesPanel?
    private var keyMonitor: Any?

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var isOpen: Bool { panel?.isVisible == true }

    func show() {
        guard let window = browser.window else { return }
        if browser.state.libraryVisible { browser.toggleLibrary() }
        let panel = self.panel ?? ManageSpacesPanel(controller: self, browser: browser)
        self.panel = panel
        panel.setFrame(window.convertToScreen(browser.contentRect), display: false)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.order(.above, relativeTo: window.windowNumber)
        if !AppPaths.isSelfTest { panel.makeKey() }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { () -> Bool in
                    // Escape closes the card, unless a name is being edited.
                    guard let self, event.keyCode == 53, NSApp.keyWindow === self.panel,
                          !(self.panel?.firstResponder is NSTextView) else { return false }
                    self.hide()
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        browser.state.activeItem?.pane?.focus()
    }

    /// Keeps the card over the page after the window's panes were re-added.
    func layout() {
        guard isOpen, let window = browser.window, let panel else { return }
        panel.setFrame(window.convertToScreen(browser.contentRect), display: true)
        window.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
    }
}

final class ManageSpacesPanel: NSPanel {
    @MainActor
    init(controller: ManageSpacesController, browser: BrowserWindowController) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: ManageSpacesOverlay(controller: controller, browser: browser))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ManageSpacesOverlay: View {
    let controller: ManageSpacesController
    let browser: BrowserWindowController

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.3))
                .contentShape(Rectangle())
                .onTapGesture { controller.hide() }
            ManageSpacesCard(controller: controller, browser: browser)
                .frame(width: 440)
                .frame(maxHeight: 560)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .ignoresSafeArea()
    }
}

private struct ManageSpacesCard: View {
    let controller: ManageSpacesController
    let browser: BrowserWindowController

    var body: some View {
        let library = browser.library
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Spaces verwalten").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Fertig") { controller.hide() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            Text("Zum Sortieren ziehen, auf den Namen klicken zum Umbenennen, aufs Symbol für Farbe und Profil.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            List {
                ForEach(library.spaces) { space in
                    ManageSpaceRow(browser: browser, space: space)
                }
                .onMove { library.moveSpaces(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(420, CGFloat(library.spaces.count) * 50 + 12))
            Divider()
            HStack {
                Button {
                    controller.hide()
                    browser.addSpace()
                } label: {
                    Label("Neuer Space", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(Localization.count(library.spaces.count, one: "1 Space", other: "%lld Spaces"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
    }
}

private struct ManageSpaceRow: View {
    let browser: BrowserWindowController
    @Bindable var space: Space
    @State private var renaming = false
    @State private var editing = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let library = browser.library
        let profile = library.profile(id: space.profileID)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary)
                .help("Zum Sortieren ziehen")
            Button { editing = true } label: {
                SpaceIcon(icon: space.icon, size: 13)
                    .foregroundStyle(SpaceTheme(hex: space.colorHex).foreground)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color(nsColor: space.color)))
                    .overlay {
                        if library.profiles.count > 1 {
                            Circle().strokeBorder(Color(nsColor: library.color(for: profile)), lineWidth: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Symbol, Farbe und Profil")
            .popover(isPresented: $editing, arrowEdge: .trailing) {
                SpaceEditor(browser: browser, space: space)
            }
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onAppear { nameFocused = true }
                        .onSubmit { commitName() }
                        .onExitCommand { renaming = false }
                        .onChange(of: nameFocused) { _, focused in if !focused, renaming { commitName() } }
                } else {
                    Text(space.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            name = space.name
                            renaming = true
                        }
                        .help("Zum Umbenennen klicken")
                }
                Text(L("Profil: %@ · %lld angeheftet, %lld offen", profile.name, space.pinned.allTabs.count, space.today.allTabs.count))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if browser.state.space === space {
                Text("Aktuell").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Button { browser.deleteSpace(space) } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(library.spaces.count < 2)
            .help(L(library.spaces.count < 2 ? "Der letzte Space bleibt" : "Space löschen …"))
        }
        .padding(.vertical, 4)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != space.name {
            space.name = trimmed
            browser.library.setNeedsSave()
        }
        renaming = false
    }
}
