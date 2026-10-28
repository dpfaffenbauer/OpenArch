import AppKit
import SwiftUI

/// Arc's ⌃Tab switcher: holding ⌃ and pressing Tab shows the recently used
/// tabs in a row over the page. More Tabs (⇧ for back, or the arrow keys)
/// move along it; letting go of ⌃ goes to the marked tab, Esc stays put.
@MainActor
final class TabSwitcher {
    private unowned let browser: BrowserWindowController
    let model = TabSwitcherModel()
    private var window: TabSwitcherWindow?
    private var monitor: Any?

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var isOpen: Bool { monitor != nil }

    /// Opens the switcher on the tab before the current one, or moves along.
    func advance(_ direction: Int) {
        if !isOpen {
            let tabs = browser.orderedTabs.sorted { $0.lastActiveAt > $1.lastActiveAt }
            guard tabs.count > 1 else { return }
            model.tabs = Array(tabs.prefix(8))
            model.selection = 0
            model.theme = SpaceTheme(hex: browser.state.space.colorHex)
            model.fit(model.tabs.count, in: browser.contentRect.size)
            // Fresh pictures of the pages that are open; sleeping ones keep
            // the last one taken.
            model.tabs.forEach(TabSnapshots.capture)
            open()
        }
        let count = model.tabs.count
        model.selection = (model.selection + direction + count) % count
    }

    /// Goes to the marked tab.
    func commit() {
        guard isOpen else { return }
        let tab = model.tabs.indices.contains(model.selection) ? model.tabs[model.selection] : nil
        close()
        if let tab, tab.container != nil || tab.split != nil {
            browser.select(tab)
        }
    }

    func cancel() {
        close()
    }

    private func open() {
        guard let parent = browser.window else { return }
        let window = self.window ?? TabSwitcherWindow(switcher: self)
        self.window = window
        window.show(over: parent.convertToScreen(browser.contentRect), parent: parent)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.hide()
    }

    /// Whether |event| was the switcher's own.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            if !event.modifierFlags.contains(.control) { commit() }
            return false
        }
        switch event.keyCode {
        case 53: cancel()  // Esc
        case 36, 76: commit()  // Return, Enter
        case 123, 126: advance(-1)  // ← ↑
        case 124, 125: advance(1)  // → ↓
        default: return false  // ⌃Tab itself goes through the menu shortcut.
        }
        return true
    }
}

@MainActor @Observable
final class TabSwitcherModel {
    var tabs: [Item] = []
    var selection = 0
    var theme = SpaceTheme(hex: "#9C99BA")
    /// The previews' size: shaped like the page, as wide as the row allows.
    var cardWidth: CGFloat = 220
    var aspect: CGFloat = 0.625

    func fit(_ count: Int, in area: CGSize) {
        guard count > 0, area.width > 0, area.height > 0 else { return }
        aspect = min(max(area.height / area.width, 0.45), 0.9)
        // Around the pictures: 16 of padding per card, 10 between cards,
        // and on each side 12 in the row, 24 of shadow room and 16 to the
        // window's edge.
        let room = area.width - 2 * (12 + 24 + 16) - CGFloat(count) * 16 - CGFloat(count - 1) * 10
        cardWidth = min(230, max(110, (room / CGFloat(count)).rounded(.down)))
    }
}

/// Small pictures of the tabs for the switcher, taken through the DevTools
/// protocol, which also reaches tabs in the background.
@MainActor
enum TabSnapshots {
    /// Width of a picture in pixels: sharp at the cards' size on Retina.
    static let width = 480.0

    static func capture(_ item: Item) {
        guard let pane = item.pane, !item.isAsleep else { return }
        pane.callDevToolsMethod("Page.getLayoutMetrics", params: [:]) { metrics in
            guard let viewport = metrics?["cssVisualViewport"] as? [String: Any],
                  let pageWidth = viewport["clientWidth"] as? Double, let pageHeight = viewport["clientHeight"] as? Double,
                  pageWidth > 0, pageHeight > 0 else { return }
            let clip: [String: Any] = ["x": viewport["pageX"] ?? 0, "y": viewport["pageY"] ?? 0,
                                       "width": pageWidth, "height": pageHeight, "scale": width / pageWidth]
            let params: [String: Any] = ["format": "jpeg", "quality": 75, "clip": clip, "optimizeForSpeed": true]
            pane.callDevToolsMethod("Page.captureScreenshot", params: params) { result in
                guard let base64 = result?["data"] as? String, let data = Data(base64Encoded: base64),
                      let image = NSImage(data: data) else { return }
                MainActor.assumeIsolated { item.snapshot = image }
            }
        }
    }
}

/// The row of tabs, centered over the page, above the tabs' own windows.
final class TabSwitcherWindow: NSWindow {
    private let host: NSHostingView<TabSwitcherView>

    @MainActor
    init(switcher: TabSwitcher) {
        host = NSHostingView(rootView: TabSwitcherView(switcher: switcher, model: switcher.model))
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        host.sizingOptions = []
        contentView = host
    }

    @MainActor
    func show(over area: NSRect, parent: NSWindow) {
        let size = host.idealSize
        let width = min(size.width, area.width - 32)
        setFrame(NSRect(x: area.midX - width / 2, y: area.midY - size.height / 2, width: width, height: size.height),
                 display: true)
        parent.removeChildWindow(self)
        parent.addChildWindow(self, ordered: .above)
        let top = parent.childWindows?.filter { $0 !== self && $0.isVisible }.min { $0.orderedIndex < $1.orderedIndex }
        order(.above, relativeTo: (top ?? parent).windowNumber)
    }

    @MainActor
    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

struct TabSwitcherView: View {
    let switcher: TabSwitcher
    let model: TabSwitcherModel

    var body: some View {
        let theme = model.theme
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                TabSwitcherCard(tab: tab, selected: index == model.selection, width: model.cardWidth,
                                aspect: model.aspect, theme: theme)
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture {
                        model.selection = index
                        switcher.commit()
                    }
            }
        }
        .padding(12)
        .foregroundStyle(theme.foreground)
        .background(RoundedRectangle(cornerRadius: 18).fill(theme.background).shadow(color: .black.opacity(0.3), radius: 18, y: 6))
        .padding(24)
        .environment(\.colorScheme, theme.colorScheme)
    }
}

/// One tab: a picture of its page, like the macOS window switcher, and
/// its icon and title below.
private struct TabSwitcherCard: View {
    let tab: Item
    let selected: Bool
    let width: CGFloat
    let aspect: CGFloat
    let theme: SpaceTheme

    var body: some View {
        let height = (width * aspect).rounded()
        VStack(alignment: .leading, spacing: 8) {
            preview(height: height)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.foreground.opacity(0.12), lineWidth: 1))
            HStack(spacing: 6) {
                FaviconView(item: tab, size: 16)
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? theme.selection : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.foreground.opacity(selected ? 0.55 : 0), lineWidth: 2))
    }

    /// The page as it was last seen, or its icon until there is a picture.
    @ViewBuilder
    private func preview(height: CGFloat) -> some View {
        if let snapshot = tab.snapshot {
            Image(nsImage: snapshot)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height, alignment: .top)
        } else {
            ZStack {
                theme.tile
                FaviconView(item: tab, size: 32)
            }
        }
    }
}
