import AppKit

/// Dock icons to choose from: twelve takes on the arch (Tunnel is OpenArch's
/// own), one in the color of the space you are in, and a different one each
/// day.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case dusk, neon, bands, tunnel, bauhaus, sidebar, moonGate, pixel, origami, orbit, candy, keystone, space, daily

    var id: String { rawValue }

    /// The standard icon, the one in the app bundle.
    static let standard = AppIconStyle.tunnel

    var name: String {
        switch self {
        case .space: "Space-Farbe"
        case .daily: "Jeden Tag"
        default: design?.name ?? rawValue
        }
    }

    /// The drawing, for the twelve fixed icons.
    var design: AppIconDesign? {
        switch self {
        case .space, .daily: nil
        default: AppIconDesign.all[rawValue]
        }
    }
}

/// One of the arch icons: a tile and a glyph drawn on a 64-point grid, as
/// on the design canvas.
struct AppIconDesign {
    let name: String
    /// One color, or a gradient from the top down.
    let tile: [String]
    /// SVG elements on a 64 × 64 grid.
    let glyph: String
    var glow: NSColor?

    /// The glyph as an image (macOS reads SVG).
    var glyphImage: NSImage? {
        NSImage(data: Data("""
            <svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">\(glyph)</svg>
            """.utf8))
    }

    static let all: [String: AppIconDesign] = [
        "dusk": AppIconDesign(name: "Dusk", tile: ["#FFB36B", "#F2577E"], glyph: """
            <path fill="#2B1B4A" d="M12 58 V30 A20 20 0 0 1 52 30 V58 Z"/><circle cx="32" cy="48" r="9" fill="#FFD27A"/>\
            <rect x="12" y="48" width="40" height="10" fill="#1A0F30"/>
            """),
        "neon": AppIconDesign(name: "Neon", tile: ["#0B0F1A"], glyph: """
            <path fill="#3EF0E0" d="M6 58 V32 A26 26 0 0 1 58 32 V58 H55.5 V32 A23.5 23.5 0 0 0 8.5 32 V58 Z"/>\
            <path fill="#7CFF8A" d="M13 58 V32 A19 19 0 0 1 51 32 V58 H48.5 V32 A16.5 16.5 0 0 0 15.5 32 V58 Z"/>\
            <path fill="#FF5FD2" d="M20 58 V32 A12 12 0 0 1 44 32 V58 H41.5 V32 A9.5 9.5 0 0 0 22.5 32 V58 Z"/>
            """, glow: NSColor(srgbRed: 124 / 255, green: 1, blue: 138 / 255, alpha: 0.6)),
        "bands": AppIconDesign(name: "Bänder", tile: ["#FFF4E2"], glyph: """
            <path fill="#F2577E" d="M6 58 V34 A26 26 0 0 1 58 34 V58 H52 V34 A20 20 0 0 0 12 34 V58 Z"/>\
            <path fill="#FFB36B" d="M12 58 V34 A20 20 0 0 1 52 34 V58 H46 V34 A14 14 0 0 0 18 34 V58 Z"/>\
            <path fill="#55B860" d="M18 58 V34 A14 14 0 0 1 46 34 V58 H40 V34 A8 8 0 0 0 24 34 V58 Z"/>\
            <path fill="#3E7BE6" d="M24 58 V34 A8 8 0 0 1 40 34 V58 Z"/>
            """),
        "tunnel": AppIconDesign(name: "Tunnel", tile: ["#13201A"], glyph: tunnelGlyph(outer: "#55B860", ring: "#8FDB99", ground: "#13201A")),
        "bauhaus": AppIconDesign(name: "Bauhaus", tile: ["#F1E9DA"], glyph: """
            <path fill="#E2463B" d="M8 34 A24 24 0 0 1 56 34 Z"/><path fill="#F1E9DA" d="M20 34 A12 12 0 0 1 44 34 Z"/>\
            <rect x="8" y="34" width="12" height="24" fill="#2F5BD3"/><rect x="44" y="34" width="12" height="24" fill="#F4C430"/>\
            <circle cx="32" cy="47" r="4" fill="#13201A"/>
            """),
        "sidebar": AppIconDesign(name: "Sidebar", tile: ["#FFFFFF"], glyph: """
            <path fill="#13201A" d="M8 58 V30 A24 24 0 0 1 56 30 V58 Z"/><path fill="#EAF6EC" d="M25 53 V36 A12.5 12.5 0 0 1 50 36 V53 Z"/>\
            <rect x="30" y="42" width="15" height="3" rx="1.5" fill="#55B860"/><rect x="30" y="47" width="10" height="3" rx="1.5" fill="#B9DDBF"/>\
            <rect x="12" y="33" width="9" height="3" rx="1.5" fill="#55B860"/><rect x="12" y="39" width="9" height="3" rx="1.5" fill="#3E7BE6"/>\
            <rect x="12" y="45" width="6" height="3" rx="1.5" fill="#F08A3C"/>
            """),
        "moonGate": AppIconDesign(name: "Moon Gate", tile: ["#C8643B"], glyph: """
            <circle cx="32" cy="32" r="22" fill="#BFE3F2"/><circle cx="41" cy="22" r="4" fill="#FFF3C4"/>\
            <path fill="#55B860" d="M11.51 40 Q32 30 52.49 40 A22 22 0 0 1 11.51 40 Z"/>
            """),
        "pixel": AppIconDesign(name: "Pixel", tile: ["#101A14"], glyph: pixelGlyph),
        "origami": AppIconDesign(name: "Origami", tile: ["#EAF6EC"], glyph: """
            <path fill="#55B860" d="M6 32 L9.48 19 L21.61 26 L20 32 Z"/><path fill="#2F8A3E" d="M9.48 19 L19 9.48 L26 21.61 L21.61 26 Z"/>\
            <path fill="#55B860" d="M19 9.48 L32 6 L32 20 L26 21.61 Z"/><path fill="#2F8A3E" d="M32 6 L45 9.48 L38 21.61 L32 20 Z"/>\
            <path fill="#55B860" d="M45 9.48 L54.52 19 L42.39 26 L38 21.61 Z"/><path fill="#2F8A3E" d="M54.52 19 L58 32 L44 32 L42.39 26 Z"/>\
            <path fill="#2F8A3E" d="M6 32 H20 L6 45 Z"/><path fill="#55B860" d="M20 32 V58 H6 V45 Z"/>\
            <path fill="#55B860" d="M44 32 H58 V45 Z"/><path fill="#2F8A3E" d="M44 32 L58 45 V58 H44 Z"/>
            """),
        "orbit": AppIconDesign(name: "Orbit", tile: ["#1B2340"], glyph: """
            <circle cx="10" cy="22" r="1" fill="#FFFFFF"/><circle cx="38" cy="7" r="1" fill="#FFFFFF"/>\
            <circle cx="22" cy="10" r="0.8" fill="#FFFFFF"/>\
            <path fill="#FFFFFF" d="M8 56 V34 A22 22 0 0 1 52 34 V56 H42 V34 A12 12 0 0 0 18 34 V56 Z"/>\
            <circle cx="52" cy="14" r="5" fill="#F08A3C"/>
            """),
        "candy": AppIconDesign(name: "Candy", tile: ["#FFD6E5"], glyph: """
            <path fill="#FF4F8B" d="M10 50 V30 A22 22 0 0 1 54 30 V50 H42 V30 A10 10 0 0 0 22 30 V50 Z"/>\
            <circle cx="16" cy="50" r="6" fill="#FF4F8B"/><circle cx="48" cy="50" r="6" fill="#FF4F8B"/>\
            <rect x="13" y="24" width="4" height="12" rx="2" fill="#FFFFFF" opacity="0.7"/>
            """),
        "keystone": AppIconDesign(name: "Keystone", tile: ["#13201A"], glyph: """
            <g fill="#E8EDE6"><path d="M6 32 A26 26 0 0 1 10.34 17.61 L21.17 24.81 A13 13 0 0 0 19 32 Z"/>\
            <path d="M11.13 16.5 A26 26 0 0 1 23.19 7.54 L27.6 19.77 A13 13 0 0 0 21.56 24.25 Z"/>\
            <path d="M40.81 7.54 A26 26 0 0 1 52.87 16.5 L42.44 24.25 A13 13 0 0 0 36.4 19.77 Z"/>\
            <path d="M53.66 17.61 A26 26 0 0 1 58 32 L45 32 A13 13 0 0 0 42.83 24.81 Z"/>\
            <rect x="6" y="34.5" width="13" height="10.5"/><rect x="6" y="47.5" width="13" height="10.5"/>\
            <rect x="45" y="34.5" width="13" height="10.5"/><rect x="45" y="47.5" width="13" height="10.5"/></g>\
            <path fill="#55B860" d="M24.49 7.11 A26 26 0 0 1 39.51 7.11 L35.76 19.55 A13 13 0 0 0 28.24 19.55 Z"/>
            """),
    ]

    /// Tunnel's nested arches; Space-Farbe draws it in the space's colors.
    static func tunnelGlyph(outer: String, ring: String, ground: String) -> String {
        """
        <path fill="\(outer)" d="M6 58 V32 A26 26 0 0 1 58 32 V58 Z"/><path fill="\(ground)" d="M11 58 V36 A21 21 0 0 1 53 36 V58 Z"/>\
        <path fill="\(ring)" d="M16 58 V40 A16 16 0 0 1 48 40 V58 Z"/><path fill="\(ground)" d="M21 58 V44 A11 11 0 0 1 43 44 V58 Z"/>\
        <path fill="#F3F5F1" d="M26 58 V48 A6 6 0 0 1 38 48 V58 Z"/>
        """
    }

    /// An arch of green pixels with an orange one in the doorway.
    static let pixelGlyph: String = {
        let rows: [(y: Int, xs: [Int])] = [
            (5, [17, 23, 29, 35, 41]), (11, [11, 17, 23, 29, 35, 41, 47]), (17, [5, 11, 17, 41, 47, 53]),
        ] + [23, 29, 35, 41, 47, 53].map { ($0, [5, 11, 47, 53]) }
        let pixels = rows.flatMap { row in
            row.xs.map { "<rect x=\"\($0)\" y=\"\(row.y)\" width=\"5.4\" height=\"5.4\" rx=\"1\"/>" }
        }
        return "<g fill=\"#7CFF8A\">\(pixels.joined())</g><rect x=\"29\" y=\"47\" width=\"5.4\" height=\"5.4\" rx=\"1\" fill=\"#F08A3C\"/>"
    }()
}

@MainActor
enum AppIcons {
    static var style: AppIconStyle {
        // Earlier choices ("standard", the plain colors) become Tunnel.
        get { AppIconStyle(rawValue: UserDefaults.standard.string(forKey: "appIcon") ?? "") ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appIcon") }
    }

    private static var spaceHex = "#7B6CF6"

    /// Picks |style|: the Dock shows it at once, and keeps it while OpenArch
    /// is closed (see saveForDock).
    static func choose(_ style: AppIconStyle) {
        self.style = style
        apply()
        saveForDock()
    }

    /// At launch: the Dock icon, and the icon the Dock keeps while OpenArch
    /// is closed.
    static func applyAtLaunch(spaceHex: String) {
        self.spaceHex = spaceHex
        apply()
        saveForDock()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { if style == .daily { apply() } }
        }
    }

    /// The window in front changed space.
    static func spaceDidChange(_ hex: String) {
        guard hex != spaceHex else { return }
        spaceHex = hex
        if style == .space { apply() }
    }

    private static func apply() {
        NSApp.applicationIconImage = style == .standard ? nil : image(for: style)
    }

    /// Where the Dock's plug-in (Sources/OpenArchDockTile) finds the icon to
    /// show while OpenArch is closed; none means the bundle's own.
    static var dockIconFile: URL {
        AppPaths.support.appendingPathComponent("DockIcon.png")
    }

    /// The icon the Dock shows last stays there after OpenArch quits: the
    /// Dock's plug-in draws it. The app bundle itself is never changed, so
    /// its signature stays intact.
    static func saveForDock() {
        let file = dockIconFile
        if style == .standard {
            try? FileManager.default.removeItem(at: file)
        } else if let tiff = image(for: style, size: 512).tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: file, options: .atomic)
        }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("dev.openarch.dockIconChanged"), object: nil, deliverImmediately: true)
    }

    /// Earlier versions put the chosen icon on the app in Finder. That adds
    /// a file and Finder information to the bundle and breaks its signature
    /// (1Password, for one, then no longer trusts the browser), so it comes
    /// off again.
    static func repairBundle() {
        let path = Bundle.main.bundlePath
        let iconFile = path + "/Icon\r"
        let hasFinderInfo = getxattr(path, "com.apple.FinderInfo", nil, 0, 0, 0) >= 0
        guard FileManager.default.fileExists(atPath: iconFile) || hasFinderInfo else { return }
        NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        try? FileManager.default.removeItem(atPath: iconFile)
        removexattr(path, "com.apple.FinderInfo", 0)
        log("removed the custom icon from the app bundle, which broke its signature")
    }

    /// Today's design for "Jeden Tag".
    static func design(for day: Date) -> AppIconStyle {
        let designs = AppIconStyle.allCases.filter { $0.design != nil }
        let index = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        return designs[index % designs.count]
    }

    static func image(for style: AppIconStyle, size: CGFloat = 512) -> NSImage {
        switch style {
        case .daily:
            return image(for: design(for: Date()), size: size)
        case .space:
            let base = NSColor(hex: spaceHex) ?? .systemPurple
            let ground = base.blended(withFraction: 0.78, of: .black) ?? base
            let ring = base.blended(withFraction: 0.45, of: .white) ?? base
            let design = AppIconDesign(name: "Space", tile: [ground.hexString],
                                       glyph: AppIconDesign.tunnelGlyph(outer: base.hexString, ring: ring.hexString,
                                                                        ground: ground.hexString))
            return draw(design, size: size)
        default:
            return style.design.map { draw($0, size: size) } ?? NSImage()
        }
    }

    /// An icon on Apple's 1024-point grid: the tile with a soft shadow, and
    /// the glyph at two thirds of its width, as on the design canvas.
    static func draw(_ design: AppIconDesign, size: CGFloat) -> NSImage {
        let glyph = design.glyphImage
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / 1024
            let tile = superellipse(NSRect(x: 100, y: 100, width: 824, height: 824), scale: scale)
            let colors = design.tile.compactMap { NSColor(hex: $0) }

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 22 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
            shadow.set()
            (colors.last ?? .gray).setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()

            if colors.count > 1 {
                // The canvas's 160° CSS gradient: mostly top to bottom.
                NSGradient(colors: colors)?.draw(in: tile, angle: -70)
            }
            if let first = colors.first, first.luminance > 0.9 {
                // Light tiles get an edge, so they hold up on a light Dock.
                NSColor.black.withAlphaComponent(0.08).setStroke()
                tile.lineWidth = 4 * scale
                tile.stroke()
            }

            let side = 824 * 112 / 168 * scale
            let rect = NSRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            if let glow = design.glow {
                let shadow = NSShadow()
                shadow.shadowColor = glow
                shadow.shadowBlurRadius = side * 5 / 112
                shadow.set()
            }
            glyph?.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// The standard icon for the app bundle (an .iconset for iconutil) and
    /// the website, from the same drawing: `OpenArch --export-icons <folder>`.
    static func exportIcons(to folder: URL) {
        let iconset = folder.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                writePNG(of: .standard, pixels: points * scale, to: iconset.appendingPathComponent(name))
            }
        }
        writePNG(of: .standard, pixels: 512, to: folder.appendingPathComponent("icon.png"))
    }

    private static func writePNG(of style: AppIconStyle, pixels: Int, to url: URL) {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image(for: style, size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
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
