import AppKit
import OpenArchCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    let browser: BrowserWindowController
    /// Shown over the page while the sidebar is collapsed.
    var floating = false

    var body: some View {
        let offset = browser.state.swipeOffset
        Group {
            if browser.state.libraryVisible {
                LibraryView(browser: browser)
            } else {
                sidebar
            }
        }
        .ignoresSafeArea()
        // Follows the fingers during a swipe between spaces.
        .offset(x: offset)
        .opacity(1 - min(0.6, abs(offset) / 220))
        // Clip the swipe to the sidebar, but up into the transparent title
        // bar: plain .clipped() cut off the top row next to the window buttons.
        .mask { Rectangle().ignoresSafeArea() }
    }

    private var sidebar: some View {
        let state = browser.state
        let space = state.space
        let theme = SpaceTheme(hex: space.colorHex)
        return VStack(alignment: .leading, spacing: 0) {
            SidebarTopBar(browser: browser, theme: theme, floating: floating)
            if browser.library.settings.showSidebarAddress {
                AddressPill(browser: browser, theme: theme)
                    .padding(.bottom, 8)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    if browser.isPrivate {
                        PrivateHeader(theme: theme)
                    } else {
                        FavoritesGrid(browser: browser, theme: theme)
                        SpaceHeader(browser: browser, space: space, theme: theme)
                        PinnedSection(browser: browser, space: space, theme: theme)
                    }
                    TodaySection(browser: browser, space: space, theme: theme)
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            if let playing = browser.nowPlaying {
                MediaCard(browser: browser, item: playing, theme: theme)
            }
            if case .ready = Updater.shared.phase {
                UpdateBanner(theme: theme)
            }
            if browser.isPrivate {
                Spacer().frame(height: 12)
            } else {
                SpaceBar(browser: browser, theme: theme)
            }
        }
        .padding(.horizontal, 8)
        .ignoresSafeArea()
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.colorScheme)
        .tint(theme.foreground)
    }
}

/// A private window has no spaces, favorites or pinned tabs, only this.
private struct PrivateHeader: View {
    let theme: SpaceTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Privates Fenster", systemImage: "eyeglasses")
                .font(.system(size: 13, weight: .semibold))
            Text("Kein Verlauf, keine Cookies auf der Festplatte. Alles ist weg, sobald du das Fenster schließt.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tile))
    }
}

/// Media playing in another tab: play/pause, picture-in-picture, sound, and
/// a click on the card goes to the tab.
private struct MediaCard: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let media = item.media ?? MediaState()
        HStack(spacing: 8) {
            Button { browser.select(item) } label: {
                HStack(spacing: 9) {
                    FaviconView(item: item, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.title.isEmpty ? item.displayTitle : media.title)
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(media.artist.isEmpty ? CommandBarModel.shortURL(item.currentURL) : media.artist)
                            .font(.system(size: 11)).opacity(0.65).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zum Tab wechseln")
            IconButton(symbol: media.playing ? "pause.fill" : "play.fill", help: media.playing ? "Pause" : "Abspielen") {
                browser.mediaCommand(item, "toggle")
            }
            if media.video {
                IconButton(symbol: media.pip ? "pip.exit" : "pip.enter", help: "Bild-in-Bild") {
                    browser.mediaCommand(item, media.pip ? "exitpip" : "pip")
                }
            }
            IconButton(symbol: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       help: item.isMuted ? "Ton einschalten" : "Stummschalten") {
                browser.toggleMute(item)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? theme.tileHover : theme.tile))
        .onHover { hovering = $0 }
        .padding(.top, 6)
    }
}

/// A downloaded update, like Arc's "Restart to update" at the bottom.
private struct UpdateBanner: View {
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        Button { Updater.shared.installAndRelaunch() } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                Text("Update bereit").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("Neu starten").font(.system(size: 12, weight: .medium)).opacity(0.75)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? theme.tileHover : theme.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Installiert die neue Version und startet OpenArch neu. Tabs bleiben erhalten.")
        .padding(.top, 6)
    }
}

// MARK: - Top

private struct SidebarTopBar: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    var floating = false

    var body: some View {
        let active = browser.state.activeItem
        HStack(spacing: 0) {
            // Room for the window buttons, which a floating sidebar sits below.
            Spacer().frame(width: floating ? 4 : 72)
            IconButton(symbol: "sidebar.left", help: floating ? "Sidebar anheften (⌘S)" : "Sidebar ausblenden (⌘S)") {
                browser.toggleSidebar()
            }
            if OACEngine.remoteDebuggingPort > 0 {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.leading, 4)
                    .help("KI-Steuerung aktiv: Chrome DevTools Protocol auf 127.0.0.1:\(OACEngine.remoteDebuggingPort)")
            }
            Spacer()
            IconButton(symbol: "arrow.left", help: "Zurück (⌘[)") { browser.goBack() }
                .disabled(!(active?.canGoBack ?? false))
            IconButton(symbol: "arrow.right", help: "Vorwärts (⌘])") { browser.goForward() }
                .disabled(!(active?.canGoForward ?? false))
            IconButton(symbol: active?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Neu laden (⌘R)") {
                if active?.isLoading == true { browser.activePane?.stopLoading() } else { browser.reload() }
            }
            .disabled(active == nil)
        }
        .frame(height: 30)
        .padding(.bottom, 6)
    }
}

struct IconButton: View {
    let symbol: String
    var help: String = ""
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering && isEnabled ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 0.75 : 0.3)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct AddressPill: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let active = browser.state.activeItem
        let url = active.flatMap { URL(string: $0.currentURL) }
        HStack(spacing: 6) {
            if let url, url.scheme == "https" {
                Image(systemName: "lock.fill").font(.system(size: 9)).opacity(0.5)
            }
            Text(url.map(displayHost) ?? "Suchen oder URL eingeben")
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .opacity(url == nil ? 0.55 : 0.9)
            Spacer(minLength: 4)
            if hovering, active != nil {
                Button { browser.copyURL() } label: {
                    Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .opacity(0.7)
                .help("URL kopieren (⌘⇧C)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.tile))
        .contentShape(Rectangle())
        .onTapGesture { browser.commandBar.show(mode: .editURL) }
        .onHover { hovering = $0 }
        .help("URL bearbeiten (⌘L)")
    }

    private func displayHost(_ url: URL) -> String {
        if url.scheme == "chrome" { return InternalURL.display(url.absoluteString) }
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    @State private var dropTargeted = false

    var body: some View {
        let favorites = browser.library.profile(id: browser.state.space.profileID).favorites
        let columns = Array(repeating: GridItem(.flexible(), spacing: 9), count: favorites.items.count > 9 ? 4 : 3)
        Group {
            if favorites.items.isEmpty {
                Text("Tabs hierher ziehen, um sie als Favoriten oben zu halten")
                    .font(.system(size: 11))
                    .opacity(0.5)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.tile, style: StrokeStyle(lineWidth: 1, dash: [4])))
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(favorites.items) { item in
                        FavoriteTile(browser: browser, item: item, theme: theme)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? theme.hover : .clear))
        .onDrop(of: [.openArchTab, .plainText], isTargeted: $dropTargeted) { providers in
            browser.handleDrop(providers, target: .end(favorites))
        }
    }
}

private struct FavoriteTile: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let isActive = browser.state.activeItem === item
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 11)
                .fill(isActive ? theme.selection : (hovering ? theme.tileHover : theme.tile))
            FaviconView(item: item, size: 17)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    AudioButton(browser: browser, item: item, size: 9)
                        .padding(4)
                }
            if item.pane != nil {
                Capsule().fill(theme.foreground.opacity(0.5)).frame(width: 12, height: 2.5).padding(.bottom, 4)
            }
        }
        .frame(height: 46)
        .contentShape(Rectangle())
        .onTapGesture { browser.select(item) }
        .onHover { hovering = $0 }
        .help(item.displayTitle)
        .onDrag {
            browser.beginTabDrag(item)
            return tabDragProvider(item)
        }
        .onDrop(of: [.openArchTab, .plainText], isTargeted: nil) { providers in
            browser.handleDrop(providers, target: .before(item))
        }
        .contextMenu {
            Button("Neu laden") { item.pane?.reload() }.disabled(item.pane == nil)
            Button("Schließen") { browser.close(item) }.disabled(item.pane == nil)
            Button("Zur gespeicherten URL") { browser.goToSavedURL(item) }.disabled(!item.hasNavigatedAway)
            Button("Aktuelle URL speichern") { browser.resetSavedURL(item) }.disabled(item.liveURL == nil)
            Divider()
            Button("In Split View öffnen") { browser.split(item) }.disabled(browser.state.activeItem == nil || browser.state.activeItem === item)
            Button("URL kopieren") { copy(item.currentURL) }
            Divider()
            Button("Aus Favoriten entfernen") { browser.removeFromFavorites(item) }
        }
    }
}

// MARK: - Space header

private struct SpaceHeader: View {
    let browser: BrowserWindowController
    let space: Space
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let editing = Binding(
            get: { browser.state.editingSpaceID == space.id },
            set: { browser.state.editingSpaceID = $0 ? space.id : nil })
        HStack(spacing: 10) {
            SpaceIcon(icon: space.icon, size: 12)
                .frame(width: 16)
            Text(space.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Space bearbeiten …") { editing.wrappedValue = true }
                Button("Neuer Ordner") { browser.newFolder() }
                Divider()
                Button("Neuer Space") { browser.addSpace() }
                Button("Space löschen …") { browser.deleteSpace(space) }
                    .disabled(browser.library.spaces.count < 2)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 0.8 : 0)
        }
        .foregroundStyle(theme.secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { editing.wrappedValue = true }
        .popover(isPresented: editing, arrowEdge: .trailing) {
            SpaceEditor(browser: browser, space: space)
        }
    }
}

// MARK: - Pinned

private struct PinnedSection: View {
    let browser: BrowserWindowController
    let space: Space
    let theme: SpaceTheme
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(space.pinned.items) { item in
                SidebarNode(browser: browser, item: item, theme: theme, depth: 0)
            }
            Color.clear.frame(height: space.pinned.items.isEmpty ? 30 : 8)
                .overlay {
                    if space.pinned.items.isEmpty {
                        Text("Tabs hierher ziehen zum Anheften").font(.system(size: 11)).opacity(0.45)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(dropTargeted ? theme.hover : .clear))
                .onDrop(of: [.openArchTab, .plainText], isTargeted: $dropTargeted) { providers in
                    browser.handleDrop(providers, target: .end(space.pinned))
                }
        }
    }
}

/// A row and, for open folders, its children.
private struct SidebarNode: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    let depth: Int

    var body: some View {
        switch item.kind {
        case .folder:
            FolderRow(browser: browser, item: item, theme: theme, depth: depth)
            if item.isExpanded {
                ForEach(item.children) { child in
                    SidebarNode(browser: browser, item: child, theme: theme, depth: depth + 1)
                }
            }
        case .split:
            SplitRow(browser: browser, item: item, theme: theme, depth: depth)
        case .tab:
            TabRow(browser: browser, item: item, theme: theme, depth: depth)
        }
    }
}

private struct FolderRow: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    let depth: Int
    @State private var hovering = false
    @State private var dropZone: DropZone?

    var body: some View {
        HStack(spacing: 10) {
            FolderIcon(icon: item.icon, isOpen: item.isExpanded)
            RenamableTitle(browser: browser, item: item)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 4)
        }
        .rowStyle(depth: depth, isActive: false, hovering: hovering, theme: theme, dropZone: dropZone)
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { browser.select(item) } }
        .onHover { hovering = $0 }
        .onDrag { tabDragProvider(item) }
        .onDrop(of: [.openArchTab, .plainText], delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: true, zone: $dropZone))
        .contextMenu {
            Button("Umbenennen") { browser.state.renamingItemID = item.id }
            Button("Neuer Unterordner") { browser.newFolder(in: item) }
            Button("Alle öffnen") {
                for tab in item.descendants where tab.kind == .tab { browser.select(tab, focus: false) }
            }
            Divider()
            Button("Ordner löschen …") { browser.deleteFolder(item) }
        }
    }
}

private struct TabRow: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    let depth: Int
    @State private var hovering = false
    @State private var dropZone: DropZone?

    var body: some View {
        let isActive = browser.state.activeItem === item
        HStack(spacing: 10) {
            FaviconView(item: item, size: 16)
            AudioButton(browser: browser, item: item)
            if item.hasNavigatedAway {
                Text("/").font(.system(size: 14)).opacity(0.5).padding(.horizontal, -4)
            }
            RenamableTitle(browser: browser, item: item)
                .font(.system(size: 14))
            Spacer(minLength: 2)
            if hovering {
                if item.hasNavigatedAway {
                    SmallButton(symbol: "arrow.uturn.backward", help: "Zur angehefteten URL") { browser.goToSavedURL(item) }
                }
                if item.role == .today || item.pane != nil {
                    SmallButton(symbol: item.role == .today ? "xmark" : "minus", help: item.role == .today ? "Schließen (⌘W)" : "Entladen") {
                        browser.close(item)
                    }
                }
            } else if item.isLoading {
                ProgressView().controlSize(.mini).opacity(0.6)
            }
        }
        .rowStyle(depth: depth, isActive: isActive, hovering: hovering, theme: theme, dropZone: dropZone)
        .onTapGesture { browser.select(item) }
        .onHover { hovering = $0 }
        .onDrag {
            browser.beginTabDrag(item)
            return tabDragProvider(item)
        }
        .onDrop(of: [.openArchTab, .plainText], delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: false, zone: $dropZone))
        .contextMenu { TabContextMenu(browser: browser, item: item) }
        .help(item.currentURL)
    }
}

private struct SplitRow: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    let depth: Int
    @State private var hovering = false
    @State private var dropZone: DropZone?

    var body: some View {
        let isShown = browser.state.shownItem === item
        HStack(spacing: 4) {
            ForEach(item.children) { child in
                let isActive = browser.state.activeItem === child
                HStack(spacing: 7) {
                    FaviconView(item: child, size: 15)
                    AudioButton(browser: browser, item: child, size: 10)
                    Text(child.displayTitle).font(.system(size: 13)).lineLimit(1)
                }
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(isActive && isShown ? theme.foreground.opacity(0.14) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { browser.select(child) }
                .contextMenu { TabContextMenu(browser: browser, item: child) }
            }
        }
        .rowStyle(depth: depth, isActive: isShown, hovering: hovering, theme: theme, dropZone: dropZone, horizontalPadding: 3)
        .onHover { hovering = $0 }
        .onDrag { tabDragProvider(item) }
        .onDrop(of: [.openArchTab, .plainText], delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: false, zone: $dropZone))
        .help("Split View")
    }
}

private struct TabContextMenu: View {
    let browser: BrowserWindowController
    let item: Item

    var body: some View {
        Button("Neu laden") { item.pane?.reload() }.disabled(item.pane == nil)
        if item.isAudible || item.isMuted {
            Button(item.isMuted ? "Ton einschalten" : "Stummschalten") { browser.toggleMute(item) }
        }
        Button("Duplizieren") { browser.duplicate(item) }
        Button("Umbenennen") { browser.state.renamingItemID = item.id }
        Button("URL kopieren") { copy(item.currentURL) }
        Divider()
        if item.role == .today {
            Button("Anheften (⌘D)") { browser.togglePin(item) }
        } else if item.role == .pinned {
            Button("Lösen") { browser.togglePin(item) }
            Button("Zur angehefteten URL") { browser.goToSavedURL(item) }.disabled(!item.hasNavigatedAway)
            Button("Aktuelle URL anheften") { browser.resetSavedURL(item) }.disabled(item.liveURL == nil)
        }
        Button("Zu Favoriten hinzufügen") { browser.addToFavorites(item) }
        Menu("In Ordner verschieben") {
            ForEach(browser.state.space.pinned.allItems.filter { $0.kind == .folder }) { folder in
                Button(folderPath(folder)) { browser.pin(item, into: folder) }
            }
            Divider()
            Button("Neuer Ordner") { browser.pin(item, into: browser.newFolder()) }
        }
        Divider()
        if item.split != nil {
            Button("Split View aufheben") { browser.unsplit(item) }
        } else {
            Button("Split View mit aktuellem Tab") { browser.split(item) }
                .disabled(browser.state.activeItem == nil || browser.state.activeItem === item)
        }
        Menu("In Space verschieben") {
            ForEach(browser.library.spaces.filter { $0 !== browser.state.space }) { space in
                Button(space.name) { browser.moveToSpace(item, space) }
            }
        }
        Divider()
        Button(item.role == .today ? "Schließen" : "Entladen") { browser.close(item) }
            .disabled(item.role != .today && item.pane == nil)
        if item.role == .pinned {
            Button("Löschen") { browser.deletePinned(item) }
        }
    }

    private func folderPath(_ folder: Item) -> String {
        var names = [folder.displayTitle]
        var current = folder.parentFolder
        while let parent = current {
            names.insert(parent.displayTitle, at: 0)
            current = parent.parentFolder
        }
        return names.joined(separator: " › ")
    }
}

// MARK: - Today

private struct TodaySection: View {
    let browser: BrowserWindowController
    let space: Space
    let theme: SpaceTheme
    @State private var hoveringHeader = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Rectangle().fill(theme.foreground.opacity(0.18)).frame(height: 1)
                if hoveringHeader, !space.today.items.isEmpty {
                    Button("Aufräumen") { browser.clearToday() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.6)
                        .help("Alle Tabs unter dem Strich archivieren")
                }
            }
            .frame(height: 16)
            .padding(.horizontal, 8)
            .onHover { hoveringHeader = $0 }
            .onDrop(of: [.openArchTab, .plainText], isTargeted: $dropTargeted) { providers in
                browser.handleDrop(providers, target: .end(space.today))
            }

            NewTabRow(browser: browser, theme: theme)
            ForEach(space.today.items) { item in
                SidebarNode(browser: browser, item: item, theme: theme, depth: 0)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(dropTargeted ? theme.hover : .clear))
    }
}

private struct NewTabRow: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 16)
            Text("Neuer Tab").font(.system(size: 14))
            Spacer()
            if hovering {
                Text("⌘T").font(.system(size: 11)).opacity(0.6)
            }
        }
        .foregroundStyle(theme.secondary)
        .rowStyle(depth: 0, isActive: false, hovering: hovering, theme: theme, dropZone: nil)
        .onTapGesture { browser.commandBar.show(mode: .newTab) }
        .onHover { hovering = $0 }
    }
}

// MARK: - Spaces

private struct SpaceBar: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "books.vertical", help: "Bibliothek: Medien, Downloads, Spaces, Archiv (⌥⌘B)") {
                browser.toggleLibrary()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(Array(browser.library.spaces.enumerated()), id: \.element.id) { index, space in
                        SpaceButton(browser: browser, space: space, index: index, theme: theme)
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            Menu {
                Button("Neuer Space") { browser.addSpace() }
                Button("Neuer Ordner") { browser.newFolder() }
                Divider()
                Button("Aus Arc importieren …") { (NSApp.delegate as? AppDelegate)?.importFromArc(nil) }
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(0.75)
            .help("Neuer Space")
        }
        .frame(height: 40)
    }
}

private struct SpaceButton: View {
    let browser: BrowserWindowController
    let space: Space
    let index: Int
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let isCurrent = browser.state.space === space
        SpaceIcon(icon: space.icon, size: 12)
            .frame(width: 28, height: 28)
            .background(Circle().fill(isCurrent ? theme.selection : (hovering ? theme.hover : .clear)))
            .opacity(isCurrent ? 1 : 0.6)
            .contentShape(Circle())
            .onTapGesture { browser.switchSpace(to: space) }
            .onHover { hovering = $0 }
            .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
            .onDrop(of: [.openArchTab, .plainText], isTargeted: nil) { providers in
                browser.handleDrop(providers, toSpace: space)
            }
            .contextMenu {
                Button("Space bearbeiten …") {
                    browser.switchSpace(to: space)
                    browser.state.editingSpaceID = space.id
                }
                Button("Nach links") { browser.library.moveSpace(space, by: -1) }
                Button("Nach rechts") { browser.library.moveSpace(space, by: 1) }
                Divider()
                Button("Space löschen …") { browser.deleteSpace(space) }.disabled(browser.library.spaces.count < 2)
            }
    }
}

// MARK: - Building blocks

struct FaviconView: View {
    let item: Item
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = item.favicon ?? FaviconStore.shared.image(forURL: item.currentURL)
                ?? FaviconStore.shared.image(forURL: item.savedURL) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if item.currentURL.hasPrefix("chrome://") {
                Image(systemName: "gearshape.fill").resizable().aspectRatio(contentMode: .fit).opacity(0.7)
            } else {
                let letter = item.host.replacingOccurrences(of: "www.", with: "").first.map { String($0).uppercased() } ?? "•"
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(Color.primary.opacity(0.15))
                    .overlay(Text(letter).font(.system(size: size * 0.6, weight: .bold)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

private struct SmallButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0.7)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A title that turns into a text field while the item is being renamed.
private struct RenamableTitle: View {
    let browser: BrowserWindowController
    let item: Item
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if browser.state.renamingItemID == item.id {
            TextField("Name", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear {
                    text = item.customTitle ?? item.displayTitle
                    focused = true
                }
                .onSubmit { browser.rename(item, to: text) }
                .onExitCommand { browser.state.renamingItemID = nil }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, browser.state.renamingItemID == item.id { browser.rename(item, to: text) }
                }
        } else {
            Text(item.displayTitle).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// Arc's folder glyph: an outline, optionally with a symbol inside.
private struct FolderIcon: View {
    let icon: String?
    let isOpen: Bool

    var body: some View {
        ZStack {
            Image(systemName: "folder")
                .font(.system(size: 15, weight: .regular))
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 6.5, weight: .bold))
                    .offset(y: 1)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// The speaker shown while a tab plays sound (or is muted); a click toggles
/// mute.
private struct AudioButton: View {
    let browser: BrowserWindowController
    let item: Item
    var size: CGFloat = 11
    @State private var hovering = false

    var body: some View {
        if item.isAudible || item.isMuted {
            Button { browser.toggleMute(item) } label: {
                Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: size, weight: .semibold))
                    .opacity(hovering ? 1 : 0.7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(item.isMuted ? "Ton einschalten" : "Stummschalten")
        }
    }
}

enum DropZone {
    case before, after, into
}

private extension View {
    func rowStyle(depth: Int, isActive: Bool, hovering: Bool, theme: SpaceTheme, dropZone: DropZone?,
                  horizontalPadding: CGFloat = 10) -> some View {
        self
            .padding(.leading, horizontalPadding + CGFloat(depth) * 16)
            .padding(.trailing, horizontalPadding - 4)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? theme.selection : (hovering || dropZone == .into ? theme.hover : .clear))
                    .shadow(color: .black.opacity(isActive && !theme.isDark ? 0.08 : 0), radius: 1, y: 0.5))
            .overlay(alignment: dropZone == .after ? .bottom : .top) {
                if dropZone == .before || dropZone == .after {
                    Capsule().fill(theme.foreground.opacity(0.7)).frame(height: 2).padding(.leading, CGFloat(depth) * 16)
                }
            }
            .contentShape(Rectangle())
    }
}

/// Drops onto a row: the upper half inserts before, the lower half after,
/// and the middle of a folder drops into it.
private struct RowDropDelegate: DropDelegate {
    let browser: BrowserWindowController
    let item: Item
    let acceptsInto: Bool
    @Binding var zone: DropZone?

    private func zone(for info: DropInfo) -> DropZone {
        let y = info.location.y
        if acceptsInto, y > 8, y < 24 { return .into }
        return y < 16 ? .before : .after
    }

    func dropEntered(info: DropInfo) { zone = zone(for: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = zone(for: info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target: BrowserWindowController.DropTarget
        switch zone(for: info) {
        case .before: target = .before(item)
        case .after: target = .after(item)
        case .into: target = .into(item)
        }
        zone = nil
        return browser.handleDrop(info.itemProviders(for: [.openArchTab, .plainText]), target: target)
    }
}

extension UTType {
    /// A sidebar item being dragged: private to OpenArch, so Finder and other
    /// apps ignore it (no text clippings with an id in them).
    static let openArchTab = UTType(exportedAs: "dev.openarch.tab", conformingTo: .data)
}

extension NSPasteboard.PasteboardType {
    static let openArchTab = NSPasteboard.PasteboardType("dev.openarch.tab")
}

/// What dragging a sidebar item carries: its id, as OpenArch's own type.
func tabDragProvider(_ item: Item) -> NSItemProvider {
    let provider = NSItemProvider()
    let id = Data(item.id.uuidString.utf8)
    provider.registerDataRepresentation(forTypeIdentifier: UTType.openArchTab.identifier, visibility: .all) { completion in
        completion(id, nil)
        return nil
    }
    return provider
}

@MainActor
func copy(_ string: String) {
    copyPasteboard.clearContents()
    copyPasteboard.setString(string, forType: .string)
}

/// The clipboard; the self-test copies into a pasteboard of its own instead.
@MainActor
var copyPasteboard: NSPasteboard {
    AppPaths.isSelfTest ? NSPasteboard(name: NSPasteboard.Name("dev.openarch.selftest")) : .general
}
