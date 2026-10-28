import AppKit
import OpenArchCore
import QuartzCore
import UniformTypeIdentifiers

/// Downloads as the sidebar shows them, like Arc: the file flies into the
/// library button when it starts, a ring around the button shows the
/// progress, and the button bounces once the file is there. Chrome itself
/// saves the file and lists it in its toolbar.
@MainActor @Observable
final class Downloads {
    static let shared = Downloads()

    /// Running downloads: progress 0…1, or -1 while the size is unknown.
    private(set) var progress: [UInt32: Double] = [:]
    /// Goes up with every finished download.
    private(set) var finished = 0
    @ObservationIgnored private var lastUpdate: [UInt32: Date] = [:]
    @ObservationIgnored private var seen = Set<UInt32>()
    @ObservationIgnored private var done = Set<UInt32>()
    @ObservationIgnored private var sweepScheduled = false

    /// The running downloads together, nil when none runs, -1 when no size
    /// is known.
    var overall: Double? {
        guard !progress.isEmpty else { return nil }
        let known = progress.values.filter { $0 >= 0 }
        return known.isEmpty ? -1 : known.reduce(0, +) / Double(known.count)
    }

    func update(_ download: OACDownload, in browser: BrowserWindowController?) {
        let id = download.identifier
        if seen.insert(id).inserted, !download.isFailed, let browser {
            DownloadFlight.fly(download.fileName, into: browser)
        }
        if download.isComplete || download.isFailed {
            progress[id] = nil
            lastUpdate[id] = nil
            if download.isComplete, done.insert(id).inserted {
                finished += 1
            }
        } else {
            progress[id] = download.percentComplete < 0 ? -1 : Double(download.percentComplete) / 100
            lastUpdate[id] = Date()
            scheduleSweep()
        }
    }

    /// A download whose tab went away can stop reporting; its share of the
    /// ring goes after a minute without news.
    private func scheduleSweep() {
        guard !sweepScheduled else { return }
        sweepScheduled = true
        after(60) { [self] in
            sweepScheduled = false
            let cutoff = Date().addingTimeInterval(-60)
            for (id, date) in lastUpdate where date < cutoff {
                progress[id] = nil
                lastUpdate[id] = nil
            }
            if !progress.isEmpty { scheduleSweep() }
        }
    }
}

/// The file's icon flying from where you clicked into the library button.
@MainActor
enum DownloadFlight {
    static func fly(_ fileName: String, into browser: BrowserWindowController) {
        guard let window = browser.window, window.isVisible, !window.isMiniaturized else { return }
        let content = browser.contentRect
        var start = window.mouseLocationOutsideOfEventStream
        if !content.contains(start) {
            start = NSPoint(x: content.midX, y: content.midY)
        }
        let end = browser.libraryButtonCenter

        let overlay = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.isReleasedWhenClosed = false
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        view.wantsLayer = true
        overlay.contentView = view
        window.addChildWindow(overlay, ordered: .above)
        // Above the tabs' own windows, which are children of the window too.
        let top = window.childWindows?.filter { $0 !== overlay && $0.isVisible }.min { $0.orderedIndex < $1.orderedIndex }
        overlay.order(.above, relativeTo: (top ?? window).windowNumber)

        let type = UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        layer.contents = icon.layerContents(forContentsScale: window.backingScaleFactor)
        layer.contentsScale = window.backingScaleFactor
        layer.position = end
        layer.opacity = 0
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -2)
        view.layer?.addSublayer(layer)

        // Up a little first, then down into the button.
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + 120))
        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path
        position.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.3
        scale.toValue = 0.35
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 0.2]
        opacity.keyTimes = [0, 0.12, 0.85, 1]
        let group = CAAnimationGroup()
        group.animations = [position, scale, opacity]
        group.duration = 0.75

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                window.removeChildWindow(overlay)
                overlay.orderOut(nil)
            }
        }
        layer.add(group, forKey: "flight")
        CATransaction.commit()
    }
}
