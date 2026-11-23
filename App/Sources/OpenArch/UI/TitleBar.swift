import AppKit
import SwiftUI

/// A window whose title bar is transparent, with the content running under
/// it. Since macOS 27.2.1, AppKit ignores a double-click on such a title
/// bar (a window without `titlebarAppearsTransparent` still zooms), so the
/// window does it itself: a double-click in the title bar's height on the
/// window's background, or on a `TitleBarArea`, does what System Settings
/// says (zoom, minimize, or nothing).
class TitleBarWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2, isTitleBarBackground(at: event.locationInWindow) {
            performTitleBarDoubleClick()
            return
        }
        super.sendEvent(event)
    }

    /// The title bar's height: what the content layout leaves out at the top.
    var titleBarHeight: CGFloat {
        let height = frame.height - contentLayoutRect.height
        return height > 0 ? height : 28
    }

    /// Whether |point| (window coordinates) lies in the title bar's height
    /// on nothing that takes clicks itself: the window's background or a
    /// TitleBarArea, not a button, a page or other SwiftUI content.
    func isTitleBarBackground(at point: NSPoint) -> Bool {
        guard styleMask.contains(.titled), !styleMask.contains(.fullScreen),
              point.y >= frame.height - titleBarHeight, let content = contentView,
              let hit = content.hitTest(content.convert(point, from: nil)) else { return false }
        var view: NSView? = hit
        while let current = view, current !== content {
            if current is TitleBarAreaView { return true }
            if current is SpaceBackgroundView { return true }
            view = current.superview
        }
        return hit === content
    }

    /// What System Settings > Desktop & Dock > "Double-click a window's
    /// title bar to" asks for. Unset means zoom.
    func performTitleBarDoubleClick() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "None":
            return
        case "Minimize":
            performMiniaturize(nil)
        case "Maximize", "Fill":
            performZoom(nil)
        default:
            // Before macOS 11 there was only this switch.
            if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
                performMiniaturize(nil)
            } else {
                performZoom(nil)
            }
        }
    }
}

/// The free space of a bar in the title bar: put behind it, it marks where
/// a double-click zooms the window (see TitleBarWindow). Buttons and fields
/// above it keep their clicks; dragging the window works as before.
struct TitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarAreaView { TitleBarAreaView() }
    func updateNSView(_ view: TitleBarAreaView, context: Context) {}
}

final class TitleBarAreaView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// SwiftUI that only shows something, like the loading line in the title
/// bar's strip above the page: clicks go through it to what lies below.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
