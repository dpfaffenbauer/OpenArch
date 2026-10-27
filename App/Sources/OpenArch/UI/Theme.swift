import AppKit
import SwiftUI

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

/// Sidebar colors derived from a space's color, like Arc's themes.
struct SpaceTheme: Equatable {
    let base: NSColor

    init(hex: String) {
        base = NSColor(hex: hex) ?? .systemPurple
    }

    /// Arc keeps white text on everything but very light colors.
    var isDark: Bool { base.luminance < 0.72 }

    var background: Color { Color(nsColor: base) }
    var backgroundBottom: Color {
        Color(nsColor: base.blended(withFraction: 0.18, of: isDark ? .black : .white) ?? base)
    }
    var foreground: Color { isDark ? .white : Color(white: 0.1) }
    var secondary: Color { foreground.opacity(0.62) }
    var tile: Color { isDark ? Color.white.opacity(0.17) : Color.black.opacity(0.06) }
    var tileHover: Color { isDark ? Color.white.opacity(0.24) : Color.black.opacity(0.09) }
    var hover: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.05) }
    var selection: Color { isDark ? Color.white.opacity(0.26) : Color.white.opacity(0.7) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

/// Space colors offered in the editor.
let spaceColorPresets = [
    "#7B6CF6", "#5E81F4", "#3FA9F5", "#2BB3A3", "#55B860", "#A0B33A",
    "#E5A33B", "#F0784A", "#E5566A", "#D85CB4", "#9A95B5", "#6B7280",
]

/// Icons offered in the space editor.
let spaceIconPresets = [
    "person.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "bolt.fill",
    "flame.fill", "leaf.fill", "globe", "server.rack", "terminal.fill",
    "chevron.left.forwardslash.chevron.right", "book.fill", "graduationcap.fill", "cart.fill",
    "music.note", "gamecontroller.fill", "camera.fill", "paintbrush.fill", "moon.fill",
    "sun.max.fill", "cloud.fill", "folder.fill", "building.2.fill", "chart.bar.fill",
    "cube.fill", "wrench.and.screwdriver.fill", "sparkles", "airplane", "dollarsign.circle.fill",
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
