import AppKit
import SwiftUI

/// With the sidebar collapsed, moving the mouse to the window's left edge
/// brings it back over the page, like Arc. It goes away again once the
/// mouse has left it for a moment.
@MainActor
final class FloatingSidebar {
    private unowned let browser: BrowserWindowController
    private var panel: FloatingSidebarWindow?
    private var watch: Timer?
    private var outsideSince: Date?
    private var menuOpen = false
    private var observers: [Any] = []
    private(set) var isShown = false
    /// The self-test moves the "mouse" without touching the real one.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }

    static let margin: CGFloat = 6

    init(browser: BrowserWindowController) {
        self.browser = browser
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false }
        })
    }

    /// Where the sidebar floats, in screen coordinates: below the window
    /// buttons, along the left edge.
    var frame: NSRect? {
        guard let window = browser.window, let content = window.contentView else { return nil }
        let top: CGFloat = window.styleMask.contains(.fullScreen) ? Self.margin : 30
        let rect = NSRect(x: Self.margin, y: Self.margin, width: browser.sidebarWidth,
                          height: content.bounds.height - Self.margin - top)
        return window.convertToScreen(rect)
    }

    func show() {
        guard !isShown, !browser.state.sidebarVisible, let window = browser.window, window.isVisible,
              let frame else { return }
        let panel = self.panel ?? FloatingSidebarWindow(browser: browser)
        self.panel = panel
        panel.applyTheme(SpaceTheme(hex: browser.state.space.colorHex))
        panel.setFrame(frame.offsetBy(dx: -16, dy: 0), display: false)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.order(.above, relativeTo: window.windowNumber)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
        isShown = true
        outsideSince = nil
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouse() }
        }
    }

    func hide() {
        watch?.invalidate()
        watch = nil
        guard isShown, let panel else { return }
        isShown = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Keeps the sidebar in place and above the panes, which are child
    /// windows too and get re-added when they move.
    func layout() {
        guard isShown, let panel, let window = browser.window, let frame else { return }
        if browser.state.sidebarVisible {
            hide()
            return
        }
        panel.setFrame(frame, display: true)
        window.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
    }

    func applyTheme() {
        panel?.applyTheme(SpaceTheme(hex: browser.state.space.colorHex))
    }

    private func checkMouse() {
        guard let panel, isShown else { return }
        let inside = panel.frame.insetBy(dx: -14, dy: -14).contains(mouseLocation())
        if inside || menuOpen || NSEvent.pressedMouseButtons != 0 || panel.isKeyWindow {
            outsideSince = nil
            return
        }
        let since = outsideSince ?? Date()
        outsideSince = since
        if Date().timeIntervalSince(since) > 0.35 {
            hide()
        }
    }
}

/// The window the floating sidebar lives in; it can take the keyboard for
/// renaming tabs and folders.
final class FloatingSidebarWindow: NSWindow {
    init(browser: BrowserWindowController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: SidebarView(browser: browser, floating: true))
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
    }

    func applyTheme(_ theme: SpaceTheme) {
        contentView?.layer?.backgroundColor = theme.base.cgColor
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A strip along the window's left edge that brings back the collapsed
/// sidebar when the mouse touches it.
final class SidebarEdgeView: NSView {
    var onEnter: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }
}
