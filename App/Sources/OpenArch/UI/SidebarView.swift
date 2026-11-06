import AppKit
import OpenArchCore
import OpenArchShared
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            if !floating { browser.state.sidebarFrame = $0 }
        }
        // Follows the fingers during a swipe between spaces.
        .offset(x: offset)
        .opacity(1 - min(0.6, abs(offset) / 220))
        // Clip the swipe to the sidebar, but up into the transparent title
        // bar: plain .clipped() cut off the top row next to the window buttons.
        .mask { Rectangle().ignoresSafeArea() }
    }

    private var sidebar: some View {
        let theme = SpaceTheme(hex: browser.state.space.colorHex)
        let stack = browser.state.downloadStack
        return VStack(alignment: .leading, spacing: 0) {
            content(theme: theme)
                // The newest downloads over the library button, the sidebar
                // blurred away behind them.
                .blur(radius: stack.isShown ? 18 : 0)
                .opacity(stack.isShown ? 0 : 1)
                .allowsHitTesting(!stack.isShown)
                .overlay {
                    if stack.isShown {
                        DownloadStackView(browser: browser, stack: stack, theme: theme)
                            .transition(.opacity)
                    }
                }
            if browser.isStandalone {
                Spacer().frame(height: 12)
            } else {
                SpaceBar(browser: browser, theme: theme, isDocked: !floating)
            }
        }
        .padding(.horizontal, 8)
        .ignoresSafeArea()
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.colorScheme)
        .tint(theme.foreground)
    }

    /// Everything above the space bar.
    private func content(theme: SpaceTheme) -> some View {
        let state = browser.state
        let space = state.space
        return VStack(alignment: .leading, spacing: 0) {
            SidebarTopBar(browser: browser, theme: theme, floating: floating)
            if browser.library.settings.showSidebarAddress {
                AddressPill(browser: browser, theme: theme)
                    .padding(.bottom, 8)
            }
            if state.agentsVisible {
                AgentsList(browser: browser, theme: theme)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if browser.isPrivate {
                            PrivateHeader(theme: theme)
                        } else if !browser.isSeparate {
                            // A separate window has only tabs, no bookmarks.
                            FavoritesGrid(browser: browser, theme: theme)
                            SpaceHeader(browser: browser, space: space, theme: theme)
                            PinnedSection(browser: browser, space: space, theme: theme)
                        }
                        TodaySection(browser: browser, space: space, theme: theme)
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                // The free space under the tabs takes drops too: they go last.
                .contentShape(Rectangle())
                .onDrop(of: UTType.sidebarDrops, isTargeted: nil) { providers in
                    browser.handleDrop(providers, target: .end(space.today))
                }
            }
            if let player = browser.player {
                MediaCard(browser: browser, source: player, theme: theme)
            }
            if case .ready = Updater.shared.phase {
                UpdateBanner(theme: theme)
            }
        }
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

/// Media playing in another tab or in Spotify, as a small player: the
/// cover, what plays and an equalizer while it plays. Resting the pointer on
/// it opens the controls (position, previous, play, next, sound,
/// picture-in-picture); a click on the cover or the title goes to the tab
/// (or Spotify).
private struct MediaCard: View {
    let browser: BrowserWindowController
    let source: NowPlaying
    let theme: SpaceTheme
    @State private var expanded = false
    @State private var collapsing: Task<Void, Never>?

    private var media: MediaState {
        switch source {
        case .tab(let item): return item.media ?? MediaState()
        case .spotify(let media): return media
        }
    }

    /// The tab it plays in; nil for Spotify.
    private var tab: Item? {
        if case .tab(let item) = source { return item }
        return nil
    }

    var body: some View {
        let media = self.media
        VStack(spacing: 0) {
            header(media)
            if expanded {
                VStack(spacing: 2) {
                    if media.isSeekable {
                        MediaProgress(media: media, theme: theme) { seek(to: $0) }
                    } else if media.live {
                        LiveBadge()
                    }
                    controls(media)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(expanded ? theme.tileHover : theme.tile))
        .onHover { hover($0) }
        .padding(.top, 6)
    }

    private func header(_ media: MediaState) -> some View {
        HStack(spacing: 4) {
            Button { show() } label: {
                HStack(spacing: 9) {
                    MediaArtwork(source: source, media: media, theme: theme)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(media.title.isEmpty ? (tab?.displayTitle ?? "Spotify") : media.title)
                            .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text(subtitle(media))
                            .font(.system(size: 11)).opacity(0.65).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHelp)
            if expanded {
                if let tab, media.video {
                    IconButton(symbol: media.pip ? "pip.exit" : "pip.enter", help: "Bild-in-Bild", size: 12) {
                        browser.mediaCommand(tab, media.pip ? "exitpip" : "pip")
                    }
                }
                IconButton(symbol: "xmark", help: "Schließen (hält die Wiedergabe an)", size: 11) {
                    dismiss()
                }
            } else {
                Equalizer(playing: media.playing)
                    .padding(.trailing, 7)
            }
        }
    }

    private func subtitle(_ media: MediaState) -> String {
        if !media.artist.isEmpty { return media.artist }
        if !media.album.isEmpty { return media.album }
        return tab.map { CommandBarModel.shortURL($0.currentURL) } ?? "Spotify"
    }

    private func controls(_ media: MediaState) -> some View {
        HStack(spacing: 0) {
            IconButton(symbol: "arrow.up.right", help: showHelp, size: 11) {
                show()
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                IconButton(symbol: "backward.fill", help: media.previous ? "Vorheriger Titel" : "Zum Anfang", size: 12) {
                    command("previous")
                }
                .disabled(!media.previous && !media.isSeekable)
                PlayPauseButton(playing: media.playing, theme: theme) {
                    command("toggle")
                }
                IconButton(symbol: "forward.fill", help: "Nächster Titel", size: 12) {
                    command("next")
                }
                .disabled(!media.next)
            }
            Spacer(minLength: 0)
            if let tab {
                IconButton(symbol: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                           help: tab.isMuted ? "Ton einschalten" : "Stummschalten", size: 12) {
                    browser.toggleMute(tab)
                }
            } else {
                // Keeps the middle buttons in the middle.
                Color.clear.frame(width: IconButton.width, height: 24)
            }
        }
    }

    private var showHelp: String { tab == nil ? "Spotify öffnen" : "Zum Tab wechseln" }

    private func show() {
        switch source {
        case .tab(let item): browser.select(item)
        case .spotify: SpotifyPlayer.shared.show()
        }
    }

    private func command(_ command: String) {
        switch source {
        case .tab(let item): browser.mediaCommand(item, command)
        case .spotify: SpotifyPlayer.shared.command(command)
        }
    }

    private func seek(to seconds: Double) {
        switch source {
        case .tab(let item): browser.seekMedia(item, to: seconds)
        case .spotify: SpotifyPlayer.shared.seek(to: seconds)
        }
    }

    private func dismiss() {
        switch source {
        case .tab(let item): browser.dismissMedia(item)
        case .spotify: SpotifyPlayer.shared.dismiss()
        }
    }

    private func hover(_ inside: Bool) {
        collapsing?.cancel()
        if inside {
            withAnimation(.spring(duration: 0.3)) { expanded = true }
        } else {
            // A moment's grace, so the controls stay when the pointer slips off.
            collapsing = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.3)) { expanded = false }
            }
        }
    }
}

/// The cover of what plays, or the site's (or Spotify's) icon on a tile.
private struct MediaArtwork: View {
    let source: NowPlaying
    let media: MediaState
    let theme: SpaceTheme
    private static let size: CGFloat = 32

    var body: some View {
        ZStack {
            if let cover = ArtworkStore.shared.image(for: media.artwork, profile: profile) {
                Image(nsImage: cover)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.size, height: Self.size)
                    .transition(.opacity)
            } else {
                Rectangle().fill(theme.tile)
                switch source {
                case .tab(let item):
                    FaviconView(item: item, size: 16)
                case .spotify:
                    if let icon = SpotifyPlayer.shared.icon {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "music.note").font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
        .animation(.easeOut(duration: 0.2), value: media.artwork)
    }

    /// Covers load through the tab's profile; Spotify's through the default one.
    private var profile: OACProfile? {
        switch source {
        case .tab(let item): return item.pane?.profile
        case .spotify: return OACProfile.default
        }
    }
}

/// Four bars that dance while something plays and rest when it pauses.
private struct Equalizer: View {
    let playing: Bool
    private static let speeds: [Double] = [2.6, 3.7, 3.1, 4.3]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    let level = CGFloat(playing ? 0.3 + 0.7 * abs(sin(time * Self.speeds[index] + Double(index) * 1.3)) : 0.25)
                    Capsule().frame(width: 2.5, height: 12 * level)
                }
            }
            .frame(height: 12)
        }
        .opacity(playing ? 0.85 : 0.45)
        .accessibilityLabel(playing ? "Spielt" : "Pausiert")
    }
}

/// Play and pause, on a round tile like a player's main button.
private struct PlayPauseButton: View {
    let playing: Bool
    let theme: SpaceTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovering ? theme.selection : theme.tile))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(playing ? "Pause" : "Abspielen")
    }
}

/// The position as a bar that can be clicked and dragged, with the time
/// played and the time left below it.
private struct MediaProgress: View {
    let media: MediaState
    let theme: SpaceTheme
    let seek: (Double) -> Void
    /// Where the bar is held (0–1), while dragging and until the page
    /// reports the new position.
    @State private var scrub: Double?
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !media.playing || scrub != nil)) { context in
            let duration = media.duration
            let position = scrub.map { $0 * duration } ?? media.position(at: context.date)
            let fraction = duration > 0 ? min(1, position / duration) : 0
            VStack(spacing: 1) {
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width)
                    let thickness: CGFloat = hovering || dragging ? 6 : 4
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.foreground.opacity(0.18))
                        Capsule().fill(theme.foreground.opacity(0.85))
                            .frame(width: max(thickness, width * CGFloat(fraction)))
                    }
                    .frame(height: thickness)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragging = true
                                scrub = Double(max(0, min(1, value.location.x / width)))
                            }
                            .onEnded { value in
                                let target = Double(max(0, min(1, value.location.x / width)))
                                dragging = false
                                scrub = target
                                seek(target * duration)
                                settle()
                            }
                    )
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering || dragging)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("−" + Self.format(max(0, duration - position)))
                }
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .opacity(0.6)
            }
        }
        .onChange(of: media.reportedAt) {
            if !dragging { scrub = nil }
        }
    }

    /// Lets go of the held position if the page does not report a new one
    /// (a jump too small to report, or a page that ignores it).
    private func settle() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !dragging { scrub = nil }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// A stream without an end has no position to show.
private struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text("LIVE").font(.system(size: 9.5, weight: .bold)).opacity(0.75)
            Spacer()
        }
        .padding(.horizontal, 4)
        .frame(height: 16)
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

    private static let antennaWidth: CGFloat = 20

    var body: some View {
        let active = browser.state.activeItem
        let remote = OACEngine.remoteDebuggingPort > 0
        let remoteHelp = "KI-Steuerung aktiv: Chrome DevTools Protocol auf 127.0.0.1:\(OACEngine.remoteDebuggingPort)"
        let toggleHelp = floating ? "Sidebar anheften (⌘S)" : "Sidebar ausblenden (⌘S)"
        // What is left beside the window buttons, the toggle and back,
        // forward and reload, less the sidebar's padding. The narrowest
        // sidebar has room for nothing more: a wider bar widened the whole
        // sidebar, which SwiftUI centered and so pushed under the window
        // buttons.
        let room = browser.sidebarWidth - 16 - (floating ? 4 : 72) - 4 * IconButton.width
        let siteControls = active?.kind == .tab && !floating
        let siteButton = siteControls && room >= IconButton.width
        // Without room the antenna is a dot on the toggle.
        let antenna = remote && room - (siteButton ? IconButton.width : 0) >= Self.antennaWidth
        HStack(spacing: 0) {
            // Room for the window buttons, which a floating sidebar sits below.
            Spacer().frame(width: floating ? 4 : 72)
            IconButton(symbol: "sidebar.left", help: remote && !antenna ? "\(toggleHelp)\n\(remoteHelp)" : toggleHelp) {
                browser.toggleSidebar()
            }
            .overlay(alignment: .topTrailing) {
                if remote && !antenna {
                    Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: -3, y: 3)
                        .allowsHitTesting(false)
                }
            }
            if antenna {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: Self.antennaWidth - 4)
                    .padding(.leading, 4)
                    .help(remoteHelp)
            }
            Spacer(minLength: 0)
            if siteButton, let active {
                IconButton(symbol: "slider.horizontal.3", help: "Website-Einstellungen: Berechtigungen, Zoom, Daten") {
                    browser.state.siteControlsVisible.toggle()
                }
                .popover(isPresented: siteControlsShown, arrowEdge: .bottom) {
                    SiteControls(browser: browser, item: active)
                }
            }
            IconButton(symbol: "arrow.left", help: "Zurück (⌘[)") { browser.goBack() }
                .disabled(!(active?.canGoBack ?? false))
            IconButton(symbol: "arrow.right", help: "Vorwärts (⌘])") { browser.goForward() }
                .disabled(!(active?.canGoForward ?? false))
            IconButton(symbol: active?.isLoading == true ? "xmark" : "arrow.clockwise", help: "Neu laden (⌘R)") {
                if active?.isLoading == true { browser.activePane?.stopLoading() } else { browser.reload() }
            }
            .disabled(active == nil)
        }
        // Without its button, ⌃⌘I shows the site controls under the bar.
        .popover(isPresented: siteControls && !siteButton ? siteControlsShown : .constant(false), arrowEdge: .bottom) {
            if let active {
                SiteControls(browser: browser, item: active)
            }
        }
        .frame(height: 30)
        .padding(.bottom, 6)
    }

    private var siteControlsShown: Binding<Bool> {
        Binding(get: { browser.state.siteControlsVisible }, set: { browser.state.siteControlsVisible = $0 })
    }
}

struct IconButton: View {
    static let width: CGFloat = 28

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
                .frame(width: Self.width, height: 24)
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
        .background {
            // Fills up while the page loads, like Arc's.
            LoadingProgressBar(item: active, color: theme.foreground.opacity(theme.isDark ? 0.16 : 0.09))
                .background(theme.tile)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
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
        .onDrop(of: UTType.sidebarDrops, isTargeted: $dropTargeted) { providers in
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
        .onTapGesture { browser.click(item) }
        .onHover { hovering = $0 }
        .help(item.displayTitle)
        .onDrag {
            browser.beginTabDrag(item)
            return tabDragProvider(item)
        }
        .onDrop(of: UTType.sidebarDrops, isTargeted: nil) { providers in
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
                Button("Space teilen …") {
                    if let app = NSApp.delegate as? AppDelegate { ShareWindows.share(.space(space), app: app) }
                }
                if Sharing.shared.subscription(space.id) != nil {
                    Button("Geteilten Space jetzt aktualisieren") { Task { await Sharing.shared.refresh() } }
                    Button("Nicht mehr folgen") { Sharing.shared.unsubscribe(space.id) }
                }
                Button("Neuer Ordner") { browser.newFolder() }
                if browser.library.settings.agentChats {
                    Button("Neuer Agent-Chat") { browser.newAgentChat() }
                }
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
                .onDrop(of: UTType.sidebarDrops, isTargeted: $dropTargeted) { providers in
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
                if item.live != nil {
                    LiveFolderStatus(browser: browser, folder: item, theme: theme, depth: depth + 1)
                }
            }
        case .split:
            SplitRow(browser: browser, item: item, theme: theme, depth: depth)
        case .tab:
            TabRow(browser: browser, item: item, theme: theme, depth: depth)
        case .agent:
            AgentRow(browser: browser, item: item, theme: theme, depth: depth)
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
            if Sharing.shared.isShared(item.id) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.55)
                    .help(Sharing.shared.subscription(item.id) != nil ? "Geteilt mit dir" : "Geteilt")
            }
            if item.liveStatus == .loading {
                ProgressView().controlSize(.mini).opacity(0.6)
            } else if item.live != nil, hovering {
                SmallButton(symbol: "arrow.clockwise", help: "Jetzt aktualisieren") { LiveFolders.shared.refresh(item) }
            }
        }
        .rowStyle(depth: depth, isActive: false, hovering: hovering, theme: theme, dropZone: dropZone)
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { browser.click(item) } }
        .onHover { hovering = $0 }
        .onDrag { tabDragProvider(item) }
        .onDrop(of: UTType.sidebarDrops, delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: true, zone: $dropZone))
        .contextMenu {
            if item.live != nil {
                Button("Jetzt aktualisieren") { LiveFolders.shared.refresh(item) }
                Divider()
            }
            Button("Umbenennen") { browser.state.renamingItemID = item.id }
            Button("Neuer Unterordner") { browser.newFolder(in: item) }
            Button("Alle öffnen") {
                for tab in item.descendants where tab.kind == .tab { browser.select(tab, focus: false) }
            }
            Divider()
            Button("Teilen …") {
                if let app = NSApp.delegate as? AppDelegate { ShareWindows.share(.folder(item), app: app) }
            }
            if Sharing.shared.subscription(item.id) != nil {
                Button("Geteilten Ordner jetzt aktualisieren") { Task { await Sharing.shared.refresh() } }
                Button("Nicht mehr folgen") { Sharing.shared.unsubscribe(item.id) }
            }
            Divider()
            Button("Ordner löschen …") { browser.deleteFolder(item) }
        }
    }
}

/// Under a live folder's tabs: that GitHub wants a login, could not be
/// reached, or has nothing open.
private struct LiveFolderStatus: View {
    let browser: BrowserWindowController
    let folder: Item
    let theme: SpaceTheme
    let depth: Int
    @State private var hovering = false

    var body: some View {
        switch folder.liveStatus {
        case .signedOut:
            row(symbol: "person.crop.circle.badge.exclamationmark", text: "Bei GitHub anmelden") {
                browser.openInNewTab("https://github.com/login")
            }
        case .failed:
            row(symbol: "exclamationmark.triangle", text: "GitHub nicht erreichbar, erneut versuchen") {
                LiveFolders.shared.refresh(folder)
            }
        case .loading:
            EmptyView()
        case nil:
            if folder.children.isEmpty {
                Text(folder.live?.kind == .issues ? "Keine offenen Issues" : "Keine offenen Pull Requests")
                    .font(.system(size: 12.5))
                    .opacity(0.5)
                    .padding(.leading, 10 + CGFloat(depth) * 16)
                    .frame(height: 28)
            }
        }
    }

    private func row(symbol: String, text: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
            Text(text).font(.system(size: 13))
            Spacer(minLength: 2)
        }
        .opacity(0.75)
        .rowStyle(depth: depth, isActive: false, hovering: hovering, theme: theme, dropZone: nil)
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
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
                .opacity(item.isAsleep ? 0.5 : 1)
                .help(item.isAsleep ? "Schläft: lädt neu, wenn du den Tab öffnest" : "")
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
                if item.role != .today, item.pane != nil || item.isAsleep {
                    SmallButton(symbol: "minus", help: "Entladen") { browser.close(item) }
                }
                if item.role == .today {
                    SmallButton(symbol: "xmark", help: "Schließen (⌘W)") { browser.close(item) }
                } else if item.role == .pinned {
                    SmallButton(symbol: "xmark", help: "Lösen: zu den Tabs unter dem Strich") { browser.togglePin(item) }
                }
            } else if item.isLoading {
                ProgressView().controlSize(.mini).opacity(0.6)
            }
        }
        .rowStyle(depth: depth, isActive: isActive, hovering: hovering, theme: theme, dropZone: dropZone)
        .onTapGesture { browser.click(item) }
        .onHover { hovering = $0 }
        .onDrag {
            browser.beginTabDrag(item)
            return tabDragProvider(item)
        }
        .onDrop(of: UTType.sidebarDrops, delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: false, splits: true, zone: $dropZone))
        .contextMenu { TabContextMenu(browser: browser, item: item) }
        .help(item.currentURL)
    }
}

/// An agent chat: a turning wheel while the agent works, a dot when it
/// answered while you were elsewhere.
private struct AgentRow: View {
    let browser: BrowserWindowController
    let item: Item
    let theme: SpaceTheme
    let depth: Int
    @State private var hovering = false
    @State private var dropZone: DropZone?

    var body: some View {
        let isActive = browser.state.activeItem === item
        let session = item.agentSession
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16)
            RenamableTitle(browser: browser, item: item)
                .font(.system(size: 14))
            Spacer(minLength: 2)
            if hovering {
                if item.role == .today {
                    SmallButton(symbol: "xmark", help: "Chat schließen (⌘W)") { browser.close(item) }
                } else if item.role == .pinned {
                    SmallButton(symbol: "xmark", help: "Lösen: zu den Tabs unter dem Strich") { browser.togglePin(item) }
                }
            } else if session?.isRunning == true {
                ProgressView().controlSize(.mini).opacity(0.6)
            } else if session?.isUnread == true {
                Circle().fill(theme.foreground).frame(width: 7, height: 7).padding(.trailing, 6)
            }
        }
        .rowStyle(depth: depth, isActive: isActive, hovering: hovering, theme: theme, dropZone: dropZone)
        .onTapGesture { browser.select(item) }
        .onHover { hovering = $0 }
        .onDrag { tabDragProvider(item) }
        .onDrop(of: UTType.sidebarDrops, delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: false, zone: $dropZone))
        .contextMenu {
            Button("Umbenennen") { browser.state.renamingItemID = item.id }
            if item.role == .today {
                Button("Anheften (⌘D)") { browser.togglePin(item) }
            } else if item.role == .pinned {
                Button("Lösen") { browser.togglePin(item) }
            }
            if let folder = item.agent?.folder {
                Button("Ordner im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                }
            }
            Divider()
            if session?.isRunning == true {
                Button("Anhalten") { session?.stop() }
            }
            Button("Chat löschen") { browser.deleteAgentChat(item) }
        }
        .help(item.agent.map { "Agent-Chat in \(($0.folder as NSString).abbreviatingWithTildeInPath)" } ?? "")
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
                .onTapGesture { browser.click(child) }
                .contextMenu { TabContextMenu(browser: browser, item: child) }
            }
        }
        .rowStyle(depth: depth, isActive: isShown, hovering: hovering, theme: theme, dropZone: dropZone, horizontalPadding: 3)
        .onHover { hovering = $0 }
        .onDrag { tabDragProvider(item) }
        .onDrop(of: UTType.sidebarDrops, delegate: RowDropDelegate(browser: browser, item: item, acceptsInto: false, splits: true, zone: $dropZone))
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
        // Private and separate windows have no pinned tabs, favorites or folders.
        if !browser.isStandalone {
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
        }
        if let split = item.split {
            Button("Split View aufheben") { browser.unsplit(item) }
            Button("Seiten tauschen (⌃⇧S)") { browser.swapSplit(split) }
            Button(split.splitStacked ? "Nebeneinander anzeigen" : "Übereinander anzeigen") {
                browser.setSplitStacked(split, !split.splitStacked)
            }
        } else {
            Button("Split View mit aktuellem Tab") { browser.split(item) }
                .disabled(browser.state.activeItem == nil || browser.state.activeItem === item)
        }
        if browser.isSeparate {
            // Back into the main window, the space it came from first.
            Menu("In Space verschieben") {
                let spaces = browser.library.spaces
                ForEach(spaces.filter { $0 === browser.homeSpace } + spaces.filter { $0 !== browser.homeSpace }) { space in
                    Button(space.name) { browser.moveBack(item, to: space) }
                }
            }
        } else {
            Menu("In Space verschieben") {
                ForEach(browser.library.spaces.filter { $0 !== browser.state.space }) { space in
                    Button(space.name) { browser.moveToSpace(item, space) }
                }
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
            .onDrop(of: UTType.sidebarDrops, isTargeted: $dropTargeted) { providers in
                browser.handleDrop(providers, target: .end(space.today))
            }

            NewTabRow(browser: browser, theme: theme)
                .onDrop(of: UTType.sidebarDrops, isTargeted: $dropTargeted) { providers in
                    browser.handleDrop(providers, target: space.today.items.first.map { .before($0) } ?? .end(space.today))
                }
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
                if browser.library.settings.agentChats, !browser.isStandalone {
                    SmallButton(symbol: "sparkles", help: "Neuer Agent-Chat") { browser.newAgentChat() }
                }
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
    /// In the window's sidebar, not the one floating over the page.
    var isDocked = true

    var body: some View {
        let stack = browser.state.downloadStack
        let downloads = browser.library.settings.downloadStack
        let help = downloads ? "Letzte Downloads; Bibliothek mit ⌥⌘B oder Rechtsklick"
            : "Bibliothek: Medien, Downloads, Spaces, Archiv (⌥⌘B)"
        HStack(spacing: 4) {
            IconButton(symbol: "books.vertical", help: help) {
                if downloads { stack.toggle() } else { browser.toggleLibrary() }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(stack.isShown ? theme.tile : .clear))
            .overlay { DownloadRing(theme: theme) }
            .symbolEffect(.bounce, value: Downloads.shared.finished)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                if isDocked { browser.state.libraryButtonFrame = $0 }
            }
            .contextMenu { LibraryButtonMenu(browser: browser) }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    if browser.library.settings.agentChats, !browser.isPrivate {
                        AgentsSpaceButton(browser: browser, theme: theme)
                    }
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
                if browser.library.settings.agentChats, !browser.isPrivate {
                    Button("Neuer Agent-Chat") { browser.newAgentChat() }
                }
                Menu("GitHub-Live-Ordner") {
                    Button("Meine Pull Requests") { browser.newLiveFolder(.myPullRequests, name: "Meine Pull Requests") }
                    Button("Reviews für mich") { browser.newLiveFolder(.reviewRequests, name: "Reviews für mich") }
                    Button("Meine Issues") { browser.newLiveFolder(.myIssues, name: "Meine Issues") }
                }
                Divider()
                Button("Geteilten Link öffnen …") {
                    if let app = NSApp.delegate as? AppDelegate { ShareWindows.askForLink(app: app) }
                }
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

/// Around the library button while files download: how far they are, or a
/// turning arc while their size is unknown.
private struct DownloadRing: View {
    let theme: SpaceTheme

    var body: some View {
        if let overall = Downloads.shared.overall {
            ZStack {
                Circle().stroke(theme.foreground.opacity(0.2), lineWidth: 2)
                if overall >= 0 {
                    Circle().trim(from: 0, to: max(0.04, overall))
                        .stroke(theme.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: overall)
                } else {
                    TimelineView(.animation) { context in
                        Circle().trim(from: 0, to: 0.25)
                            .stroke(theme.foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 360))
                    }
                }
            }
            .frame(width: 24, height: 24)
            .allowsHitTesting(false)
            .help("Downloads laufen")
        }
    }
}

/// Agents, at the start of the space bar like a space of its own (⌃0); a
/// dot while sessions wait for you.
private struct AgentsSpaceButton: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let isCurrent = browser.state.agentsVisible
        let waiting = ClaudeSessions.shared.waitingCount
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(Circle().fill(isCurrent ? theme.selection : (hovering ? theme.hover : .clear)))
            .overlay(alignment: .topTrailing) {
                if waiting > 0, !isCurrent {
                    Circle().fill(Color.orange).frame(width: 7, height: 7).offset(x: -3, y: 3)
                }
            }
            .opacity(isCurrent ? 1 : 0.6)
            .contentShape(Circle())
            .onTapGesture { browser.toggleAgents() }
            .onHover { hovering = $0 }
            .help(waiting > 0 ? "Agents (⌃0): \(waiting) warten auf dich" : "Agents (⌃0)")
    }
}

private struct SpaceButton: View {
    let browser: BrowserWindowController
    let space: Space
    let index: Int
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        let isCurrent = browser.state.space === space && !browser.state.agentsVisible
        SpaceIcon(icon: space.icon, size: 12)
            .frame(width: 28, height: 28)
            .background(Circle().fill(isCurrent ? theme.selection : (hovering ? theme.hover : .clear)))
            .opacity(isCurrent ? 1 : 0.6)
            .contentShape(Circle())
            .onTapGesture {
                browser.state.agentsVisible = false
                browser.switchSpace(to: space)
            }
            .onHover { hovering = $0 }
            .help(index < 9 ? "\(space.name) (⌃\(index + 1))" : space.name)
            .onDrag {
                browser.state.draggingSpaceID = space.id
                let provider = NSItemProvider()
                let id = Data(space.id.uuidString.utf8)
                provider.registerDataRepresentation(forTypeIdentifier: UTType.openArchSpace.identifier, visibility: .ownProcess) { completion in
                    completion(id, nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [.openArchSpace] + UTType.sidebarDrops, delegate: SpaceDropDelegate(browser: browser, space: space))
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
    case before, after, into, split

    /// Where a drop at |y| (from a 36-point row's top) lands: the edges go
    /// before or after the row, the middle into a folder or, on a tab, into
    /// a split view with it.
    static func at(y: CGFloat, folder: Bool, tab: Bool) -> DropZone {
        if folder, y > 8, y < 24 { return .into }
        if tab, y > 11, y < 25 { return .split }
        return y < 16 ? .before : .after
    }
}

extension View {
    func rowStyle(depth: Int, isActive: Bool, hovering: Bool, theme: SpaceTheme, dropZone: DropZone?,
                  horizontalPadding: CGFloat = 10) -> some View {
        self
            .padding(.leading, horizontalPadding + CGFloat(depth) * 16)
            .padding(.trailing, horizontalPadding - 4)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? theme.selection
                          : (hovering || dropZone == .into || dropZone == .split ? theme.hover : .clear))
                    .shadow(color: .black.opacity(isActive && !theme.isDark ? 0.08 : 0), radius: 1, y: 0.5))
            .overlay(alignment: dropZone == .after ? .bottom : .top) {
                if dropZone == .before || dropZone == .after {
                    Capsule().fill(theme.foreground.opacity(0.7)).frame(height: 2).padding(.leading, CGFloat(depth) * 16)
                }
            }
            .overlay(alignment: .trailing) {
                if dropZone == .split {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(Capsule().fill(theme.selection))
                        .padding(.trailing, 6)
                }
            }
            .contentShape(Rectangle())
    }
}

@MainActor
private enum DropHighlights {
    /// Per row: the pending clean-up of its drop highlight.
    static var pending: [UUID: DispatchWorkItem] = [:]
}

/// Drops onto a row: the upper half inserts before, the lower half after,
/// and the middle of a folder drops into it.
private struct RowDropDelegate: DropDelegate {
    let browser: BrowserWindowController
    let item: Item
    let acceptsInto: Bool
    /// A tab: the middle of the row makes a split view with it.
    var splits = false
    @Binding var zone: DropZone?

    private func zone(for info: DropInfo) -> DropZone {
        DropZone.at(y: info.location.y, folder: acceptsInto, tab: splits)
    }

    func dropEntered(info: DropInfo) { show(zone(for: info)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        show(zone(for: info))
        // Our own tabs move; a page or another app only lets its links be
        // copied, and a move would be refused.
        return DropProposal(operation: info.hasItemsConforming(to: [.openArchTab]) ? .move : .copy)
    }
    func dropExited(info: DropInfo) { zone = nil }

    /// SwiftUI does not always say when a drag has left a row, and the
    /// highlight stayed: it goes once the updates (several a second while a
    /// drag is over the row) stop coming.
    private func show(_ newZone: DropZone) {
        zone = newZone
        let binding = $zone
        let id = item.id
        DropHighlights.pending[id]?.cancel()
        let clear = DispatchWorkItem { binding.wrappedValue = nil }
        DropHighlights.pending[id] = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: clear)
    }

    func performDrop(info: DropInfo) -> Bool {
        let target: BrowserWindowController.DropTarget
        switch zone(for: info) {
        case .before: target = .before(item)
        case .after: target = .after(item)
        case .into: target = .into(item)
        case .split: target = .split(item)
        }
        zone = nil
        return browser.handleDrop(info.itemProviders(for: UTType.sidebarDrops), target: target)
    }
}

/// Space icons: a dragged space takes the place of the one it is over, so
/// the others make room as it moves, like in Arc. Tabs and links dropped on
/// a space move there.
private struct SpaceDropDelegate: DropDelegate {
    let browser: BrowserWindowController
    let space: Space

    private var draggedSpace: Space? {
        browser.state.draggingSpaceID.flatMap { id in browser.library.spaces.first { $0.id == id } }
    }

    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: [.openArchSpace]), let dragged = draggedSpace, dragged !== space else { return }
        withAnimation(.snappy(duration: 0.2)) { browser.library.moveSpace(dragged, to: space) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.openArchSpace, .openArchTab]) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.openArchSpace]) {
            browser.state.draggingSpaceID = nil
            return true
        }
        return browser.handleDrop(info.itemProviders(for: UTType.sidebarDrops), toSpace: space)
    }
}

extension UTType {
    /// A sidebar item being dragged: private to OpenArch, so Finder and other
    /// apps ignore it (no text clippings with an id in them).
    static let openArchTab = UTType(exportedAs: "dev.openarch.tab", conformingTo: .data)
    /// A space icon being dragged within the space bar.
    static let openArchSpace = UTType(exportedAs: "dev.openarch.space", conformingTo: .data)

    /// What the sidebar takes: its own tabs, links (files from Finder too)
    /// and text with an address in it.
    static let sidebarDrops: [UTType] = [.openArchTab, .url, .plainText]
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
