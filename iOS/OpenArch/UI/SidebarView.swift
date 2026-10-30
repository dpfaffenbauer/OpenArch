import OpenArchShared
import SwiftUI

/// The sidebar: one page per space (swipe sideways to change spaces, as on
/// the Mac's trackpad), with favorites, pinned folders and today's tabs.
struct SidebarView: View {
    @Bindable var browser: Browser
    @State private var renameText = ""

    var body: some View {
        let theme = SpaceTheme(hex: browser.space.colorHex)
        VStack(spacing: 0) {
            TabView(selection: spaceSelection) {
                ForEach(browser.library.spaces) { space in
                    SpacePage(browser: browser, space: space)
                        .tag(space.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            SpaceBar(browser: browser, theme: theme)
        }
        .background(theme.gradient.ignoresSafeArea())
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.colorScheme)
        .alert("Umbenennen", isPresented: renameShown) {
            TextField("Name", text: $renameText)
            Button("Fertig") {
                if let item = browser.renaming { browser.rename(item, to: renameText) }
                browser.renaming = nil
            }
            Button("Abbrechen", role: .cancel) { browser.renaming = nil }
        }
        .onChange(of: browser.renaming?.id) {
            renameText = browser.renaming?.displayTitle ?? ""
        }
        // On the iPhone, pulling the list only drags the sheet: what is
        // followed is checked whenever the sidebar opens.
        .task { await browser.sharing.refresh() }
    }

    private var spaceSelection: Binding<UUID> {
        Binding(get: { browser.space.id }, set: { id in
            if let space = browser.library.space(id: id) { browser.switchSpace(to: space) }
        })
    }

    private var renameShown: Binding<Bool> {
        Binding(get: { browser.renaming != nil }, set: { if !$0 { browser.renaming = nil } })
    }
}

// MARK: - A space

private struct SpacePage: View {
    let browser: Browser
    let space: Space

    var body: some View {
        let theme = SpaceTheme(hex: space.colorHex)
        List {
            SpaceHeader(browser: browser, space: space)
                .plainRow()
            if !browser.library.favorites.isEmpty {
                FavoritesGrid(browser: browser, theme: theme)
                    .plainRow(top: 4, bottom: 10)
            }
            ForEach(Self.rows(space.pinned, depth: 0), id: \.item.id) { row in
                if row.item.kind == .folder {
                    FolderRow(browser: browser, folder: row.item, theme: theme)
                        .plainRow(leading: 12 + CGFloat(row.depth) * 18)
                } else {
                    TabRow(browser: browser, item: row.item, theme: theme)
                        .plainRow(leading: 12 + CGFloat(row.depth) * 18,
                                  background: browser.activeItem === row.item ? theme.selection : .clear)
                }
            }
            if space.pinned.isEmpty {
                Text("Halte einen Tab gedrückt und wähle „Anheften“, damit er hier bleibt.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondary)
                    .plainRow(top: 4, bottom: 4)
            }
            TodayHeader(browser: browser, space: space, theme: theme)
                .plainRow(top: 14, bottom: 4)
            Button {
                browser.present(.commandBar(.newTab))
            } label: {
                Label("Neuer Tab", systemImage: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .plainRow()
            ForEach(space.today) { item in
                TabRow(browser: browser, item: item, theme: theme)
                    .plainRow(background: browser.activeItem === item ? theme.selection : .clear)
                    .swipeActions(edge: .trailing) {
                        Button("Schließen", systemImage: "xmark", role: .destructive) { browser.close(item) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Anheften", systemImage: "pin") { browser.pin(item) }.tint(.orange)
                    }
            }
            .onMove { browser.moveToday(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 10)
        .refreshable { await browser.sharing.refresh() }
        .background(theme.gradient)
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.colorScheme)
    }

    struct Row {
        let item: Item
        let depth: Int
    }

    /// Pinned items and the contents of open folders, in order.
    @MainActor static func rows(_ items: [Item], depth: Int) -> [Row] {
        items.flatMap { item in
            [Row(item: item, depth: depth)]
                + (item.kind == .folder && item.isExpanded ? rows(item.children, depth: depth + 1) : [])
        }
    }
}

private extension View {
    func plainRow(leading: CGFloat = 12, top: CGFloat = 1, bottom: CGFloat = 1, background: Color = .clear) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(RoundedRectangle(cornerRadius: 10).fill(background).padding(.horizontal, 6))
    }
}

private struct SpaceHeader: View {
    let browser: Browser
    let space: Space

    var body: some View {
        let followed = browser.sharing.subscription(space.id)
        HStack(spacing: 10) {
            SymbolOrEmoji(icon: space.icon, size: 15)
            Text(space.name)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(1)
            if followed != nil || browser.sharing.owned(space.id) != nil {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.6)
                    .accessibilityLabel("Geteilt")
            }
            Spacer()
            Menu {
                Button("Space bearbeiten …", systemImage: "pencil") { browser.present(.editSpace(space)) }
                Button("Space teilen …", systemImage: "square.and.arrow.up") { browser.present(.share(.space(space))) }
                if followed != nil {
                    Button("Jetzt aktualisieren", systemImage: "arrow.clockwise") {
                        Task { await browser.sharing.refresh() }
                    }
                    Button("Nicht mehr folgen", systemImage: "person.2.slash") { browser.sharing.unsubscribe(space.id) }
                }
                Divider()
                Button("Neuer Ordner", systemImage: "folder.badge.plus") { browser.newFolder() }
                Button("Neuer Space", systemImage: "plus.square.on.square") { browser.addSpace() }
                Divider()
                Button("Space löschen", systemImage: "trash", role: .destructive) { browser.deleteSpace(space) }
                    .disabled(browser.library.spaces.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }
}

private struct TodayHeader: View {
    let browser: Browser
    let space: Space
    let theme: SpaceTheme

    var body: some View {
        HStack {
            Rectangle().fill(theme.foreground.opacity(0.18)).frame(height: 1)
            Text("Heute").font(.caption.weight(.semibold)).foregroundStyle(theme.secondary)
            Rectangle().fill(theme.foreground.opacity(0.18)).frame(height: 1)
            if !space.today.isEmpty {
                Button("Aufräumen") { browser.clearToday() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondary)
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Favorites

struct FavoritesGrid: View {
    let browser: Browser
    let theme: SpaceTheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(browser.library.favorites) { item in
                Button {
                    browser.select(item)
                } label: {
                    FaviconView(host: item.host, size: 24)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(browser.activeItem === item ? theme.selection : theme.tile,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottom) {
                            if browser.hasPage(item) {
                                Capsule().fill(theme.foreground.opacity(0.5)).frame(width: 12, height: 3).padding(.bottom, 4)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.displayTitle)
                .contextMenu {
                    ItemMenu(browser: browser, item: item)
                } preview: {
                    Text(item.displayTitle).padding()
                }
            }
        }
    }
}

// MARK: - Rows

private struct TabRow: View {
    let browser: Browser
    let item: Item
    let theme: SpaceTheme

    var body: some View {
        Button {
            browser.select(item)
        } label: {
            HStack(spacing: 10) {
                FaviconView(host: item.host, size: 18)
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: browser.activeItem === item ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.isLoading {
                    ProgressView().controlSize(.mini)
                } else if browser.hasPage(item) && browser.place(of: item) != .today {
                    // A pinned tab with an open page, as on the Mac.
                    Circle().fill(theme.foreground.opacity(0.45)).frame(width: 5, height: 5)
                }
            }
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            ItemMenu(browser: browser, item: item)
        }
    }
}

private struct FolderRow: View {
    let browser: Browser
    let folder: Item
    let theme: SpaceTheme

    var body: some View {
        let followed = browser.sharing.subscription(folder.id)
        let shared = followed != nil || browser.sharing.owned(folder.id) != nil
        Button {
            withAnimation(.easeOut(duration: 0.15)) { folder.isExpanded.toggle() }
            browser.library.setNeedsSave()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                        .font(.system(size: 16, weight: .medium))
                    if let icon = folder.icon {
                        Image(systemName: icon).font(.system(size: 7, weight: .bold)).offset(y: 1.5)
                    }
                }
                .frame(width: 18)
                Text(folder.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if shared {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.6)
                        .accessibilityLabel("Geteilt")
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                    .opacity(0.45)
            }
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Umbenennen", systemImage: "pencil") { browser.renaming = folder }
            Button("Neuer Unterordner", systemImage: "folder.badge.plus") { browser.newFolder(in: folder) }
            Button("Ordner teilen …", systemImage: "square.and.arrow.up") { browser.present(.share(.folder(folder))) }
            if followed != nil {
                Button("Jetzt aktualisieren", systemImage: "arrow.clockwise") {
                    Task { await browser.sharing.refresh() }
                }
                Button("Nicht mehr folgen", systemImage: "person.2.slash") { browser.sharing.unsubscribe(folder.id) }
            }
            MoveMenu(browser: browser, item: folder)
            Divider()
            Button("Ordner löschen", systemImage: "trash", role: .destructive) { browser.delete(folder) }
        }
    }
}

/// What a tab's (or favorite's) menu offers, by where it is.
private struct ItemMenu: View {
    let browser: Browser
    let item: Item

    var body: some View {
        let place = browser.place(of: item)
        if let url = URL(string: item.currentURL) {
            SwiftUI.ShareLink(item: url) { Label("Teilen …", systemImage: "square.and.arrow.up") }
        }
        Button("Link kopieren", systemImage: "link") { browser.copy(item.currentURL) }
        Button("Umbenennen", systemImage: "pencil") { browser.renaming = item }
        Divider()
        switch place {
        case .today:
            Button("Anheften", systemImage: "pin") { browser.pin(item) }
            Button("Zu Favoriten", systemImage: "star") { browser.addToFavorites(item) }
            MoveMenu(browser: browser, item: item)
        case .pinned:
            Button("Lösen", systemImage: "pin.slash") { browser.unpin(item) }
            Button("Zu Favoriten", systemImage: "star") { browser.addToFavorites(item) }
            MoveMenu(browser: browser, item: item)
        case .favorites:
            Button("Aus Favoriten entfernen", systemImage: "star.slash") { browser.removeFromFavorites(item) }
        case nil:
            EmptyView()
        }
        Divider()
        if browser.hasPage(item) && place != .today {
            Button("Seite schließen", systemImage: "xmark") { browser.close(item) }
        }
        switch place {
        case .today:
            Button("Schließen", systemImage: "xmark", role: .destructive) { browser.close(item) }
        case .pinned:
            Button("Löschen", systemImage: "trash", role: .destructive) { browser.delete(item) }
        default:
            EmptyView()
        }
    }
}

private struct MoveMenu: View {
    let browser: Browser
    let item: Item

    var body: some View {
        let folders = browser.space.folders.filter { folder in
            folder !== item && !item.descendants.contains { $0 === folder }
        }
        Menu("In Ordner verschieben", systemImage: "folder") {
            if browser.place(of: item) == .pinned, browser.library.parent(of: item) != nil {
                Button("Oberste Ebene") { browser.pin(item) }
            }
            ForEach(folders) { folder in
                Button(folder.displayTitle) { browser.pin(item, into: folder) }
            }
            Divider()
            Button("Neuer Ordner", systemImage: "folder.badge.plus") {
                browser.pin(item, into: browser.newFolder())
            }
        }
    }
}

// MARK: - Space bar

/// At the bottom of the sidebar: the spaces, and what else there is.
private struct SpaceBar: View {
    let browser: Browser
    let theme: SpaceTheme

    var body: some View {
        HStack(spacing: 4) {
            Button {
                browser.present(.settings)
            } label: {
                Image(systemName: "gearshape").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Einstellungen")
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(browser.library.spaces) { space in
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { browser.switchSpace(to: space) }
                        } label: {
                            SymbolOrEmoji(icon: space.icon, size: 14)
                                .frame(width: 36, height: 36)
                                .background(space === browser.space ? theme.tile : .clear, in: Circle())
                                .contentShape(Circle())
                        }
                        .accessibilityLabel(space.name)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity)
            Menu {
                Button("Neuer Space", systemImage: "plus.square.on.square") { browser.addSpace() }
                Button("Neuer Ordner", systemImage: "folder.badge.plus") { browser.newFolder() }
                Divider()
                Button("Code scannen", systemImage: "qrcode.viewfinder") { browser.present(.scanner) }
                Button("Geteilten Link einfügen", systemImage: "doc.on.clipboard") {
                    if let text = UIPasteboard.general.string, let link = ShareURL(string: text) {
                        browser.present(.importShare(link))
                    } else {
                        browser.showToast("Kein OpenArch-Link in der Zwischenablage")
                    }
                }
            } label: {
                Image(systemName: "plus").frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .accessibilityLabel("Hinzufügen")
        }
        .font(.system(size: 17, weight: .semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
