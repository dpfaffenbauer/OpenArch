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
        HStack(spacing: 8) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                let selected = index == model.selection
                VStack(alignment: .leading, spacing: 8) {
                    FaviconView(item: tab, size: 26)
                    Text(tab.displayTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(CommandBarModel.shortURL(tab.currentURL))
                        .font(.system(size: 11))
                        .opacity(0.6)
                        .lineLimit(1)
                }
                .padding(12)
                .frame(width: 148, height: 118)
                .background(RoundedRectangle(cornerRadius: 12).fill(selected ? theme.selection : theme.tile))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.foreground.opacity(selected ? 0.55 : 0), lineWidth: 2))
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
