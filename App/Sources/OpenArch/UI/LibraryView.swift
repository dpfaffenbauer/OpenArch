import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Arc's library, in place of the sidebar: media, downloads, spaces and
/// archived tabs.
struct LibraryView: View {
    let browser: BrowserWindowController
    @State private var query = ""
    @State private var files = LibraryFiles()

    var body: some View {
        let state = browser.state
        let theme = SpaceTheme(hex: state.space.colorHex)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: 72)
                IconButton(symbol: "sidebar.left", help: "Sidebar ausblenden (⌘S)") { browser.toggleSidebar() }
                Spacer()
                IconButton(symbol: "xmark", help: "Bibliothek schließen (⌥⌘B)") { browser.toggleLibrary() }
            }
            .frame(height: 30)
            .padding(.bottom, 6)

            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 4) {
                    ForEach(LibrarySection.allCases) { section in
                        LibrarySectionButton(section: section, isSelected: state.librarySection == section, theme: theme) {
                            state.librarySection = section
                            query = ""
                        }
                    }
                    Spacer()
                }
                .frame(width: 78)

                VStack(alignment: .leading, spacing: 8) {
                    SearchField(text: $query, placeholder: "\(state.librarySection.title) durchsuchen …", theme: theme)
                    Group {
                        switch state.librarySection {
                        case .media: MediaSection(browser: browser, files: files, query: query, theme: theme)
                        case .downloads: DownloadsSection(browser: browser, files: files, query: query, theme: theme)
                        case .spaces: SpacesSection(browser: browser, query: query, theme: theme)
                        case .archive: ArchiveSection(browser: browser, query: query, theme: theme)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .foregroundStyle(theme.foreground)
        .environment(\.colorScheme, theme.colorScheme)
        .ignoresSafeArea()
    }
}

private struct LibrarySectionButton: View {
    let section: LibrarySection
    let isSelected: Bool
    let theme: SpaceTheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: section.symbol).font(.system(size: 18, weight: .regular))
            Text(section.title).font(.system(size: 11, weight: .semibold))
        }
        .frame(width: 76, height: 64)
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? theme.tile : (hovering ? theme.hover : .clear)))
        .opacity(isSelected ? 1 : 0.75)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

private struct SearchField: View {
    @Binding var text: String
    let placeholder: String
    let theme: SpaceTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).opacity(0.6)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.tile))
    }
}

// MARK: - Files

struct LibraryFile: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    let size: Int
    let isDirectory: Bool
    let isMedia: Bool
    var id: URL { url }
}

/// Files in Downloads (and screenshots on the Desktop) for the library.
@MainActor @Observable
final class LibraryFiles {
    private(set) var downloads: [LibraryFile] = []
    private(set) var media: [LibraryFile] = []
    private(set) var isLoaded = false

    func reload() async {
        // The background self-test must not trigger macOS's folder prompts.
        guard !AppPaths.isSelfTest else {
            isLoaded = true
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let (downloads, desktop) = await Task.detached {
            (Self.scan(home.appendingPathComponent("Downloads")), Self.scan(home.appendingPathComponent("Desktop")))
        }.value
        self.downloads = downloads
        media = (downloads + desktop).filter(\.isMedia).sorted { $0.date > $1.date }
        isLoaded = true
    }

    nonisolated private static func scan(_ directory: URL) -> [LibraryFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .contentTypeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let type = values.contentType
            return LibraryFile(url: url, date: values.contentModificationDate ?? .distantPast,
                               size: values.fileSize ?? 0, isDirectory: values.isDirectory ?? false,
                               isMedia: type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true)
        }
        .sorted { $0.date > $1.date }
        .prefix(400)
        .map { $0 }
    }
}

private func matches(_ query: String, _ text: String) -> Bool {
    let words = query.lowercased().split(separator: " ")
    let haystack = text.lowercased()
    return words.allSatisfy { haystack.contains($0) }
}

private struct MediaSection: View {
    let browser: BrowserWindowController
    let files: LibraryFiles
    let query: String
    let theme: SpaceTheme

    var body: some View {
        let items = files.media.filter { query.isEmpty || matches(query, $0.url.lastPathComponent) }
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(items) { file in
                    FileThumbnail(url: file.url)
                        .frame(height: 110)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tile))
                        .contentShape(Rectangle())
                        .onTapGesture { NSWorkspace.shared.open(file.url) }
                        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
                        .contextMenu { FileMenu(browser: browser, file: file) }
                        .help(file.url.lastPathComponent)
                }
            }
        }
        .scrollIndicators(.never)
        .overlay { EmptyHint(isEmpty: files.isLoaded && items.isEmpty, text: "Keine Bilder in Downloads oder auf dem Schreibtisch") }
        .task(id: Downloads.shared.finished) { await files.reload() }
    }
}

private struct DownloadsSection: View {
    let browser: BrowserWindowController
    let files: LibraryFiles
    let query: String
    let theme: SpaceTheme

    var body: some View {
        let items = files.downloads.filter { query.isEmpty || matches(query, $0.url.lastPathComponent) }
        let running = Downloads.shared.running
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(running) { download in
                    RunningDownloadRow(download: download, theme: theme)
                }
                ForEach(items) { file in
                    DownloadFileRow(browser: browser, file: file, subtitle: subtitle(file), theme: theme)
                }
            }
        }
        .scrollIndicators(.never)
        .overlay { EmptyHint(isEmpty: files.isLoaded && items.isEmpty && running.isEmpty, text: "Keine Downloads") }
        .task(id: Downloads.shared.finished) { await files.reload() }
    }

    private func subtitle(_ file: LibraryFile) -> String {
        let date = file.date.formatted(.relative(presentation: .named))
        return file.isDirectory ? date : "\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)) · \(date)"
    }
}

/// A download still on its way: how far it is, and a button to stop it.
private struct RunningDownloadRow: View {
    let download: Downloads.Running
    let theme: SpaceTheme

    var body: some View {
        LibraryRow(theme: theme) {
            let type = UTType(filenameExtension: (download.name as NSString).pathExtension) ?? .data
            Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(download.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                if download.progress >= 0 {
                    ProgressView(value: download.progress).controlSize(.small).tint(theme.foreground)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small).tint(theme.foreground)
                }
            }
            Button { Downloads.shared.cancel(download.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .opacity(0.7)
            .help("Download abbrechen")
        }
    }
}

/// A file in Downloads; resting the pointer on it shows a preview.
private struct DownloadFileRow: View {
    let browser: BrowserWindowController
    let file: LibraryFile
    let subtitle: String
    let theme: SpaceTheme
    @State private var hovering = false
    @State private var previewing = false

    var body: some View {
        LibraryRow(theme: theme) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11)).opacity(0.6)
            }
        }
        .onTapGesture { NSWorkspace.shared.open(file.url) }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .contextMenu { FileMenu(browser: browser, file: file) }
        .onHover { hovering = $0 }
        .task(id: hovering) {
            // Only after the pointer rests a moment, not while it passes by.
            if hovering {
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { previewing = true }
            } else {
                previewing = false
            }
        }
        .popover(isPresented: $previewing, arrowEdge: .trailing) {
            VStack(spacing: 8) {
                FileThumbnail(url: file.url, size: 260)
                    .frame(width: 260, height: 220)
                Text(file.url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(width: 284)
        }
    }
}

private struct FileMenu: View {
    let browser: BrowserWindowController
    let file: LibraryFile

    var body: some View {
        Button("Öffnen") { NSWorkspace.shared.open(file.url) }
        Button("In neuem Tab öffnen") { browser.openInNewTab(file.url.absoluteString) }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Divider()
        Button("In den Papierkorb") { NSWorkspace.shared.recycle([file.url]) }
    }
}

/// A Quick Look thumbnail, loaded lazily.
private struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 200
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .padding(10)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                       scale: 2, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = thumbnail.nsImage
            }
        }
    }
}

// MARK: - Spaces and archive

private struct SpacesSection: View {
    let browser: BrowserWindowController
    let query: String
    let theme: SpaceTheme

    var body: some View {
        let library = browser.library
        let spaces = library.spaces.filter { query.isEmpty || matches(query, $0.name) }
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(spaces) { space in
                    LibraryRow(theme: theme, isSelected: browser.state.space === space) {
                        SpaceIcon(icon: space.icon, size: 13)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color(nsColor: space.color)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(space.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("Profil: \(library.profile(id: space.profileID).name) · \(space.pinned.allTabs.count) angeheftet, \(space.today.allTabs.count) offen")
                                .font(.system(size: 11)).opacity(0.6).lineLimit(1)
                        }
                    }
                    .onTapGesture {
                        browser.switchSpace(to: space)
                        browser.toggleLibrary()
                    }
                    .contextMenu {
                        Button("Bearbeiten …") {
                            browser.switchSpace(to: space)
                            browser.toggleLibrary()
                            browser.state.editingSpaceID = space.id
                        }
                        Button("Nach oben") { library.moveSpace(space, by: -1) }
                        Button("Nach unten") { library.moveSpace(space, by: 1) }
                        Divider()
                        Button("Löschen …") { browser.deleteSpace(space) }.disabled(library.spaces.count < 2)
                    }
                }
                Button {
                    browser.toggleLibrary()
                    browser.addSpace()
                } label: {
                    Label("Neuer Space", systemImage: "plus")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .opacity(0.75)
            }
        }
        .scrollIndicators(.never)
    }
}

private struct ArchiveSection: View {
    let browser: BrowserWindowController
    let query: String
    let theme: SpaceTheme

    var body: some View {
        let library = browser.library
        let tabs = library.archive.filter { query.isEmpty || matches(query, $0.title + " " + $0.url) }
        VStack(spacing: 6) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { _, tab in
                        LibraryRow(theme: theme) {
                            ArchivedFavicon(url: tab.url)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.title.isEmpty ? tab.url : tab.title).font(.system(size: 13)).lineLimit(1)
                                Text("\(CommandBarModel.shortURL(tab.url)) · \(tab.date.formatted(.relative(presentation: .named)))")
                                    .font(.system(size: 11)).opacity(0.6).lineLimit(1)
                            }
                        }
                        .onTapGesture { browser.restoreArchived(tab) }
                        .contextMenu {
                            Button("Wiederherstellen") { browser.restoreArchived(tab) }
                            Button("URL kopieren") { copy(tab.url) }
                            Button("Aus dem Archiv entfernen") { library.removeArchived(tab) }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .overlay { EmptyHint(isEmpty: tabs.isEmpty, text: "Archivierte Tabs erscheinen hier") }
            if !library.archive.isEmpty {
                Button("Archiv leeren") { library.clearArchive() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.6)
            }
        }
    }
}

private struct ArchivedFavicon: View {
    let url: String

    var body: some View {
        Group {
            if let image = FaviconStore.shared.image(forURL: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe").resizable().aspectRatio(contentMode: .fit).opacity(0.6)
            }
        }
        .frame(width: 16, height: 16)
        .frame(width: 26)
    }
}

private struct LibraryRow<Content: View>: View {
    let theme: SpaceTheme
    var isSelected = false
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? theme.selection : (hovering ? theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct EmptyHint: View {
    let isEmpty: Bool
    let text: String

    var body: some View {
        if isEmpty {
            Text(text).font(.system(size: 12)).opacity(0.5).multilineTextAlignment(.center).padding()
        }
    }
}
