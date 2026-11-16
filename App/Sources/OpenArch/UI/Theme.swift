import AppKit
import SwiftUI
import OpenArchLocalization

extension NSColor {
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        func byte(_ value: CGFloat) -> Int { max(0, min(255, Int((value * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
    }

    /// Relative luminance (0 = black, 1 = white).
    var luminance: CGFloat {
        let color = usingColorSpace(.sRGB) ?? self
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}

// MARK: - Colors in sRGB and OKLab

/// An opaque sRGB color, components 0–1 (gamma encoded), for the theme math.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
        self.r = clamp(r)
        self.g = clamp(g)
        self.b = clamp(b)
    }

    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    static let white = RGB(1, 1, 1)
    static let black = RGB(0, 0, 0)

    var hex: String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// |self| at |alpha| over |below|, as Core Animation blends.
    func over(_ below: RGB, alpha: Double) -> RGB {
        RGB(r * alpha + below.r * (1 - alpha), g * alpha + below.g * (1 - alpha), b * alpha + below.b * (1 - alpha))
    }

    /// WCAG luminance.
    var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast between two colors (1–21).
    func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// Björn Ottosson's OKLab: a color space in which mixing two colors looks
/// even, without the gray middle of a mix in sRGB.
struct OKLab: Equatable {
    var l: Double, a: Double, b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    /// In degrees, 0–360.
    var hue: Double {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    /// Lightness, chroma and hue in degrees (OKLCH).
    init(l: Double, chroma: Double, hue: Double) {
        let radians = hue * .pi / 180
        self.init(l: l, a: chroma * cos(radians), b: chroma * sin(radians))
    }

    init(_ rgb: RGB) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private var linearRGB: (Double, Double, Double) {
        let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Back to sRGB. A color outside it keeps its lightness and hue and
    /// gives up chroma until it fits.
    var rgb: RGB {
        func fits(_ c: (Double, Double, Double)) -> Bool {
            [c.0, c.1, c.2].allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 }
        }
        var linear = linearRGB
        if !fits(linear) {
            var low = 0.0, high = 1.0
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if fits(OKLab(l: l, a: a * mid, b: b * mid).linearRGB) { low = mid } else { high = mid }
            }
            linear = OKLab(l: l, a: a * low, b: b * low).linearRGB
        }
        func encode(_ v: Double) -> Double {
            let v = min(1, max(0, v))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return RGB(encode(linear.0), encode(linear.1), encode(linear.2))
    }

    static func mix(_ x: OKLab, _ y: OKLab, _ t: Double) -> OKLab {
        OKLab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }
}

// MARK: - The stored theme

/// Light or dark sidebar: by the colors and the Mac (auto), or always.
enum ThemeAppearance: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L("Auto")
        case .light: L("Hell")
        case .dark: L("Dunkel")
        }
    }

    var symbol: String {
        switch self {
        case .auto: "sparkles"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

/// A space's theme as Arc stores it: one to three colors that blend along
/// the window's diagonal, how strongly they show, grain and light or dark.
/// Saved in Library.json with each space.
struct ThemeData: Codable, Equatable, Hashable {
    /// "#RRGGBB", one to three.
    var colors: [String]
    /// 0–1; Arc's intensity slider.
    var intensity: Double
    /// 0–1; Arc's grain dial.
    var grain: Double
    var appearance: ThemeAppearance

    static let defaultIntensity = 0.81
    static let maxColors = 3

    init(colors: [String], intensity: Double = ThemeData.defaultIntensity, grain: Double = 0,
         appearance: ThemeAppearance = .auto) {
        self.colors = colors
        self.intensity = intensity
        self.grain = grain
        self.appearance = appearance
        normalize()
    }

    /// A space with a single color (how OpenArch stored spaces before
    /// themes): that color as the only handle.
    init(hex: String, grain: Double = 0) {
        self.init(colors: [hex], grain: grain)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colors = try container.decodeIfPresent([String].self, forKey: .colors) ?? []
        intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? Self.defaultIntensity
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        // A value from a newer version falls back to auto.
        appearance = (try? container.decodeIfPresent(ThemeAppearance.self, forKey: .appearance)) ?? .auto
        normalize()
    }

    /// Valid colors only, at most three, at least one; values in range.
    private mutating func normalize() {
        colors = colors.compactMap { RGB(hex: $0)?.hex }.prefix(Self.maxColors).map { $0 }
        if colors.isEmpty { colors = [ThemeData.presets[2]] }
        intensity = intensity.isFinite ? min(1, max(0, intensity)) : Self.defaultIntensity
        grain = grain.isFinite ? min(1, max(0, grain)) : 0
    }

    /// Arc's nine swatches in its theme picker.
    static let presets = [
        "#F0EAE5", "#E59EBA", "#9E749B", "#E1676F", "#EF8C63",
        "#F2D46C", "#73E49B", "#7EB6D5", "#656786",
    ]
}

// MARK: - The resolved theme

/// Every color the window needs for one space's theme, like Arc's: the
/// background (an OKLab blend of the colors along the 45° diagonal, drawn at
/// 0.2 + 0.55 × intensity over white or black, over the window's blur, with
/// grain on top) and the tokens for text, hover, selection, the command bar,
/// menus and toasts, all derived from it.
struct SpaceTheme: Equatable {
    let data: ThemeData
    let isDark: Bool
    /// White (light) or black (dark), under the colors.
    let underlay: RGB
    /// How strongly the colors cover the underlay; lowered from
    /// 0.2 + 0.55 × intensity only where text would no longer read.
    let layerOpacity: Double
    private let stops: [OKLab]
    /// The background's average color, for plain fills.
    let average: RGB
    let surfaceRGB: RGB
    let accentRGB: RGB
    let toastRGB: RGB

    @MainActor private static var cache: [String: SpaceTheme] = [:]

    /// The theme for |data| on the Mac's light or dark mode, cached.
    @MainActor static func resolve(_ data: ThemeData, systemDark: Bool = SpaceTheme.systemIsDark) -> SpaceTheme {
        let key = "\(data.colors) \(data.intensity) \(data.grain) \(data.appearance.rawValue) \(systemDark)"
        if let theme = cache[key] { return theme }
        let theme = SpaceTheme(data, systemDark: systemDark)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = theme
        return theme
    }

    /// A theme with a single color (previews, defaults).
    @MainActor init(hex: String) {
        self = SpaceTheme.resolve(ThemeData(hex: hex))
    }

    @MainActor static var systemIsDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Whether |data| looks dark on a Mac in light or dark mode. Auto follows
    /// the Mac, but very light colors stay light and very dark ones dark,
    /// as in Arc.
    static func rendersDark(_ data: ThemeData, systemDark: Bool) -> Bool {
        switch data.appearance {
        case .light: return false
        case .dark: return true
        case .auto:
            let labs = data.colors.compactMap(RGB.init(hex:)).map(OKLab.init)
            guard !labs.isEmpty else { return systemDark }
            let lightness = labs.map(\.l).reduce(0, +) / Double(labs.count)
            if lightness >= 0.8 { return false }
            if lightness <= 0.42 { return true }
            return systemDark
        }
    }

    init(_ data: ThemeData, systemDark: Bool) {
        self.data = data
        let dark = Self.rendersDark(data, systemDark: systemDark)
        isDark = dark
        underlay = dark ? .black : .white
        let stops = data.colors.compactMap(RGB.init(hex:)).map(OKLab.init)
        self.stops = stops
        let ink: RGB = dark ? .white : RGB(0.1, 0.1, 0.1)

        // Wash the colors out where the text would not read on them (navy
        // with dark text, lemon with white text): the theme gives way.
        var opacity = 0.2 + 0.55 * data.intensity
        let samples = Self.samplePoints.map { Self.layerColor(stops: stops, t: $0.0, y: $0.1) }
        func worst(_ opacity: Double) -> Double {
            samples.map { ink.contrast(with: $0.over(dark ? .black : .white, alpha: opacity)) }.min() ?? 21
        }
        while opacity > 0.05, worst(opacity) < 4.6 {
            opacity -= 0.02
        }
        let layerOpacity = max(0, opacity)
        self.layerOpacity = layerOpacity
        let composited = samples.map { OKLab($0.over(dark ? .black : .white, alpha: layerOpacity)) }
        let mean = composited.reduce(OKLab(l: 0, a: 0, b: 0)) { OKLab(l: $0.l + $1.l, a: $0.a + $1.a, b: $0.b + $1.b) }
        let count = Double(max(1, composited.count))
        let meanLab = OKLab(l: mean.l / count, a: mean.a / count, b: mean.b / count)
        average = meanLab.rgb

        // Command bar, menus' cards: near white or deep gray, with a little
        // of the theme's hue.
        surfaceRGB = OKLab(l: dark ? 0.26 : 0.985, chroma: min(meanLab.chroma * 0.3, dark ? 0.02 : 0.012), hue: meanLab.hue).rgb
        // The most colorful color at a middle lightness that carries white text.
        let vivid = stops.max { $0.chroma < $1.chroma } ?? OKLab(l: 0.6, a: 0, b: 0)
        var accentL = dark ? 0.62 : 0.56
        var accent = OKLab(l: accentL, chroma: min(max(vivid.chroma, 0.09), 0.2), hue: vivid.hue).rgb
        if vivid.chroma < 0.03 { accent = OKLab(l: accentL, a: 0, b: 0).rgb }
        while RGB.white.contrast(with: accent) < 4.5, accentL > 0.25 {
            accentL -= 0.02
            accent = OKLab(l: accentL, chroma: vivid.chroma < 0.03 ? 0 : min(max(vivid.chroma, 0.09), 0.2), hue: vivid.hue).rgb
        }
        accentRGB = accent
        // Toasts: a deep pill in the theme's hue with white text.
        toastRGB = OKLab(l: 0.27, chroma: min(vivid.chroma * 0.35, 0.05), hue: vivid.hue).rgb
    }

    /// Points along the diagonal and down the window, for the contrast check.
    private static let samplePoints: [(Double, Double)] = {
        var points: [(Double, Double)] = []
        for t in stride(from: 0.0, through: 1.0, by: 0.25) {
            for y in stride(from: 0.0, through: 1.0, by: 0.5) { points.append((t, y)) }
        }
        return points
    }()

    /// The colors alone at diagonal position |t| (0 top left, 1 bottom
    /// right) and height |y| (0 top): colors 1 and 2 blend in OKLab and
    /// reach color 2 at three quarters; color 3 fades in towards the bottom.
    private static func layerColor(stops: [OKLab], t: Double, y: Double) -> RGB {
        guard let first = stops.first else { return RGB(0.6, 0.6, 0.65) }
        var color = stops.count > 1 ? OKLab.mix(first, stops[1], min(1, t / 0.75)).rgb : first.rgb
        if stops.count > 2 {
            color = stops[2].rgb.over(color, alpha: y)
        }
        return color
    }

    /// The finished background at a point of a window (0,0 top left, 1,1
    /// bottom right) of |aspect| = width / height, without the desktop: the
    /// diagonal runs at 45° whatever the window's shape.
    func backgroundColor(x: Double, y: Double, aspect: Double = 1) -> RGB {
        let t = (x * aspect + y) / (aspect + 1)
        return Self.layerColor(stops: stops, t: t, y: y).over(underlay, alpha: layerOpacity)
    }

    /// The colors alone, opaque, for a view of |size|, to draw at
    /// layerOpacity over the underlay. Smooth enough at ~160 pixels across;
    /// the grain hides any steps.
    func layerImage(for size: CGSize, pixels: Int = 160) -> CGImage? {
        let aspect = size.height > 0 ? Double(size.width / size.height) : 1
        let width = aspect >= 1 ? pixels : max(2, Int(Double(pixels) * aspect))
        let height = aspect >= 1 ? max(2, Int(Double(pixels) / aspect)) : pixels
        // The OKLab blend depends only on the place along the diagonal.
        let ramp: [RGB] = (0...255).map { Self.layerColor(stops: Array(stops.prefix(2)), t: Double($0) / 255, y: 0) }
        let third = stops.count > 2 ? stops[2].rgb : nil
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let y = Double(row) / Double(height - 1)
            for column in 0..<width {
                let x = Double(column) / Double(width - 1)
                let t = (x * aspect + y) / (aspect + 1)
                var color = ramp[Int((min(1, t / 0.75) * 255).rounded())]
                if stops.count < 2 { color = ramp[0] }
                if let third { color = third.over(color, alpha: y) }
                let index = (row * width + column) * 4
                bytes[index] = UInt8((color.r * 255).rounded())
                bytes[index + 1] = UInt8((color.g * 255).rounded())
                bytes[index + 2] = UInt8((color.b * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// How much grain shows; an inactive window dims it to a quarter, as Arc.
    func grainAmount(active: Bool) -> Double {
        data.grain * (active ? 1 : 0.25)
    }

    // MARK: Tokens

    /// The background's color as one plain color.
    var base: NSColor { average.nsColor }
    var background: Color { average.color }
    /// The blend as a SwiftUI gradient, for cards drawn in the theme.
    var gradient: LinearGradient {
        let colors = (0...6).map { step -> Color in
            let t = Double(step) / 6
            return backgroundColor(x: t, y: t).color
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Sidebar text.
    var foreground: Color { isDark ? .white : Color(white: 0.1) }
    var secondary: Color { foreground.opacity(0.62) }
    var tile: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.06) }
    var tileHover: Color { isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.09) }
    var hover: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.05) }
    var selection: Color { isDark ? Color.white.opacity(0.24) : Color.white.opacity(0.75) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var appearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
    /// The command bar's card, and other cards over the page.
    var surface: Color { surfaceRGB.color }
    var surfaceText: Color { isDark ? Color.white.opacity(0.94) : Color(white: 0.1) }
    var surfaceSelection: Color { accent.opacity(isDark ? 0.32 : 0.16) }
    /// Buttons, sliders and switches in the theme.
    var accent: Color { accentRGB.color }
    var toastBackground: Color { toastRGB.color.opacity(0.94) }
    /// The outline around the focused side of a split.
    var focusRing: NSColor { isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.35) }
}

/// Icons offered in the space editor.
let spaceIconPresets = [
    "person.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "bolt.fill",
    "flame.fill", "leaf.fill", "globe", "server.rack", "terminal.fill",
    "chevron.left.forwardslash.chevron.right", "book.fill", "graduationcap.fill", "cart.fill",
    "music.note", "gamecontroller.fill", "camera.fill", "paintbrush.fill", "moon.fill",
    "sun.max.fill", "cloud.fill", "folder.fill", "building.2.fill", "chart.bar.fill",
    "cube.fill", "wrench.and.screwdriver.fill", "sparkles", "airplane", "dollarsign.circle.fill",
]

/// Colors new spaces get, one each while there are unused ones.
let spaceColorPresets = [
    "#7B6CF6", "#5E81F4", "#3FA9F5", "#2BB3A3", "#55B860", "#A0B33A",
    "#E5A33B", "#F0784A", "#E5566A", "#D85CB4", "#9A95B5", "#6B7280",
]

/// A space icon: an SF Symbol name or an emoji.
struct SpaceIcon: View {
    let icon: String
    var size: CGFloat = 13

    var body: some View {
        if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
        } else {
            Text(icon).font(.system(size: size + 1))
        }
    }
}
