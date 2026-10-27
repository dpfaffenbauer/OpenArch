import AppKit

/// Dock icons to choose from, like Arc's: the standard one, one that takes
/// the color of the space you are in, and a few fixed colors.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case standard, space, green, apricot, sky, rose, graphite, midnight, paper

    var id: String { rawValue }

    var name: String {
        switch self {
        case .standard: "Standard"
        case .space: "Space-Farbe"
        case .green: "Grün"
        case .apricot: "Apricot"
        case .sky: "Himmel"
        case .rose: "Rosé"
        case .graphite: "Graphit"
        case .midnight: "Mitternacht"
        case .paper: "Papier"
        }
    }

    /// The tile's top-left and bottom-right colors, and the arch's.
    var colors: (top: NSColor, bottom: NSColor, arch: NSColor)? {
        switch self {
        case .standard, .space: nil
        case .green: (hex("#6BD07A"), hex("#2E9E5B"), .white)
        case .apricot: (hex("#F7C15E"), hex("#E0782E"), .white)
        case .sky: (hex("#6CC4FF"), hex("#2F7FE0"), .white)
        case .rose: (hex("#F58BB0"), hex("#D9467A"), .white)
        case .graphite: (hex("#5C5C68"), hex("#1F1F26"), .white)
        case .midnight: (hex("#3B40A0"), hex("#12133A"), hex("#E8E6FF"))
        case .paper: (hex("#FFFFFF"), hex("#E2E2EA"), hex("#2A2A33"))
        }
    }

    private func hex(_ value: String) -> NSColor { NSColor(hex: value) ?? .gray }
}

@MainActor
enum AppIcons {
    static var style: AppIconStyle {
        get { AppIconStyle(rawValue: UserDefaults.standard.string(forKey: "appIcon") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appIcon") }
    }

    /// The icon in the app bundle.
    static let standardImage: NSImage = {
        Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? NSApp.applicationIconImage
    }()

    private static var spaceHex = "#7B6CF6"

    /// Picks |style|: the Dock shows it at once, and fixed colors also go on
    /// the app in Finder (and in the Dock while OpenArch is closed).
    static func choose(_ style: AppIconStyle) {
        self.style = style
        apply(updatingBundle: true)
    }

    /// At launch: the Dock icon, and the bundle's icon again after an update
    /// replaced the app.
    static func applyAtLaunch(spaceHex: String) {
        self.spaceHex = spaceHex
        let bundleHasIcon = FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r")
        apply(updatingBundle: style.colors != nil && !bundleHasIcon)
    }

    /// The window in front changed space.
    static func spaceDidChange(_ hex: String) {
        guard hex != spaceHex else { return }
        spaceHex = hex
        if style == .space { apply(updatingBundle: false) }
    }

    private static func apply(updatingBundle: Bool) {
        NSApp.applicationIconImage = style == .standard ? nil : image(for: style)
        // Finder and the closed app keep the standard icon for "space"; the
        // self-test leaves the bundle alone.
        guard updatingBundle, !AppPaths.isSelfTest else { return }
        NSWorkspace.shared.setIcon(style.colors == nil ? nil : image(for: style, size: 1024),
                                   forFile: Bundle.main.bundlePath, options: [])
    }

    static func image(for style: AppIconStyle, size: CGFloat = 512) -> NSImage {
        if let colors = style.colors {
            return draw(top: colors.top, bottom: colors.bottom, arch: colors.arch, size: size)
        }
        guard style == .space else { return standardImage }
        let base = NSColor(hex: spaceHex) ?? .systemPurple
        let arch = base.luminance < 0.72 ? NSColor.white : NSColor(white: 0.12, alpha: 1)
        return draw(top: base.blended(withFraction: 0.18, of: .white) ?? base,
                    bottom: base.blended(withFraction: 0.22, of: .black) ?? base, arch: arch, size: size)
    }

    /// OpenArch's icon: a rounded tile with a diagonal gradient and the arch,
    /// on Apple's 1024-point icon grid.
    static func draw(top: NSColor, bottom: NSColor, arch: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 1024
            let tile = superellipse(NSRect(x: 100, y: 100, width: 824, height: 824), scale: scale)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 22 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
            shadow.set()
            bottom.setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -50)
            // A soft light from above, and a hairline edge.
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])?
                .draw(in: tile, angle: -90)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            tile.lineWidth = 4 * scale
            tile.stroke()

            arch.setFill()
            archPath(scale: scale).fill()
            return true
        }
    }

    /// The arch: two legs and a half circle, 107 points thick.
    private static func archPath(scale: CGFloat) -> NSBezierPath {
        let center = NSPoint(x: 511.5 * scale, y: 471 * scale)
        let outer = 253.5 * scale, inner = 146.5 * scale, bottom = 302 * scale
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x - outer, y: bottom))
        path.line(to: NSPoint(x: center.x - outer, y: center.y))
        path.appendArc(withCenter: center, radius: outer, startAngle: 180, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: center.x + outer, y: bottom))
        path.line(to: NSPoint(x: center.x + inner, y: bottom))
        path.line(to: NSPoint(x: center.x + inner, y: center.y))
        path.appendArc(withCenter: center, radius: inner, startAngle: 0, endAngle: 180, clockwise: false)
        path.line(to: NSPoint(x: center.x - inner, y: bottom))
        path.close()
        return path
    }

    /// Apple's icon shape: a superellipse rather than a rounded rectangle.
    private static func superellipse(_ rect: NSRect, scale: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let a = rect.width / 2 * scale, b = rect.height / 2 * scale
        let center = NSPoint(x: rect.midX * scale, y: rect.midY * scale)
        let exponent: CGFloat = 5
        for step in 0...360 {
            let t = CGFloat(step) / 360 * 2 * .pi
            let c = cos(t), s = sin(t)
            let x = a * copysign(pow(abs(c), 2 / exponent), c)
            let y = b * copysign(pow(abs(s), 2 / exponent), s)
            let point = NSPoint(x: center.x + x, y: center.y + y)
            step == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        return path
    }
}
