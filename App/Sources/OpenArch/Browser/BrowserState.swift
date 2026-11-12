import Foundation
import OpenArchLocalization
import Observation

/// What the sidebar and command bar observe about one browser window.
@MainActor @Observable
final class BrowserState {
    var space: Space
    /// The focused tab. In a split view, the focused side.
    var activeItem: Item?
    var sidebarVisible = true
    /// Item being renamed inline in the sidebar.
    var renamingItemID: UUID?
    /// Sidebar rows selected with ⇧- or ⌘⇧-click (SidebarSelection).
    var selection: [UUID] = []
    /// Where a ⇧-click range starts: the row clicked last.
    @ObservationIgnored var selectionAnchorID: UUID?
    /// The closed folder whose tabs show beside it (FolderPreview).
    var folderPreviewID: UUID?
    @ObservationIgnored var folderPreviewTimer: DispatchWorkItem?
    /// Space whose editor popover is open.
    var editingSpaceID: UUID?
    /// The Site Control Center popover is open.
    var siteControlsVisible = false
    /// The space icon being dragged to another place in the space bar.
    var draggingSpaceID: UUID?
    /// A sidebar tab is being dragged: empty favorites and pinned expand
    /// their drop placeholders until the drag ends.
    var tabDragActive = false
    /// Agents (⌃0) take the sidebar's place, like a space of their own.
    var agentsVisible = false
    /// The library (media, downloads, spaces, archive) replaces the sidebar.
    var libraryVisible = false
    var librarySection = LibrarySection.media
    /// The newest downloads over the library button.
    let downloadStack = DownloadStack()
    /// Horizontal offset of the sidebar while it is being swiped.
    var swipeOffset: CGFloat = 0
    /// The Mac is in dark mode, which auto themes follow.
    var systemDark = false
    /// The library button and the whole sidebar, both in SwiftUI's global
    /// coordinates (whose origin depends on the safe area), for downloads
    /// flying into the button.
    @ObservationIgnored var libraryButtonFrame = CGRect.zero
    @ObservationIgnored var sidebarFrame = CGRect.zero

    init(space: Space) {
        self.space = space
    }

    /// The tab or split shown in the content area.
    var shownItem: Item? {
        activeItem?.split ?? activeItem
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case history, media, downloads, spaces, archive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: L("Verlauf")
        case .media: L("Medien")
        case .downloads: L("Downloads")
        case .spaces: L("Spaces")
        case .archive: L("Archiv")
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .media: "photo.on.rectangle"
        case .downloads: "arrow.down.circle"
        case .spaces: "square.on.square"
        case .archive: "archivebox"
        }
    }
}
