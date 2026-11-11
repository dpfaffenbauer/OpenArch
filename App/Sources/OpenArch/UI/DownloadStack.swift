import AppKit
import QuickLookThumbnailing
import OpenArchLocalization
import SwiftUI
import UniformTypeIdentifiers

/// The newest downloads over the library button, like Arc: a click on the
/// button brings them up, and a click on it again, beside them, on the page
/// or Escape puts them away. A click on a file opens it, and it can be
/// dragged out like from Finder.
@MainActor @Observable
final class DownloadStack {
    private(set) var isShown = false
    /// The files in the download folder, newest first.
    private(set) var files: [LibraryFile] = []
    private(set) var isLoaded = false
    @ObservationIgnored private var monitor: Any?

    /// Where downloads land: the self-test's own folder, else Downloads.
    static var folder: URL {
        AppPaths.isSelfTest ? SelfTest.downloadFolder
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    func toggle() {
        if isShown { dismiss() } else { show() }
    }

    func show() {
        Task { await reload() }
        guard !isShown else { return }
        // A click in another window (a page is a window of its own) or
        // Escape puts the stack away; clicks in the sidebar are its own.
        weak var window = NSApp.currentEvent?.window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let escape = event.type == .keyDown && event.keyCode == 53
            let elsewhere = event.type != .keyDown && event.window !== window
            guard escape || elsewhere else { return event }
            MainActor.assumeIsolated { self?.dismiss() }
            return escape ? nil : event
        }
        set(true)
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        set(false)
    }

    func reload() async {
        let folder = Self.folder
        let files = await Task.detached { LibraryFiles.scan(folder) }.value
        self.files = files
        isLoaded = true
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
        case .images: L("Bilder")
        case .media: L("Videos und Musik")
        case .documents: L("Dokumente")
        case .archives: L("Archive, Apps und Installer")
        case .other: L("Andere")
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
                        Text(L(files.count < stack.files.count ? "Keine passenden Downloads" : "Keine Downloads"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 40)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
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
        .overlay {
            FileDrag(url: file.url) {
                NSWorkspace.shared.open(file.url)
                stack.dismiss()
            } moved: {
                Task { await stack.reload() }
            }
        }
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
        Toggle("Klick zeigt die letzten Downloads", isOn: Binding(
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

/// Clicks and drags on a file, the way Finder does them: the file's URL on
/// the pasteboard and its icon under the pointer, so that other apps get
/// the file itself; dropped on a folder in Finder, it moves there. Right
/// clicks go on to SwiftUI for the context menu.
private struct FileDrag: NSViewRepresentable {
    let url: URL
    let click: () -> Void
    /// The file left its folder (moved or put in the trash by the drop).
    let moved: () -> Void

    func makeNSView(context: Context) -> FileDragView { FileDragView() }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.url = url
        view.click = click
        view.moved = moved
    }
}

private final class FileDragView: NSView, NSDraggingSource {
    var url: URL?
    var click: () -> Void = {}
    var moved: () -> Void = {}
    private var mouseDown: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: super.hitTest(point)
        default: nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDown = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDown, let url,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3 else { return }
        mouseDown = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDown != nil { click() }
        mouseDown = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic, .move, .delete] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.contains(.move) || operation.contains(.delete) { moved() }
    }
}
