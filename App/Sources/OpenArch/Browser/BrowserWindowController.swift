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

    /// Tabs whose panes are currently shown, left to right.
    private var visibleTabs: [Item] = []
    private var itemsByPane: [ObjectIdentifier: Item] = [:]
    private let rootView = BrowserRootView()
    private var sidebarHost: NSHostingView<SidebarView>!
    private var emptyHost: NSHostingView<EmptyContentView>!
    private var dividers: [SplitDividerView] = []
    private let focusRing = FocusRingView()
    private let sidebarHandle = SplitDividerView()
    private(set) lazy var commandBar = CommandBarController(browser: self)
    private(set) var sidebarSwipe: SidebarSwipe?
    private var archiveTimer: Timer?

    static let contentInset: CGFloat = 8
    static let splitGap: CGFloat = 8

    init(library: Library, history: History) {
        self.library = library
        self.history = history
        let space = library.space(id: library.selectedSpaceID) ?? library.spaces[0]
        state = BrowserState(space: space)

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

        window.setFrameAutosaveName(AppPaths.isSelfTest ? "OpenArchSelfTestWindow" : "OpenArchBrowserWindow")
        if AppPaths.isSelfTest || !window.setFrameUsingName("OpenArchBrowserWindow") {
            window.center()
        }
        applyTheme()
        observeChanges()
        sidebarSwipe = SidebarSwipe(browser: self)
        OACPane.externalTabHandler = { [weak self] url in
            MainActor.assumeIsolated { _ = self?.openInNewTab(url) }
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

    private func applyTheme() {
        let theme = SpaceTheme(hex: state.space.colorHex)
        window?.backgroundColor = theme.base
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        focusRing.color = theme.isDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.35)
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

    /// The red button hides the window; tabs keep running and the Dock
    /// icon brings it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide the panes first: ordering out the window would detach them in
        // a way they cannot simply be ordered back from.
        hidePanesForTransition()
        sender.orderOut(nil)
        library.save()
        return false
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
        if let space = library.space(containing: item), space !== state.space {
            switchSpace(to: space, restoring: false)
        }
        item.lastActiveAt = Date()
        state.activeItem = item
        state.space.activeItemID = item.id

        let tabs = item.split?.children ?? [item]
        for old in visibleTabs where !tabs.contains(where: { $0 === old }) {
            old.pane?.hide()
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

    private func ensurePane(for tab: Item) {
        guard tab.pane == nil else { return }
        let profile = library.profile(for: tab, in: state.space)
        let url = tab.currentURL.isEmpty ? "about:blank" : tab.currentURL
        let pane = OACPane(profile: profile.chromium, url: url)
        pane.delegate = self
        pane.cornerRadius = 8
        pane.activatesOnShow = !AppPaths.isSelfTest
        pane.toolbarVisible = library.settings.showChromeToolbar
        tab.pane = pane
        itemsByPane[ObjectIdentifier(pane)] = tab
    }

    /// Closes |tab|'s pane but keeps the item (pinned tabs, favorites).
    func unload(_ tab: Item) {
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
        visibleTabs.removeAll { $0 === tab }
    }

    func switchSpace(to space: Space, restoring: Bool = true) {
        guard space !== state.space else { return }
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
            library.archive(item)
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

    func closeActiveTab() {
        if let active = state.activeItem {
            close(active)
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
        guard let archived = library.popArchived() else { return }
        let item = openInNewTab(archived.url)
        item.savedTitle = archived.title
    }

    func duplicate(_ item: Item) {
        guard item.kind == .tab else { return }
        openInNewTab(item.currentURL, after: item)
    }

    private func archiveInactiveTabs() {
        let hours = library.settings.archiveAfterHours
        guard hours > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        for space in library.spaces {
            for tab in space.today.allTabs where tab.lastActiveAt < cutoff && tab !== state.activeItem
                && !visibleTabs.contains(where: { $0 === tab }) {
                library.archive(tab)
                unload(tab)
                tab.detach()
            }
        }
        library.setNeedsSave()
    }

    // MARK: Pinning, favorites, folders, splits

    func pin(_ item: Item, into folder: Item? = nil) {
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
        guard item.kind == .tab else { return }
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
        for container in library.allContainers {
            for tab in container.allTabs {
                tab.pane?.toolbarVisible = visible
            }
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

    func pane(_ pane: OACPane, titleDidChange title: String) {
        guard let item = item(for: pane) else { return }
        item.liveTitle = title
        history.updateTitle(url: item.currentURL, title: title)
        library.setNeedsSave()
    }

    func pane(_ pane: OACPane, addressDidChange url: String) {
        guard let item = item(for: pane) else { return }
        item.liveURL = url
        history.recordVisit(url: url, title: nil)
        library.setNeedsSave()
    }

    func pane(_ pane: OACPane, faviconDidChange favicon: NSImage) {
        guard let item = item(for: pane) else { return }
        item.favicon = favicon
        FaviconStore.shared.store(favicon, forURL: item.currentURL)
    }

    func pane(_ pane: OACPane, loadingStateDidChange isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let item = item(for: pane) else { return }
        item.isLoading = isLoading
        item.canGoBack = canGoBack
        item.canGoForward = canGoForward
    }

    func pane(_ pane: OACPane, wantsNewTabWithURL url: String, background: Bool) {
        openInNewTab(url, after: item(for: pane), select: !background)
    }

    func paneDidBecomeActive(_ pane: OACPane) {
        guard let item = item(for: pane), item !== state.activeItem,
              visibleTabs.contains(where: { $0 === item }) else { return }
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
        case .newWindow, .closeWindow, .showBookmarkBar:
            break  // One window with OpenArch's own sidebar.
        default:
            if (OACChromeCommand.selectTab0.rawValue...OACChromeCommand.selectTab7.rawValue).contains(commandID) {
                selectTab(at: commandID - OACChromeCommand.selectTab0.rawValue)
                return true
            }
            return false
        }
        return true
    }

    func pane(_ pane: OACPane, consoleMessage message: String, source: String, line: Int) {
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
