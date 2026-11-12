import AppKit

/// A space's theme drawn as Arc draws it, back to front: the window's blur
/// (the desktop behind it, frosted), white or black, the colors at
/// 0.2 + 0.55 × intensity, and the grain. Behind the sidebar and around the
/// pages, and behind the floating sidebar and Little OpenArch's bar.
@MainActor
final class SpaceBackgroundView: NSView {
    /// The desktop, frosted; shown while the window is in front.
    let blur = NSVisualEffectView()
    private let underlay = NSView()
    private let colors = NSView()
    private let grain = GrainView()
    /// macOS 26's Liquid Glass sheet in the glass look, between the blur and
    /// the colors.
    private(set) var glassSheet: NSView?

    private(set) var theme: SpaceTheme?
    private var renderedSize = CGSize.zero
    /// What is drawn now (self-test): the colors' opacity, the underlay's,
    /// and the grain.
    private(set) var colorOpacity: Double = 0
    private(set) var underlayOpacity: Double = 0
    var grainAmount: Double { grain.isHidden ? 0 : grain.amount }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        // Glass in front or not: macOS would flatten an inactive window's
        // blur to plain gray (with Settings in front, for instance).
        blur.state = .active
        for view in [underlay, colors] {
            view.wantsLayer = true
            view.layer?.actions = ["contents": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull()]
        }
        colors.layer?.contentsGravity = .resize
        addSubview(blur)
        addSubview(underlay)
        addSubview(colors)
        addSubview(grain)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks go to whatever lies under it in its window.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setGlassSheet(_ sheet: NSView?) {
        glassSheet?.removeFromSuperview()
        glassSheet = sheet
        if let sheet { addSubview(sheet, positioned: .above, relativeTo: underlay) }
    }

    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
        }
    }

    /// |active|: the window is in front, so the desktop shows through and
    /// the grain is at full strength. |glassTint|: the glass look, with this
    /// much of the colors over the glass and no white or black under them.
    func apply(_ theme: SpaceTheme, active: Bool, glassTint: Double? = nil) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let glass = glassTint != nil
        if theme != self.theme || renderedSize != bounds.size {
            self.theme = theme
            renderColors()
        }
        underlay.layer?.backgroundColor = theme.underlay.nsColor.cgColor
        // Arc lets a little of the desktop through while the window is in
        // front, and none once it is not. Slightly more here, so the
        // window itself feels a touch translucent by default.
        underlayOpacity = glass ? 0 : (active && !reduced ? (theme.isDark ? 0.74 : 0.79) : 1)
        underlay.alphaValue = underlayOpacity
        blur.isHidden = (!glass && underlayOpacity >= 1) || glassSheet.map { !$0.isHidden } == true
        colorOpacity = glassTint ?? theme.layerOpacity
        colors.alphaValue = colorOpacity
        grain.amount = theme.grainAmount(active: active)
    }

    private func renderColors() {
        guard let theme else { return }
        renderedSize = bounds.size
        colors.layer?.contents = theme.layerImage(for: bounds.size.width > 0 ? bounds.size : CGSize(width: 1, height: 1))
    }

    override func layout() {
        super.layout()
        for view in [blur, underlay, colors, grain] { view.frame = bounds }
        glassSheet?.frame = bounds
        // The diagonal stays at 45° when the window changes shape; redraw
        // once it has really changed.
        if let theme, abs(bounds.width / max(1, bounds.height) - renderedSize.width / max(1, renderedSize.height)) > 0.02 {
            self.theme = theme
            renderColors()
        }
    }
}
