import SwiftUI
import UIKit

extension UIColor {
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Relative luminance (0 = black, 1 = white).
    var luminance: CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    func mixed(with other: UIColor, _ fraction: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * fraction, green: g1 + (g2 - g1) * fraction,
                       blue: b1 + (b2 - b1) * fraction, alpha: 1)
    }
}

/// Colors derived from a space's color, as in OpenArch for Mac: white text
/// on everything but light colors. The line is a little lower than on the
/// Mac, where text is smaller on a screen in the shade: white on the orange
/// and olive presets is about 2.2:1, dark text about 7.5:1.
struct SpaceTheme: Equatable {
    let base: UIColor

    init(hex: String) {
        base = UIColor(hex: hex) ?? .systemPurple
    }

    var isDark: Bool { base.luminance < 0.62 }
    var background: Color { Color(uiColor: base) }
    var backgroundBottom: Color { Color(uiColor: base.mixed(with: isDark ? .black : .white, 0.18)) }
    var gradient: LinearGradient {
        LinearGradient(colors: [background, backgroundBottom], startPoint: .top, endPoint: .bottom)
    }
    var foreground: Color { isDark ? .white : Color(white: 0.1) }
    var secondary: Color { foreground.opacity(0.72) }
    var tile: Color { isDark ? Color.white.opacity(0.17) : Color.black.opacity(0.06) }
    var selection: Color { isDark ? Color.white.opacity(0.26) : Color.white.opacity(0.7) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

/// Space colors offered in the editor (the Mac's).
let spaceColorPresets = [
    "#7B6CF6", "#5E81F4", "#3FA9F5", "#2BB3A3", "#55B860", "#A0B33A",
    "#E5A33B", "#F0784A", "#E5566A", "#D85CB4", "#9A95B5", "#6B7280",
]

let spaceIconPresets = [
    "person.fill", "briefcase.fill", "house.fill", "star.fill", "heart.fill", "bolt.fill",
    "flame.fill", "leaf.fill", "globe", "book.fill", "graduationcap.fill", "cart.fill",
    "music.note", "gamecontroller.fill", "camera.fill", "paintbrush.fill", "moon.fill", "sun.max.fill",
    "cloud.fill", "folder.fill", "building.2.fill", "chart.bar.fill", "sparkles", "airplane",
]

/// A space or folder icon: an SF Symbol name or an emoji.
struct SymbolOrEmoji: View {
    let icon: String
    var size: CGFloat = 15

    var body: some View {
        if UIImage(systemName: icon) != nil {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
        } else {
            Text(icon).font(.system(size: size + 1))
        }
    }
}
