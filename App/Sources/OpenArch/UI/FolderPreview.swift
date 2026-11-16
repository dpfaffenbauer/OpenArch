import OpenArchLocalization
import SwiftUI

/// Resting the pointer on a closed folder shows its tabs beside it, as in
/// Arc: a list to search, where a click opens a tab without opening the
/// folder.
enum FolderPreview {
    static let delay = 0.45

    /// What the list shows: the folder's tabs and agent chats, those in
    /// subfolders and split views too, in sidebar order.
    @MainActor static func entries(in folder: Item) -> [Item] {
        folder.descendants.filter { $0.kind == .tab || $0.kind == .agent }
    }

    /// The entries whose title or address contain every word of |query|.
    @MainActor static func filter(_ entries: [Item], _ query: String) -> [Item] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = (entry.displayTitle + " " + entry.currentURL).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

extension BrowserWindowController {
    /// The pointer entered or left a folder's row, or its preview.
    func hoverFolder(_ folder: Item, inside: Bool) {
        state.folderPreviewTimer?.cancel()
        let id = folder.id
        if inside {
            guard !folder.isExpanded, state.folderPreviewID != id else { return }
            let show = DispatchWorkItem { [weak self] in
                guard let self, !folder.isExpanded, folder.container != nil else { return }
                self.state.folderPreviewID = id
            }
            state.folderPreviewTimer = show
            DispatchQueue.main.asyncAfter(deadline: .now() + FolderPreview.delay, execute: show)
        } else if state.folderPreviewID == id {
            // A moment's grace, for the way from the row to the list.
            let hide = DispatchWorkItem { [weak self] in
                guard let self, self.state.folderPreviewID == id else { return }
                self.state.folderPreviewID = nil
            }
            state.folderPreviewTimer = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: hide)
        }
    }

    /// A tab picked in a folder's preview.
    func openFromFolderPreview(_ item: Item) {
        state.folderPreviewTimer?.cancel()
        state.folderPreviewID = nil
        select(item)
    }
}

/// The list beside a closed folder.
struct FolderPreviewView: View {
    let browser: BrowserWindowController
    let folder: Item
    @State private var query = ""
    @State private var hovered: UUID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let entries = FolderPreview.entries(in: folder)
        let shown = FolderPreview.filter(entries, query)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).opacity(0.5)
                TextField(L("%@ durchsuchen", folder.displayTitle), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = shown.first { browser.openFromFolderPreview(first) }
                    }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            Divider()
            if shown.isEmpty {
                Text(L(entries.isEmpty ? "Der Ordner ist leer" : "Nichts gefunden"))
                    .font(.system(size: 12))
                    .opacity(0.5)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(shown) { entry in
                            row(entry)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 250)
        .onHover { browser.hoverFolder(folder, inside: $0) }
    }

    private func row(_ entry: Item) -> some View {
        HStack(spacing: 8) {
            if entry.kind == .agent {
                Image(systemName: "sparkles").font(.system(size: 12)).frame(width: 15)
            } else {
                FaviconView(item: entry, size: 15)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.displayTitle).font(.system(size: 12.5)).lineLimit(1)
                if entry.kind == .tab {
                    Text(CommandBarModel.shortURL(entry.currentURL)).font(.system(size: 10.5)).opacity(0.55).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.pane != nil {
                Circle().fill(Color.primary.opacity(0.45)).frame(width: 5, height: 5).help("Geladen")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovered == entry.id ? 0.09 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .onTapGesture { browser.openFromFolderPreview(entry) }
        .help(entry.currentURL)
    }
}
