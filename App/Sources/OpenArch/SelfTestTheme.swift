import AppKit
import SwiftUI

/// Checks for Arc's themes and the sidebar on the right: how themes are
/// saved and carried over from single colors, the Arc import of themes,
/// how a theme is drawn, and the window's layout with the sidebar on the
/// right. `--selftest --theme-test` runs only these.
extension SelfTest {
    func themeFeatures(then done: @escaping () -> Void) {
        themeStorageTest()
        arcThemeImportTest()
        themeRenderingTest {
            self.sidebarRightTest(then: done)
        }
    }

    // MARK: Saving and migrating

    private func themeStorageTest() {
        // A library from before themes: one color per space, grain for all.
        let legacy = #"""
            {"version": 1, "profiles": [{"id": "Default", "name": "Test", "favorites": []}],
             "spaces": [{"id": "6B1D2F3E-0000-4000-8000-000000000001", "name": "Alt", "icon": "star.fill",
                         "colorHex": "#E5A33B", "profileID": "Default", "pinned": [], "today": []}],
             "settings": {"grain": 0.4}}
            """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let old = try? decoder.decode(LibraryData.self, from: Data(legacy.utf8)) else {
            return expect(false, "a library from before themes reads")
        }
        let scratch = Library()
        scratch.apply(old)
        let migrated = scratch.spaces.first?.theme
        expect(migrated == ThemeData(colors: ["#E5A33B"], intensity: 0.81, grain: 0.4, appearance: .auto),
               "a space with one color becomes a theme with that color as its one handle, the old grain and Arc's intensity (\(String(describing: migrated)))")

        // Saved and read again: every part of the theme stays, and the first
        // color is still there for older versions.
        let theme = ThemeData(colors: ["#2F6AF0", "#13B5B0", "#F08A9A"], intensity: 0.33, grain: 0.7, appearance: .dark)
        scratch.spaces.first?.theme = theme
        let saved = LibraryData(profiles: old.profiles, spaces: scratch.spaces.map(\.data), settings: scratch.settings)
        let json = (try? encoder.encode(saved)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let again = (try? decoder.decode(LibraryData.self, from: Data(json.utf8)))?.spaces.first
        expect(again?.theme == theme && again?.colorHex == "#2F6AF0",
               "a theme is saved with its three colors, intensity, grain and appearance, and the first color for older versions")
        let reread = Library()
        if let again { reread.apply(LibraryData(profiles: old.profiles, spaces: [again], settings: scratch.settings)) }
        expect(reread.spaces.first?.theme == theme, "and a saved theme is not replaced by the old grain")

        // What a newer version or a hand-edited file might hold.
        let odd = ##"{"colors": ["#112233", "nonsense", "#445566", "#778899", "#AABBCC"], "intensity": 3, "appearance": "sepia"}"##
        let read = try? decoder.decode(ThemeData.self, from: Data(odd.utf8))
        expect(read == ThemeData(colors: ["#112233", "#445566", "#778899"], intensity: 1, grain: 0, appearance: .auto),
               "a theme keeps at most three valid colors and values in range (\(String(describing: read)))")
    }

    // MARK: Arc import

    private func arcThemeImportTest() {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> String {
            #"{"red": \#(r), "green": \#(g), "blue": \#(b), "alpha": 1, "colorSpace": "extendedSRGB"}"#
        }
        // As Arc writes it: a gradient of two colors and an overlay color, a
        // single color (with grain as a string, as Arc 1.x stores it), and an
        // old file with only the palette's mid tone.
        let gradient = #"""
            {"background": {"single": {"_0": {"style": {"color": {"_0": {"blendedGradient": {"_0": {
               "baseColors": [\#(rgb(1, 0, 0)), {"color": \#(rgb(0, 0, 1))}], "overlayColors": [\#(rgb(0, 1, 0))],
               "modifiers": {"intensityFactor": 0.42, "noiseFactor": 0.3, "overlay": {"grain": {}}},
               "translucencyStyle": "dark"}}}}}, "isVibrant": true}}},
             "primaryColorPalette": {"midTone": \#(rgb(0.5, 0.5, 0.5))}}
            """#
        let single = #"""
            {"background": {"single": {"_0": {"style": {"color": {"_0": {"blendedSingleColor": {"_0": {
               "modifiers": {"noiseFactor": 0, "intensityFactor": 0.8, "overlay": "grain"}, "translucencyStyle": "light",
               "color": \#(rgb(0.40031713247299194, 0.4041288197040558, 0.5372623801231384))}}}}}, "isVibrant": true,
               "contentOverBackgroundAppearance": "dark"}}}}
            """#
        let old = #"{"primaryColorPalette": {"midTone": \#(rgb(0.557, 0.863, 0.753))}}"#
        func space(_ number: Int, _ theme: String) -> String {
            #"["s\#(number)", {"id": "5A1D2F3E-0000-4000-8000-00000000000\#(number)", "title": "S\#(number)", "containerIDs": ["pinned", "p", "unpinned", "u"], "customInfo": {"windowTheme": \#(theme)}}]"#
        }
        let spaces = [space(1, gradient), space(2, single), space(3, old)]
            .map { String($0.dropFirst().dropLast()) }.joined(separator: ", ")
        let json = #"""
            {"sidebar": {"containers": [{"global": {}}, {
              "items": ["p", {"id": "p", "data": {}, "childrenIds": []}, "u", {"id": "u", "data": {}, "childrenIds": []}],
              "spaces": [\#(spaces)], "topAppsContainerIDs": []}]}}
            """#
        let file = AppPaths.support.appendingPathComponent("arc-theme-test.json")
        try? Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let (data, _) = try? ArcImporter.load(from: file) else {
            return expect(false, "the Arc fixture with themes reads")
        }
        let themes = data.spaces.map(\.theme)
        expect(themes.count == 3 && themes[0] == ThemeData(colors: ["#FF0000", "#0000FF", "#00FF00"], intensity: 0.42, grain: 0.3,
                                                           appearance: .dark),
               "an Arc gradient comes over exactly: its colors in order, intensity, grain and dark (\(String(describing: themes.first ?? nil)))")
        expect(themes.count == 3 && themes[1] == ThemeData(colors: ["#666789"], intensity: 0.8, grain: 0, appearance: .light)
               && data.spaces[1].colorHex == "#666789",
               "an Arc single color with its intensity and light look (\(String(describing: themes.count > 1 ? themes[1] : nil)))")
        expect(themes.count == 3 && themes[2] == ThemeData(colors: ["#8EDCC0"]),
               "an old Arc theme with only its palette becomes one color at Arc's intensity")
    }

    // MARK: Drawing

    private func themeRenderingTest(then done: @escaping () -> Void) {
        let twoColors = ThemeData(colors: ["#FF0000", "#0000FF"], intensity: 0.81, grain: 0, appearance: .light)
        let theme = SpaceTheme(twoColors, systemDark: false)
        let alpha = 0.2 + 0.55 * 0.81
        let topLeft = theme.backgroundColor(x: 0, y: 0)
        let expected = RGB(1, 0, 0).over(.white, alpha: theme.layerOpacity)
        let threeQuarters = theme.backgroundColor(x: 0.75, y: 0.75)
        let blue = RGB(0, 0, 1).over(.white, alpha: theme.layerOpacity)
        // Halfway in OKLab is a purple, not sRGB's dark (127, 0, 127).
        let middle = OKLab.mix(OKLab(RGB(1, 0, 0)), OKLab(RGB(0, 0, 1)), 0.5).rgb
        let srgbMiddle = RGB(0.5, 0, 0.5)
        expect(theme.layerOpacity <= alpha + 0.0001 && theme.layerOpacity > 0.2 && abs(topLeft.r - expected.r) < 0.01
               && abs(threeQuarters.b - blue.b) < 0.01 && abs(threeQuarters.r - blue.r) < 0.01 && middle.luminance > srgbMiddle.luminance,
               "colors blend in OKLab along the diagonal, the second reached at three quarters, at most 0.2 + 0.55 × intensity (\(String(format: "%.3f", theme.layerOpacity)))")
        let mint = SpaceTheme(ThemeData(colors: ["#53CA9F"], appearance: .light), systemDark: false)
        expect(abs(mint.layerOpacity - alpha) < 0.0001 && mint.backgroundColor(x: 0.5, y: 0.5).hex == "#90DDC1",
               "Arc's mint at the default intensity is Arc's #90DDC1 (\(mint.backgroundColor(x: 0.5, y: 0.5).hex))")
        let navy = SpaceTheme(ThemeData(colors: ["#101850"], intensity: 1, appearance: .light), systemDark: false)
        let navyGround = navy.backgroundColor(x: 0.5, y: 0.5)
        expect(navy.layerOpacity < alpha && RGB(0.1, 0.1, 0.1).contrast(with: navyGround) >= 4.5,
               "a dark color in a light theme washes out until the text reads (\(String(format: "%.2f", navy.layerOpacity)))")
        expect(SpaceTheme.rendersDark(ThemeData(colors: ["#F0EAE5"]), systemDark: true) == false
               && SpaceTheme.rendersDark(ThemeData(colors: ["#101850"]), systemDark: false) == true
               && SpaceTheme.rendersDark(ThemeData(colors: ["#7B6CF6"]), systemDark: true) == true
               && SpaceTheme.rendersDark(ThemeData(colors: ["#7B6CF6"]), systemDark: false) == false,
               "auto follows the Mac, but very light colors stay light and very dark ones dark")
        let dark = SpaceTheme(ThemeData(colors: ["#2F6AF0", "#13B5B0"], appearance: .dark), systemDark: false)
        expect(dark.isDark && dark.underlay == .black && dark.surfaceRGB.luminance < 0.1 && theme.surfaceRGB.luminance > 0.9
               && RGB.white.contrast(with: dark.accentRGB) >= 4.5 && RGB.white.contrast(with: theme.accentRGB) >= 4.5,
               "one theme gives the command bar's card, the accent and the toasts their colors")

        // Live in the window: a new theme colors it at once, grain included,
        // and an inactive window dims the grain.
        let space = browser.state.space
        let before = space.theme
        space.theme = ThemeData(colors: ["#E59EBA", "#7EB6D5"], intensity: 0.6, grain: 0.6, appearance: .light)
        after(0.2) {
            let shown = self.browser.background.theme
            self.expect(shown?.data == space.theme && abs(self.browser.background.colorOpacity - (shown?.layerOpacity ?? -1)) < 0.0001
                        && self.browser.grainAmount == 0.6,
                        "changing the theme colors the window at once, with its grain")
            if let shown {
                let probe = SpaceBackgroundView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
                probe.apply(shown, active: false)
                self.expect(abs(probe.grainAmount - 0.15) < 0.0001 && probe.underlayOpacity == 1,
                            "an inactive window dims the grain to a quarter and lets no desktop through")
                probe.apply(shown, active: true, glassTint: 0.4)
                self.expect(probe.underlayOpacity == 0 && probe.colorOpacity == 0.4,
                            "in the glass look the colors lie over the glass at the tint")
            }
            self.renderThemeEditor()
            space.theme = before
            after(0.2) { done() }
        }
    }

    private func renderThemeEditor() {
        let space = browser.state.space
        let host = NSHostingView(rootView: SpaceEditor(browser: browser, space: space))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.height > 300, "the space editor has the theme picker (\(Int(host.fittingSize.height)) pt)")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: AppPaths.support.appendingPathComponent("theme-editor.png"))
        }
        // The disc: the color under a handle is the handle's.
        let hex = ColorDisc.color(angle: 210, radius: 0.6).hex
        let position = ColorDisc.position(of: hex)
        expect(abs(position.angle - 210) < 2 && abs(position.radius - 0.6) < 0.02 && ColorDisc.color(angle: position.angle, radius: position.radius).hex == hex,
               "a color picked on the disc sits where it was picked")
    }

    // MARK: Sidebar on the right

    private func sidebarRightTest(then done: @escaping () -> Void) {
        guard let window = browser.window, let root = window.contentView else { return done() }
        let settings = library.settings
        library.settings.sidebarOnRight = true
        browser.sidebarSideChanged()
        root.layoutSubtreeIfNeeded()
        let bounds = root.bounds, width = browser.sidebarWidth, inset = BrowserWindowController.contentInset
        let layout = browser.sidebarLayout
        let content = browser.contentRect
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
        expect(close(layout.sidebar?.maxX ?? 0, bounds.width) && close(layout.sidebar?.width ?? 0, width),
               "with the sidebar on the right it lies along the window's right edge (\(layout.sidebar ?? .zero))")
        expect(close(content.minX, inset) && close(content.maxX, bounds.width - width) && content.maxY <= bounds.height - 30 + 0.5,
               "the page is inset from the left edge, beside the sidebar and below the window buttons (\(content))")
        let handle = layout.handle ?? .zero
        expect(close(handle.minX, bounds.width - width) && handle.width > 0, "the sidebar is resized from its inner, left edge (\(handle))")
        // Dragging the inner edge to the left widens it, as the pointer goes.
        let grip = NSPoint(x: handle.midX, y: handle.midY)
        if let divider = root.hitTest(grip) as? SplitDividerView,
           let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: grip.x - 40, y: grip.y), modifierFlags: [],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1) {
            divider.mouseDragged(with: drag)
            expect(close(browser.sidebarWidth, min(440, width + 40)),
                   "dragging the inner edge 40 pt to the left widens it by 40 pt (\(Int(width)) → \(Int(browser.sidebarWidth)))")
        } else {
            expect(false, "the sidebar's inner edge takes the drag")
        }
        browser.resizeSidebar(to: width - 4)
        expect(window.standardWindowButton(.closeButton)?.isHidden == false
               && window.standardWindowButton(.miniaturizeButton)?.isHidden == false
               && window.standardWindowButton(.zoomButton)?.isHidden == false,
               "the system window buttons are the window's own")
        // The library button, where downloads fly, is in the sidebar.
        after(0.3) {
            let library = self.browser.libraryButtonCenter
            self.expect(library.x > bounds.width - width && library.x < bounds.width,
                        "a download flies into the library button on the right (\(library))")
            self.sidebarRightPreview(bounds: bounds, width: width) {
                self.sidebarRightHidden(bounds: bounds) {
                    self.library.settings = settings
                    self.browser.sidebarSideChanged()
                    root.layoutSubtreeIfNeeded()
                    self.expect(self.browser.sidebarLayout.sidebar?.minX == 0 && close(self.browser.contentRect.minX, width),
                                "back on the left, all of it goes back")
                    done()
                }
            }
        }
    }

    private func sidebarRightPreview(bounds: NSRect, width: CGFloat, then done: @escaping () -> Void) {
        let preview = browser.tabPreview
        preview.delay = 0
        let sidebar = browser.state.sidebarFrame
        guard let target = browser.orderedTabs.first(where: { $0 !== browser.state.activeItem }),
              !sidebar.isEmpty, let parent = browser.window else {
            expect(false, "a tab to preview with the sidebar on the right")
            return done()
        }
        let row = CGRect(x: sidebar.minX + 8, y: sidebar.minY + 220, width: sidebar.width - 16, height: 34)
        preview.hover(target, row: row, inside: true)
        after(0.6) {
            let window = NSApp.windows.first { $0 is TabPreviewWindow && $0.isVisible }
            let right = parent.frame.maxX - width - 4
            self.expect(preview.isShown && abs((window?.frame.maxX ?? 0) - right) < 2,
                        "the tab preview opens to the left of a sidebar on the right (\(Int(window?.frame.maxX ?? 0)) vs \(Int(right)))")
            preview.hide()
            preview.delay = 0.6
            done()
        }
    }

    private func sidebarRightHidden(bounds: NSRect, then done: @escaping () -> Void) {
        browser.toggleSidebar()
        let edge = browser.sidebarLayout.edge ?? .zero
        expect(edge.maxX == bounds.width && edge.width > 0 && browser.contentRect.minX == BrowserWindowController.contentInset,
               "hidden, the window's right edge brings the sidebar back (\(edge))")
        let floating = browser.floatingSidebar
        floating.mouseLocation = { NSPoint(x: -10_000, y: -10_000) }
        floating.pressedMouseButtons = { 0 }
        floating.show()
        after(0.25) {
            let frame = floating.frame ?? .zero
            let parent = self.browser.window?.frame ?? .zero
            self.expect(floating.isShown && abs(frame.maxX - (parent.maxX - FloatingSidebar.margin)) < 1,
                        "and it floats over the page from the right (\(frame))")
            floating.hide()
            floating.mouseLocation = { NSEvent.mouseLocation }
            floating.pressedMouseButtons = { NSEvent.pressedMouseButtons }
            self.browser.toggleSidebar()
            done()
        }
    }
}
