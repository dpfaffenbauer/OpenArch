import AppKit

/// Arc's grain: fine noise over the space's color, behind the sidebar and
/// around the pages. Settings › Allgemein › Sidebar › Körnung.
final class GrainView: NSView {
    /// 0 = none, 1 = strong.
    var amount: Double = 0 {
        didSet {
            isHidden = amount <= 0
            layer?.opacity = Float(min(1, max(0, amount)) * 0.55)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(patternImage: Self.noise).cgColor
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks go through to the sidebar and the window behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// One tile of noise, at twice the points for Retina, light and dark
    /// specks with little alpha so it suits any color.
    private static let noise: NSImage = {
        let pixels = 256
        let image = NSImage(size: NSSize(width: pixels / 2, height: pixels / 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return image }
        // The same pattern every time (a simple LCG), so it never flickers.
        var seed: UInt32 = 0x9E37_79B9
        for index in 0..<(pixels * pixels) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let value = UInt8(seed >> 24)
            let light = value & 1 == 0
            // Premultiplied: white or black at 0–35 % alpha.
            let alpha = UInt8(Double(value) / 255 * 90)
            let channel = light ? alpha : 0
            data[index * 4] = channel
            data[index * 4 + 1] = channel
            data[index * 4 + 2] = channel
            data[index * 4 + 3] = alpha
        }
        rep.size = image.size
        image.addRepresentation(rep)
        return image
    }()
}
