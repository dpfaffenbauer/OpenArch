import OpenArchShared
import SwiftUI
import WebKit

/// iPhone: the page with a bar below it; the sidebar comes up as a sheet.
/// iPad and the inside of iPhone Duo: the sidebar beside the page, as on the
/// Mac. On iPhone Duo, the page goes to the display's edges as in Safari, the
/// controls float beside the status bar's symbols, and neither the page nor
/// the sidebar lies across the fold.
struct RootView: View {
    @Bindable var browser: Browser
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let theme = SpaceTheme(hex: browser.space.colorHex)
        GeometryReader { proxy in
            arrangement(ReservedLayout(proxy), proxy: proxy)
        }
        .background(theme.gradient.ignoresSafeArea())
        .animation(.easeOut(duration: 0.25), value: browser.space.colorHex)
        .sheet(item: $browser.sheet) { sheet in
            content(for: sheet)
                // Unlike the window below them, which goes by the space or page.
                .preferredColorScheme(systemColorScheme)
        }
        .overlay(alignment: .top) {
            if let toast = browser.toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: browser.toast)
        #if DEBUG
        .overlay { if Demo.isRequested { DemoHeartbeat() } }
        #endif
        .onAppear {
            if let item = browser.activeItem { browser.select(item) }
        }
    }

    @ViewBuilder
    private func arrangement(_ layout: ReservedLayout, proxy: GeometryProxy) -> some View {
        let regular = sizeClass == .regular
        let sidebarShown = regular && browser.sidebarVisible
        let showsBar = layout.showsBottomBar
        let extends = layout.pageEdges(sidebarShown: sidebarShown)
        HStack(spacing: 0) {
            if let fold = layout.fold, fold.height > fold.width {
                // Like a book: the sidebar on one side, the page on the other.
                if sidebarShown {
                    sidebar.frame(width: fold.minX)
                    Spacer().frame(width: fold.width)
                }
                BrowserView(browser: browser, regular: regular, showsBar: showsBar, extends: extends,
                            barLeading: sidebarShown ? 0 : fold.maxX)
            } else if let fold = layout.fold, sidebarShown {
                // Like a laptop: the page above the fold, the rest below it.
                VStack(spacing: 0) {
                    PageView(browser: browser, extends: extends.subtracting(.bottom))
                        .frame(height: fold.minY)
                    Spacer().frame(height: fold.height)
                    sidebar
                    if showsBar { BottomBar(browser: browser, regular: regular) }
                }
            } else {
                if sidebarShown {
                    sidebar.frame(width: min(320, proxy.size.width * 0.48))
                }
                BrowserView(browser: browser, regular: regular, showsBar: showsBar, extends: extends)
            }
        }
        .overlay(alignment: layout.rail?.edge == .leading ? .topLeading : .topTrailing) {
            if let rail = layout.rail {
                VerticalBar(browser: browser, regular: regular, rail: rail)
                    .offset(x: rail.edge == .leading ? -rail.width : rail.width)
            }
        }
        .overlay(alignment: .topLeading) {
            if let band = layout.band {
                BandBar(browser: browser, regular: regular, band: band)
                    .offset(y: -band.height)
            }
        }
        // Over a page, the status bar's symbols go by the page.
        .preferredColorScheme(chromeScheme(floating: !showsBar))
    }

    private func chromeScheme(floating: Bool) -> ColorScheme {
        let theme = SpaceTheme(hex: browser.space.colorHex)
        guard floating, let dark = browser.activeItem?.pageIsDark else { return theme.colorScheme }
        return dark ? .dark : .light
    }

    private var systemColorScheme: ColorScheme? {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return screen.flatMap { ColorScheme($0.traitCollection.userInterfaceStyle) }
    }

    private var sidebar: some View {
        SidebarView(browser: browser).transition(.move(edge: .leading))
    }

    @ViewBuilder
    private func content(for sheet: Sheet) -> some View {
        switch sheet {
        case .sidebar:
            SidebarView(browser: browser)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        case .commandBar(let mode):
            CommandBarView(browser: browser, mode: mode)
        case .share(let target):
            ShareView(browser: browser, target: target)
        case .importShare(let link):
            ImportView(browser: browser, link: link)
        case .settings:
            SettingsView(browser: browser)
        case .scanner:
            ScannerSheet(browser: browser)
        case .editSpace(let space):
            SpaceEditor(browser: browser, space: space)
        }
    }
}

// MARK: - Page

struct BrowserView: View {
    let browser: Browser
    let regular: Bool
    var showsBar = true
    /// Where the page goes on beyond the safe area.
    var extends: Edge.Set = []
    /// Keeps the bar off the fold when the page lies across it.
    var barLeading: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            PageView(browser: browser, extends: extends)
            if showsBar {
                BottomBar(browser: browser, regular: regular)
                    .padding(.leading, barLeading)
                    .background(SpaceTheme(hex: browser.space.colorHex).backgroundBottom.ignoresSafeArea(edges: [.horizontal, .bottom]))
            }
        }
    }
}

struct PageView: View {
    let browser: Browser
    /// Where the page goes on beyond the safe area, as in Safari.
    var extends: Edge.Set = []

    var body: some View {
        let theme = SpaceTheme(hex: browser.space.colorHex)
        ZStack(alignment: .top) {
            if let item = browser.activeItem, let tab = browser.activeTab {
                WebViewHost(webView: tab.webView)
                    .ignoresSafeArea(.container, edges: extends)
                if item.isLoading {
                    ProgressView(value: max(0.05, item.progress))
                        .progressViewStyle(.linear)
                        .tint(theme.isDark ? theme.background : .accentColor)
                        .frame(height: 2)
                }
            } else {
                StartPage(browser: browser)
            }
        }
    }
}

/// Hosts the shown tab's web view; switching tabs swaps it, the pages stay.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> HostView {
        HostView()
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.show(webView)
    }

    final class HostView: UIView {
        func show(_ webView: WKWebView) {
            guard webView.superview !== self else { return }
            subviews.forEach { $0.removeFromSuperview() }
            webView.frame = bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
            matchSystemAppearance()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            matchSystemAppearance()
        }

        /// Pages go by the system's light or dark, not by the space's color.
        private func matchSystemAppearance() {
            guard let style = window?.windowScene?.screen.traitCollection.userInterfaceStyle else { return }
            overrideUserInterfaceStyle = style
            backgroundColor = .systemBackground
        }
    }
}

/// Below the page: sidebar, back, the address, a new tab and the page menu.
struct BottomBar: View {
    let browser: Browser
    let regular: Bool

    var body: some View {
        let theme = SpaceTheme(hex: browser.space.colorHex)
        let item = browser.activeItem
        HStack(spacing: 2) {
            BarButton(symbol: "sidebar.leading", label: "Seitenleiste") {
                if regular {
                    withAnimation(.easeOut(duration: 0.25)) { browser.sidebarVisible.toggle() }
                } else {
                    browser.present(.sidebar)
                }
            }
            BarButton(symbol: "chevron.backward", label: "Zurück") {
                browser.activeTab?.webView.goBack()
            }
            .disabled(item?.canGoBack != true)
            if regular {
                BarButton(symbol: "chevron.forward", label: "Vorwärts") {
                    browser.activeTab?.webView.goForward()
                }
                .disabled(item?.canGoForward != true)
            }
            Button {
                browser.present(.commandBar(item == nil ? .newTab : .edit))
            } label: {
                HStack(spacing: 6) {
                    if let item {
                        if item.currentURL.hasPrefix("https://") {
                            Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).opacity(0.6)
                        }
                        Text(item.barTitle).lineLimit(1)
                    } else {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                        Text("Suchen oder Adresse").lineLimit(1)
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(theme.tile, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Adresse")
            .padding(.horizontal, 4)
            BarButton(symbol: "plus", label: "Neuer Tab") {
                browser.present(.commandBar(.newTab))
            }
            Menu {
                PageMenu(browser: browser)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Mehr")
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .foregroundStyle(theme.foreground)
        // Where the start page's gradient ends, so that there is no edge.
        .background(theme.backgroundBottom.ignoresSafeArea(edges: [.horizontal, .bottom]))
        .environment(\.colorScheme, theme.colorScheme)
    }
}

private extension Item {
    var barTitle: String {
        host.isEmpty ? displayTitle : host.replacingOccurrences(of: "www.", with: "")
    }
}

/// A floating bar while the page is being read: this button, which brings
/// the bar back, as scrolling up does.
private struct ExpandBarsButton: View {
    let browser: Browser

    var body: some View {
        BarButton(symbol: "ellipsis", label: "Leiste einblenden") {
            browser.barsCollapsed = false
        }
    }
}

/// What the floating bars have in common: the sidebar, back and forward.
private struct NavigationButtons: View {
    let browser: Browser
    let regular: Bool

    var body: some View {
        let item = browser.activeItem
        BarButton(symbol: "sidebar.leading", label: "Seitenleiste") {
            if regular {
                withAnimation(.easeOut(duration: 0.25)) { browser.sidebarVisible.toggle() }
            } else {
                browser.present(.sidebar)
            }
        }
        BarButton(symbol: "chevron.backward", label: "Zurück") {
            browser.activeTab?.webView.goBack()
        }
        .disabled(item?.canGoBack != true)
        BarButton(symbol: "chevron.forward", label: "Vorwärts") {
            browser.activeTab?.webView.goForward()
        }
        .disabled(item?.canGoForward != true)
    }
}

private struct NewTabAndMenu: View {
    let browser: Browser

    var body: some View {
        BarButton(symbol: "plus", label: "Neuer Tab") {
            browser.present(.commandBar(.newTab))
        }
        Menu {
            PageMenu(browser: browser)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .tint(.primary)
        .accessibilityLabel("Mehr")
    }
}

private extension View {
    /// Floats over the page.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }
}

/// On iPhone Duo with the status bar's column beside the page: the controls
/// one below the other, under the symbols, where the system puts its own
/// toolbars.
struct VerticalBar: View {
    let browser: Browser
    let regular: Bool
    let rail: ReservedLayout.Rail

    var body: some View {
        let item = browser.activeItem
        VStack(spacing: 2) {
            if browser.barsCollapsed {
                ExpandBarsButton(browser: browser)
            } else {
                NavigationButtons(browser: browser, regular: regular)
                Button {
                    browser.present(.commandBar(item == nil ? .newTab : .edit))
                } label: {
                    VStack(spacing: 4) {
                        if let item {
                            Image(systemName: item.currentURL.hasPrefix("https://") ? "lock.fill" : "globe")
                                .font(.system(size: 11, weight: .semibold))
                                .opacity(0.6)
                            // Breaks at a dot rather than within a word.
                            Text(item.barTitle.replacingOccurrences(of: ".", with: ".\u{200B}"))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.8)
                        } else {
                            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                            Text("Suchen").lineLimit(1)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adresse")
                NewTabAndMenu(browser: browser)
            }
        }
        .padding(.vertical, 6)
        .frame(width: browser.barsCollapsed ? 52 : rail.width - 12)
        .floatingGlass(cornerRadius: 26)
        .animation(.spring(duration: 0.3), value: browser.barsCollapsed)
        .frame(width: rail.width)
        .padding(.top, rail.top + 4)
    }
}

/// On iPhone Duo with the status bar in a band above the page: the controls
/// in a row, beside the symbols.
struct BandBar: View {
    let browser: Browser
    let regular: Bool
    let band: ReservedLayout.Band

    var body: some View {
        let item = browser.activeItem
        HStack(spacing: 2) {
            if browser.barsCollapsed {
                ExpandBarsButton(browser: browser)
            } else {
                NavigationButtons(browser: browser, regular: regular)
                Button {
                    browser.present(.commandBar(item == nil ? .newTab : .edit))
                } label: {
                    HStack(spacing: 6) {
                        if let item {
                            if item.currentURL.hasPrefix("https://") {
                                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).opacity(0.6)
                            }
                            Text(item.barTitle).lineLimit(1)
                        } else {
                            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold))
                            Text("Suchen oder Adresse").lineLimit(1)
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adresse")
                NewTabAndMenu(browser: browser)
            }
        }
        .padding(.horizontal, 6)
        .floatingGlass(cornerRadius: 24)
        .animation(.spring(duration: 0.3), value: browser.barsCollapsed)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(width: band.width, height: band.height, alignment: .leading)
    }
}

struct BarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The page's menu (⋯ in the bar).
struct PageMenu: View {
    let browser: Browser

    var body: some View {
        if let item = browser.activeItem {
            let place = browser.place(of: item)
            Button("Neu laden", systemImage: "arrow.clockwise") { browser.activeTab?.webView.reload() }
            if item.canGoForward {
                Button("Vorwärts", systemImage: "chevron.forward") { browser.activeTab?.webView.goForward() }
            }
            if let url = URL(string: item.currentURL) {
                SwiftUI.ShareLink(item: url) { Label("Seite teilen …", systemImage: "square.and.arrow.up") }
            }
            Button("Link kopieren", systemImage: "link") { browser.copy(item.currentURL) }
            Divider()
            switch place {
            case .today:
                Button("Anheften", systemImage: "pin") { browser.pin(item) }
                Button("Zu Favoriten", systemImage: "star") { browser.addToFavorites(item) }
            case .pinned, .favorites:
                if item.hasNavigatedAway {
                    Button("Zur gespeicherten Adresse", systemImage: "arrow.uturn.backward") { browser.goToSavedURL(item) }
                    Button("Diese Adresse speichern", systemImage: "square.and.arrow.down") { browser.saveCurrentURL(item) }
                }
            case nil:
                EmptyView()
            }
            Divider()
            Button(place == .today ? "Tab schließen" : "Seite schließen", systemImage: "xmark", role: .destructive) {
                browser.close(item)
            }
        }
        Button("Einstellungen", systemImage: "gearshape") { browser.present(.settings) }
    }
}

/// With no tab shown: the space's color, the address field and the favorites.
struct StartPage: View {
    let browser: Browser

    var body: some View {
        let theme = SpaceTheme(hex: browser.space.colorHex)
        ScrollView {
            VStack(spacing: 28) {
                SymbolOrEmoji(icon: browser.space.icon, size: 34)
                    .padding(.top, 60)
                Button {
                    browser.present(.commandBar(.newTab))
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Suchen oder Adresse eingeben")
                        Spacer()
                    }
                    .font(.system(size: 17, weight: .medium))
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(theme.tile, in: RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                FavoritesGrid(browser: browser, theme: theme)
                if let first = browser.space.today.first {
                    Button("Zuletzt: \(first.displayTitle)") { browser.select(first) }
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(theme.foreground)
        .background(theme.gradient)
        .environment(\.colorScheme, theme.colorScheme)
    }
}

