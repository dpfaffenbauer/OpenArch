import AppKit
import OpenArchCore
import SwiftUI

/// One browser window: the sidebar on the left and, to its right, the
/// content area where the active tab's Chrome pane (or the panes of a split
/// view) sit as child windows.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, OACPaneDelegate {
    let library: Library
    let history: History
    let state: BrowserState
    /// A private window: its own in-memory profile, no history, and tabs
    /// that are gone once it closes.
    let isPrivate: Bool
    private var privateProfile: OACProfile?

    /// Tabs whose panes are currently shown, left to right.
    private var visibleTabs: [Item] = []
    private var itemsByPane: [ObjectIdentifier: Item] = [:]
    private let rootView = BrowserRootView()
    private var sidebarHost: NSHostingView<SidebarView>!
    private var emptyHost: NSHostingView<EmptyContentView>!
    private var dividers: [SplitDividerView] = []
    private let focusRing = FocusRingView()
    private let sidebarHandle = SplitDividerView()
    private let sidebarEdge = SidebarEdgeView()
    private(set) lazy var floatingSidebar = FloatingSidebar(browser: self)
    private(set) lazy var peek = PeekController(browser: self)
    private(set) lazy var commandBar = CommandBarController(browser: self)
    private(set) var sidebarSwipe: SidebarSwipe?
    private var archiveTimer: Timer?

    static let contentInset: CGFloat = 8
    static let splitGap: CGFloat = 8

    init(library: Library, history: History, isPrivate: Bool = false, cascadingFrom other: NSWindow? = nil) {
        self.library = library
        self.history = history
        self.isPrivate = isPrivate
        if isPrivate {
            // Not part of the library: never saved, never in the space bar.
            state = BrowserState(space: Space(name: "Privates Fenster", icon: "eyeglasses", colorHex: "#2C2C30", profileID: ""))
            privateProfile = OACProfile.makePrivate()
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
        sidebarHost = NSHostingView(rootView: SidebarView(browser: self))
        sidebarHost.sizingOptions = []
        emptyHost = NSHostingView(rootView: EmptyContentView(browser: self))
        emptyHost.sizingOptions = []
        rootView.addSubview(emptyHost)
        rootView.addSubview(sidebarHost)
        rootView.addSubview(focusRing)
        sidebarHandle.onDrag = { [weak self] _, x in self?.resizeSidebar(to: x) }
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
        sidebarSwipe = SidebarSwipe(browser: self)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTheme() }
            }
        }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.archiveInactiveTabs() }
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
            _ = state.space.colorHex
            _ = state.space.id
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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

    private func applyTheme() {
        let theme = SpaceTheme(hex: state.space.colorHex)
        window?.backgroundColor = isFrontmost ? theme.base : theme.inactiveBase
        if isFrontmost, !isPrivate, !AppPaths.isSelfTest {
            AppIcons.spaceDidChange(state.space.colorHex)
        }
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        focusRing.color = theme.isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.35)
        floatingSidebar.applyTheme()
    }

    // MARK: Layout

    /// The sidebar's width; the library needs a bit more room.
    var sidebarWidth: CGFloat {
        let width = CGFloat(library.settings.sidebarWidth)
        return state.libraryVisible ? max(width, 400) : width
    }

    /// The area right of the sidebar where panes go, in window coordinates.
    var contentRect: NSRect {
        let bounds = rootView.bounds
        let inset = Self.contentInset
        var rect = bounds
        if state.sidebarVisible {
            rect.origin.x = sidebarWidth
            rect.size.width = bounds.width - sidebarWidth - inset
            rect.origin.y = inset
            rect.size.height = bounds.height - 2 * inset
        } else {
            // Leave room for the window buttons above the content.
            let top: CGFloat = window?.styleMask.contains(.fullScreen) == true ? inset : 30
            rect = NSRect(x: inset, y: inset, width: bounds.width - 2 * inset, height: bounds.height - inset - top)
        }
        return rect
    }

    func layoutContent() {
        guard let window else { return }
        let bounds = rootView.bounds
        sidebarHost.isHidden = !state.sidebarVisible
        sidebarHost.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        sidebarHandle.isHidden = !state.sidebarVisible
        sidebarHandle.frame = NSRect(x: sidebarWidth - 5, y: 0, width: 8, height: max(0, bounds.height - 40))
        sidebarEdge.isHidden = state.sidebarVisible
        sidebarEdge.frame = NSRect(x: 0, y: 0, width: Self.contentInset - 2, height: max(0, bounds.height - 30))
        let content = contentRect
        emptyHost.frame = content
        emptyHost.isHidden = !visibleTabs.isEmpty

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
        layoutFocusRing(frames: frames)
        floatingSidebar.layout()
        peek.layout()
    }

    private func paneFrames(in rect: NSRect) -> [NSRect] {
        guard visibleTabs.count > 1, let split = visibleTabs.first?.split else {
            return visibleTabs.isEmpty ? [] : [rect]
        }
        let count = visibleTabs.count
        var fractions = split.splitFractions
        if fractions.count != count || fractions.contains(where: { $0 <= 0 }) {
            fractions = Array(repeating: 1.0 / Double(count), count: count)
        }
        let available = rect.width - Self.splitGap * CGFloat(count - 1)
        var frames: [NSRect] = []
        var x = rect.minX
        for (index, fraction) in fractions.enumerated() {
            let width = index == count - 1 ? rect.maxX - x : (available * fraction).rounded()
            frames.append(NSRect(x: x, y: rect.minY, width: width, height: rect.height))
            x += width + Self.splitGap
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
        for (index, divider) in dividers.enumerated() {
            divider.index = index
            divider.frame = NSRect(x: frames[index].maxX, y: content.minY, width: Self.splitGap, height: content.height)
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

    private func dragDivider(_ index: Int, to x: CGFloat) {
        guard let split = visibleTabs.first?.split, visibleTabs.count > index + 1 else { return }
        let content = contentRect
        let count = visibleTabs.count
        let available = content.width - Self.splitGap * CGFloat(count - 1)
        var frames = paneFrames(in: content)
        let minWidth: CGFloat = 240
        let left = frames[index]
        let right = frames[index + 1]
        let newLeftWidth = max(minWidth, min(x - left.minX, left.width + right.width - minWidth))
        frames[index].size.width = newLeftWidth
        frames[index + 1].size.width = left.width + right.width - newLeftWidth
        split.splitFractions = frames.map { Double($0.width / available) }
        layoutContent()
        library.setNeedsSave()
    }

    /// Dragging the sidebar's edge. Far enough to the left, it collapses
    /// like Arc's; dragging back out (still holding) opens it again.
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
        hidePanesForTransition()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        relayoutSoon()
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

    /// Where each visible pane should be, in screen coordinates (self-test).
    var expectedPaneFrames: [(Item, NSRect)] {
        guard let window else { return [] }
        return zip(visibleTabs, paneFrames(in: contentRect)).map { ($0, window.convertToScreen($1)) }
    }

    func toggleLibrary() {
        state.libraryVisible.toggle()
        if state.libraryVisible {
            state.sidebarVisible = true
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
            closeForGood(handingTabsTo: app.browsers.first { $0 !== self && !$0.isPrivate })
            return true
        }
        sender.orderOut(nil)
        return false
    }

    /// A private window's tabs end with it; a normal window's tabs stay open
    /// and |heir| takes over their pages.
    private func closeForGood(handingTabsTo heir: BrowserWindowController?) {
        archiveTimer?.invalidate()
        commandBar.hide()
        if isPrivate {
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

    func windowDidBecomeMain(_ notification: Notification) {
        (NSApp.delegate as? AppDelegate)?.browserBecameActive(self)
        applyTheme()
    }

    func windowDidResignMain(_ notification: Notification) {
        applyTheme()
    }

    // MARK: Selection

    /// Shows |item|: a tab, or the focused/first tab of a split. Folders
    /// toggle open and closed.
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
        case .tab:
            break
        }
        if peek.isOpen {
            peek.close()
        }
        if let space = library.space(containing: item), space !== state.space {
            switchSpace(to: space, restoring: false)
        }
        item.lastActiveAt = Date()
        state.activeItem = item
        state.space.activeItemID = item.id

        let tabs = item.split?.children ?? [item]
        for old in visibleTabs where !tabs.contains(where: { $0 === old }) {
            pictureInPictureIfPlaying(old)
            old.pane?.hide()
        }
        for tab in tabs {
            claim(tab)
        }
        for tab in tabs where tab.media?.pip == true {
            mediaCommand(tab, "exitpip")
        }
        visibleTabs = tabs
        for tab in tabs {
            ensurePane(for: tab)
        }
        layoutContent()
        if focus {
            item.pane?.focus()
        }
        library.setNeedsSave()
    }

    /// Clears the content area (no tab selected).
    private func showNothing() {
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
        let pane = OACPane(profile: profile, url: url)
        pane.delegate = self
        pane.cornerRadius = 8
        pane.activatesOnShow = !AppPaths.isSelfTest
        pane.toolbarVisible = library.settings.showChromeToolbar
        tab.pane = pane
        itemsByPane[ObjectIdentifier(pane)] = tab
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
        visibleTabs.removeAll { $0 === tab }
    }

    func switchSpace(to space: Space, restoring: Bool = true) {
        guard space !== state.space, !isPrivate else { return }
        state.space = space
        library.selectedSpaceID = space.id
        library.setNeedsSave()
        guard restoring else { return }
        if let id = space.activeItemID, let item = library.item(id: id),
           library.space(containing: item) === space || item.role == .favorites {
            select(item)
        } else {
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
        if isPrivate { return flattenVisible(state.space.today.items) }
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
        if inNewTab || state.activeItem == nil {
            openInNewTab(url)
        } else if let active = state.activeItem {
            navigate(active, to: url)
        }
    }

    func navigate(_ item: Item, to url: String) {
        let url = InternalURL.resolve(url)
        if let pane = item.pane {
            pane.loadURL(url)
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
        case .tab:
            break
        }
        let wasActive = state.activeItem === item
        let neighbor = wasActive ? neighbor(forClosing: item) : nil
        if item.role == .today {
            if !isPrivate { library.archive(item) }
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
    func closeActiveTab() {
        if let active = state.activeItem {
            close(active)
        } else {
            window?.performClose(nil)
        }
    }

    private func neighbor(forClosing item: Item) -> Item? {
        if let split = item.split {
            return split.children.first { $0 !== item }
        }
        if item.role == .today {
            let siblings = item.parent?.children ?? item.container?.items ?? []
            if let index = siblings.firstIndex(where: { $0 === item }) {
                if index + 1 < siblings.count { return siblings[index + 1] }
                if index > 0 { return siblings[index - 1] }
            }
        }
        // Otherwise the most recently used tab that is still open.
        return orderedTabs
            .filter { $0 !== item && $0.pane != nil }
            .max { $0.lastActiveAt < $1.lastActiveAt }
    }

    func reopenClosedTab() {
        guard !isPrivate, let archived = library.popArchived() else { return }
        let item = openInNewTab(archived.url)
        item.savedTitle = archived.title
    }

    func duplicate(_ item: Item) {
        guard item.kind == .tab else { return }
        openInNewTab(item.currentURL, after: item)
    }

    private func archiveInactiveTabs() {
        let hours = library.settings.archiveAfterHours
        guard hours > 0, !isPrivate else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        for space in library.spaces {
            // Not what any window shows right now.
            for tab in space.today.allTabs where tab.lastActiveAt < cutoff && tab !== state.activeItem
                && tab.pane?.isVisible != true {
                library.archive(tab)
                unload(tab)
                tab.detach()
            }
        }
        library.setNeedsSave()
    }

    // MARK: Pinning, favorites, folders, splits

    func pin(_ item: Item, into folder: Item? = nil) {
        guard !isPrivate else { return }
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
        guard item.kind == .tab, !isPrivate else { return }
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
    func newFolder(in parent: Item? = nil, name: String = "Neuer Ordner") -> Item {
        let folder = Item.folder(name)
        state.space.pinned.insert(folder, into: parent, at: 0)
        state.renamingItemID = folder.id
        library.setNeedsSave()
        return folder
    }

    func deleteFolder(_ folder: Item) {
        guard folder.kind == .folder else { return }
        let alert = NSAlert()
        alert.messageText = "Ordner „\(folder.displayTitle)“ löschen?"
        let tabs = folder.descendants.filter { $0.kind == .tab }.count
        alert.informativeText = tabs == 0 ? "Der Ordner ist leer." :
            "Die \(tabs) Tab\(tabs == 1 ? "" : "s") darin werden ebenfalls entfernt."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for tab in folder.descendants where tab.kind == .tab {
            if state.activeItem === tab { showNothing() }
            unload(tab)
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
    /// active split).
    func split(_ other: Item, with base: Item? = nil, leading: Bool = false) {
        guard let base = base ?? state.activeItem, base !== other, base.kind == .tab, other.kind == .tab else { return }
        if let split = base.split {
            guard split.children.count < 4 else { return }
            if let container = split.container {
                if other.split === split { other.detach() }
                container.insert(other, into: split, at: base.indexInParent + (leading ? 0 : 1))
            }
            split.splitFractions = []
        } else {
            guard let container = base.container else { return }
            let index = base.indexInParent
            let parent = base.parent
            let split = Item(kind: .split)
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
    func beginTabDrag(_ item: Item) {
        guard item.kind == .tab, let window, !visibleTabs.isEmpty else { return }
        let overlay = splitDropOverlay ?? SplitDropOverlay(browser: self)
        splitDropOverlay = overlay
        overlay.show(over: window.convertToScreen(contentRect), above: window)
        // Drag sessions run their own event loop; this fires once it is over.
        dragWatch?.invalidate()
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                self?.dragWatch?.invalidate()
                self?.splitDropOverlay?.hide()
            }
        }
    }

    /// A tab dropped on the left or right half of the page.
    func dropForSplit(_ item: Item, leading: Bool) {
        splitDropOverlay?.hide()
        var base = state.activeItem
        if base === item {
            // Dragging the shown tab itself: pair it with the last one used.
            base = orderedTabs.filter { $0 !== item && $0.pane != nil }.max { $0.lastActiveAt < $1.lastActiveAt }
        }
        guard let base, base.kind == .tab else {
            select(item)
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
        split(other, with: base, leading: leading)
    }

    /// Splits the active tab with a new empty tab and opens the command bar
    /// for it (Arc's ⌃⇧=).
    func splitWithNewTab() {
        guard let active = state.activeItem else {
            commandBar.show(mode: .newTab)
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
            container.insert(item, at: container.role == .today ? 0 : nil)
        }
        if item.role == .pinned || item.role == .favorites, item.kind == .tab {
            item.savedURL = item.currentURL
        }
        library.setNeedsSave()
    }

    enum DropTarget {
        case before(Item), after(Item), into(Item), end(Container)
    }

    // MARK: Actions on the active tab

    var activePane: OACPane? {
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

    func copyURL() {
        guard let url = state.activeItem?.currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func copyURLAsMarkdown() {
        guard let item = state.activeItem else { return }
        let title = item.displayTitle.replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[\(title)](\(item.currentURL))", forType: .string)
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
        layoutContent()
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

    private func item(for pane: OACPane) -> Item? {
        itemsByPane[ObjectIdentifier(pane)]
    }

    func registerPane(_ pane: OACPane, for item: Item) {
        itemsByPane[ObjectIdentifier(pane)] = item
    }

    func pane(_ pane: OACPane, titleDidChange title: String) {
        guard let item = item(for: pane) else { return }
        item.liveTitle = title
        if !isPrivate { history.updateTitle(url: item.currentURL, title: title) }
        library.setNeedsSave()
    }

    func pane(_ pane: OACPane, addressDidChange url: String) {
        guard let item = item(for: pane) else { return }
        if item.liveURL.map({ URL(string: $0)?.host() != URL(string: url)?.host() }) ?? false {
            item.media = nil  // Another site; its player reports anew.
        }
        item.liveURL = url
        if !isPrivate { history.recordVisit(url: url, title: nil) }
        library.setNeedsSave()
    }

    func pane(_ pane: OACPane, faviconDidChange favicon: NSImage) {
        guard let item = item(for: pane) else { return }
        item.favicon = favicon
        if !isPrivate { FaviconStore.shared.store(favicon, forURL: item.currentURL) }
    }

    func pane(_ pane: OACPane, loadingStateDidChange isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let item = item(for: pane) else { return }
        item.isLoading = isLoading
        item.canGoBack = canGoBack
        item.canGoForward = canGoForward
    }

    func pane(_ pane: OACPane, wantsNewTabWithURL url: String, background: Bool) {
        if !background, let source = item(for: pane), shouldPeek(url, from: source) {
            peek.open(url, from: source)
            return
        }
        openInNewTab(url, after: item(for: pane), select: !background)
    }

    func pane(_ pane: OACPane, shouldInterceptNavigationToURL url: String) -> Bool {
        guard let source = item(for: pane), shouldPeek(url, from: source) else { return false }
        peek.open(url, from: source)
        return true
    }

    /// Pinned tabs and favorites keep their page: links to other sites
    /// open in Peek.
    private func shouldPeek(_ url: String, from source: Item) -> Bool {
        library.settings.peek && (source.role == .pinned || source.role == .favorites)
            && url.hasPrefix("http") && !PeekController.sameSite(url, source.savedURL)
    }

    func paneDidBecomeActive(_ pane: OACPane) {
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
        layoutFocusRing(frames: paneFrames(in: contentRect))
    }

    func paneDidClose(_ pane: OACPane) {
        // The page closed itself (window.close()) or its browser went away.
        guard let item = item(for: pane) else { return }
        itemsByPane[ObjectIdentifier(pane)] = nil
        item.pane = nil
        close(item)
    }

    func pane(_ pane: OACPane, handleChromeCommand commandID: Int) -> Bool {
        guard commandID != Self.runningCommand, let command = OACChromeCommand(rawValue: commandID) else { return false }
        switch command {
        case .newTab:
            commandBar.show(mode: .newTab)
        case .focusLocation:
            commandBar.show(mode: .editURL)
        case .closeTab:
            closeActiveTab()
        case .restoreTab:
            reopenClosedTab()
        case .selectNextTab:
            selectRecentTab(1)
        case .selectPreviousTab:
            selectRecentTab(-1)
        case .selectLastTab:
            selectTab(at: -1)
        case .bookmarkThisTab:
            if let active = state.activeItem { togglePin(active) }
        case .savePage:
            toggleSidebar()
        case .duplicateTab:
            if let active = state.activeItem { duplicate(active) }
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

    func pane(_ pane: OACPane, mainFrameLoadStarted started: Bool, url: String) {
        // Boosts go in as early as the page allows and again once it is
        // complete (the style sheet is replaced, the script runs once).
        if let boost = BoostStore.shared.boost(for: url), boost.isEnabled,
           !boost.styleSheet.isEmpty || !boost.javaScript.isEmpty {
            pane.executeJavaScript(BoostStore.script(for: boost))
        }
    }

    /// A changed boost reaches the open tabs of its site at once.
    func applyBoost(_ boost: Boost) {
        for tab in allTabs where tab.pane != nil && boost.applies(to: tab.currentURL) {
            tab.pane?.executeJavaScript(BoostStore.script(for: boost))
        }
    }

    func editBoost() {
        guard let active = state.activeItem else { return }
        BoostPanelController.show(for: active, browser: self)
    }

    func pane(_ pane: OACPane, consoleMessage message: String, source: String, line: Int) {
        let zapPrefix = "__openarch_zap__"
        if message.hasPrefix(zapPrefix), let editor = BoostPanelController.current?.model, editor.item === item(for: pane) {
            if message.hasPrefix(zapPrefix + " ") {
                editor.zapped(String(message.dropFirst(zapPrefix.count + 1)))
            } else if message == zapPrefix + "-done" {
                editor.isZapping = false
            }
            return
        }
        let mediaPrefix = "__openarch_media__ "
        if message.hasPrefix(mediaPrefix), let item = item(for: pane) {
            item.media = try? JSONDecoder().decode(MediaState.self, from: Data(message.dropFirst(mediaPrefix.count).utf8))
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
    /// Every tab this window can show: the library's, or a private
    /// window's own.
    var allTabs: [Item] {
        isPrivate ? state.space.today.allTabs : library.allContainers.flatMap(\.allTabs)
    }

    var nowPlaying: Item? {
        allTabs
            .filter { tab in tab.pane != nil && tab.media != nil && !visibleTabs.contains { $0 === tab } }
            .max { lhs, rhs in
                if lhs.media?.playing != rhs.media?.playing { return rhs.media?.playing == true }
                return lhs.lastActiveAt < rhs.lastActiveAt
            }
    }

    /// "toggle", "pip" or "exitpip", carried out by the built-in extension.
    func mediaCommand(_ item: Item, _ command: String) {
        item.pane?.executeJavaScript("document.dispatchEvent(new CustomEvent('openarch-media', {detail: '\(command)'}))",
                                     userGesture: true)
    }

    /// Like Arc: leaving a tab with a video playing (with sound) keeps the
    /// video going in picture-in-picture.
    private func pictureInPictureIfPlaying(_ item: Item) {
        guard library.settings.autoPictureInPicture, let media = item.media,
              media.playing, media.video, media.audible, !media.pip else { return }
        mediaCommand(item, "pip")
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
    var onDrag: ((Int, CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        onDrag?(index, point.x - BrowserWindowController.splitGap / 2)
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
