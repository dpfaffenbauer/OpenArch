import AppKit
import Observation
import OpenArchCore
import SwiftUI

/// Little OpenArch: a small window for a quick look, e.g. links from other apps.
/// "In Space öffnen" moves the page, as it is, into the main window.
@MainActor
final class LittleOpenArchWindowController: NSWindowController, NSWindowDelegate, OACPaneDelegate {
    private static var open: [LittleOpenArchWindowController] = []

    private unowned let app: AppDelegate
    let pane: OACPane
    private let profileID: String
    let model = LittleOpenArchModel()
    private var transferred = false
    private let theme: SpaceTheme
    static let barHeight: CGFloat = 40

    /// Opens a Little OpenArch window, with |url| or with an address field.
    @discardableResult
    static func show(url: String?, app: AppDelegate, at point: NSPoint? = nil) -> LittleOpenArchWindowController? {
        guard let browser = app.mainBrowser else { return nil }
        let controller = LittleOpenArchWindowController(url: url, space: browser.state.space, app: app)
        return present(controller, at: point, editing: url == nil)
    }

    /// A tab dragged out of the sidebar: its page moves into the window as
    /// it is.
    @discardableResult
    static func show(adopting pane: OACPane, url: String, title: String, favicon: NSImage?, space: Space,
                     app: AppDelegate, at point: NSPoint?) -> LittleOpenArchWindowController? {
        let controller = LittleOpenArchWindowController(url: url, space: space, app: app, pane: pane)
        controller.model.title = title
        controller.model.favicon = favicon
        controller.model.canGoBack = pane.canGoBack
        controller.model.canGoForward = pane.canGoForward
        return present(controller, at: point, editing: false)
    }

    private static func present(_ controller: LittleOpenArchWindowController, at point: NSPoint?,
                                editing: Bool) -> LittleOpenArchWindowController {
        if let point, let window = controller.window {
            // Under the mouse, on whichever screen that is, and fully on it.
            let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? window.frame
            var frame = window.frame
            frame.origin.x = min(max(point.x - 160, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(point.y - frame.height + 20, screen.minY), screen.maxY - frame.height)
            window.setFrame(frame, display: false)
        }
        open.append(controller)
        if AppPaths.isSelfTest {
            // The background self-test never puts a window in front.
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
        }
        controller.layout()
        if editing {
            controller.model.isEditing = true
        }
        return controller
    }

    static var openCount: Int { open.count }

    static func closeAll() {
        for controller in open { controller.window?.close() }
    }

    /// The pane a Little OpenArch window shows (self-test).
    var shownPane: OACPane { pane }

    static var all: [LittleOpenArchWindowController] { open }

    /// The Little OpenArch window the user is working in, if any.
    static var current: LittleOpenArchWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return open.first { $0.window === key || $0.pane.window === key }
    }

    private init(url: String?, space: Space, app: AppDelegate, pane existing: OACPane? = nil) {
        self.app = app
        profileID = space.profileID
        pane = existing ?? OACPane(profile: app.library.profile(id: space.profileID).chromium, url: url ?? "about:blank")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        let theme = SpaceTheme(hex: space.colorHex)
        self.theme = theme
        window.backgroundColor = theme.base
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        // Cascade from the last Little OpenArch window, or sit at the screen's center.
        if let last = Self.open.last?.window {
            window.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 28, y: last.frame.maxY - 28))
        } else {
            window.center()
        }
        super.init(window: window)
        window.delegate = self
        model.url = url ?? ""
        let bar = NSHostingView(rootView: LittleOpenArchBar(controller: self, theme: theme))
        bar.sizingOptions = []
        window.contentView?.addSubview(bar)
        pane.delegate = self
        pane.cornerRadius = 8
        pane.activatesOnShow = !AppPaths.isSelfTest
        pane.toolbarVisible = false
        model.toolbarVisible = false
    }

    required init?(coder: NSCoder) { fatalError() }

    private var paneFrame: NSRect {
        guard let bounds = window?.contentView?.bounds else { return .zero }
        return NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - Self.barHeight - 6)
    }

    func layout() {
        guard let window, let content = window.contentView else { return }
        content.subviews.first?.frame = NSRect(x: 0, y: content.bounds.height - Self.barHeight,
                                               width: content.bounds.width, height: Self.barHeight)
        if pane.isVisible {
            pane.setFrame(paneFrame)
        } else {
            pane.show(in: window, frame: paneFrame)
        }
    }

    func windowDidResize(_ notification: Notification) { layout() }
    // Darker while not in front, like the main window.
    func windowDidBecomeMain(_ notification: Notification) { applyColor() }
    func windowDidResignMain(_ notification: Notification) { applyColor() }

    private func applyColor() {
        let front = AppPaths.isSelfTest || (NSApp.isActive && window?.isMainWindow == true)
        window?.backgroundColor = front ? theme.base : theme.inactiveBase
    }
    func windowDidMove(_ notification: Notification) { layout() }

    func windowWillClose(_ notification: Notification) {
        if !transferred {
            pane.delegate = nil
            pane.close()
        }
        Self.open.removeAll { $0 === self }
    }

    // MARK: Actions

    func load(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let url = CommandBarModel.url(fromInput: text) ?? app.library.settings.searchEngine.url(for: text)
        model.isEditing = false
        pane.loadURL(url)
        pane.focus()
    }

    /// Moves the page into the main window, in the current space (or one
    /// with the same profile, so logins stay the same).
    func moveToSpace() {
        guard let browser = app.mainBrowser, let window else { return }
        let space = space(in: browser)
        transferred = true
        pane.hide()
        browser.adopt(pane, into: space, url: model.url, title: model.title, favicon: model.favicon)
        window.close()
        browser.showWindow(nil)
    }

    func copyLink() {
        OpenArch.copy(model.url)
        model.copied = true
        after(1.5) { self.model.copied = false }
    }

    func reload() { pane.reload() }

    /// Chrome's toolbar: extension buttons, downloads, site settings.
    func toggleToolbar() {
        model.toolbarVisible.toggle()
        pane.toolbarVisible = model.toolbarVisible
    }
    func goBack() { pane.goBack() }
    func goForward() { pane.goForward() }
    func showDevTools() { pane.showDevTools() }
    func runChromeCommand(_ command: OACChromeCommand) { pane.executeChromeCommand(command.rawValue) }
    func editAddress() { model.isEditing = true }

    // MARK: OACPaneDelegate

    func pane(_ pane: OACPane, titleDidChange title: String) { model.title = title }

    func pane(_ pane: OACPane, addressDidChange url: String) {
        model.url = url
        app.history.recordVisit(url: url, title: nil)
    }

    func pane(_ pane: OACPane, faviconDidChange favicon: NSImage) {
        model.favicon = favicon
        FaviconStore.shared.store(favicon, forURL: model.url)
    }

    func pane(_ pane: OACPane, loadingStateDidChange isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        model.isLoading = isLoading
        model.canGoBack = canGoBack
        model.canGoForward = canGoForward
    }

    /// The space pages from here go to: the current one, or one with the
    /// same profile, so logins stay the same.
    private func space(in browser: BrowserWindowController) -> Space {
        browser.state.space.profileID == profileID ? browser.state.space
            : (app.library.spaces.first { $0.profileID == profileID } ?? browser.state.space)
    }

    /// Links that want a new tab go to the main window; ⌘-clicked ones to
    /// the space, in the background, like Ctrl-clicks.
    func pane(_ pane: OACPane, wantsNewTabWithURL url: String, background: Bool) {
        if background, openInSpace(url, modifiers: .command) { return }
        app.mainBrowser?.openInNewTab(url, select: !background)
        if !background { app.mainBrowser?.showWindow(nil) }
    }

    func pane(_ pane: OACPane, wantsToOpenExternalURL url: String) {
        ExternalApps.open(url, from: pane.url, in: window, library: app.library) { _ in NSSound.beep() }
    }

    func pane(_ pane: OACPane, shouldInterceptNavigationToURL url: String) -> Bool {
        openInSpace(url, modifiers: NSEvent.modifierFlags)
    }

    /// A link clicked with Ctrl (or ⌘) opens in the space, as a tab in the
    /// background, and Little OpenArch stays on its page. Chromium on the
    /// Mac only knows ⌘ for that and would follow a Ctrl-click right here.
    func openInSpace(_ url: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !modifiers.intersection([.control, .command]).isEmpty, let browser = app.mainBrowser else { return false }
        let space = space(in: browser)
        if space === browser.state.space {
            browser.openInNewTab(url, select: false)
        } else {
            space.today.insert(Item.tab(url: url), at: 0)
            app.library.setNeedsSave()
        }
        return true
    }

    func pane(_ pane: OACPane, handleChromeCommand commandID: Int) -> Bool {
        switch OACChromeCommand(rawValue: commandID) {
        case .closeTab, .closeWindow:
            window?.close()
        case .focusLocation:
            editAddress()
        case .copyURL:
            copyLink()
        case .exit:
            NSApp.terminate(nil)
        default:
            return false
        }
        return true
    }

    func paneDidClose(_ pane: OACPane) {
        if !transferred { window?.close() }
    }
}

@MainActor @Observable
final class LittleOpenArchModel {
    var url = ""
    var title = ""
    var favicon: NSImage?
    var isLoading = false
    var isEditing = false
    var copied = false
    var canGoBack = false
    var canGoForward = false
    var toolbarVisible = false
}

private struct LittleOpenArchBar: View {
    let controller: LittleOpenArchWindowController
    let theme: SpaceTheme
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let model = controller.model
        HStack(spacing: 8) {
            Spacer().frame(width: 66)
            IconButton(symbol: "arrow.left", help: "Zurück (⌘[)") { controller.goBack() }
                .disabled(!model.canGoBack)
            IconButton(symbol: "arrow.right", help: "Vorwärts (⌘])") { controller.goForward() }
                .disabled(!model.canGoForward)
            IconButton(symbol: model.isLoading ? "xmark" : "arrow.clockwise", help: "Neu laden (⌘R)") { controller.reload() }
            if model.isEditing {
                TextField("Suchen oder URL eingeben", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onAppear {
                        text = model.url == "about:blank" ? "" : model.url
                        focused = true
                    }
                    .onSubmit { controller.load(text) }
                    .onExitCommand { model.isEditing = false }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.tile))
            } else {
                Group {
                    if let favicon = model.favicon {
                        Image(nsImage: favicon).resizable().frame(width: 14, height: 14)
                    } else if model.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(displayAddress(model.url))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .opacity(0.85)
                }
                .onTapGesture { model.isEditing = true }
                .help("Adresse bearbeiten (⌘L)")
            }
            Spacer(minLength: 8)
            IconButton(symbol: "puzzlepiece.extension", help: model.toolbarVisible ? "Chrome-Toolbar ausblenden" : "Extensions und Chrome-Toolbar zeigen") {
                controller.toggleToolbar()
            }
            .opacity(model.toolbarVisible ? 1 : 0.8)
            IconButton(symbol: model.copied ? "checkmark" : "link", help: "Link kopieren") { controller.copyLink() }
            Button { controller.moveToSpace() } label: {
                Label("In Space öffnen", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.tile))
            }
            .buttonStyle(.plain)
            .disabled(model.url.isEmpty || model.url == "about:blank")
            .help("Ins Hauptfenster holen")
        }
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bar sits in the transparent title bar, next to the window
        // buttons; without this SwiftUI pushes it below the title bar.
        .ignoresSafeArea()
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.colorScheme)
    }

    private func displayAddress(_ url: String) -> String {
        guard !url.isEmpty, url != "about:blank" else { return "Little OpenArch" }
        return CommandBarModel.shortURL(url)
    }
}
