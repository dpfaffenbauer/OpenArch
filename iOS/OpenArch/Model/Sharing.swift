import OpenArchShared
import UIKit

/// Shared folders and spaces (docs/sharing.md): the live shares this device
/// made, kept up to date when they change, and the ones it follows.
@MainActor @Observable
final class Sharing {
    private(set) var records: ShareRecords
    /// Why the last upload or update failed, for Settings.
    var lastError: String?
    weak var browser: Browser?

    private let library: Library
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var uploading: Set<String> = []
    @ObservationIgnored private var changedWhileUploading: Set<String> = []
    @ObservationIgnored private var refreshing = false

    init(library: Library) {
        self.library = library
        fileURL = Library.directory.appendingPathComponent("Shares.json")
        records = ShareRecords.load(from: fileURL)
    }

    private func save() {
        do {
            try records.save(to: fileURL)
        } catch {
            print("[OpenArch] could not save shares: \(error)")
        }
    }

    // MARK: Lookup

    func owned(_ id: UUID) -> OwnedShare? {
        records.owned(source: id)
    }

    func subscription(_ id: UUID) -> ShareSubscription? {
        records.subscription(target: id)
    }

    func target(of share: OwnedShare) -> ShareTarget? {
        switch share.kind {
        case .folder: library.item(id: share.source).flatMap { $0.kind == .folder ? .folder($0) : nil }
        case .space: library.space(id: share.source).map { .space($0) }
        }
    }

    // MARK: What a share shows

    func payload(for target: ShareTarget) -> SharePayload {
        switch target {
        case .folder(let folder):
            SharePayload(kind: .folder, name: folder.displayTitle, icon: folder.icon, items: folder.children.map(Self.node))
        case .space(let space):
            SharePayload(kind: .space, name: space.name, icon: space.icon, color: space.colorHex,
                         items: space.pinned.map(Self.node))
        }
    }

    static func node(_ item: Item) -> ShareNode {
        switch item.kind {
        case .folder: .folder(id: item.id, title: item.displayTitle, icon: item.icon, children: item.children.map(node))
        case .tab: .tab(id: item.id, title: item.title.isEmpty ? URLInput.short(item.url) : item.title, url: item.url)
        }
    }

    // MARK: Sharing

    /// A live share of |target|, uploaded once; it then follows changes.
    func makeLiveShare(for target: ShareTarget, password: String?) async throws -> OwnedShare {
        var share = OwnedShare.make(source: target.id, kind: target.kind, name: target.name,
                                    relay: library.settings.relayURL)
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

    /// A link with the bookmarks inside; nothing is uploaded.
    func snapshotLink(for target: ShareTarget, password: String?) async throws -> ShareURL {
        let payload = payload(for: target)
        return try await Task.detached { try ShareReader.snapshotLink(payload, password: password) }.value
    }

    /// Ends a live share. Those who added it keep what they have.
    func end(_ share: OwnedShare) async throws {
        do {
            try await share.end()
        } catch ShareError.notFound {
            // Never uploaded, or already expired.
        }
        records.owned.removeAll { $0.id == share.id }
        save()
    }

    /// After every save of the library: live shares whose folder or space
    /// changed are uploaded again.
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
        let background = UIApplication.shared.beginBackgroundTask(withName: "Freigabe hochladen")
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
            UIApplication.shared.endBackgroundTask(background)
            if changedWhileUploading.remove(id) != nil { upload(id) }
        }
    }

    // MARK: Adding shares

    /// Adds what |opened| shows to the library: as a folder in the current
    /// space or as a space of its own. A live share keeps following the
    /// owner's changes; otherwise it is a copy.
    func add(_ opened: ShareReader.Opened, asSpace: Bool, follow: Bool) {
        guard let browser else { return }
        let payload = opened.payload
        // Copies get their own IDs; followed shares the same ones with every update.
        let key = follow ? (opened.link.shareID ?? UUID().uuidString) : UUID().uuidString
        let targetID: UUID
        if asSpace {
            let color = payload.color ?? spaceColorPresets[library.spaces.count % spaceColorPresets.count]
            let space = library.addSpace(name: payload.name, icon: payload.icon ?? "person.2.fill", colorHex: color)
            space.pinned = items(from: payload.items, key: key)
            targetID = space.id
            browser.switchSpace(to: space)
        } else {
            let folder = Item.folder(payload.name)
            folder.icon = payload.icon.flatMap { UIImage(systemName: $0) != nil ? $0 : nil }
            folder.children = items(from: payload.items, key: key)
            library.insert(folder, into: nil, of: browser.space)
            targetID = folder.id
        }
        if follow, let subscription = opened.subscription(target: targetID) {
            records.subscriptions.removeAll { $0.target == targetID }
            records.subscriptions.append(subscription)
            save()
        }
        library.setNeedsSave()
    }

    /// Stops following: the folder or space stays as it is.
    func unsubscribe(_ target: UUID) {
        records.subscriptions.removeAll { $0.target == target }
        save()
    }

    /// A folder, tab or space was deleted: its shares end, and nothing is
    /// followed into it any more.
    func forget(_ id: UUID) {
        for share in records.owned where share.source == id {
            Task { try? await end(share) }
        }
        if records.subscriptions.contains(where: { $0.target == id }) {
            unsubscribe(id)
        }
    }

    /// Fetches what changed in the shares this device follows.
    func refresh() async {
        guard !refreshing else { return }
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

    private func apply(_ payload: SharePayload, to target: UUID, key: String) {
        let before: [Item]
        if let space = library.space(id: target) {
            before = space.pinned.flatMap { [$0] + $0.descendants }
            space.name = payload.name
            if let icon = payload.icon { space.icon = icon }
            if let color = payload.color { space.colorHex = color }
            space.pinned = items(from: payload.items, key: key)
        } else if let folder = library.item(id: target), folder.kind == .folder {
            before = folder.descendants
            folder.title = payload.name
            folder.children = items(from: payload.items, key: key)
        } else {
            unsubscribe(target)
            return
        }
        // A tab the owner removed: its page closes, unless it is the one shown.
        for item in before where library.item(id: item.id) == nil {
            if item === browser?.activeItem, let space = browser?.space {
                space.today.insert(item, at: 0)
            } else {
                browser?.unload(item)
            }
        }
        library.setNeedsSave()
    }

    /// Items for shared entries: the ones from the last update where they
    /// are still there (with their pages), new ones otherwise.
    private func items(from nodes: [ShareNode], key: String) -> [Item] {
        nodes.map { node in
            let id = UUID(share: key, node: node.id)
            let kind: Item.Kind = node.isFolder ? .folder : .tab
            let item = library.item(id: id).flatMap { $0.kind == kind ? $0 : nil } ?? Item(id: id, kind: kind)
            item.title = node.title
            if let children = node.children {
                item.icon = node.icon.flatMap { UIImage(systemName: $0) != nil ? $0 : nil }
                item.children = items(from: children, key: key)
            } else {
                item.url = node.url ?? ""
            }
            return item
        }
    }
}
