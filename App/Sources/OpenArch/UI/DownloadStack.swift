import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The newest downloads over the library button, like Arc: they show while
/// the pointer rests on the button and stay while it is on them. A click on
/// one opens it, and it can be dragged out.
@MainActor @Observable
final class DownloadStack {
    private(set) var isShown = false
    /// The files in the download folder, newest first.
    private(set) var files: [LibraryFile] = []
    private(set) var isLoaded = false
    @ObservationIgnored private var onButton = false
    @ObservationIgnored private var onFiles = false
    @ObservationIgnored private var pending: Task<Void, Never>?

    /// Where downloads land: the self-test's own folder, else Downloads.
    static var folder: URL {
        AppPaths.isSelfTest ? SelfTest.downloadFolder
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    func hoverButton(_ hovering: Bool) {
        onButton = hovering
        // Read the folder while the pointer rests, so the files are there
        // when the stack comes up.
        if hovering, !isShown { Task { await reload() } }
        settle(after: hovering ? 0.35 : 0.3)
    }

    func hoverFiles(_ hovering: Bool) {
        onFiles = hovering
        settle(after: 0.3)
    }

    func show() {
        pending?.cancel()
        Task { await reload() }
        set(true)
    }

    func dismiss() {
        pending?.cancel()
        onButton = false
        onFiles = false
        set(false)
    }

    func reload() async {
        let folder = Self.folder
        let files = await Task.detached { LibraryFiles.scan(folder) }.value
        self.files = files
        isLoaded = true
    }

    /// Shows or hides the stack once the pointer has stayed a moment, so
    /// that passing over the button or the gap to the files does nothing.
    private func settle(after delay: Double) {
        pending?.cancel()
        let wanted = onButton || onFiles
        guard wanted != isShown else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.set(wanted)
        }
    }

    private func set(_ shown: Bool) {
        guard shown != isShown else { return }
        withAnimation(.snappy(duration: 0.22)) { isShown = shown }
    }
}

/// What the stack can leave out (right click on the library button).
enum DownloadKind: String, CaseIterable, Identifiable {
    case images, media, documents, archives, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: "Bilder"
        case .media: "Videos und Musik"
        case .documents: "Dokumente"
        case .archives: "Archive, Apps und Installer"
        case .other: "Andere"
        }
    }

    init(_ file: LibraryFile) {
        guard let type = UTType(filenameExtension: file.url.pathExtension) else {
            self = .other
            return
        }
        if type.conforms(to: .image) {
            self = .images
        } else if type.conforms(to: .audiovisualContent) {
            self = .media
        } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.conforms(to: .application)
                    || type.identifier == "com.apple.installer-package-archive" {
            self = .archives
        } else if type.conforms(to: .content) {
            self = .documents
        } else {
            self = .other
        }
    }
}

/// The stack itself, at the bottom of the sidebar over its blurred content:
/// the newest file nearest the button, as many as there is room for, then
/// what is still downloading.
struct DownloadStackView: View {
    let browser: BrowserWindowController
    let stack: DownloadStack
    let theme: SpaceTheme
    @State private var risen = false

    static let rowHeight: CGFloat = 56

    var body: some View {
        let hidden = Set(browser.library.settings.downloadStackHidden)
        let running = Downloads.shared.running
        let files = hidden.isEmpty ? stack.files : stack.files.filter { !hidden.contains(DownloadKind($0).rawValue) }
        GeometryReader { proxy in
            let room = max(1, Int((proxy.size.height - 12) / Self.rowHeight) - running.count)
            // Oldest at the top, the newest just over the button.
            let shown = Array(files.prefix(min(room, 12)).reversed())
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                        StackFileRow(browser: browser, stack: stack, file: file, theme: theme)
                            .rising(risen, fromBelow: shown.count - index + running.count)
                    }
                    ForEach(Array(running.enumerated()), id: \.element.id) { index, download in
                        StackRunningRow(download: download, theme: theme)
                            .rising(risen, fromBelow: running.count - index)
                    }
                    if stack.isLoaded && shown.isEmpty && running.isEmpty {
                        Text(files.count < stack.files.count ? "Keine passenden Downloads" : "Keine Downloads")
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 40)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onHover { stack.hoverFiles($0) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        // A click beside the files puts the sidebar back.
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { stack.dismiss() })
        .task(id: Downloads.shared.finished) { await stack.reload() }
        .onAppear { risen = true }
    }
}

private extension View {
    /// Rows rise out of the button one after the other, the nearest first.
    func rising(_ risen: Bool, fromBelow distance: Int) -> some View {
        offset(y: risen ? 0 : CGFloat(8 + distance * 6))
            .opacity(risen ? 1 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.82).delay(Double(distance - 1) * 0.02), value: risen)
    }
}

private struct StackFileRow: View {
    let browser: BrowserWindowController
    let stack: DownloadStack
    let file: LibraryFile
    let theme: SpaceTheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StackThumbnail(url: file.url)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(age(file.date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: DownloadStackView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            NSWorkspace.shared.open(file.url)
            stack.dismiss()
        }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .contextMenu {
            FileMenu(browser: browser, file: file) { Task { await stack.reload() } }
        }
        .help(file.url.lastPathComponent)
    }

    private func age(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "gerade eben" : date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
    }
}

/// A download still on its way, with a button to stop it.
private struct StackRunningRow: View {
    let download: Downloads.Running
    let theme: SpaceTheme

    var body: some View {
        HStack(spacing: 12) {
            let type = UTType(filenameExtension: (download.name as NSString).pathExtension) ?? .data
            Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(download.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
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
        .padding(.horizontal, 6)
        .frame(height: DownloadStackView.rowHeight)
    }
}

/// The file's Quick Look picture where it has one (a PDF's first page),
/// else its icon.
private struct StackThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 40, height: 40)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40),
                                                       scale: 2, representationTypes: .thumbnail)
            thumbnail = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request))?.nsImage
        }
    }
}

/// Right click on the library button: the library, and what the downloads
/// stack over it shows.
struct LibraryButtonMenu: View {
    let browser: BrowserWindowController

    var body: some View {
        let library = browser.library
        Button("Bibliothek öffnen") { browser.showLibrary(browser.state.librarySection) }
        Button("Downloads in der Bibliothek") { browser.showLibrary(.downloads) }
        Button("Downloads-Ordner im Finder") { NSWorkspace.shared.open(DownloadStack.folder) }
        Divider()
        Toggle("Letzte Downloads beim Darüberfahren", isOn: Binding(
            get: { library.settings.downloadStack },
            set: {
                library.settings.downloadStack = $0
                library.setNeedsSave()
            }))
        Section("Darin zeigen") {
            ForEach(DownloadKind.allCases) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { !library.settings.downloadStackHidden.contains(kind.rawValue) },
                    set: { shown in
                        library.settings.downloadStackHidden.removeAll { $0 == kind.rawValue }
                        if !shown { library.settings.downloadStackHidden.append(kind.rawValue) }
                        library.setNeedsSave()
                    }))
            }
        }
        .disabled(!library.settings.downloadStack)
    }
}
