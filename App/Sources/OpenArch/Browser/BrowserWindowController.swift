import AppKit
import OpenArchCore
import OpenArchLocalization
import SwiftUI

/// One browser window: the sidebar on the left (or on the right, Settings ›
/// Allgemein › Sidebar) and, beside it, the content area where the active
/// tab's Chrome pane (or the panes of a split view) sit as child windows.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, OACPaneDelegate {
    let library: Library
    let history: History
    let state: BrowserState
    /// A private window: its own in-memory profile, no history, and tabs
    /// that are gone once it closes.
    let isPrivate: Bool
    private var privateProfile: OACProfile?
    /// A window of its own, for tabs dragged out of the sidebar: the space
    /// it came from (its profile and color), with tabs but without
    /// favorites, pinned tabs or other spaces. Its tabs go to the archive
    /// once it closes.
    let homeSpace: Space?
    var isSeparate: Bool { homeSpace != nil }
    /// A private or separate window: a space of its own, not one of the
    /// library's, and only tabs under the line.
    var isStandalone: Bool { isPrivate || isSeparate }

    /// Tabs whose panes are currently shown, left to right.
    private(set) var visibleTabs: [Item] = []
    private var itemsByPane: [ObjectIdentifier: Item] = [:]
    private let rootView = BrowserRootView()
    /// The space's theme behind the sidebar and around the pages: the
    /// window's blur, white or black, the colors and the grain.
    let background = SpaceBackgroundView()
    /// macOS 26 in the glass look (Settings › Allgemein): the whole window is
    /// one sheet of Liquid Glass, the sidebar and the window buttons directly
    /// on it and the page floating above.
    private var windowGlass: NSView?
    /// How much grain shows (self-test).
    var grainAmount: Double { background.grainAmount }
    private var sidebarHost: NSHostingView<SidebarView>!
    private var emptyHost: NSHostingView<EmptyContentView>!
    private var agentHost: NSHostingView<AgentContentView>!
    /// The chat beside the page (⌘E, see PageChat).
    private(set) var pageChatHost: NSHostingView<PageChatContainer>!
    private var loadingLine: NSHostingView<PageLoadingLine>!
    private var dividers: [SplitDividerView] = []
    private let focusRing = FocusRingView()
    private let sidebarHandle = SplitDividerView()
    private let sidebarEdge = SidebarEdgeView()
    private(set) lazy var floatingSidebar = FloatingSidebar(browser: self)
    private(set) lazy var peek = PeekController(browser: self)
    private(set) lazy var manageSpaces = ManageSpacesController(browser: self)
    private(set) lazy var commandBar = CommandBarController(browser: self)
    private(set) lazy var tabSwitcher = TabSwitcher(browser: self)
    private(set) lazy var tabPreview = TabPreview(browser: self)
    private(set) var sidebarSwipe: SidebarSwipe?
    private var archiveTimer: Timer?
    private var occlusionCheck: DispatchWorkItem?
    /// Whether the window was on screen at the last occlusion change.
    private var isOnScreen = true

    static let contentInset: CGFloat = 8
    /// A titled window's corners, which the glass has to follow.
    static let windowCornerRadius: CGFloat = 16
    static let splitGap: CGFloat = 8

    init(library: Library, history: History, isPrivate: Bool = false, separateFrom home: Space? = nil,
         cascadingFrom other: NSWindow? = nil) {
        self.library = library
        self.history = history
        self.isPrivate = isPrivate
        homeSpace = isPrivate ? nil : home
        if isPrivate {
            // Not part of the library: never saved, never in the space bar.
            state = BrowserState(space: Space(name: "Privates Fenster", icon: "eyeglasses", colorHex: "#2C2C30", profileID: "",
                                              theme: ThemeData(colors: ["#2C2C30"], appearance: .dark)))
            privateProfile = OACProfile.makePrivate()
        } else if let home {
            // Not part of the library either, but on the home space's profile.
            state = BrowserState(space: Space(name: home.name, icon: home.icon, colorHex: home.colorHex, profileID: home.profileID,
                                              theme: home.theme))
        } else {
            state = BrowserState(space: library.space(id: library.selectedSpaceID) ?? library.spaces[0])
        }

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 720, height: 480)
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        rootView.controller = self
        window.contentView = rootView
        state.systemDark = SpaceTheme.systemIsDark
        rootView.addSubview(background)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let sheet = NSGlassEffectView()
            sheet.cornerRadius = Self.windowCornerRadius
            // Regular glass: the desktop shows frosted and the sidebar stays
            // readable; clear glass left it sharp behind the text.
            sheet.style = .regular
            windowGlass = sheet
            background.setGlassSheet(sheet)
        }
        #endif
        sidebarHost = NSHostingView(rootView: SidebarView(browser: self))
        sidebarHost.sizingOptions = []
        emptyHost = NSHostingView(rootView: EmptyContentView(browser: self))
        emptyHost.sizingOptions = []
        rootView.addSubview(emptyHost)
        agentHost = NSHostingView(rootView: AgentContentView(browser: self))
        agentHost.sizingOptions = []
        agentHost.safeAreaRegions = []  // its top runs under the title bar, like a page
        rootView.addSubview(agentHost)
        pageChatHost = NSHostingView(rootView: PageChatContainer(browser: self))
        pageChatHost.sizingOptions = []
        pageChatHost.safeAreaRegions = []
        pageChatHost.isHidden = true
        rootView.addSubview(pageChatHost)
        rootView.addSubview(sidebarHost)
        rootView.addSubview(focusRing)
        loadingLine = NSHostingView(rootView: PageLoadingLine(browser: self))
        loadingLine.sizingOptions = []
        loadingLine.safeAreaRegions = []  // it sits under the title bar
        rootView.addSubview(loadingLine)
        // The handle's middle is 4 pt inside the sidebar's edge; on the
        // right, the sidebar reaches from there to the window's edge.
        sidebarHandle.onDrag = { [weak self] _, x in
            guard let self else { return }
            self.resizeSidebar(to: self.sidebarOnRight ? self.rootView.bounds.width - x - 4 : x + 4)
        }
        rootView.addSubview(sidebarHandle)
        sidebarEdge.onEnter = { [weak self] in MainActor.assumeIsolated { self?.floatingSidebar.show() } }
        rootView.addSubview(sidebarEdge)

        if let other {
            // Further windows cascade from the current one.
            window.setFrame(other.frame.offsetBy(dx: 30, dy: -30), display: false)
        } else {
            window.setFrameAutosaveName(AppPaths.isSelfTest ? "OpenArchSelfTestWindow" : "OpenArchBrowserWindow")
            if AppPaths.isSelfTest || !window.setFrameUsingName("OpenArchBrowserWindow") {
                window.center()
            }
        }
        applyTheme()
        observeChanges()
        closeWhenEmpty()
        sidebarSwipe = SidebarSwipe(browser: self)
        // Agent chats follow the Mac's light or dark mode, like pages do.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            // AppKit's own appearance changes a moment after the notification.
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated {
                    // Auto themes follow the Mac's light or dark mode.
                    self?.state.systemDark = SpaceTheme.systemIsDark
                    self?.applyTheme()
                }
            }
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTheme() }
            }
        }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.archiveInactiveTabs()
                self?.sleepInactiveTabs()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Re-attaches panes that were detached while the window was hidden.
        layoutContent()
    }

    func restoreSession() {
        archiveInactiveTabs()
        if let id = state.space.activeItemID, let item = library.item(id: id) {
            select(item)
        } else {
            layoutContent()
        }
    }

    private func observeChanges() {
        withObservationTracking {
            _ = state.space.theme
            _ = state.space.id
            _ = homeSpace?.theme
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A separate window keeps its home space's theme.
                    if let self, let home = self.homeSpace, self.state.space.theme != home.theme {
                        self.state.space.theme = home.theme
                    }
                    self?.applyTheme()
                    self?.observeChanges()
                }
            }
        }
    }

    /// The window in front: OpenArch is active and this is its main window.
    /// (The self-test and its screenshots always look like that.)
    private var isFrontmost: Bool {
        AppPaths.isSelfTest || (NSApp.isActive && window?.isMainWindow == true)
    }

    /// The space's theme, resolved for the Mac's light or dark mode: every
    /// color of the sidebar, the command bar, menus and toasts comes from it.
    var theme: SpaceTheme {
        SpaceTheme.resolve(state.space.theme, systemDark: state.systemDark)
    }

    func applyTheme() {
        let theme = self.theme
        let glassy = library.settings.glass
        // macOS 26: Liquid Glass with the colors over it; before, frosted
        // glass and the colors over that.
        windowGlass?.isHidden = !glassy
        background.apply(theme, active: isFrontmost, glassTint: glassy ? library.settings.glassTint : nil)
        // The desktop shows through: in the glass look, and faintly behind
        // the theme while the window is in front.
        window?.isOpaque = false
        window?.backgroundColor = .clear
        if isFrontmost, !isStandalone, !AppPaths.isSelfTest {
            AppIcons.spaceDidChange(state.space.colorHex)
        }
        window?.appearance = theme.appearance
        focusRing.color = theme.focusRing
        // An agent chat is light or dark like the pages, not like the space.
        agentHost?.appearance = NSApp.effectiveAppearance
        pageChatHost?.appearance = NSApp.effectiveAppearance
        floatingSidebar.applyTheme()
    }

    // MARK: Layout

    /// The sidebar's width; the library needs a bit more room.
    var sidebarWidth: CGFloat {
        let width = CGFloat(library.settings.sidebarWidth)
        return state.libraryVisible ? max(width, 400) : width
    }

    /// Where panes go, in window coordinates: the content area, less the
    /// chat beside the page while it is open.
    var contentRect: NSRect {
        pageArea(in: contentAreaRect)
    }

    /// The sidebar on the window's right (Settings › Allgemein › Sidebar).
    var sidebarOnRight: Bool { library.settings.sidebarOnRight }

    /// Room at the start of the sidebar's top bar for the window buttons,
    /// which stay at the window's top left: none with the sidebar on the
    /// right, or floating below them.
    func sidebarButtonRoom(floating: Bool) -> CGFloat {
        floating || sidebarOnRight ? 4 : 72
    }

    var sidebarSymbol: String { sidebarOnRight ? "sidebar.right" : "sidebar.left" }

    /// |rect| laid out for a sidebar on the left, where it goes with the
    /// sidebar on the right: mirrored across the window.
    func mirrored(_ rect: NSRect) -> NSRect {
        guard sidebarOnRight else { return rect }
        return NSRect(x: rootView.bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    /// The area beside the sidebar, in window coordinates.
    var contentAreaRect: NSRect {
        let bounds = rootView.bounds
        let inset = Self.contentInset
        var rect = bounds
        if state.sidebarVisible {
            rect.origin.x = sidebarWidth
            rect.size.width = bounds.width - sidebarWidth - inset
            rect.origin.y = inset
            rect.size.height = bounds.height - 2 * inset
            if sidebarOnRight {
                // The window buttons stay at the top left, now over the page's
                // side: room for them above it, as with the sidebar hidden.
                let top: CGFloat = window?.styleMask.contains(.fullScreen) == true ? inset : 30
                rect.size.height = bounds.height - inset - top
                rect = mirrored(rect)
            }
        } else {
            // Leave room for the window buttons above the content.
            let top: CGFloat = window?.styleMask.contains(.fullScreen) == true ? inset : 30
            rect = NSRect(x: inset, y: inset, width: bounds.width - 2 * inset, height: bounds.height - inset - top)
        }
        return rect
    }

    /// The inner edge of a sidebar row (its right edge, or its left with the
    /// sidebar on the right), at its middle, in window coordinates: where a
    /// tab's preview goes. |row| is in the sidebar's SwiftUI coordinates,
    /// like state.sidebarFrame.
    func sidebarAnchor(forRow row: CGRect) -> NSPoint? {
        let sidebar = state.sidebarFrame
        guard state.sidebarVisible, !row.isEmpty, !sidebar.isEmpty else { return nil }
        // Measured from the sidebar's bottom, as for the library button.
        let point = NSPoint(x: sidebarOnRight ? 0 : sidebarWidth, y: sidebarHost.bounds.height - (sidebar.maxY - row.midY))
        return sidebarHost.convert(point, to: nil)
    }

    /// The library button in window coordinates (downloads fly into it); the
    /// bottom corner on the sidebar's side while the sidebar is hidden.
    var libraryButtonCenter: NSPoint {
        let button = state.libraryButtonFrame, sidebar = state.sidebarFrame
        guard state.sidebarVisible, !button.isEmpty, !sidebar.isEmpty else {
            return NSPoint(x: sidebarOnRight ? rootView.bounds.width - 24 : 24, y: 22)
        }
        // Measured from the sidebar's bottom left corner, which is the
        // hosting view's (flipped) bottom left corner.
        let point = NSPoint(x: button.midX - sidebar.minX, y: sidebarHost.bounds.height - (sidebar.maxY - button.midY))
        return sidebarHost.convert(point, to: nil)
    }

    func layoutContent() {
        guard let window else { return }
        let bounds = rootView.bounds
        let corner = window.styleMask.contains(.fullScreen) ? 0 : Self.windowCornerRadius
        background.frame = bounds
        background.cornerRadius = corner
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let sheet = windowGlass as? NSGlassEffectView {
            sheet.cornerRadius = corner
        }
        #endif
        sidebarHost.isHidden = !state.sidebarVisible
        sidebarHost.frame = mirrored(NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height))
        sidebarHandle.isHidden = !state.sidebarVisible
        // All of it on the sidebar's side of the page: the page's window lies
        // above this one, so a part under it never got the mouse. (On the
        // left it stops below the window buttons.)
        sidebarHandle.frame = mirrored(NSRect(x: sidebarWidth - 8, y: 0, width: 8,
                                              height: max(0, bounds.height - (sidebarOnRight ? 0 : 40))))
        // The window's edge on the sidebar's side brings it back while hidden.
        sidebarEdge.isHidden = state.sidebarVisible
        sidebarEdge.frame = mirrored(NSRect(x: 0, y: 0, width: Self.contentInset - 2, height: max(0, bounds.height - 30)))
        let content = contentRect
        let showsAgent = state.activeItem?.kind == .agent
        emptyHost.frame = content
        emptyHost.isHidden = !visibleTabs.isEmpty || showsAgent
        agentHost.frame = content
        agentHost.isHidden = !showsAgent

        let frames = paneFrames(in: content)
        for (tab, frame) in zip(visibleTabs, frames) {
            guard let pane = tab.pane else { continue }
            if pane.isVisible {
                pane.setFrame(frame)
            } else {
                pane.show(in: window, frame: frame)
            }
        }
        layoutDividers(frames: frames, content: content)
        layoutPageChat()
        layoutFocusRing(frames: frames)
        layoutLoadingLine(frames: frames)
        floatingSidebar.layout()
        peek.layout()
        manageSpaces.layout()
    }

    func paneFrames(in rect: NSRect) -> [NSRect] {
        guard visibleTabs.count > 1, let split = visibleTabs.first?.split else {
            return visibleTabs.isEmpty ? [] : [rect]
        }
        let count = visibleTabs.count
        var fractions = split.splitFractions
        if fractions.count != count || fractions.contains(where: { $0 <= 0 }) {
            fractions = Array(repeating: 1.0 / Double(count), count: count)
        }
        // Side by side from the left, or stacked from the top.
        let stacked = split.splitStacked
        let length = stacked ? rect.height : rect.width
        let available = length - Self.splitGap * CGFloat(count - 1)
        var frames: [NSRect] = []
        var offset: CGFloat = 0
        for (index, fraction) in fractions.enumerated() {
            let size = index == count - 1 ? length - offset : (available * fraction).rounded()
            frames.append(stacked
                ? NSRect(x: rect.minX, y: rect.maxY - offset - size, width: rect.width, height: size)
                : NSRect(x: rect.minX + offset, y: rect.minY, width: size, height: rect.height))
            offset += size + Self.splitGap
        }
        return frames
    }

    private func layoutDividers(frames: [NSRect], content: NSRect) {
        let needed = max(0, frames.count - 1)
        while dividers.count < needed {
            let divider = SplitDividerView()
            divider.onDrag = { [weak self] index, x in self?.dragDivider(index, to: x) }
            rootView.addSubview(divider)
            dividers.append(divider)
        }
        while dividers.count > needed {
            dividers.removeLast().removeFromSuperview()
        }
        let stacked = visibleTabs.first?.split?.splitStacked == true
        for (index, divider) in dividers.enumerated() {
            divider.index = index
            divider.stacked = stacked
            divider.frame = stacked
                ? NSRect(x: content.minX, y: frames[index].minY - Self.splitGap, width: content.width, height: Self.splitGap)
                : NSRect(x: frames[index].maxX, y: content.minY, width: Self.splitGap, height: content.height)
        }
    }

    private func layoutFocusRing(frames: [NSRect]) {
        guard frames.count > 1, let active = state.activeItem,
              let index = visibleTabs.firstIndex(where: { $0 === active }) else {
            focusRing.isHidden = true
            return
        }
        focusRing.isHidden = false
        focusRing.frame = frames[index].insetBy(dx: -3, dy: -3)
    }

    /// A line just above the page in front shows how far it has loaded. Its
    /// view is the whole strip above the page (SwiftUI draws nothing in one
    /// only 2 points high); it draws itself when no address field shows it.
    private func layoutLoadingLine(frames: [NSRect]) {
        let index = state.activeItem.flatMap { active in visibleTabs.firstIndex { $0 === active } }
        guard let index, frames.indices.contains(index) else {
            loadingLine.frame = .zero
            return
        }
        let frame = frames[index]
        loadingLine.frame = NSRect(x: frame.minX + 10, y: frame.maxY, width: max(0, frame.width - 20), height: Self.contentInset)
    }

    /// Whether the sidebar's address field shows the page's loading; the line
    /// above the page does otherwise.
    var addressFieldShowsLoading: Bool {
        state.sidebarVisible && library.settings.showSidebarAddress
    }

    /// |position| is where the divider goes: an x side by side, a y stacked.
    private func dragDivider(_ index: Int, to position: CGFloat) {
        guard let split = visibleTabs.first?.split, visibleTabs.count > index + 1 else { return }
        let content = contentRect
        let count = visibleTabs.count
        var frames = paneFrames(in: content)
        if split.splitStacked {
            let available = content.height - Self.splitGap * CGFloat(count - 1)
            let top = frames[index], bottom = frames[index + 1]
            let total = top.height + bottom.height
            let newTop = max(160, min(top.maxY - position, total - 160))
            frames[index].size.height = newTop
            frames[index + 1].size.height = total - newTop
            split.splitFractions = frames.map { Double($0.height / available) }
        } else {
            let available = content.width - Self.splitGap * CGFloat(count - 1)
            let minWidth: CGFloat = 240
            let left = frames[index]
            let right = frames[index + 1]
            let newLeftWidth = max(minWidth, min(position - left.minX, left.width + right.width - minWidth))
            frames[index].size.width = newLeftWidth
            frames[index + 1].size.width = left.width + right.width - newLeftWidth
            split.splitFractions = frames.map { Double($0.width / available) }
        }
        layoutContent()
        library.setNeedsSave()
    }

    /// Dragging the sidebar's inner edge to make it |x| wide. Narrow enough
    /// (far to the left, or to the right with the sidebar there), it
    /// collapses like Arc's; dragging back out (still holding) opens it again.
    func resizeSidebar(to x: CGFloat) {
        if x < 150 {
            if state.sidebarVisible {
                state.sidebarVisible = false
                layoutContent()
            }
            return
        }
        if !state.sidebarVisible {
            guard x > 200 else { return }
            state.sidebarVisible = true
        }
        library.settings.sidebarWidth = Double(max(200, min(440, (x + 4).rounded())))
        layoutContent()
        library.setNeedsSave()
    }

    /// Lays out now and once more after AppKit has settled (animated
    /// resizes, screen changes), so the pane windows never drift.
    private func relayoutSoon() {
        layoutContent()
        for delay in [0.05, 0.3] {
            after(delay) { [weak self] in self?.layoutContent() }
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        relayoutSoon()
    }

    func windowDidMove(_ notification: Notification) {
        relayoutSoon()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        relayoutSoon()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        relayoutSoon()
    }

    // Child windows do not survive the full screen animation well: take the
    // panes away during it and put them back afterwards.
    func windowWillEnterFullScreen(_ notification: Notification) {
        hidePanesForTransition()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        relayoutSoon()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        hidePanesForTransition()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        relayoutSoon()
    }

    func windowWillMiniaturize(_ notification: Notification) {
        windowVisibilityChanged(onScreen: false)
        hidePanesForTransition()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        relayoutSoon()
        windowVisibilityChanged(onScreen: true)
    }

    /// Covered by another window, on another desktop or hidden: a call or
    /// video in the window floats once that lasts a moment (a window passing
    /// over it does not count). The self-test's window always sits behind
    /// others, so there the test says when.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard !AppPaths.isSelfTest, let window, !window.isMiniaturized else { return }
        let onScreen = window.occlusionState.contains(.visible)
        occlusionCheck?.cancel()
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.occlusionState.contains(.visible) == onScreen,
                      onScreen != self.isOnScreen else { return }
                self.isOnScreen = onScreen
                self.windowVisibilityChanged(onScreen: onScreen)
            }
        }
        occlusionCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + (onScreen ? 0.05 : 0.6), execute: check)
    }

    private func hidePanesForTransition() {
        commandBar.hide()
        floatingSidebar.hide()
        peek.close()
        for tab in visibleTabs {
            tab.pane?.hide()
        }
    }

    /// The tabs shown side by side right now (one, or the sides of a split).
    var shownTabs: [Item] {
        visibleTabs
    }

    /// Where the Liquid Glass is, in window coordinates, if it is shown
    /// (self-test).
    var windowGlassFrame: NSRect? {
        windowGlass.flatMap { $0.isHidden ? nil : $0.frame }
    }

    /// Where the sidebar, its resize handle and the strip that brings it
    /// back are, in window coordinates, if shown (self-test).
    var sidebarLayout: (sidebar: NSRect?, handle: NSRect?, edge: NSRect?) {
        (sidebarHost.isHidden ? nil : sidebarHost.frame, sidebarHandle.isHidden ? nil : sidebarHandle.frame,
         sidebarEdge.isHidden ? nil : sidebarEdge.frame)
    }

    /// Where the loading line above the page is, in window coordinates, if
    /// it is shown (self-test).
    var loadingLineFrame: NSRect? {
        addressFieldShowsLoading || loadingLine.frame.isEmpty ? nil : loadingLine.frame
    }

    /// Where each visible pane should be, in screen coordinates (self-test).
    var expectedPaneFrames: [(Item, NSRect)] {
        guard let window else { return [] }
        return zip(visibleTabs, paneFrames(in: contentRect)).map { ($0, window.convertToScreen($1)) }
    }

    func toggleLibrary() {
        state.libraryVisible.toggle()
        state.downloadStack.dismiss()
        if state.libraryVisible {
            state.sidebarVisible = true
            state.agentsVisible = false
        }
        layoutContent()
    }

    /// The red button hides the last normal window; tabs keep running and
    /// the Dock icon brings it back. Other windows close for good.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the panes first: ordering out the window would detach them in
        // a way they cannot simply be ordered back from.
        hidePanesForTransition()
        library.save()
        if let app = NSApp.delegate as? AppDelegate, app.browserMayClose(self) {
            closeForGood(handingTabsTo: app.browsers.first { $0 !== self && !$0.isStandalone })
            return true
        }
        sender.orderOut(nil)
        return false
    }

    /// A private window's tabs end with it, a separate window's go to the
    /// archive; a normal window's tabs stay open and |heir| takes over their
    /// pages.
    private func closeForGood(handingTabsTo heir: BrowserWindowController?) {
        archiveTimer?.invalidate()
        closesWhenEmpty = false
        commandBar.hide()
        var tabs: [ArchivedTab] = []
        if isSeparate {
            let count = state.space.today.allTabs.count
            archiveTabs()
            // Archived top to bottom, each in front of the one before.
            tabs = Array(library.archive.prefix(count).reversed())
        }
        // ⌘⇧T can bring the window back (not a private one).
        if !isPrivate, let frame = window?.frame {
            ClosedWindows.shared.remember(.init(date: Date(), frame: frame, spaceID: homeSpace?.id ?? state.space.id,
                                                isSeparate: isSeparate, tabs: tabs))
        }
        if isStandalone {
            for tab in state.space.today.allTabs { unload(tab) }
        } else if let heir {
            for item in itemsByPane.values {
                guard let pane = item.pane else { continue }
                pane.hide()
                pane.delegate = heir
                heir.registerPane(pane, for: item)
            }
        }
        itemsByPane = [:]
        visibleTabs = []
        (NSApp.delegate as? AppDelegate)?.browserDidClose(self)
    }

    /// A separate window's tabs are not in the library: closing the window
    /// (or quitting) puts them in the archive, for their home space.
    func archiveTabs() {
        guard let homeSpace else { return }
        // Top to bottom: ⌘⇧T brings the bottom one back first and each next
        // one above it, so they end up in their order again.
        for tab in state.space.today.allTabs {
            library.archive(tab, from: homeSpace)
        }
        library.setNeedsSave()
    }

    /// Watches a separate window's tabs: once the last one is gone (closed,
    /// dragged out or moved to a space) the window closes too.
    private var closesWhenEmpty = false

    private func closeWhenEmpty() {
        guard isSeparate else { return }
        closesWhenEmpty = true
        withObservationTracking {
            _ = state.space.today.items
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.closesWhenEmpty else { return }
                    if self.state.space.today.items.isEmpty {
                        self.window?.performClose(nil)
                    } else {
                        self.closeWhenEmpty()
                    }
                }
            }
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.browserBecameActive(self)
        applyTheme()
    }

    func windowDidResignMain(_ notification: Notification) {
        applyTheme()
    }

    // MARK: Selection

    /// Shows |item|: a tab, the focused/first tab of a split, or an agent
    /// chat. Folders toggle open and closed.
    func select(_ item: Item, focus: Bool = true) {
        switch item.kind {
        case .folder:
            item.isExpanded.toggle()
            library.setNeedsSave()
            return
        case .split:
            let target = item.children.max { $0.lastActiveAt < $1.lastActiveAt } ?? item.children.first
            if let target {
                select(target, focus: focus)
            }
            return
        case .tab, .agent:
            break
        }
        if peek.isOpen {
            peek.close()
        }
        // From the Agents list, a chat opens where you are, whichever space keeps it.
        if !(item.kind == .agent && state.agentsVisible), let space = library.space(containing: item), space !== state.space {
            switchSpace(to: space, restoring: false)
        }
        item.lastActiveAt = Date()
        item.isUnread = false
        state.activeItem = item
        state.space.activeItemID = item.id

        // An agent chat shows instead of any page.
        let tabs = item.kind == .agent ? [] : (item.split?.children ?? [item])
        for old in visibleTabs where !tabs.contains(where: { $0 === old }) {
            TabSnapshots.capture(old)
            pictureInPictureOnLeaving(old)
            old.pane?.hide()
        }
        for tab in tabs {
            claim(tab)
        }
        tabs.forEach(pictureInPictureOnReturning)
        visibleTabs = tabs
        for tab in tabs {
            ensurePane(for: tab)
        }
        if item.kind == .agent {
            agentSession(for: item).isUnread = false
        }
        layoutContent()
        if focus {
            if item.kind == .agent {
                focusAgentChat(item)
            } else {
                item.pane?.focus()
            }
        }
        library.setNeedsSave()
    }

    /// A click in the sidebar. With ⌘ the tab, or a folder's tabs, load in
    /// the background, so their pages and titles are there when you come
    /// to them; without, it shows the tab (or opens and closes the folder).
    /// ⇧ and ⌘⇧ (and ⌘ while rows are selected) select rows instead.
    func click(_ item: Item, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if selectionClick(item, modifiers: modifiers) { return }
        clearSelection()
        state.selectionAnchorID = (item.split ?? item).id
        if modifiers.contains(.command) {
            loadInBackground(item)
        } else {
            select(item)
        }
    }

    func loadInBackground(_ item: Item) {
        let tabs = item.kind == .tab ? [item] : item.descendants.filter { $0.kind == .tab }
        for tab in tabs where tab.pane == nil {
            ensurePane(for: tab)
            tab.pane?.load()
        }
    }

    /// Clears the content area (no tab selected).
    func showNothing() {
        for tab in visibleTabs {
            tab.pane?.hide()
        }
        visibleTabs = []
        state.activeItem = nil
        state.space.activeItemID = nil
        layoutContent()
    }

    /// A tab shows in one window at a time: one shown elsewhere moves here,
    /// and the other window shows nothing in its place.
    private func claim(_ tab: Item) {
        guard let pane = tab.pane, let owner = pane.delegate as? BrowserWindowController, owner !== self else { return }
        owner.release(tab)
        pane.delegate = self
        itemsByPane[ObjectIdentifier(pane)] = tab
    }

    /// Gives |tab| up to another window.
    func release(_ tab: Item) {
        guard let pane = tab.pane else { return }
        itemsByPane[ObjectIdentifier(pane)] = nil
        guard visibleTabs.contains(where: { $0 === tab }) else { return }
        pane.hide()
        if state.activeItem === tab || visibleTabs.count == 1 {
            showNothing()
        } else {
            visibleTabs.removeAll { $0 === tab }
            layoutContent()
        }
    }

    private func ensurePane(for tab: Item) {
        guard tab.pane == nil else { return }
        let profile = privateProfile ?? library.profile(for: tab, in: state.space).chromium
        let url = tab.currentURL.isEmpty ? "about:blank" : tab.currentURL
        let pane = ProtectedMedia.makePage(url: url, profile: profile)
        configure(pane)
        tab.pane = pane
        tab.isAsleep = false
        tab.loadedAt = Date()
        itemsByPane[ObjectIdentifier(pane)] = tab
        if pane.engine == .webKit {
            // Once the page has been laid out.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tellAboutWebKit(pane) } }
        }
    }

    private func configure(_ page: any OACPage) {
        page.delegate = self
        page.cornerRadius = 8
        page.activatesOnShow = !AppPaths.isSelfTest
        page.toolbarVisible = library.settings.showChromeToolbar
        page.offersAskAboutSelection = !isPrivate
    }

    /// Shows |tab| in the other engine at |url|, in its place: the same
    /// tab, the same side of a split, the focus where it was. A streaming
    /// service's page moves to WebKit, or back to Chromium.
    func replacePage(of tab: Item, with url: String, engine: OACPageEngine) {
        guard let old = tab.pane, old.delegate === self else { return }
        let wasShown = visibleTabs.contains { $0 === tab }
        let hadFocus = state.activeItem === tab
        itemsByPane[ObjectIdentifier(old)] = nil
        old.delegate = nil
        old.hide()
        old.close()
        tab.pane = nil
        tab.media = nil
        tab.liveURL = url
        let profile = privateProfile ?? library.profile(for: tab, in: state.space).chromium
        let page = ProtectedMedia.makePage(url: url, profile: profile, engine: engine)
        configure(page)
        tab.pane = page
        tab.loadedAt = Date()
        itemsByPane[ObjectIdentifier(page)] = tab
        if wasShown {
            layoutContent()
            if hadFocus { page.focus() }
        } else {
            page.load()
        }
        tellAboutWebKit(page)
    }

    /// Once per service: "Spotify spielt mit Safaris Engine", with "Warum?"
    /// (Site Controls, which say why) and ✕.
    func tellAboutWebKit(_ page: any OACPage) {
        guard let page = page as? WebKitPage, !page.serviceName.isEmpty, !ProtectedMedia.wasTold(page.serviceName),
              let item = item(for: page), visibleTabs.contains(where: { $0 === item }) else { return }
        ProtectedMedia.told(page.serviceName)
        showToast(L("%@ spielt mit Safaris Engine", page.serviceName), symbol: "safari", action: ToastAction(title: L("Warum?")) { [weak self] in
            guard let self, let item = self.item(for: page) else { return }
            if self.state.activeItem !== item { self.select(item) }
            self.state.siteControlsVisible = true
        }, closable: true)
    }

    /// Closes |tab|'s pane but keeps the item (pinned tabs, favorites).
    func unload(_ tab: Item) {
        if let owner = tab.pane?.delegate as? BrowserWindowController, owner !== self {
            owner.release(tab)
        }
        if let pane = tab.pane {
            itemsByPane[ObjectIdentifier(pane)] = nil
            pane.delegate = nil
            pane.close()
        }
        tab.pane = nil
        tab.liveURL = nil
        tab.liveTitle = nil
        tab.isLoading = false
        tab.canGoBack = false
        tab.canGoForward = false
        tab.isAudible = false
        tab.isMuted = false
        tab.media = nil
        tab.screenShare = nil
        tab.captureHandle = nil
        tab.mediaAccess = MediaAccess()
        tab.call = nil
        tab.isAsleep = false
        visibleTabs.removeAll { $0 === tab }
    }

    func switchSpace(to space: Space, restoring: Bool = true) {
        guard space !== state.space, !isStandalone else { return }
        clearSelection()
        state.space = space
        library.selectedSpaceID = space.id
        library.setNeedsSave()
        guard restoring else { return }
        if let id = space.activeItemID, let item = library.item(id: id),
           library.space(containing: item) === space || item.role == .favorites {
            select(item)
        } else {
            visibleTabs.forEach(pictureInPictureOnLeaving)
            showNothing()
        }
    }

    func switchSpace(by offset: Int) {
        guard let index = library.spaces.firstIndex(where: { $0 === state.space }) else { return }
        let count = library.spaces.count
        switchSpace(to: library.spaces[(index + offset + count) % count])
    }

    // MARK: Tabs

    /// Tabs in sidebar order for the current space: favorites, pinned, today.
    var orderedTabs: [Item] {
        if isStandalone { return flattenVisible(state.space.today.items) }
        let favorites = library.profile(id: state.space.profileID).favorites.allTabs
        let pinned = state.space.pinned.items.flatMap { item -> [Item] in
            item.kind == .folder ? (item.isExpanded ? flattenVisible(item.children) : []) : flattenVisible([item])
        }
        return favorites + pinned + flattenVisible(state.space.today.items)
    }

    private func flattenVisible(_ items: [Item]) -> [Item] {
        items.flatMap { item -> [Item] in
            switch item.kind {
            case .tab: [item]
            case .split: item.children
            case .folder: item.isExpanded ? flattenVisible(item.children) : []
            case .agent: []
            }
        }
    }

    func selectAdjacentTab(_ offset: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let index = state.activeItem.flatMap { active in tabs.firstIndex { $0 === active } } ?? -1
        select(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// ⌘1…⌘9: the Nth tab in sidebar order (favorites first); ⌘9 the last.
    func selectTab(at index: Int) {
        let tabs = orderedTabs
        if index >= 0, index < tabs.count {
            select(tabs[index])
        } else if index < 0, let last = tabs.last {
            select(last)
        }
    }

    private var recentCycle: (tabs: [Item], index: Int, time: Date)?

    /// ⌃Tab: the most recently used tabs. Pressing again quickly goes further
    /// back, like Arc's tab switcher.
    func selectRecentTab(_ direction: Int) {
        // ⌃ held down: the switcher, which goes to the tab when ⌃ is let go.
        if NSEvent.modifierFlags.contains(.control) || tabSwitcher.isOpen {
            tabSwitcher.advance(direction)
            return
        }
        var cycle = recentCycle
        if cycle == nil || Date().timeIntervalSince(cycle!.time) > 1.5 {
            let tabs = orderedTabs.sorted { $0.lastActiveAt > $1.lastActiveAt }
            cycle = (Array(tabs.prefix(5)), 0, Date())
        }
        guard var current = cycle, current.tabs.count > 1 else { return }
        current.index = (current.index + direction + current.tabs.count) % current.tabs.count
        current.time = Date()
        recentCycle = current
        select(current.tabs[current.index])
    }

    func selectFavorite(at index: Int) {
        guard !isStandalone else { return }
        let favorites = library.profile(id: state.space.profileID).favorites.items
        if index >= 0, index < favorites.count {
            select(favorites[index])
        } else if index < 0, let last = favorites.last {
            select(last)
        }
    }

    /// Opens |url| in a new today tab, at the top or right after |source|.
    @discardableResult
    func openInNewTab(_ url: String, after source: Item? = nil, select shouldSelect: Bool = true) -> Item {
        let item = Item.tab(url: InternalURL.resolve(url))
        let today = state.space.today
        if let source, source.role == .today, source.container === today {
            let anchor = source.split ?? source
            let parent = anchor.parent
            today.insert(item, into: parent, at: anchor.indexInParent + 1)
        } else {
            today.insert(item, at: 0)
        }
        if shouldSelect {
            select(item)
        }
        library.setNeedsSave()
        return item
    }

    func open(_ url: String, inNewTab: Bool) {
        // An agent chat has no page to go elsewhere: a new tab instead.
        if inNewTab || state.activeItem == nil || state.activeItem?.kind == .agent {
            openInNewTab(url)
        } else if let active = state.activeItem {
            navigate(active, to: url)
        }
    }

    func navigate(_ item: Item, to url: String) {
        let url = InternalURL.resolve(url)
        if let pane = item.pane {
            // OpenArch's own navigations pick the engine again.
            let engine = ProtectedMedia.engine(forAddress: url, current: pane.engine)
            if engine != pane.engine {
                replacePage(of: item, with: url, engine: engine)
            } else {
                pane.loadURL(url)
            }
        } else {
            item.liveURL = url
            select(item)
        }
    }

    /// ⌘W: today tabs close (and can be reopened), pinned tabs and
    /// favorites unload.
    func close(_ item: Item) {
        switch item.kind {
        case .folder:
            deleteFolder(item)
            return
        case .split:
            for child in item.children {
                close(child)
            }
            return
        case .agent:
            // Under the line a chat closes for good; a pinned one stays.
            if item.role == .today {
                deleteAgentChat(item)
            } else if state.activeItem === item {
                if let neighbor = neighbor(forClosing: item) { select(neighbor) } else { showNothing() }
            }
            return
        case .tab:
            break
        }
        let wasActive = state.activeItem === item
        let neighbor = wasActive ? neighbor(forClosing: item) : nil
        discardPageChat(item)
        if item.role == .today {
            if !isPrivate { library.archive(item, from: homeSpace) }
            unload(item)
            item.detach()
        } else {
            unload(item)
        }
        if wasActive {
            if let neighbor {
                select(neighbor)
            } else {
                showNothing()
            }
        } else {
            layoutContent()
        }
        library.setNeedsSave()
    }

    /// ⌘W closes the tab, or the window once no tab is left to close.
    /// With Peek open it closes Peek: the card is what is in front, and its
    /// window belongs to this one, so the key never reaches Peek itself.
    func closeActiveTab() {
        if peek.isOpen {
            peek.close()
        } else if let active = state.activeItem {
            close(active)
        } else {
            window?.performClose(nil)
        }
    }

    /// The tab shown after |item| closes: the other side of its split, else
    /// the tab used before it, so closing tabs goes back the way you came
    /// instead of jumping to whatever sits next to it.
    func neighbor(forClosing item: Item) -> Item? {
        if let split = item.split {
            return split.children.first { $0 !== item }
        }
        let previous = orderedTabs
            .filter { $0 !== item && $0.pane != nil }
            .max { $0.lastActiveAt < $1.lastActiveAt }
        if let previous { return previous }
        // Nothing else open yet: the tab below it, or above.
        if item.role == .today {
            let siblings = item.parent?.children ?? item.container?.items ?? []
            if let index = siblings.firstIndex(where: { $0 === item }) {
                if index + 1 < siblings.count { return siblings[index + 1] }
                if index > 0 { return siblings[index - 1] }
            }
        }
        return nil
    }

    func reopenClosedTab() {
        guard !isPrivate, let archived = library.popArchived() else { return }
        restore(archived)
    }

    func duplicate(_ item: Item) {
        guard item.kind == .tab else { return }
        openInNewTab(item.currentURL, after: item)
    }

    private func archiveInactiveTabs() {
        let hours = library.settings.archiveAfterHours
        guard hours > 0, !isStandalone else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        for space in library.spaces {
            // Not what any window shows right now.
            for tab in space.today.allTabs where tab.lastActiveAt < cutoff && tab !== state.activeItem
                && tab.pane?.isVisible != true {
                library.archive(tab)
                unload(tab)
                tab.detach()
            }
            // Folders under the line (Tabs mit KI aufräumen) go once they are empty.
            for folder in space.today.items where folder.kind == .folder && folder.children.isEmpty {
                folder.detach()
            }
        }
        library.setNeedsSave()
    }

    /// Sleeping tabs: a tab nobody has looked at for a while gives its memory
    /// back. Its page closes; the tab keeps its place, address and title and
    /// loads again when shown. Tabs that play something, or whose page would
    /// ask before leaving (an unsent form, unsaved changes), stay awake, and
    /// so do calls and pinned chat and mail sites (keepsAwake).
    func sleepInactiveTabs(olderThan minutes: Int? = nil) {
        let minutes = minutes ?? library.settings.sleepAfterMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        // Loaded in the background a moment ago counts as recent too.
        for tab in allTabs where max(tab.lastActiveAt, tab.loadedAt ?? .distantPast) < cutoff {
            guard let pane = tab.pane, pane.delegate === self, !pane.isVisible, !tab.isAudible,
                  tab.media?.playing != true, tab.media?.pip != true, !keepsAwake(tab),
                  !visibleTabs.contains(where: { $0 === tab }) else { continue }
            pane.checkAsksBeforeLeaving { [weak self, weak tab] asks in
                guard let self, let tab, !asks, tab.pane === pane, !pane.isVisible,
                      !self.visibleTabs.contains(where: { $0 === tab }) else { return }
                self.sleep(tab)
            }
        }
    }

    func sleep(_ tab: Item) {
        let url = tab.liveURL, title = tab.liveTitle
        unload(tab)
        tab.liveURL = url
        tab.liveTitle = title
        tab.isAsleep = true
    }

    // MARK: Pinning, favorites, folders, splits

    func pin(_ item: Item, into folder: Item? = nil) {
        guard !isStandalone else { return }
        let anchor = item.split ?? item
        if anchor.role != .pinned {
            anchor.savedURL = anchor.kind == .tab ? anchor.currentURL : anchor.savedURL
            if anchor.kind == .tab, let title = anchor.liveTitle { anchor.savedTitle = title }
        }
        state.space.pinned.insert(anchor, into: folder)
        library.setNeedsSave()
    }

    func unpin(_ item: Item) {
        let anchor = item.split ?? item
        state.space.today.insert(anchor, at: 0)
        library.setNeedsSave()
    }

    func togglePin(_ item: Item) {
        if item.role == .today {
            pin(item)
        } else if item.role == .pinned {
            unpin(item)
        }
    }

    func addToFavorites(_ item: Item) {
        guard item.kind == .tab, !isStandalone else { return }
        let favorites = library.profile(id: state.space.profileID).favorites
        if item.split != nil {
            // Take the tab out of the split view first.
            state.space.today.insert(item, at: 0)
        }
        item.savedURL = item.currentURL
        if let title = item.liveTitle { item.savedTitle = title }
        favorites.insert(item)
        library.setNeedsSave()
    }

    func removeFromFavorites(_ item: Item) {
        state.space.today.insert(item, at: 0)
        library.setNeedsSave()
    }

    /// Makes the current URL the one a pinned tab or favorite returns to.
    func resetSavedURL(_ item: Item) {
        item.savedURL = item.currentURL
        if let title = item.liveTitle { item.savedTitle = title }
        library.setNeedsSave()
    }

    func goToSavedURL(_ item: Item) {
        navigate(item, to: item.savedURL)
    }

    @discardableResult
    func newFolder(in parent: Item? = nil, name: String = L("Neuer Ordner")) -> Item {
        let folder = Item.folder(name)
        state.space.pinned.insert(folder, into: parent, at: 0)
        state.renamingItemID = folder.id
        library.setNeedsSave()
        return folder
    }

    /// Joins a meeting from the sidebar's card, as in Dia: the call opens in
    /// a folder of its own under the line, and links opened from the call
    /// land in it too. Joining again goes back to that tab.
    func joinMeeting(_ meeting: Meetings.Meeting) {
        guard let url = meeting.joinURL else { return }
        let name = "📹 " + meeting.title
        let today = state.space.today
        if let folder = today.items.first(where: { $0.kind == .folder && $0.displayTitle == name }),
           let call = folder.children.first(where: { $0.kind == .tab }) {
            select(call)
            return
        }
        let folder = Item.folder(name)
        today.insert(folder, at: 0)
        let call = Item.tab(url: url, title: meeting.title)
        today.insert(call, into: folder, at: 0)
        select(call)
        library.setNeedsSave()
    }

    /// A pinned folder that fills itself from GitHub (see LiveFolders).
    @discardableResult
    func newLiveFolder(_ source: LiveSource, name: String) -> Item {
        let folder = Item.folder(name)
        folder.icon = source.kind == .pullRequests ? "arrow.triangle.pull" : "smallcircle.filled.circle"
        folder.live = source
        state.space.pinned.insert(folder, at: 0)
        library.setNeedsSave()
        LiveFolders.shared.refresh(folder)
        return folder
    }

    func deleteFolder(_ folder: Item) {
        guard folder.kind == .folder else { return }
        let alert = NSAlert()
        alert.messageText = L("Ordner „%@“ löschen?", folder.displayTitle)
        let tabs = folder.descendants.filter { $0.kind == .tab || $0.kind == .agent }.count
        alert.informativeText = tabs == 0 ? L("Der Ordner ist leer.")
            : Localization.count(tabs, one: "Die 1 Tab darin wird ebenfalls entfernt.",
                                       other: "Die %lld Tabs darin werden ebenfalls entfernt.")
        alert.addButton(withTitle: L("Löschen"))
        alert.addButton(withTitle: L("Abbrechen"))
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for tab in folder.descendants where tab.kind == .tab {
            if state.activeItem === tab { showNothing() }
            unload(tab)
        }
        for chat in folder.descendants where chat.kind == .agent {
            if state.activeItem === chat { showNothing() }
            discardAgentChat(chat)
        }
        folder.detach()
        layoutContent()
        library.setNeedsSave()
    }

    func rename(_ item: Item, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        item.customTitle = trimmed.isEmpty ? nil : trimmed
        state.renamingItemID = nil
        library.setNeedsSave()
    }

    /// Puts |other| next to the active tab in a split view (or adds it to the
    /// active split). |leading| puts it first (left, or on top); |stacked|
    /// arranges the split one above the other (or side by side), nil keeps
    /// how an existing split is arranged.
    func split(_ other: Item, with base: Item? = nil, leading: Bool = false, stacked: Bool? = nil) {
        guard var base = base ?? state.activeItem, base !== other, base.kind == .tab, other.kind == .tab else { return }
        if base.role == .favorites {
            // Favorites hold no split views: the favorite stays, and a copy
            // of it goes beside |other| under the line, as when dragging one.
            let copy = Item.tab(url: base.currentURL, title: base.displayTitle)
            state.space.today.insert(copy, at: 0)
            base = copy
        }
        if let split = base.split {
            guard split.children.count < 4 || other.split === split else { return }
            if let container = split.container {
                if other.split === split { other.detach() }
                container.insert(other, into: split, at: base.indexInParent + (leading ? 0 : 1))
            }
            split.splitFractions = []
            if let stacked { split.splitStacked = stacked }
        } else {
            guard let container = base.container else { return }
            let index = base.indexInParent
            let parent = base.parent
            let split = Item(kind: .split)
            split.splitStacked = stacked ?? false
            container.insert(split, into: parent, at: index)
            if leading {
                container.insert(other, into: split)
                container.insert(base, into: split)
            } else {
                container.insert(base, into: split)
                container.insert(other, into: split)
            }
        }
        select(other)
        library.setNeedsSave()
    }

    // MARK: Drag a tab onto the page for split view

    private var splitDropOverlay: SplitDropOverlay?
    private var dragWatch: Timer?

    /// Called when a tab starts being dragged out of the sidebar: shows drop
    /// zones over the page until the drag ends.
    /// Set when a dragged sidebar item lands in an OpenArch window.
    static var tabDropHandled = false

    func beginTabDrag(_ item: Item) {
        guard item.kind == .tab, let window else { return }
        Self.tabDropHandled = false
        if !visibleTabs.isEmpty {
            let overlay = splitDropOverlay ?? SplitDropOverlay(browser: self)
            splitDropOverlay = overlay
            overlay.show(over: window.convertToScreen(contentRect), above: window)
        }
        // Drag sessions run their own event loop; this fires once it is over.
        dragWatch?.invalidate()
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons == 0 else { return }
                self.dragWatch?.invalidate()
                self.splitDropOverlay?.hide()
                // Dropped where no OpenArch window took it (the desktop, the
                // other screen): the tab opens there in a window of its own.
                let point = NSEvent.mouseLocation
                if !Self.tabDropHandled, !Self.isOverOpenArchWindow(point) {
                    self.openInSeparateWindow(item, at: point)
                }
            }
        }
    }

    static func isOverOpenArchWindow(_ point: NSPoint) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.alphaValue > 0 && $0.frame.contains(point) }
    }

    /// Like Arc: a tab dragged out of the sidebar becomes a window of its
    /// own where it was dropped, with tabs but without favorites and pinned
    /// tabs. A today tab moves there and takes its page along without
    /// reloading; pinned tabs and favorites stay and open a copy.
    @discardableResult
    func openInSeparateWindow(_ item: Item, at point: NSPoint?) -> BrowserWindowController? {
        guard item.kind == .tab, !isPrivate, let app = NSApp.delegate as? AppDelegate else { return nil }
        let separate = app.openSeparateWindow(home: homeSpace ?? state.space, from: self, at: point)
        guard item.role == .today else {
            separate.openInNewTab(item.currentURL)
            return separate
        }
        let wasActive = state.activeItem === item
        let next = wasActive ? neighbor(forClosing: item) : nil
        separate.state.space.today.insert(item)
        // Its page moves over as it is (see claim).
        separate.select(item)
        if wasActive {
            if let next { select(next) } else { showNothing() }
        } else {
            layoutContent()
        }
        library.setNeedsSave()
        return separate
    }

    /// A tab dropped on the left or right half of the page.
    /// Shows a split's tabs one above the other, or side by side again.
    func setSplitStacked(_ split: Item, _ stacked: Bool) {
        guard split.kind == .split, split.splitStacked != stacked else { return }
        split.splitStacked = stacked
        split.splitFractions = []
        layoutContent()
        library.setNeedsSave()
    }

    /// Swaps the sides of a split view, left and right (or top and bottom);
    /// with three or four tabs their order reverses.
    func swapSplit(_ split: Item) {
        guard split.kind == .split, split.children.count > 1 else { return }
        split.children.reverse()
        split.splitFractions.reverse()
        if visibleTabs.first?.split === split {
            visibleTabs = split.children
        }
        layoutContent()
        library.setNeedsSave()
    }

    /// A tab dropped on a half of the page: left or right puts it beside
    /// the shown tab, top or bottom (|stacked|) above or below it. With
    /// |target| (a tab or split dropped onto in the sidebar) it joins that
    /// one instead, after it.
    func dropForSplit(_ item: Item, onto target: Item? = nil, leading: Bool = false, stacked: Bool? = nil) {
        splitDropOverlay?.hide()
        var base = target.map { $0.kind == .split ? $0.children.last : $0 } ?? state.activeItem
        if target == nil, base === item {
            // Dragging the shown tab itself: pair it with the last one used.
            base = orderedTabs.filter { $0 !== item && $0.pane != nil }.max { $0.lastActiveAt < $1.lastActiveAt }
        }
        guard let base, base !== item, base.kind == .tab else {
            if target == nil { select(item) }
            return
        }
        var other = item
        if item.split === base.split, base.split != nil {
            // Rearranging within the same split.
            other = item
        } else if item.role == .favorites || (item.role == .pinned && base.role != .pinned) {
            // Keep favorites and pinned tabs where they are; split a copy.
            other = Item.tab(url: item.currentURL, title: item.displayTitle)
            state.space.today.insert(other, at: 0)
        }
        split(other, with: base, leading: leading, stacked: stacked)
    }

    /// Splits the active tab with a new empty tab and opens the command bar
    /// for it (Arc's ⌃⇧=).
    func splitWithNewTab() {
        guard let active = state.activeItem, active.kind == .tab else {
            commandBar.show(mode: .newTab)
            return
        }
        // Four sides are all a split view takes; the menu item is greyed
        // out then, but its shortcut still comes here.
        guard (active.split?.children.count ?? 1) < 4 else {
            if !AppPaths.isSelfTest { NSSound.beep() }
            return
        }
        commandBar.show(mode: .newSplit(active))
    }

    func unsplit(_ item: Item? = nil) {
        guard let tab = item ?? state.activeItem, let split = tab.split, let container = split.container else { return }
        let index = split.indexInParent
        let parent = split.parent
        for (offset, child) in split.children.enumerated() {
            container.insert(child, into: parent, at: index + offset + 1)
        }
        split.detach()
        select(tab)
        library.setNeedsSave()
    }

    /// Moves |item| relative to |target| (drag and drop in the sidebar).
    func move(_ item: Item, to target: DropTarget) {
        // A pinned tab or favorite keeps the address it returns to; one
        // dragged in from under the line is pinned at its current page.
        let wasBookmark = item.role == .pinned || item.role == .favorites
        switch target {
        case .before(let other):
            guard other !== item, !other.isDescendant(of: item), let container = other.container else { return }
            container.insert(item, into: other.parent, at: other.indexInParent)
        case .after(let other):
            guard other !== item, !other.isDescendant(of: item), let container = other.container else { return }
            container.insert(item, into: other.parent, at: other.indexInParent + 1)
        case .into(let folder):
            guard folder !== item, !folder.isDescendant(of: item), folder.kind == .folder,
                  let container = folder.container else { return }
            folder.isExpanded = true
            container.insert(item, into: folder)
        case .end(let container):
            if container.role == .favorites, item.kind != .tab { return }
            container.insert(item)
        case .split(let other):
            dropForSplit(item, onto: other)
            return
        }
        if !wasBookmark, item.role == .pinned || item.role == .favorites, item.kind == .tab {
            item.savedURL = item.currentURL
        }
        library.setNeedsSave()
    }

    enum DropTarget {
        /// |split|: onto a tab (or split) in the sidebar, for a split view with it.
        case before(Item), after(Item), into(Item), end(Container), split(Item)
    }

    // MARK: Actions on the active tab

    var activePane: (any OACPage)? {
        state.activeItem?.pane
    }

    func goBack() { activePane?.goBack() }
    func goForward() { activePane?.goForward() }
    func reload() { activePane?.reload() }

    /// Set while OpenArch runs a Chrome command itself, so the command is
    /// not intercepted again (⌘⇧S runs "Save page", which ⌘S maps away).
    private static var runningCommand: Int?

    func runChromeCommand(_ command: OACChromeCommand) {
        Self.runningCommand = command.rawValue
        activePane?.executeChromeCommand(command.rawValue)
        Self.runningCommand = nil
    }

    /// The page in front: Peek's card while it is open, else the tab. With
    /// rows selected in the sidebar, all their addresses.
    func copyURL() {
        if selectedItems.count > 1, !peek.isOpen {
            return copySelectedURLs()
        }
        guard let url = peek.isOpen ? peek.model.url : state.activeItem?.currentURL, !url.isEmpty else { return }
        OpenArch.copy(url)
        showToast("Link kopiert")
    }

    func copyURLAsMarkdown() {
        guard let item = state.activeItem, item.kind == .tab else { return }
        let title = item.displayTitle.replacingOccurrences(of: "]", with: "\\]")
        OpenArch.copy("[\(title)](\(item.currentURL))")
        showToast("Link als Markdown kopiert")
    }

    private(set) var toast: ToastWindow?

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill", action: ToastAction? = nil,
                   closable: Bool = false) {
        guard let window else { return }
        let toast = self.toast ?? ToastWindow()
        self.toast = toast
        toast.show(text, symbol: symbol, over: window.convertToScreen(contentRect), parent: window, action: action,
                   closable: closable, theme: theme)
    }

    /// ⌃⇧1…4: focus a side of the split view; ⌃⇧[ and ⌃⇧] the neighbours.
    func focusSplitPane(_ index: Int) {
        guard visibleTabs.count > 1, visibleTabs.indices.contains(index) else { return }
        select(visibleTabs[index])
    }

    func focusAdjacentSplitPane(_ offset: Int) {
        guard visibleTabs.count > 1, let active = state.activeItem,
              let index = visibleTabs.firstIndex(where: { $0 === active }) else { return }
        select(visibleTabs[(index + offset + visibleTabs.count) % visibleTabs.count])
    }

    func showLibrary(_ section: LibrarySection) {
        state.librarySection = section
        if !state.libraryVisible {
            toggleLibrary()
        }
    }

    func toggleSidebar() {
        state.sidebarVisible.toggle()
        state.downloadStack.dismiss()
        layoutContent()
    }

    /// The sidebar moved to the other side (Settings › Allgemein › Sidebar):
    /// a short cross-fade, since sliding it across the page looks like a
    /// glitch, and everything laid out again.
    func sidebarSideChanged() {
        tabPreview.hide()
        floatingSidebar.hide()
        state.downloadStack.dismiss()
        layoutContent()
        if window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sidebarHost.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                sidebarHost.animator().alphaValue = 1
            }
        }
    }

    func toggleChromeToolbar() {
        library.settings.showChromeToolbar.toggle()
        let visible = library.settings.showChromeToolbar
        let windows = (NSApp.delegate as? AppDelegate)?.browsers ?? [self]
        for tab in windows.flatMap(\.allTabs) {
            tab.pane?.toolbarVisible = visible
        }
        library.setNeedsSave()
    }

    func openChromePage(_ url: String) {
        openInNewTab(url)
    }

    // MARK: OACPaneDelegate

    private func item(for pane: any OACPage) -> Item? {
        itemsByPane[ObjectIdentifier(pane)]
    }

    func registerPane(_ pane: any OACPage, for item: Item) {
        itemsByPane[ObjectIdentifier(pane)] = item
    }

    func pane(_ pane: any OACPage, titleDidChange title: String) {
        guard let item = item(for: pane) else { return }
        item.liveTitle = title
        if !isPrivate { history.updateTitle(url: item.currentURL, title: title) }
        library.setNeedsSave()
    }

    func pane(_ pane: any OACPage, addressDidChange url: String) {
        guard let item = item(for: pane) else { return }
        if item.liveURL.map({ URL(string: $0)?.host() != URL(string: url)?.host() }) ?? false {
            item.media = nil  // Another site; its player reports anew.
        }
        item.liveURL = url
        if !isPrivate { history.recordVisit(url: url, title: nil) }
        library.setNeedsSave()
    }

    func pane(_ pane: any OACPage, faviconDidChange favicon: NSImage) {
        guard let item = item(for: pane) else { return }
        item.favicon = favicon
        if !isPrivate { FaviconStore.shared.store(favicon, forURL: item.currentURL) }
    }

    func pane(_ pane: any OACPage, loadingStateDidChange isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let item = item(for: pane) else { return }
        // A new load starts from nothing, not from the last one's 100 %.
        if isLoading, !item.isLoading { item.loadingProgress = 0 }
        item.isLoading = isLoading
        item.canGoBack = canGoBack
        item.canGoForward = canGoForward
    }

    func pane(_ pane: any OACPage, loadingProgressDidChange progress: Double) {
        item(for: pane)?.loadingProgress = progress
    }

    func pane(_ pane: any OACPage, wantsNewTabWithURL url: String, background: Bool) {
        if !background, let source = item(for: pane), shouldPeek(url, from: source) {
            peek.open(url, from: source)
            return
        }
        openInNewTab(url, after: item(for: pane), select: !background)
    }

    func pane(_ pane: any OACPage, wantsToOpenExternalURL url: String) {
        ExternalApps.open(url, from: pane.url, in: window, library: library) { [weak self] text in
            self?.showToast(text, symbol: "exclamationmark.circle.fill")
        }
    }

    /// A Chromium page going to a streaming service: the tab moves to
    /// WebKit at that address, in its place (a POST stays).
    func pane(_ pane: any OACPage, shouldHandOffNavigationToURL url: String, method: String) -> Bool {
        guard let item = item(for: pane), ProtectedMedia.handsOff(from: pane.engine, to: url, method: method) else { return false }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { [weak self] in
                guard let self, item.pane === pane else { return }
                self.replacePage(of: item, with: url, engine: .webKit)
            }
        }
        return true
    }

    func pane(_ pane: any OACPage, shouldInterceptNavigationToURL url: String) -> Bool {
        guard let source = item(for: pane), shouldPeek(url, from: source) else { return false }
        peek.open(url, from: source)
        return true
    }

    /// Pinned tabs and favorites keep their page: links to other sites
    /// open in Peek.
    func pane(_ pane: OACPane, wantsPeekWithURL url: String) -> Bool {
        guard library.settings.peek, url.hasPrefix("http"), let source = item(for: pane) else { return false }
        peek.open(url, from: source)
        return true
    }

    private func shouldPeek(_ url: String, from source: Item) -> Bool {
        library.settings.peek && FeatureSwitches.shared.isOn(.peek) && (source.role == .pinned || source.role == .favorites)
            && url.hasPrefix("http") && !PeekController.sameSite(url, source.savedURL)
    }

    func paneDidBecomeActive(_ pane: any OACPage) {
        guard let item = item(for: pane), item !== state.activeItem else { return }
        guard visibleTabs.contains(where: { $0 === item }) else {
            // Brought to the front from outside (an AI agent via DevTools,
            // an extension): show it in the window.
            select(item)
            return
        }
        item.lastActiveAt = Date()
        state.activeItem = item
        state.space.activeItemID = item.id
        let frames = paneFrames(in: contentRect)
        layoutFocusRing(frames: frames)
        layoutLoadingLine(frames: frames)
    }

    func paneDidClose(_ pane: any OACPage) {
        // The page closed itself (window.close()) or its browser went away;
        // while OpenArch quits, every browser goes, and the tabs stay.
        guard !library.isFrozen, let item = item(for: pane) else { return }
        itemsByPane[ObjectIdentifier(pane)] = nil
        item.pane = nil
        close(item)
    }

    func pane(_ pane: any OACPage, handleChromeCommand commandID: Int) -> Bool {
        guard commandID != Self.runningCommand, let command = OACChromeCommand(rawValue: commandID) else { return false }
        switch command {
        case .newTab:
            commandBar.show(mode: .newTab)
        case .focusLocation:
            commandBar.show(mode: .editURL)
        case .closeTab:
            closeActiveTab()
        case .restoreTab:
            // The last closed tab, or window if that closed later.
            (NSApp.delegate as? AppDelegate)?.reopenTab(nil)
        case .selectNextTab:
            selectRecentTab(1)
        case .selectPreviousTab:
            selectRecentTab(-1)
        case .selectLastTab:
            selectTab(at: -1)
        case .bookmarkThisTab:
            if let active = state.activeItem { togglePin(active) }
        case .savePage:
            // ⌘S is Arc's sidebar key; Chrome's ⋮ menu "Save page as…" saves.
            guard let event = NSApp.currentEvent, event.type == .keyDown, event.charactersIgnoringModifiers == "s",
                  event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
            toggleSidebar()
        case .duplicateTab:
            if let active = state.activeItem { duplicate(active) }
        case .copyURL:
            // Chrome's own ⌘⇧C would copy without the "Link kopiert" toast.
            copyURL()
        case .newSplitTab:
            splitWithNewTab()
        case .tabSearch:
            commandBar.show(mode: .newTab)
        case .fullscreen:
            window?.toggleFullScreen(nil)
        case .exit:
            NSApp.terminate(nil)
        case .options:
            (NSApp.delegate as? AppDelegate)?.showSettings(nil)
        case .showHistory:
            openChromePage("chrome://history")
        case .showDownloads:
            openChromePage("chrome://downloads")
        case .manageExtensions:
            openChromePage("chrome://extensions")
        case .showBookmarkManager:
            openChromePage("chrome://bookmarks")
        case .clearBrowsingData:
            openChromePage("chrome://settings/clearBrowserData")
        case .newWindow:
            (NSApp.delegate as? AppDelegate)?.openWindow(isPrivate: false)
        case .newIncognitoWindow:
            (NSApp.delegate as? AppDelegate)?.openWindow(isPrivate: true)
        case .closeWindow:
            window?.performClose(nil)
        case .showBookmarkBar:
            break  // OpenArch's sidebar instead.
        default:
            if (OACChromeCommand.selectTab0.rawValue...OACChromeCommand.selectTab7.rawValue).contains(commandID) {
                selectTab(at: commandID - OACChromeCommand.selectTab0.rawValue)
                return true
            }
            return false
        }
        return true
    }

    func pane(_ pane: any OACPage, mainFrameLoadStarted started: Bool, url: String) {
        // A new document shares nothing (yet); it names itself anew.
        if started, let item = item(for: pane) {
            item.screenShare = nil
            item.call = nil
        }
        // Boosts go in as early as the page allows and again once it is
        // complete (the style sheet is replaced, the script runs once).
        if FeatureSwitches.shared.isOn(.boosts), let boost = BoostStore.shared.boost(for: url), boost.isEnabled,
           !boost.styleSheet.isEmpty || !boost.javaScript.isEmpty {
            pane.executeJavaScript(BoostStore.script(for: boost))
        }
    }

    func pane(_ pane: OACPane, mediaAccessDidChangeVideo video: Bool, audio: Bool) {
        item(for: pane)?.mediaAccess = MediaAccess(video: video, audio: audio)
    }

    /// A changed boost reaches the open tabs of its site at once.
    func applyBoost(_ boost: Boost) {
        guard FeatureSwitches.shared.isOn(.boosts) else { return }
        for tab in allTabs where tab.pane != nil && boost.applies(to: tab.currentURL) {
            tab.pane?.executeJavaScript(BoostStore.script(for: boost))
        }
    }

    func editBoost() {
        guard let active = state.activeItem, active.kind == .tab else { return }
        guard FeatureSwitches.shared.isOn(.boosts) else {
            showToast("Boosts sind vorübergehend abgeschaltet", symbol: "exclamationmark.circle.fill")
            return
        }
        BoostPanelController.show(for: active, browser: self)
    }

    func pane(_ pane: any OACPage, consoleMessage message: String, source: String, line: Int) {
        let zapPrefix = "__openarch_zap__"
        if message.hasPrefix(zapPrefix), let editor = BoostPanelController.current?.model, editor.item === item(for: pane) {
            if message.hasPrefix(zapPrefix + " ") {
                editor.zapped(String(message.dropFirst(zapPrefix.count + 1)))
            } else if message == zapPrefix + "-done" {
                editor.isZapping = false
            }
            return
        }
        let capturePrefix = "__openarch_capture__ "
        if message.hasPrefix(capturePrefix), let item = item(for: pane) {
            item.screenShare = try? JSONDecoder().decode(ScreenShare.self, from: Data(message.dropFirst(capturePrefix.count).utf8))
            return
        }
        let handlePrefix = "__openarch_handle__ "
        if message.hasPrefix(handlePrefix), let item = item(for: pane) {
            item.captureHandle = String(message.dropFirst(handlePrefix.count))
            return
        }
        let callPrefix = "__openarch_call__"
        if message.hasPrefix(callPrefix), let item = item(for: pane) {
            let rest = message.dropFirst(callPrefix.count)
            if rest.hasPrefix(" ") {
                let call = try? JSONDecoder().decode(CallState.self, from: Data(rest.dropFirst().utf8))
                let opened = call?.pip.isEmpty == false && item.call?.pip.isEmpty != false
                item.call = call
                if opened { PictureInPictureWindows.shared.expect() }
            } else if rest == "-back" {
                returnToCall(item)
            }
            SelfTest.current?.consoleMessage(message, from: item)
            return
        }
        let mediaPrefix = "__openarch_media__ "
        if message.hasPrefix(mediaPrefix), let item = item(for: pane) {
            let media = try? JSONDecoder().decode(MediaState.self, from: Data(message.dropFirst(mediaPrefix.count).utf8))
            if media?.playing == true, item.media?.playing != true { item.mediaDismissed = false }
            if media?.pip == true, item.media?.pip != true { PictureInPictureWindows.shared.expect() }
            item.media = media
            return
        }
        let prefix = "__openarch_audio__ "
        if message.hasPrefix(prefix), let item = item(for: pane),
           let data = message.dropFirst(prefix.count).data(using: .utf8),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            item.isAudible = state["audible"] ?? false
            item.isMuted = state["muted"] ?? false
            return
        }
        SelfTest.current?.consoleMessage(message, from: item(for: pane))
    }

    // MARK: Media

    /// The tab whose media the sidebar shows controls for: something playing
    /// (or paused) in a tab that is not on screen right now.
    /// Every tab this window can show: the library's, or a private or
    /// separate window's own.
    var allTabs: [Item] {
        isStandalone ? state.space.today.allTabs : library.allContainers.flatMap(\.allTabs)
    }

    var nowPlaying: Item? {
        allTabs
            .filter { tab in
                // Muted videos playing by themselves (feeds, page backgrounds)
                // are not what you listen to.
                guard tab.pane != nil, let media = tab.media, media.audible, !tab.mediaDismissed else { return false }
                return !visibleTabs.contains { $0 === tab }
            }
            .max { lhs, rhs in
                if lhs.media?.playing != rhs.media?.playing { return rhs.media?.playing == true }
                return lhs.lastActiveAt < rhs.lastActiveAt
            }
    }

    /// What the sidebar's player shows: media in a tab that is not on
    /// screen, or Spotify on the Mac. What plays comes before what is
    /// paused, a tab before Spotify.
    var player: NowPlaying? {
        let tab = nowPlaying
        let spotify = SpotifyPlayer.shared.dismissed ? nil : SpotifyPlayer.shared.media
        if let tab, tab.media?.playing == true { return .tab(tab) }
        if let spotify, spotify.playing { return .spotify(spotify) }
        if let tab { return .tab(tab) }
        return spotify.map { .spotify($0) }
    }

    /// Closes the media card: the playback stops, and the card stays away
    /// until the page plays again.
    func dismissMedia(_ item: Item) {
        if item.media?.playing == true { mediaCommand(item, "toggle") }
        if item.media?.pip == true { mediaCommand(item, "exitpip") }
        item.mediaDismissed = true
    }

    /// A tab of this window sharing the screen, and the tab it shares if
    /// that is one of OpenArch's (in any space or window).
    var screenShare: (sharer: Item, shared: Item?)? {
        guard let sharer = allTabs.first(where: { $0.pane != nil && $0.screenShare != nil }),
              let share = sharer.screenShare else { return nil }
        guard share.surface == "browser", !share.handle.isEmpty else { return (sharer, nil) }
        let tabs = (NSApp.delegate as? AppDelegate)?.browsers.flatMap(\.allTabs) ?? allTabs
        return (sharer, tabs.first { $0.captureHandle == share.handle })
    }

    /// Whether a page somewhere shares |item|.
    func isBeingShared(_ item: Item) -> Bool {
        guard let handle = item.captureHandle else { return false }
        let tabs = (NSApp.delegate as? AppDelegate)?.browsers.flatMap(\.allTabs) ?? allTabs
        return tabs.contains { $0.screenShare?.handle == handle }
    }

    /// Ends the sharing as Chrome's own "Freigabe beenden" would.
    func stopScreenShare(_ item: Item) {
        item.pane?.executeJavaScript("document.dispatchEvent(new Event('openarch-capture-stop'))")
    }

    /// "toggle", "previous", "next", "pip" or "exitpip", carried out by the
    /// built-in extension (previous and next with the page's own tracks).
    func mediaCommand(_ item: Item, _ command: String) {
        item.pane?.executeJavaScript("document.dispatchEvent(new CustomEvent('openarch-media', {detail: '\(command)'}))",
                                     userGesture: true)
    }

    /// Jumps to a position (seconds) in what the tab plays.
    func seekMedia(_ item: Item, to seconds: Double) {
        guard seconds.isFinite else { return }
        mediaCommand(item, "seek:" + String(format: "%.2f", max(0, seconds)))
    }

    /// The speaker on a tab: mutes or unmutes it.
    func toggleMute(_ item: Item) {
        guard let pane = item.pane else { return }
        item.isMuted.toggle()
        pane.setAudioMuted(item.isMuted)
    }
}

// MARK: - Views

final class BrowserWindow: NSWindow {
    /// The background self-test keeps its window behind all others.
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if AppPaths.isSelfTest {
            orderBack(sender)
        } else {
            super.makeKeyAndOrderFront(sender)
        }
    }
}

/// The window's content view; lays out sidebar and panes on resize.
final class BrowserRootView: NSView {
    weak var controller: BrowserWindowController?

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated { controller?.layoutContent() }
    }
}

/// The gap between two split panes; drag it to resize them.
final class SplitDividerView: NSView {
    var index = 0
    /// Between tabs one above the other: dragged up and down.
    var stacked = false {
        didSet { if stacked != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var onDrag: ((Int, CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: stacked ? .resizeUpDown : .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let gap = BrowserWindowController.splitGap
        onDrag?(index, stacked ? point.y + gap / 2 : point.x - gap / 2)
    }
}

/// Outline around the focused pane of a split view.
final class FocusRingView: NSView {
    var color = NSColor.white.withAlphaComponent(0.5) {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        color.setStroke()
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
