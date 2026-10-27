import AppKit

/// While a tab is dragged out of the sidebar, a transparent panel over the
/// page offers two drop zones: drop on the left or right half to show the
/// tab beside the current one (Arc's drag-to-split).
@MainActor
final class SplitDropOverlay {
    private let panel: NSPanel
    private let dropView = SplitDropView()

    init(browser: BrowserWindowController) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the pane windows, which would otherwise take the drop.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = dropView
        dropView.onDrop = { [weak browser] id, leading in
            guard let browser, let item = browser.library.item(id: id) else { return false }
            browser.dropForSplit(item, leading: leading)
            return true
        }
    }

    func show(over screenRect: NSRect, above window: NSWindow) {
        dropView.zone = nil
        panel.setFrame(screenRect, display: false)
        panel.orderFront(nil)
    }

    func hide() {
        dropView.zone = nil
        panel.orderOut(nil)
    }
}

final class SplitDropView: NSView {
    enum Zone { case leading, trailing }

    var zone: Zone? {
        didSet { if oldValue != zone { needsDisplay = true } }
    }
    var onDrop: ((UUID, Bool) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.openArchTab])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func zone(for sender: NSDraggingInfo) -> Zone {
        convert(sender.draggingLocation, from: nil).x < bounds.midX ? .leading : .trailing
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        zone = zone(for: sender)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        zone = zone(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        zone = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let leading = zone(for: sender) == .leading
        zone = nil
        guard let data = sender.draggingPasteboard.data(forType: .openArchTab),
              let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return false }
        BrowserWindowController.tabDropHandled = true
        return onDrop?(id, leading) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let zone else { return }
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        var half = bounds
        half.size.width = bounds.width / 2
        if zone == .trailing { half.origin.x = bounds.midX }
        let target = half.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: target, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.22).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: target.midX - size.width / 2, y: target.midY + 4,
                                   width: size.width, height: size.height))
        }
        let label = NSAttributedString(string: "Split View", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let labelSize = label.size()
        label.draw(at: NSPoint(x: target.midX - labelSize.width / 2, y: target.midY - labelSize.height - 6))
    }
}
