import AppKit
import OpenArchCore
import SwiftUI

/// Über OpenArch: a flight through OpenArch's arches. The logo springs in,
/// the name builds itself letter by letter, and a click on the logo goes to
/// warp speed.
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    static let warpNotification = Notification.Name("OpenArchAboutWarp")
    private(set) var window: NSWindow?

    func show(selfTest: Bool = false) {
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Über OpenArch"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(AboutView.night)
            window.center()
            self.window = window
            return window
        }()
        // A new view each time, so the intro plays again.
        window.contentView = NSHostingView(rootView: AboutView())
        if selfTest {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func warp() {
        NotificationCenter.default.post(name: Self.warpNotification, object: nil)
    }
}

/// The tunnel icon's colors, and the night around it.
private let nightColor = Color(red: 0.035, green: 0.06, blue: 0.045)
private let greenColor = Color(red: 0.333, green: 0.722, blue: 0.376)
private let mintColor = Color(red: 0.561, green: 0.859, blue: 0.6)
private let orangeColor = Color(red: 0.94, green: 0.54, blue: 0.24)

struct AboutView: View {
    static let night = nightColor
    static let green = greenColor
    static let mint = mintColor

    @State private var start = Date()
    @State private var appeared = false
    @State private var floating = false
    @State private var warps: [Date] = []
    @State private var pointer: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let time = timeline.date.timeIntervalSince(start)
                Canvas { context, size in
                    WarpTunnel(time: reduceMotion ? 4 : time, travel: travel(at: timeline.date),
                               flash: flash(at: timeline.date), pointer: pointer).draw(in: &context, size: size)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)
                logo
                Spacer().frame(height: 26)
                LetterTitle(text: "OpenArch", appeared: appeared)
                Spacer().frame(height: 10)
                ShimmerName(appeared: appeared, reduceMotion: reduceMotion)
                Spacer(minLength: 30)
                details
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.8).delay(1.3), value: appeared)
                Spacer().frame(height: 26)
            }
            .padding(.horizontal, 32)
        }
        .background(Self.night)
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointer = location } else { pointer = nil }
        }
        .onAppear {
            start = Date()
            if reduceMotion {
                appeared = true
            } else {
                appeared = true
                after(1.4) { floating = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AboutWindowController.warpNotification)) { _ in warp() }
    }

    private var logo: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 132, height: 132)
            .shadow(color: Self.green.opacity(0.65), radius: 28)
            .scaleEffect(appeared ? 1 : 0.15)
            .rotationEffect(.degrees(appeared ? 0 : -30))
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.75, dampingFraction: 0.5).delay(0.15), value: appeared)
            .offset(y: floating ? -7 : 7)
            .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: floating)
            .onTapGesture { warp() }
            .help("Klick für Warp")
    }

    private var details: some View {
        VStack(spacing: 14) {
            VStack(spacing: 3) {
                Text("Version \(Updater.shared.versionDescription)")
                Text("Chromium \(OACEngine.versionString)")
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                AboutLink(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
                          url: "https://github.com/dpfaffenbauer/OpenArch")
                AboutLink(title: "openarch.app", symbol: "globe", url: "https://openarch.app")
            }
            Text("Open Source unter der MIT-Lizenz · mit Chromium und CEF gebaut")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    /// Hyperspace for two seconds: the tunnel rushes past, then slows down.
    private func warp() {
        guard !reduceMotion else { return }
        warps.append(Date())
        warps = warps.filter { Date().timeIntervalSince($0) < 3 }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    /// How far the flight has come: steady, plus each warp's extra distance
    /// (speed up to eight times, smoothly in and out over two seconds).
    private func travel(at date: Date) -> Double {
        var distance = date.timeIntervalSince(start)
        for warp in warps {
            let u = min(2, max(0, date.timeIntervalSince(warp)))
            distance += 7 * (u / 2 - sin(.pi * u) / (2 * .pi))
        }
        return distance
    }

    private func flash(at date: Date) -> Double {
        warps.map { warp in
            let u = date.timeIntervalSince(warp)
            return u < 0 || u > 2 ? 0 : sin(.pi * u / 2)
        }.max() ?? 0
    }
}

/// The tunnel: OpenArch's arch, again and again, coming at you, on a floor
/// of light, with sparks streaming out of the vanishing point.
private struct WarpTunnel {
    let time: Double
    let travel: Double
    let flash: Double
    let pointer: CGPoint?

    private static let colors: [Color] = [greenColor, mintColor, greenColor, orangeColor, mintColor]

    func draw(in context: inout GraphicsContext, size: CGSize) {
        // The intro fades the tunnel in.
        let intro = smoothstep(0, 1.2, time)
        var center = CGPoint(x: size.width / 2, y: size.height * 0.36)
        if let pointer {
            center.x += (pointer.x - size.width / 2) * 0.08
            center.y += (pointer.y - size.height / 2) * 0.06
        }

        if flash > 0 {
            let radius = max(size.width, size.height) * (0.3 + flash * 0.5)
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(colors: [mintColor.opacity(0.35 * flash), .clear]),
                                               center: center, startRadius: 0, endRadius: radius))
        }

        let count = 16
        // Far ones first, so the near ones draw over them.
        let arches = (0..<count).map { index -> (z: Double, index: Int) in
            (fraction(Double(index) / Double(count) + travel * 0.11), index)
        }.sorted { $0.z < $1.z }

        for (z, index) in arches {
            let scale = 0.03 + pow(z, 2.5) * 3.4
            let alpha = intro * min(1, z * 5) * (1 - smoothstep(0.78, 1, z))
            guard alpha > 0.01 else { continue }
            let width = 150 * scale, height = 200 * scale
            let bottom = center.y + 110 * scale
            let color = Self.colors[index % Self.colors.count]

            // Its line on the floor.
            var floor = Path()
            floor.move(to: CGPoint(x: 0, y: bottom))
            floor.addLine(to: CGPoint(x: size.width, y: bottom))
            context.stroke(floor, with: .color(color.opacity(alpha * 0.18)), lineWidth: 1)

            let arch = archPath(center: center.x, bottom: bottom, width: width, height: height)
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 4 + 5 * scale))
                glow.stroke(arch, with: .color(color.opacity(alpha * 0.9)), lineWidth: 2 + 5 * scale)
            }
            context.stroke(arch, with: .color(color.opacity(alpha)), lineWidth: 1 + 2.2 * scale)
        }

        // Floor lines from the vanishing point.
        for step in -6...6 {
            var ray = Path()
            ray.move(to: CGPoint(x: center.x, y: center.y + 4))
            ray.addLine(to: CGPoint(x: center.x + Double(step) * size.width * 0.32, y: size.height + 40))
            context.stroke(ray, with: .color(greenColor.opacity(0.07 * intro)), lineWidth: 1)
        }

        // Sparks: each its own direction and speed; streaks while warping.
        let reach = max(size.width, size.height) * 0.75
        for spark in 0..<110 {
            let seed = Double(spark)
            let angle = random(seed * 1.7) * 2 * .pi
            let speed = 0.15 + random(seed * 3.1) * 0.35
            let r = fraction(random(seed * 5.3) + travel * speed * 0.35)
            let distance = pow(r, 2) * reach
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let point = CGPoint(x: center.x + direction.x * distance, y: center.y + direction.y * distance)
            let alpha = intro * min(1, r * 8) * (1 - r) * 0.9
            let color = spark % 7 == 0 ? Self.colors[3] : (spark % 2 == 0 ? Color.white : mintColor)
            if flash > 0.05 {
                let length = 10 + flash * 90 * r
                var streak = Path()
                streak.move(to: point)
                streak.addLine(to: CGPoint(x: point.x - direction.x * length, y: point.y - direction.y * length))
                context.stroke(streak, with: .color(color.opacity(alpha)), lineWidth: 0.8 + r * 1.8)
            } else {
                let size = 0.6 + r * 2.4
                context.fill(Path(ellipseIn: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)),
                             with: .color(color.opacity(alpha)))
            }
        }
    }

    /// The arch of the logo: straight sides, a round top, open at the floor.
    private func archPath(center x: Double, bottom: Double, width: Double, height: Double) -> Path {
        let radius = width / 2
        var path = Path()
        path.move(to: CGPoint(x: x - radius, y: bottom))
        path.addLine(to: CGPoint(x: x - radius, y: bottom - height + radius))
        path.addArc(center: CGPoint(x: x, y: bottom - height + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: x + radius, y: bottom))
        return path
    }

    private func fraction(_ value: Double) -> Double { value - floor(value) }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// The same "random" number for the same seed, every frame.
    private func random(_ seed: Double) -> Double {
        fraction(sin(seed * 12.9898 + 78.233) * 43758.5453)
    }
}

/// "OpenArch", each letter flying in after the one before.
private struct LetterTitle: View {
    let text: String
    let appeared: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, AboutView.mint], startPoint: .top, endPoint: .bottom))
                    .shadow(color: AboutView.green.opacity(0.7), radius: 14)
                    .offset(y: appeared ? 0 : 46)
                    .scaleEffect(appeared ? 1 : 0.4, anchor: .bottom)
                    .opacity(appeared ? 1 : 0)
                    .blur(radius: appeared ? 0 : 10)
                    .animation(.spring(response: 0.55, dampingFraction: 0.55).delay(0.45 + Double(index) * 0.06), value: appeared)
            }
        }
        .tracking(-1)
    }
}

/// "von Dominik Pfaffenbauer", with light running over the name.
private struct ShimmerName: View {
    let appeared: Bool
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text("von")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
            name
        }
        .offset(y: appeared ? 0 : 14)
        .opacity(appeared ? 1 : 0)
        .animation(.easeOut(duration: 0.7).delay(1.05), value: appeared)
    }

    private var name: some View {
        let label = Text("Dominik Pfaffenbauer").font(.system(size: 19, weight: .bold, design: .rounded))
        return label
            .foregroundStyle(.white.opacity(0.85))
            .overlay {
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    let phase = (timeline.date.timeIntervalSinceReferenceDate / 2.6).truncatingRemainder(dividingBy: 1) * 1.8 - 0.4
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: AboutView.mint, location: 0.4),
                                           .init(color: .white, location: 0.5),
                                           .init(color: AboutView.mint, location: 0.6),
                                           .init(color: .clear, location: 1)],
                                   startPoint: UnitPoint(x: phase - 0.35, y: 0.5),
                                   endPoint: UnitPoint(x: phase + 0.35, y: 0.5))
                }
                .mask(label)
            }
            .shadow(color: AboutView.green.opacity(0.5), radius: 10)
    }
}

private struct AboutLink: View {
    let title: String
    let symbol: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            (NSApp.delegate as? AppDelegate)?.browser?.openInNewTab(url)
            AboutWindowController.shared.window?.close()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(.white.opacity(hovering ? 0.16 : 0.08)))
                .overlay(Capsule().strokeBorder(AboutView.mint.opacity(hovering ? 0.6 : 0.25)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
