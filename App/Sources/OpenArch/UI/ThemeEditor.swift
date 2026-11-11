import AppKit
import SwiftUI
import OpenArchLocalization

/// Arc's theme picker for a space: a color disc with one to three handles,
/// Arc's nine swatches, Auto / Hell / Dunkel, intensity and grain. Every
/// change shows in the window at once.
struct ThemeEditor: View {
    @Binding var theme: ThemeData
    /// After every change (to save it).
    var changed: () -> Void = {}
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorDisc(theme: $theme, selected: $selected, changed: changed)
                .frame(width: ColorDisc.size, height: ColorDisc.size)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Button {
                    guard theme.colors.count > 1 else { return }
                    update { $0.colors.removeLast() }
                    selected = min(selected, theme.colors.count - 1)
                } label: {
                    Image(systemName: "minus").frame(width: 14)
                }
                .disabled(theme.colors.count <= 1)
                .help("Eine Farbe weniger")
                Button {
                    guard theme.colors.count < ThemeData.maxColors else { return }
                    update { $0.colors.append(ColorDisc.companion(for: $0.colors)) }
                    selected = theme.colors.count - 1
                } label: {
                    Image(systemName: "plus").frame(width: 14)
                }
                .disabled(theme.colors.count >= ThemeData.maxColors)
                .help("Noch eine Farbe für den Verlauf")
                Spacer(minLength: 8)
                Picker("", selection: Binding(get: { theme.appearance }, set: { value in update { $0.appearance = value } })) {
                    ForEach(ThemeAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .controlSize(.small)
            HStack(spacing: 5) {
                ForEach(ThemeData.presets, id: \.self) { hex in
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(theme.colors.indices.contains(selected)
                                                                             && theme.colors[selected] == hex ? 0.8 : 0.12),
                                                       lineWidth: theme.colors.indices.contains(selected) && theme.colors[selected] == hex ? 2 : 0.5))
                        .contentShape(Circle())
                        .onTapGesture { setColor(hex) }
                        .help(hex)
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: theme.colors.indices.contains(selected) ? theme.colors[selected] : "#808080") ?? .gray) },
                    set: { setColor(NSColor($0).hexString) }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Eigene Farbe")
            }
            slider("Intensität", value: Binding(get: { theme.intensity }, set: { value in update { $0.intensity = value } }),
                   symbols: ("drop", "drop.fill"))
            slider("Körnung", value: Binding(get: { theme.grain }, set: { value in update { $0.grain = value } }),
                   symbols: ("circle", "circle.dotted"))
        }
    }

    private func slider(_ title: String, value: Binding<Double>, symbols: (String, String)) -> some View {
        HStack(spacing: 8) {
            Text(L(title)).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Image(systemName: symbols.0).font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
            Image(systemName: symbols.1).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// A swatch or the color panel replaces the selected handle's color.
    private func setColor(_ hex: String) {
        update { theme in
            let index = theme.colors.indices.contains(selected) ? selected : 0
            theme.colors[index] = hex
        }
    }

    private func update(_ change: (inout ThemeData) -> Void) {
        var copy = theme
        change(&copy)
        guard copy != theme else { return }
        theme = copy
        changed()
    }
}

/// The disc: the hue goes round, from dark in the middle to light at the
/// edge. The first handle moves the others with it, as in Arc.
struct ColorDisc: View {
    @Binding var theme: ThemeData
    @Binding var selected: Int
    var changed: () -> Void
    @State private var dragging: Int?
    @State private var lastAngle: Double?

    static let size: CGFloat = 196
    private static let pitch: CGFloat = 9

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            // The field, as dots.
            var y = center.y - radius
            while y <= center.y + radius {
                var x = center.x - radius
                while x <= center.x + radius {
                    let dx = x - center.x, dy = y - center.y
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance <= radius - 2 {
                        let polar = Self.polar(dx: dx, dy: dy, radius: radius)
                        let color = Self.color(angle: polar.angle, radius: polar.radius)
                        let dot = 2.6 + 1.4 * (1 - distance / radius)
                        context.fill(Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)),
                                     with: .color(color.color))
                    }
                    x += Self.pitch
                }
                y += Self.pitch
            }
            // Lines from the first handle to the others, then the handles.
            let points = theme.colors.map { Self.point(for: $0, center: center, radius: radius) }
            if let first = points.first {
                for point in points.dropFirst() {
                    var line = Path()
                    line.move(to: first)
                    line.addLine(to: point)
                    context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 2)
                }
            }
            for (index, point) in points.enumerated().reversed() {
                let size: CGFloat = index == 0 ? 30 : 20
                let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                var shadow = context
                shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: 3, y: 1))
                shadow.fill(Path(ellipseIn: rect), with: .color(.white))
                let inner = rect.insetBy(dx: 3, dy: 3)
                context.fill(Path(ellipseIn: inner), with: .color(Color(nsColor: NSColor(hex: theme.colors[index]) ?? .gray)))
                if index == selected, theme.colors.count > 1 {
                    context.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(.primary.opacity(0.5)), lineWidth: 1.5)
                }
            }
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(drag).onEnded { _ in
            dragging = nil
            lastAngle = nil
        })
        .help("Ziehen, um die Farbe zu wählen")
    }

    private func drag(_ value: DragGesture.Value) {
        let radius = Self.size / 2
        let center = CGPoint(x: radius, y: radius)
        if dragging == nil {
            // The nearest handle, else the selected one jumps there.
            let points = theme.colors.map { Self.point(for: $0, center: center, radius: radius) }
            let nearest = points.indices.min { distance(points[$0], value.startLocation) < distance(points[$1], value.startLocation) }
            if let nearest, distance(points[nearest], value.startLocation) < 22 {
                dragging = nearest
            } else {
                dragging = theme.colors.indices.contains(selected) ? selected : 0
            }
            selected = dragging ?? 0
        }
        guard let index = dragging else { return }
        let polar = Self.polar(dx: value.location.x - center.x, dy: value.location.y - center.y, radius: radius)
        var copy = theme
        let old = Self.position(of: copy.colors[index])
        copy.colors[index] = Self.color(angle: polar.angle, radius: polar.radius).hex
        // The first handle turns the others with it.
        if index == 0, copy.colors.count > 1 {
            let turn = polar.angle - old.angle
            for other in 1..<copy.colors.count {
                let position = Self.position(of: copy.colors[other])
                copy.colors[other] = Self.color(angle: position.angle + turn, radius: position.radius).hex
            }
        }
        if copy != theme {
            theme = copy
            changed()
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: The disc's colors

    /// Angle in degrees (0 at the right, clockwise) and distance from the
    /// middle (0–1) of a point |dx|, |dy| from the middle.
    static func polar(dx: CGFloat, dy: CGFloat, radius: CGFloat) -> (angle: Double, radius: Double) {
        var angle = Double(atan2(dy, dx)) * 180 / .pi
        if angle < 0 { angle += 360 }
        return (angle, Double(min(1, hypot(dx, dy) / max(1, radius))))
    }

    /// The color at a place on the disc: hue by angle, lightness from 0.16
    /// in the middle to 0.9 at the edge.
    static func color(angle: Double, radius: Double) -> RGB {
        hsl(hue: angle.truncatingRemainder(dividingBy: 360) + (angle < 0 ? 360 : 0),
            saturation: 0.9, lightness: 0.16 + 0.74 * min(1, max(0, radius)))
    }

    /// Where a color sits on the disc.
    static func position(of hex: String) -> (angle: Double, radius: Double) {
        let rgb = RGB(hex: hex) ?? RGB(0.5, 0.5, 0.5)
        let maxValue = max(rgb.r, rgb.g, rgb.b), minValue = min(rgb.r, rgb.g, rgb.b)
        let lightness = (maxValue + minValue) / 2
        var hue = 0.0
        let delta = maxValue - minValue
        if delta > 0.0001 {
            switch maxValue {
            case rgb.r: hue = 60 * ((rgb.g - rgb.b) / delta).truncatingRemainder(dividingBy: 6)
            case rgb.g: hue = 60 * ((rgb.b - rgb.r) / delta + 2)
            default: hue = 60 * ((rgb.r - rgb.g) / delta + 4)
            }
        }
        if hue < 0 { hue += 360 }
        return (hue, min(1, max(0, (lightness - 0.16) / 0.74)))
    }

    static func point(for hex: String, center: CGPoint, radius: CGFloat) -> CGPoint {
        let position = position(of: hex)
        let radians = position.angle * .pi / 180
        let distance = CGFloat(position.radius) * (radius - 10)
        return CGPoint(x: center.x + cos(radians) * distance, y: center.y + sin(radians) * distance)
    }

    /// The next color for the gradient: the complement of the first, then a
    /// third beside it, at the first's lightness.
    static func companion(for colors: [String]) -> String {
        let first = position(of: colors.first ?? "#7B6CF6")
        let turn = colors.count <= 1 ? 180.0 : 120.0
        return color(angle: (first.angle + turn).truncatingRemainder(dividingBy: 360), radius: first.radius).hex
    }

    private static func hsl(hue: Double, saturation: Double, lightness: Double) -> RGB {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let h = hue / 60
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<1: (chroma, x, 0)
        case ..<2: (x, chroma, 0)
        case ..<3: (0, chroma, x)
        case ..<4: (0, x, chroma)
        case ..<5: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        let m = lightness - chroma / 2
        return RGB(r + m, g + m, b + m)
    }
}
