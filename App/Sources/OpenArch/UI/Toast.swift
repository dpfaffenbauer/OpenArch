import AppKit
import SwiftUI

/// A button in a toast ("Rückgängig"): the toast then stays a while longer.
struct ToastAction {
    let title: String
    let handler: @MainActor () -> Void
}

/// A short message over the page, like Arc's "Copied" pill: ⌘⇧C and friends.
@MainActor
final class ToastWindow: NSWindow {
    private let host = ToastHost(rootView: ToastView(text: "", symbol: ""))
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

    /// Shows |text| centered near the top of |area| (screen coordinates),
    /// with |action|'s button if there is one. A |closable| toast has a ✕
    /// and stays a good while longer.
    func show(_ text: String, symbol: String = "checkmark.circle.fill", over area: NSRect, parent: NSWindow,
              action: ToastAction? = nil, closable: Bool = false) {
        generation += 1
        let shown = generation
        let dismiss: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == shown else { return }
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
        }
        let button = action.map { action in
            ToastAction(title: action.title) {
                action.handler()
                dismiss()
            }
        }
        host.rootView = ToastView(text: text, symbol: symbol, action: button, close: closable ? dismiss : nil)
        ignoresMouseEvents = action == nil && !closable
        let size = host.idealSize
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 18, width: size.width, height: size.height),
                 display: true)
        alphaValue = 1
        parent.removeChildWindow(self)
        parent.addChildWindow(self, ordered: .above)
        // Above the tabs' own windows, which are children of |parent| too;
        // right above |parent| the page would cover it.
        let top = parent.childWindows?.filter { $0 !== self && $0.isVisible }.min { $0.orderedIndex < $1.orderedIndex }
        order(.above, relativeTo: (top ?? parent).windowNumber)
        after(closable ? 15 : action == nil ? 1.3 : 8) { [weak self] in
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

/// Its button works on the first click, while the page still has the focus.
private final class ToastHost: NSHostingView<ToastView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct ToastView: View {
    let text: String
    let symbol: String
    var action: ToastAction?
    var close: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: symbol)
            if let action {
                Button(action.title) { action.handler() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
            }
            if let close {
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .help("Schließen")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, action == nil && close == nil ? 14 : 5)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .padding(8)
        .fixedSize()
    }
}

extension NSHostingView {
    /// The size the SwiftUI view asks for. With empty sizingOptions (so the
    /// view never resizes its window) fittingSize is zero on current macOS,
    /// which left the toast and the ⌃Tab switcher 0×0 and unseen.
    var idealSize: CGSize {
        NSHostingController(rootView: rootView)
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }
}
