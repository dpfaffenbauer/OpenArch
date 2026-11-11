import AppKit
import OpenArchLocalization

/// Several sidebar rows at once, as in Arc: ⇧-click selects the rows from
/// the last one clicked to this one, ⌘⇧-click (or ⌘-click while rows are
/// selected) adds or removes one. A plain ⌘-click still loads a tab in the
/// background. Selected rows move together when dragged, and the selection's
/// menu archives them, puts them in a new folder or another space, and
/// copies their addresses (⇧⌘C too).
extension BrowserWindowController {
    /// The rows that can be selected, in sidebar order: pinned (the inside
    /// of open folders too), then today. A split view is one row.
    var selectableRows: [Item] {
        func rows(_ items: [Item]) -> [Item] {
            items.flatMap { item -> [Item] in
                item.kind == .folder && item.isExpanded ? [item] + rows(item.children) : [item]
            }
        }
        return (isStandalone ? [] : rows(state.space.pinned.items)) + rows(state.space.today.items)
    }

    /// The selected rows that are still there, in sidebar order.
    var selectedItems: [Item] {
        let ids = Set(state.selection)
        guard !ids.isEmpty else { return [] }
        return selectableRows.filter { ids.contains($0.id) }
    }

    /// Handles a click with ⇧ or ⌘ as a selection; false when it is none
    /// (then it selects or loads as before).
    func selectionClick(_ item: Item, modifiers: NSEvent.ModifierFlags) -> Bool {
        let row = item.split ?? item
        guard row.role == .pinned || row.role == .today else { return false }
        let shift = modifiers.contains(.shift), command = modifiers.contains(.command)
        if shift && command || command && !state.selection.isEmpty {
            toggleSelection(row)
            return true
        }
        if shift {
            extendSelection(to: row)
            return true
        }
        return false
    }

    /// Adds |row| to the selection, or takes it out. The first one added
    /// joins the row that is shown, as it already looks selected.
    func toggleSelection(_ row: Item) {
        if state.selection.isEmpty, let shown = state.shownItem, shown !== row, shown.role == .pinned || shown.role == .today {
            state.selection = [shown.id]
        }
        if let index = state.selection.firstIndex(of: row.id) {
            state.selection.remove(at: index)
        } else {
            state.selection.append(row.id)
        }
        state.selectionAnchorID = row.id
    }

    /// Selects the rows from the anchor (the last row clicked, or the one
    /// shown) to |row|.
    func extendSelection(to row: Item) {
        let rows = selectableRows
        let anchorID = state.selectionAnchorID ?? state.shownItem?.id
        guard let end = rows.firstIndex(where: { $0 === row }) else { return }
        let start = rows.firstIndex { $0.id == anchorID } ?? end
        state.selection = rows[min(start, end)...max(start, end)].map(\.id)
        if state.selectionAnchorID == nil { state.selectionAnchorID = rows[start].id }
    }

    func clearSelection() {
        if !state.selection.isEmpty { state.selection = [] }
        state.selectionAnchorID = nil
    }

    func isSelected(_ item: Item) -> Bool {
        state.selection.contains(item.id)
    }

    /// Several rows are selected and |item| is one of them: its menu and its
    /// drag act on all of them.
    func actsOnSelection(_ item: Item) -> Bool {
        isSelected(item.split ?? item) && selectedItems.count > 1
    }

    /// The selection without rows inside a selected folder (they go along
    /// with it).
    private var selectionRoots: [Item] {
        let items = selectedItems
        return items.filter { item in !items.contains { $0 !== item && $0.kind == .folder && item.isDescendant(of: $0) } }
    }

    /// The tabs of the selection: tabs, the tabs of splits and folders.
    var selectedTabs: [Item] {
        selectionRoots.flatMap { $0.kind == .tab ? [$0] : $0.descendants.filter { $0.kind == .tab } }
    }

    /// ⇧⌘C with rows selected: every address, one per line.
    func copySelectedURLs() {
        let urls = selectedTabs.map(\.currentURL).filter { !$0.isEmpty }
        guard !urls.isEmpty else { return }
        OpenArch.copy(urls.joined(separator: "\n"))
        showToast(Localization.count(urls.count, one: "Link kopiert", other: "%lld Links kopiert"))
    }

    /// Today tabs close into the archive (⇧⌘T brings them back), pinned
    /// tabs and splits go into it too. Folders and agent chats stay: they
    /// have no way back from the archive.
    @discardableResult
    func archiveSelection() -> Int {
        var count = 0
        for row in selectionRoots where row.kind == .tab || row.kind == .split {
            count += row.kind == .tab ? 1 : row.children.count
            if row.role == .today {
                close(row)
            } else {
                deletePinned(row)
            }
        }
        clearSelection()
        if count > 0 { showToast(Localization.count(count, one: "1 Tab archiviert", other: "%lld Tabs archiviert"), symbol: "archivebox") }
        return count
    }

    /// „Neuer Ordner mit N Tabs“: a pinned folder in place of the first
    /// selected row, with the selection in it, ready to be named.
    @discardableResult
    func newFolderWithSelection() -> Item? {
        let rows = selectionRoots
        guard !rows.isEmpty, !isStandalone else { return nil }
        let folder = Item.folder(L("Neuer Ordner"))
        let pinned = state.space.pinned
        if let first = rows.first, first.container === pinned {
            pinned.insert(folder, into: first.parent, at: first.indexInParent)
        } else {
            pinned.insert(folder, at: 0)
        }
        for row in rows {
            if row.role == .today, row.kind == .tab {
                row.savedURL = row.currentURL
                if let title = row.liveTitle { row.savedTitle = title }
            }
            for tab in row.descendants where tab.kind == .tab && tab.role == .today {
                tab.savedURL = tab.currentURL
            }
            pinned.insert(row, into: folder)
        }
        clearSelection()
        state.renamingItemID = folder.id
        library.setNeedsSave()
        return folder
    }

    func moveSelection(toSpace space: Space) {
        for row in selectionRoots {
            moveToSpace(row, space)
        }
        clearSelection()
    }

    /// Moves several dragged rows to |target|, keeping their order.
    func moveAll(_ items: [Item], to target: DropTarget) {
        var anchor = target
        for item in items {
            move(item, to: anchor)
            // The next one goes after the one just moved.
            switch anchor {
            case .after, .before: anchor = .after(item)
            case .split: return
            default: break
            }
        }
        clearSelection()
    }

    /// What dragging |item| carries: its id, or the ids of all selected rows
    /// (one per line) when it is one of them.
    func dragProvider(for item: Item) -> NSItemProvider {
        guard actsOnSelection(item) else { return tabDragProvider(item) }
        return tabDragProvider(ids: selectionRoots.map(\.id))
    }
}
