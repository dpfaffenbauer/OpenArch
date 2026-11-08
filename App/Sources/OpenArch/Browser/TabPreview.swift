import AppKit
import SwiftUI

/// Resting the pointer on a tab in the sidebar shows a picture of its page
/// beside the sidebar, with its title and address (Settings › Allgemein ›
/// Sidebar › Vorschau beim Überfahren). Moving on to the next tab switches
/// the picture at once.
@MainActor
final class TabPreview {
    private unowned let browser: BrowserWindowController
    private var window: TabPreviewWindow?
    private var pending: DispatchWorkItem?
    /// The tab the preview shows (or is about to).
    private(set) var item: Item?
    /// The self-test shows it without waiting.
    var delay: TimeInterval = 0.6

    init(browser: BrowserWindowController) {
        self.browser = browser
    }

    var isShown: Bool { window?.isVisible == true }

    /// The pointer entered or left a tab's row; |row| is its frame in the
    /// sidebar's SwiftUI coordinates.
    func hover(_ item: Item, row: CGRect, inside: Bool) {
        guard inside else { return leave(item) }
        guard browser.library.settings.tabPreviews, FeatureSwitches.shared.isOn(.tabPreviews), browser.state.sidebarVisible, item.kind == .tab,
              item !== browser.state.activeItem, let anchor = browser.sidebarAnchor(forRow: row) else { return }
        pending?.cancel()
        self.item = item
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.show(item, at: anchor) }
        }
        pending = work
        // Already open: the next tab right away, as the pointer moves down.
        DispatchQueue.main.asyncAfter(deadline: .now() + (isShown ? 0.04 : delay), execute: work)
    }

    func leave(_ item: Item) {
        guard self.item === item else { return }
        pending?.cancel()
        // A moment's grace, so going to the next row does not flicker.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        item = nil
        window?.hide()
    }

    private func show(_ item: Item, at anchor: NSPoint) {
        guard let parent = browser.window, parent.isVisible, self.item === item else { return }
        // A fresh picture of a loaded page (in the background too); until it
        // arrives, the last one or the tab's icon.
        TabSnapshots.capture(item)
        let window = self.window ?? TabPreviewWindow()
        self.window = window
        let content = browser.contentRect
        let aspect = content.width > 0 ? min(0.75, max(0.45, content.height / content.width)) : 0.6
        window.show(TabPreviewCard(item: item, aspect: aspect, theme: SpaceTheme(hex: browser.state.space.colorHex)),
                    beside: anchor, in: parent)
    }
}

/// A borderless window over the pages (which are windows of their own).
final class TabPreviewWindow: NSWindow {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    @MainActor
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        host.sizingOptions = []
        contentView = host
    }

    /// Left edge at the sidebar's edge, centered on the row, inside the window.
    @MainActor
    func show(_ card: TabPreviewCard, beside anchor: NSPoint, in parent: NSWindow) {
        host.rootView = AnyView(card)
        // Measured on a view of its own: the window's view has no sizing
        // options (it must not resize the window), so it measures as zero.
        let size = NSHostingView(rootView: card).fittingSize
        let screenAnchor = parent.convertPoint(toScreen: anchor)
        let limits = parent.frame.insetBy(dx: 8, dy: 8)
        var origin = NSPoint(x: screenAnchor.x + 4, y: screenAnchor.y - size.height / 2)
        origin.y = min(max(origin.y, limits.minY), limits.maxY - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true)
        if self.parent !== parent {
            self.parent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
        }
        // Above the page's own windows.
        let top = parent.childWindows?.filter { $0 !== self && $0.isVisible }.min { $0.orderedIndex < $1.orderedIndex }
        order(.above, relativeTo: (top ?? parent).windowNumber)
    }

    @MainActor
    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// The page as it was last seen, its icon and title, and the address.
struct TabPreviewCard: View {
    let item: Item
    let aspect: CGFloat
    let theme: SpaceTheme
    static let width: CGFloat = 300

    var body: some View {
        let height = (Self.width * aspect).rounded()
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let snapshot = item.snapshot {
                    Image(nsImage: snapshot).resizable().scaledToFill()
                        .frame(width: Self.width, height: height, alignment: .top)
                } else {
                    ZStack {
                        theme.tile
                        VStack(spacing: 8) {
                            FaviconView(item: item, size: 32)
                            if item.pane == nil {
                                Text(item.isAsleep ? "Schläft" : "Nicht geladen").font(.system(size: 11)).opacity(0.6)
                            }
                        }
                    }
                }
            }
            .frame(width: Self.width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.foreground.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    FaviconView(item: item, size: 14)
                    Text(item.displayTitle).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Text(CommandBarModel.shortURL(item.currentURL)).font(.system(size: 11)).opacity(0.6).lineLimit(1)
                    .truncationMode(.middle)
                if let checks = item.checks, !checks.label.isEmpty {
                    Label(checks.label, systemImage: checks.state == .success ? "checkmark.circle.fill"
                          : checks.state == .failure ? "xmark.circle.fill" : "circle.dotted.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(checks.state == .success ? Color.green : checks.state == .failure ? .red : .orange)
                }
            }
            .frame(width: Self.width, alignment: .leading)
        }
        .padding(10)
        .foregroundStyle(theme.foreground)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: theme.base))
            .shadow(color: .black.opacity(0.3), radius: 14, y: 5))
        .padding(16)
        .environment(\.colorScheme, theme.colorScheme)
    }
}
