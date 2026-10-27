import AppKit
import SwiftUI

/// A short message over the page, like Arc's "Copied" pill: ⌘⇧C and friends.
@MainActor
final class ToastWindow: NSWindow {
    private let host = NSHostingView(rootView: ToastView(text: ""))
    private var generation = 0

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

    /// Shows |text| centered near the top of |area| (screen coordinates).
    func show(_ text: String, over area: NSRect, parent: NSWindow) {
        host.rootView = ToastView(text: text)
        let size = host.fittingSize
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 18, width: size.width, height: size.height),
                 display: true)
        alphaValue = 1
        parent.removeChildWindow(self)
        parent.addChildWindow(self, ordered: .above)
        // Above the tabs' own windows, which are children of |parent| too;
        // right above |parent| the page would cover it.
        let top = parent.childWindows?.filter { $0 !== self && $0.isVisible }.min { $0.orderedIndex < $1.orderedIndex }
        order(.above, relativeTo: (top ?? parent).windowNumber)
        generation += 1
        let shown = generation
        after(1.3) { [weak self] in
            guard let self, self.generation == shown else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    guard self.generation == shown else { return }
                    self.parent?.removeChildWindow(self)
                    self.orderOut(nil)
                }
            }
        }
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .padding(8)
            .fixedSize()
    }
}
