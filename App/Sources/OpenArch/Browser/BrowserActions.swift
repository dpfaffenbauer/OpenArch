import AppKit
import OpenArchCore
import UniformTypeIdentifiers

/// Sidebar actions: drag and drop, spaces, tidying up.
extension BrowserWindowController {
    /// Handles a drop of a sidebar item (its id as text) or a link: from a
    /// page, another app, or a file from Finder.
    @discardableResult
    func handleDrop(_ providers: [NSItemProvider], target: DropTarget) -> Bool {
        loadDroppedString(providers) { string in
            if let id = UUID(uuidString: string), let item = self.library.item(id: id) {
                self.move(item, to: target)
            } else if let url = Self.droppedLink(string) {
                let item = Item.tab(url: url)
                self.state.space.today.insert(item, at: 0)
                self.move(item, to: target)
                self.select(item)
            }
        }
    }

    @discardableResult
    func handleDrop(_ providers: [NSItemProvider], toSpace space: Space) -> Bool {
        loadDroppedString(providers) { self.drop($0, toSpace: space) }
    }

    /// A tab dropped on a space's icon moves there; a link opens there.
    func drop(_ string: String, toSpace space: Space) {
        if let id = UUID(uuidString: string), let item = library.item(id: id) {
            moveToSpace(item, space)
        } else if let url = Self.droppedLink(string) {
            switchSpace(to: space)
            openInNewTab(url)
        }
    }

    /// A dropped string worth a tab: a web or file address, or one without
    /// its scheme ("example.com/page"). Other text is not.
    static func droppedLink(_ string: String) -> String? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) {
            return text
        }
        guard !text.isEmpty, !text.contains(where: \.isWhitespace), let url = URL(string: "https://" + text),
              url.host()?.contains(".") == true else { return nil }
        return url.absoluteString
    }

    private func loadDroppedString(_ providers: [NSItemProvider], _ handler: @escaping @MainActor (String) -> Void) -> Bool {
        let wrapped: @MainActor (String) -> Void = { string in
            // A sidebar item landed in a window: no separate window for it.
            if UUID(uuidString: string) != nil { BrowserWindowController.tabDropHandled = true }
            handler(string)
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.openArchTab.identifier) }) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.openArchTab.identifier) { data, _ in
                guard let string = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
                Task { @MainActor in wrapped(string) }
            }
            BrowserWindowController.tabDropHandled = true
            return true
        }
        // Links from pages, Safari, Mail and files from Finder come as URLs,
        // often without any text.
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSURL.self) }) {
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let string = (object as? NSURL)?.absoluteString else { return }
                Task { @MainActor in wrapped(string) }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = (object as? NSString).map(String.init) else { return }
            Task { @MainActor in wrapped(string) }
        }
        return true
    }

    /// Takes over a pane that lives elsewhere (Little OpenArch) as a new
    /// today tab, without reloading the page.
    func adopt(_ pane: OACPane, into space: Space, url: String, title: String, favicon: NSImage?) {
        let item = Item.tab(url: url, title: title)
        item.pane = pane
        item.liveURL = url
        item.liveTitle = title
        item.favicon = favicon
        pane.delegate = self
        pane.cornerRadius = 8
        pane.activatesOnShow = !AppPaths.isSelfTest
        pane.toolbarVisible = library.settings.showChromeToolbar
        registerPane(pane, for: item)
        space.today.insert(item, at: 0)
        select(item)
        library.setNeedsSave()
    }

    func restoreArchived(_ tab: ArchivedTab) {
        library.removeArchived(tab)
        restore(tab)
    }

    /// An archived tab comes back where it was: in its space, at its place
    /// under the line.
    func restore(_ archived: ArchivedTab) {
        let item = Item.tab(url: archived.url, title: archived.title)
        let space = isPrivate ? state.space : (library.space(id: archived.spaceID) ?? state.space)
        space.today.insert(item, at: min(archived.index ?? 0, space.today.items.count))
        select(item)
        library.setNeedsSave()
    }

    func moveToSpace(_ item: Item, _ space: Space) {
        guard space !== state.space || item.role == .favorites else { return }
        let anchor = item.split ?? item
        let tabs = anchor.kind == .tab ? [anchor] : anchor.descendants.filter { $0.kind == .tab }
        let sameProfile = space.profileID == library.profile(for: item, in: state.space).id
        let wasShown = tabs.contains { $0 === state.activeItem } || anchor === state.activeItem
        for tab in tabs where !sameProfile {
            tab.savedURL = tab.currentURL
            unload(tab)
        }
        if anchor.role == .pinned || anchor.kind == .folder {
            space.pinned.insert(anchor)
        } else {
            space.today.insert(anchor, at: 0)
        }
        if wasShown {
            for tab in tabs { tab.pane?.hide() }
            if let next = orderedTabs.filter({ $0.pane != nil }).max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
                select(next)
            } else {
                state.activeItem = nil
                layoutContent()
            }
        }
        library.setNeedsSave()
    }

    func deletePinned(_ item: Item) {
        let anchor = item.split ?? item
        for tab in anchor.kind == .tab ? [anchor] : anchor.descendants where tab.kind == .tab {
            library.archive(tab)
            if state.activeItem === tab { close(tab) }
            unload(tab)
        }
        anchor.detach()
        layoutContent()
        library.setNeedsSave()
    }

    /// Archives every today tab of the current space ("Aufräumen"). Agent
    /// chats stay: there is no archive to bring them back from.
    func clearToday() {
        let tabs = state.space.today.allTabs
        let activeWasToday = tabs.contains { $0 === state.activeItem }
        for tab in tabs {
            if !isPrivate { library.archive(tab) }
            unload(tab)
        }
        for item in state.space.today.items where item.kind != .agent {
            item.detach()
        }
        if activeWasToday {
            state.activeItem = nil
            state.space.activeItemID = nil
        }
        layoutContent()
        library.setNeedsSave()
    }

    func addSpace() {
        let used = Set(library.spaces.map(\.colorHex))
        let color = spaceColorPresets.first { !used.contains($0) } ?? spaceColorPresets[library.spaces.count % spaceColorPresets.count]
        let space = library.addSpace(name: "Neuer Space", icon: "star.fill", colorHex: color, profileID: state.space.profileID)
        switchSpace(to: space)
        state.editingSpaceID = space.id
    }

    func deleteSpace(_ space: Space) {
        guard library.spaces.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Space „\(space.name)“ löschen?"
        alert.informativeText = "Angeheftete Tabs, Ordner und offene Tabs dieses Space werden entfernt. Die Daten des Profils (Logins, Cookies) bleiben erhalten."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if space === state.space, let other = library.spaces.first(where: { $0 !== space }) {
            switchSpace(to: other)
        }
        for tab in space.pinned.allTabs + space.today.allTabs {
            unload(tab)
        }
        library.removeSpace(space)
        layoutContent()
    }

    /// Moves a space to another profile. Its open tabs reload in the new one.
    func setProfile(_ profileID: String, for space: Space) {
        guard space.profileID != profileID else { return }
        for tab in space.pinned.allTabs + space.today.allTabs {
            tab.savedURL = tab.role == .today ? tab.currentURL : tab.savedURL
            unload(tab)
        }
        space.profileID = profileID
        if space === state.space {
            if let active = state.activeItem, library.space(containing: active) === space || active.role == .favorites {
                state.activeItem = nil
                select(active)
            } else {
                layoutContent()
            }
        }
        library.setNeedsSave()
    }
}

/// Importing.
extension BrowserWindowController {
    /// Closes every pane before the library's contents are replaced.
    func prepareForLibraryReplacement() {
        for container in library.allContainers {
            for tab in container.allTabs {
                unload(tab)
            }
            // An import replaces the sidebar: its agent chats go with it.
            for item in container.allItems where item.kind == .agent {
                item.agentSession?.discard()
                AgentSession.deleteTranscript(item.id)
            }
        }
        state.activeItem = nil
        layoutContent()
    }

    func libraryWasReplaced() {
        let space = library.space(id: library.selectedSpaceID) ?? library.spaces[0]
        state.space = space
        library.selectedSpaceID = space.id
        if let id = space.activeItemID, let item = library.item(id: id) {
            select(item)
        } else {
            layoutContent()
        }
    }

    /// A pinned folder with a Web Store link per Arc extension.
    func addExtensionFolder(_ extensions: [ArcExtensions.Extension]) {
        let folder = Item.folder("Extensions aus Arc",
                                 children: extensions.map { Item.tab(url: $0.storeURL, title: $0.name) })
        state.space.pinned.insert(folder, at: 0)
        library.setNeedsSave()
        if let first = folder.children.first {
            select(first)
        }
    }
}
