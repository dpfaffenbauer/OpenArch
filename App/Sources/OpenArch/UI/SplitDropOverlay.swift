import AppKit

/// While a tab is dragged out of the sidebar, a transparent panel over the
/// page offers four drop zones: drop on the left or right half to show the
/// tab beside the current one, on the top or bottom half to show it above
/// or below (Arc's drag-to-split).
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
        dropView.onDrop = { [weak browser] id, zone in
            guard let browser, let item = browser.library.item(id: id) else { return false }
            browser.dropForSplit(item, leading: zone.isFirst, stacked: zone.isStacked)
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
    enum Zone {
        case leading, trailing, top, bottom

        /// The dropped tab comes first: on the left, or on top.
        var isFirst: Bool { self == .leading || self == .top }
        var isStacked: Bool { self == .top || self == .bottom }
    }

    var zone: Zone? {
        didSet { if oldValue != zone { needsDisplay = true } }
    }
    var onDrop: ((UUID, Zone) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.openArchTab])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The half whose outer edge |point| is nearest to, measured against
    /// the page's width and height so a wide page still has a top and a
    /// bottom. The middle counts as left or right.
    static func zone(at point: NSPoint, in bounds: NSRect) -> Zone {
        let dx = min(point.x - bounds.minX, bounds.maxX - point.x) / max(bounds.width, 1)
        let dy = min(point.y - bounds.minY, bounds.maxY - point.y) / max(bounds.height, 1)
        if dy < dx {
            return point.y > bounds.midY ? .top : .bottom
        }
        return point.x < bounds.midX ? .leading : .trailing
    }

    private func zone(for sender: NSDraggingInfo) -> Zone {
        Self.zone(at: convert(sender.draggingLocation, from: nil), in: bounds)
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
        let zone = zone(for: sender)
        self.zone = nil
        guard let data = sender.draggingPasteboard.data(forType: .openArchTab),
              let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return false }
        BrowserWindowController.tabDropHandled = true
        return onDrop?(id, zone) ?? false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let zone else { return }
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        var half = bounds
        switch zone {
        case .leading:
            half.size.width = bounds.width / 2
        case .trailing:
            half.size.width = bounds.width / 2
            half.origin.x = bounds.midX
        case .top:
            half.size.height = bounds.height / 2
            half.origin.y = bounds.midY
        case .bottom:
            half.size.height = bounds.height / 2
        }
        let target = half.insetBy(dx: 10, dy: 10)
        let path = NSBezierPath(roundedRect: target, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.22).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        let symbolName = zone.isStacked ? "rectangle.split.1x2" : "rectangle.split.2x1"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
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
