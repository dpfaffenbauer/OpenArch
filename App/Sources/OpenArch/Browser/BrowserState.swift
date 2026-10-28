import Foundation
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
    /// Space whose editor popover is open.
    var editingSpaceID: UUID?
    /// The Site Control Center popover is open.
    var siteControlsVisible = false
    /// The space icon being dragged to another place in the space bar.
    var draggingSpaceID: UUID?
    /// The library (media, downloads, spaces, archive) replaces the sidebar.
    var libraryVisible = false
    var librarySection = LibrarySection.media
    /// Horizontal offset of the sidebar while it is being swiped.
    var swipeOffset: CGFloat = 0
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
    case media, downloads, spaces, archive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: "Medien"
        case .downloads: "Downloads"
        case .spaces: "Spaces"
        case .archive: "Archiv"
        }
    }

    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle"
        case .downloads: "arrow.down.circle"
        case .spaces: "square.on.square"
        case .archive: "archivebox"
        }
    }
}
