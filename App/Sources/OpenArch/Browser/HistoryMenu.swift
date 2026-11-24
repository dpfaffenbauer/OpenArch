import AppKit
import OpenArchCore
import OpenArchLocalization
import SwiftUI

/// The history menu of Back and Forward, as in Chrome and Safari: a
/// right-click (or ⌃-click) on the button lists the pages that way, the
/// nearest first, then the whole history. A pick goes there at once; with
/// ⌘ it opens in a new tab (⌘⇧ in front), as a ⌘-click on the button does.
/// This is the menu of the sidebar's buttons and Little OpenArch's; the
/// toolbar above a Chromium page has its own (toolbar.mm).
@MainActor
enum HistoryMenu {
    /// As many as Chrome lists.
    static let maxEntries = 12
    /// Longer titles are cut.
    static let maxTitleLength = 60

    /// |direction| is -1 for Back, 1 for Forward. |openInNewTab| gets the
    /// offset and whether the tab opens in the background; nil when there
    /// is nothing that way.
    static func menu(for page: (any OACPage)?, direction: Int,
                     openInNewTab: @escaping (Int, Bool) -> Void,
                     showHistory: @escaping () -> Void) -> NSMenu? {
        guard let page else { return nil }
        let menu = NSMenu()
        for step in 1...maxEntries {
            let offset = direction * step
            guard let url = page.historyURL(atOffset: offset) else { break }
            var title = page.historyTitle(atOffset: offset) ?? ""
            if title.isEmpty || title == url { title = History.display(url) }
            if title.count > maxTitleLength { title = String(title.prefix(maxTitleLength)) + "…" }
            let item = ClosureMenuItem(title: title) { [weak page] in
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.command) {
                    openInNewTab(offset, !modifiers.contains(.shift))
                } else {
                    page?.go(toHistoryOffset: offset)
                }
            }
            item.toolTip = url
            let icon = FaviconStore.shared.image(forURL: url)?.copy() as? NSImage
                ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            icon?.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        guard menu.numberOfItems > 0 else { return nil }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L("Gesamten Verlauf anzeigen"), action: showHistory))
        return menu
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}

extension View {
    /// A menu on a right-click or ⌃-click, made when it opens (nil: none).
    /// Other clicks go through to the view.
    func secondaryClickMenu(_ menu: @escaping () -> NSMenu?) -> some View {
        overlay(SecondaryClickMenu(menu: menu))
    }
}

private struct SecondaryClickMenu: NSViewRepresentable {
    let menu: () -> NSMenu?

    func makeNSView(context: Context) -> SecondaryClickView { SecondaryClickView() }
    func updateNSView(_ view: SecondaryClickView, context: Context) { view.makeMenu = menu }
}

final class SecondaryClickView: NSView {
    var makeMenu: (() -> NSMenu?)?

    /// Only right-clicks and ⌃-clicks land here; the button below gets the rest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        let secondary = switch event.type {
        case .rightMouseDown, .rightMouseUp: true
        case .leftMouseDown, .leftMouseUp: event.modifierFlags.contains(.control)
        default: false
        }
        return secondary ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
