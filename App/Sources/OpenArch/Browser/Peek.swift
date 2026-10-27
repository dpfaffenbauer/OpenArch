import AppKit
import OpenArchCore
import SwiftUI

/// Peek, like Arc's: links from pinned tabs and favorites that lead to
/// another site open in a card over the page instead of replacing it. The
/// card can become a tab or a split; Escape or a click beside it closes it.
@MainActor
final class PeekController: NSObject, OACPaneDelegate {
    private unowned let browser: BrowserWindowController
    private var backdrop: PeekBackdropWindow?
    private(set) var pane: OACPane?
    private var source: Item?
    private var keyMonitor: Any?
    let model = PeekModel()

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var isOpen: Bool { pane != nil }

    /// Two addresses on the same site (github.com and gist.github.com are).
    static func sameSite(_ lhs: String, _ rhs: String) -> Bool {
        func site(_ url: String) -> String {
            let labels = (URL(string: url)?.host() ?? "").lowercased().split(separator: ".")
            guard labels.count > 2 else { return labels.joined(separator: ".") }
            // co.uk, com.au and friends need one label more.
            let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
            let count = labels.last!.count == 2 && secondLevel.contains(String(labels[labels.count - 2])) ? 3 : 2
            return labels.suffix(count).joined(separator: ".")
        }
        return site(lhs) == site(rhs)
    }

    /// Where the card goes, in window coordinates.
    private var cardFrame: NSRect {
        let content = browser.contentRect
        let width = min(content.width - 80, 1180)
        let height = content.height - 64
        return NSRect(x: content.midX - width / 2, y: content.minY + 16, width: width, height: height)
    }

    func open(_ url: String, from source: Item?) {
        close()
        guard let window = browser.window else { return }
        let space = browser.state.space
        let profile = source.map { browser.library.profile(for: $0, in: space) } ?? browser.library.profile(id: space.profileID)
        let pane = OACPane(profile: profile.chromium, url: url)
        pane.delegate = self
        pane.cornerRadius = 12
        pane.activatesOnShow = !AppPaths.isSelfTest
        pane.toolbarVisible = false
        self.pane = pane
        self.source = source
        model.url = url
        model.title = ""

        let backdrop = self.backdrop ?? PeekBackdropWindow(controller: self)
        self.backdrop = backdrop
        backdrop.setFrame(window.convertToScreen(browser.contentRect), display: false)
        backdrop.cardFrame = window.convertToScreen(cardFrame)
        window.addChildWindow(backdrop, ordered: .above)
        backdrop.order(.above, relativeTo: window.windowNumber)
        pane.show(in: window, frame: cardFrame)
        pane.focus()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let key = NSApp.keyWindow, key === self.pane?.window || key === self.backdrop else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let pane {
            pane.delegate = nil
            pane.close()
        }
        pane = nil
        hideBackdrop()
        source?.pane?.focus()
        source = nil
    }

    private func hideBackdrop() {
        if let backdrop {
            backdrop.parent?.removeChildWindow(backdrop)
            backdrop.orderOut(nil)
        }
    }

    /// The page becomes a tab of its own, as it is.
    func openAsTab(split: Bool = false) {
        guard let pane else { return }
        let source = self.source
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        self.pane = nil
        self.source = nil
        hideBackdrop()
        pane.hide()
        browser.adopt(pane, into: browser.state.space, url: pane.url, title: pane.title, favicon: pane.favicon)
        if split, let source, let item = browser.state.activeItem {
            browser.split(item, with: source)
        }
    }

    /// Keeps the card above the window's panes after they were re-added.
    func layout() {
        guard isOpen, let window = browser.window, let backdrop, let pane else { return }
        backdrop.setFrame(window.convertToScreen(browser.contentRect), display: true)
        backdrop.cardFrame = window.convertToScreen(cardFrame)
        window.removeChildWindow(backdrop)
        window.addChildWindow(backdrop, ordered: .above)
        pane.setFrame(cardFrame)
        pane.orderFront()
    }

    // MARK: OACPaneDelegate

    func pane(_ pane: OACPane, titleDidChange title: String) { model.title = title }
    func pane(_ pane: OACPane, addressDidChange url: String) { model.url = url }

    func pane(_ pane: OACPane, wantsNewTabWithURL url: String, background: Bool) {
        browser.openInNewTab(url, select: !background)
    }

    func pane(_ pane: OACPane, handleChromeCommand commandID: Int) -> Bool {
        if commandID == OACChromeCommand.closeTab.rawValue {
            close()
            return true
        }
        return false
    }

    func paneDidClose(_ pane: OACPane) {
        if pane === self.pane { close() }
    }
}

@MainActor @Observable
final class PeekModel {
    var url = ""
    var title = ""
}

/// Dims the page around the card and holds the card's buttons.
final class PeekBackdropWindow: NSWindow {
    private let hosting: NSHostingView<PeekBackdropView>
    var cardFrame: NSRect = .zero {
        didSet { hosting.rootView.card = convertFromScreen(cardFrame) }
    }

    @MainActor
    init(controller: PeekController) {
        hosting = NSHostingView(rootView: PeekBackdropView(controller: controller, model: controller.model, card: .zero))
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        hosting.sizingOptions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct PeekBackdropView: View {
    let controller: PeekController
    let model: PeekModel
    var card: NSRect

    var body: some View {
        GeometryReader { geometry in
            // AppKit's y axis points up; SwiftUI's down.
            let top = geometry.size.height - card.maxY
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.32))
                    .contentShape(Rectangle())
                    .onTapGesture { controller.close() }
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.25))
                    .frame(width: card.width, height: card.height)
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                    .offset(x: card.minX, y: top)
                    .allowsHitTesting(false)
                HStack(spacing: 6) {
                    Text(model.title.isEmpty ? CommandBarModel.shortURL(model.url) : model.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 12)
                    PeekButton(symbol: "rectangle.split.2x1", help: "Neben dem Tab öffnen") { controller.openAsTab(split: true) }
                    PeekButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Als Tab öffnen") { controller.openAsTab() }
                    PeekButton(symbol: "xmark", help: "Schließen (Esc)") { controller.close() }
                }
                .frame(width: card.width, height: 32)
                .offset(x: card.minX, y: max(4, top - 40))
            }
        }
        .ignoresSafeArea()
    }
}

private struct PeekButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering ? 0.28 : 0.16)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
