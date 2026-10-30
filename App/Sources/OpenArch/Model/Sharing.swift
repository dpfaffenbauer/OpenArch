import AppKit
import OpenArchShared

/// A pinned folder or a space, to share.
enum ShareTarget {
    case folder(Item)
    case space(Space)

    var id: UUID {
        switch self {
        case .folder(let item): item.id
        case .space(let space): space.id
        }
    }

    @MainActor var name: String {
        switch self {
        case .folder(let item): item.displayTitle
        case .space(let space): space.name
        }
    }

    var kind: SharePayload.Kind {
        switch self {
        case .folder: .folder
        case .space: .space
        }
    }
}

/// Shared folders and spaces without an account (docs/sharing.md): the
/// live shares made on this Mac, uploaded again when they change, and the
/// shares it follows, fetched every five minutes like live folders. The keys
/// are kept in Shares.json next to the library.
@MainActor @Observable
final class Sharing {
    static let shared = Sharing()

    private(set) var records: ShareRecords
    /// Why the last upload or update failed, for Settings.
    var lastError: String?

    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private let fileURL = AppPaths.support.appendingPathComponent("Shares.json")
    @ObservationIgnored private var uploading: Set<String> = []
    @ObservationIgnored private var changedWhileUploading: Set<String> = []
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var timer: Timer?

    private init() {
        records = ShareRecords.load(from: fileURL)
    }

    func start(_ library: Library) {
        self.library = library
        guard !records.subscriptions.isEmpty || !records.owned.isEmpty else { return startTimer() }
        Task { await refresh() }
        libraryDidSave()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { Task { await Sharing.shared.refresh() } }
        }
    }

    private func save() {
        do {
            try records.save(to: fileURL)
        } catch {
            log("could not save shares: \(error)")
        }
    }

    // MARK: Lookup

    func owned(_ id: UUID) -> OwnedShare? {
        records.owned(source: id)
    }

    func subscription(_ id: UUID) -> ShareSubscription? {
        records.subscription(target: id)
    }

    func isShared(_ id: UUID) -> Bool {
        owned(id) != nil || subscription(id) != nil
    }

    /// The folder or space a share of this Mac shows; nil once deleted.
    func target(of share: OwnedShare) -> ShareTarget? {
        switch share.kind {
        case .folder: library?.item(id: share.source).flatMap { $0.kind == .folder ? .folder($0) : nil }
        case .space: library?.space(id: share.source).map { .space($0) }
        }
    }

    // MARK: What a share shows

    func payload(for target: ShareTarget) -> SharePayload {
        switch target {
        case .folder(let folder):
            SharePayload(kind: .folder, name: folder.displayTitle, icon: folder.icon,
                         items: folder.children.flatMap(Self.nodes))
        case .space(let space):
            SharePayload(kind: .space, name: space.name, icon: space.icon, color: space.colorHex,
                         items: space.pinned.items.flatMap(Self.nodes))
        }
    }

    /// A split view is shared as its tabs.
    static func nodes(_ item: Item) -> [ShareNode] {
        switch item.kind {
        case .tab:
            let title = item.customTitle ?? (item.savedTitle.isEmpty ? item.host : item.savedTitle)
            return [.tab(id: item.id, title: title, url: item.savedURL)]
        case .folder:
            return [.folder(id: item.id, title: item.displayTitle, icon: item.icon, children: item.children.flatMap(nodes))]
        case .split:
            return item.children.flatMap(nodes)
        }
    }

    // MARK: Sharing

    func makeLiveShare(for target: ShareTarget, password: String?) async throws -> OwnedShare {
        var share = OwnedShare.make(source: target.id, kind: target.kind, name: target.name,
                                    relay: library?.settings.shareRelayURL)
        if let password {
            let unprotected = share
            share = try await Task.detached {
                var protected = unprotected
                try protected.setPassword(password)
                return protected
            }.value
        }
        share = try await share.publish(payload(for: target))
        records.owned.removeAll { $0.source == target.id }
        records.owned.append(share)
        save()
        return share
    }

    func snapshotLink(for target: ShareTarget, password: String?) async throws -> ShareURL {
        let payload = payload(for: target)
        return try await Task.detached { try ShareReader.snapshotLink(payload, password: password) }.value
    }

    /// Ends a live share; those who added it keep what they have.
    func end(_ share: OwnedShare) async throws {
        do {
            try await share.end()
        } catch ShareError.notFound {
            // Never uploaded, or expired.
        }
        records.owned.removeAll { $0.id == share.id }
        save()
    }

    /// After every save of the library: shares whose folder or space changed
    /// are uploaded again.
    func libraryDidSave() {
        for share in records.owned {
            upload(share.id)
        }
    }

    private func upload(_ id: String) {
        guard let share = records.owned.first(where: { $0.id == id }), let target = target(of: share) else { return }
        let payload = payload(for: target)
        guard share.needsUpload(payload) else { return }
        guard !uploading.contains(id) else {
            changedWhileUploading.insert(id)
            return
        }
        uploading.insert(id)
        Task {
            do {
                let uploaded = try await share.publish(payload)
                if let index = records.owned.firstIndex(where: { $0.id == id }) {
                    records.owned[index].version = uploaded.version
                    records.owned[index].publishedHash = uploaded.publishedHash
                    records.owned[index].publishedAt = uploaded.publishedAt
                    save()
                }
                lastError = nil
            } catch {
                lastError = "„\(share.name)“: \(error.localizedDescription)"
            }
            uploading.remove(id)
            if changedWhileUploading.remove(id) != nil { upload(id) }
        }
    }

    // MARK: Adding shares

    /// Adds a share to the library: as a pinned folder in |space|, or as a
    /// space of its own (with |space|'s profile). Followed, it keeps up with
    /// the owner's changes; otherwise it is a copy.
    func add(_ opened: ShareReader.Opened, asSpace: Bool, follow: Bool, in space: Space,
             browser: BrowserWindowController?) {
        guard let library else { return }
        let payload = opened.payload
        let key = follow ? (opened.link.shareID ?? UUID().uuidString) : UUID().uuidString
        let targetID: UUID
        if asSpace {
            let used = Set(library.spaces.map(\.colorHex))
            let color = payload.color ?? spaceColorPresets.first { !used.contains($0) } ?? spaceColorPresets[0]
            let added = library.addSpace(name: payload.name, icon: payload.icon ?? "person.2.fill", colorHex: color,
                                         profileID: space.profileID)
            added.pinned.replace(with: items(from: payload.items, key: key))
            targetID = added.id
            browser?.switchSpace(to: added)
        } else {
            let folder = Item.folder(payload.name)
            folder.icon = Self.symbol(payload.icon)
            space.pinned.insert(folder, at: 0)
            folder.replaceChildren(with: items(from: payload.items, key: key))
            targetID = folder.id
        }
        if follow, let subscription = opened.subscription(target: targetID) {
            records.subscriptions.removeAll { $0.target == targetID }
            records.subscriptions.append(subscription)
            save()
        }
        library.setNeedsSave()
    }

    /// Stops following; the folder or space stays as it is.
    func unsubscribe(_ target: UUID) {
        records.subscriptions.removeAll { $0.target == target }
        save()
    }

    /// Fetches what changed in the shares this Mac follows.
    func refresh() async {
        guard !refreshing, library != nil else { return }
        refreshing = true
        defer { refreshing = false }
        for subscription in records.subscriptions where !subscription.ended {
            let id = subscription.id
            do {
                let update = try await subscription.fetchUpdate()
                if let update {
                    apply(update.payload, to: subscription.target, key: id)
                }
                updateSubscription(id) {
                    $0.lastChecked = Date()
                    if let update { $0.version = update.version }
                }
            } catch ShareError.ended, ShareError.notFound {
                updateSubscription(id) { $0.ended = true }
            } catch {
                lastError = "„\(subscription.name)“: \(error.localizedDescription)"
            }
        }
    }

    private func updateSubscription(_ id: String, _ change: (inout ShareSubscription) -> Void) {
        guard let index = records.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        change(&records.subscriptions[index])
        save()
    }

    /// The owner's new state. Tabs that went away stay while their page is
    /// open, as in live folders.
    private func apply(_ payload: SharePayload, to target: UUID, key: String) {
        guard let library else { return }
        if let space = library.space(id: target) {
            let before = space.pinned.allTabs
            space.name = payload.name
            if let icon = payload.icon { space.icon = icon }
            if let color = payload.color { space.colorHex = color }
            let items = items(from: payload.items, key: key)
            let kept = before.filter { tab in tab.pane != nil && !items.contains { $0 === tab || $0.descendants.contains { $0 === tab } } }
            space.pinned.replace(with: items + kept)
        } else if let folder = library.item(id: target), folder.kind == .folder {
            let before = folder.descendants.filter { $0.kind == .tab }
            folder.customTitle = payload.name
            let items = items(from: payload.items, key: key)
            let kept = before.filter { tab in tab.pane != nil && !items.contains { $0 === tab || $0.descendants.contains { $0 === tab } } }
            folder.replaceChildren(with: items + kept)
        } else {
            // The folder or space was deleted.
            unsubscribe(target)
            return
        }
        library.setNeedsSave()
    }

    /// Items for shared entries: the same ones as after the last update where
    /// they are still there (with their pages), new ones otherwise.
    private func items(from nodes: [ShareNode], key: String) -> [Item] {
        nodes.map { node in
            let id = UUID(share: key, node: node.id)
            if let children = node.children {
                let folder = library?.item(id: id).flatMap { $0.kind == .folder ? $0 : nil } ?? Item(id: id, kind: .folder)
                folder.customTitle = node.title
                folder.icon = Self.symbol(node.icon)
                folder.children = items(from: children, key: key)
                return folder
            }
            let tab = library?.item(id: id).flatMap { $0.kind == .tab ? $0 : nil } ?? Item(id: id, kind: .tab)
            tab.savedTitle = node.title
            tab.savedURL = node.url ?? ""
            return tab
        }
    }

    /// Folders show SF Symbols only.
    private static func symbol(_ icon: String?) -> String? {
        icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
    }
}
