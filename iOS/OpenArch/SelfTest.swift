import OpenArchShared
import UIKit

/// Automated checks in the running app, like the Mac's --selftest: launched
/// with -selftest (ios.yml does that in the simulator), it opens a page,
/// pins it into a folder, shares the folder as a link, adds the link again
/// and checks what came out, with screenshots of the sheets on the way into
/// Documents/selftest. Prints "[selftest] DONE failures=N" and quits.
///
/// With -relay <url> (say a local relay: relay/README.md), it also shares a
/// folder live and follows it in the same library. With -hold it stays open
/// after the test, for looking at the app from outside.
@MainActor
final class SelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-selftest")
    }

    /// The value after |name| in the launch arguments.
    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private let browser: Browser
    private var failures = 0
    private let shots: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("selftest", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init(browser: Browser) {
        self.browser = browser
    }

    private func check(_ condition: Bool, _ name: String) {
        print("[selftest] \(condition ? "ok" : "FAIL") \(name)")
        if !condition { failures += 1 }
    }

    /// Waits up to |seconds| for |condition|.
    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func screenshot(_ name: String) async {
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
        else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: shots.appendingPathComponent("\(name).png"))
        print("[selftest] screenshot \(name)")
    }

    private func dismiss() async {
        browser.sheet = nil
        try? await Task.sleep(for: .seconds(1))
    }

    func run() async {
        print("[selftest] START")
        let library = browser.library
        let space = browser.space
        check(library.spaces.count == 1 && library.favorites.count == 4, "a first library: one space, four favorites")
        await screenshot("1-start")

        // A page loads in a new today tab.
        browser.go("example.com", mode: .newTab)
        guard let tab = browser.activeItem else {
            check(false, "a typed address opens a tab")
            return finish()
        }
        check(space.today.first === tab, "the new tab is first under the line")
        let loaded = await wait(30) { tab.liveTitle?.contains("Example") == true }
        check(loaded, "example.com loads (title \(tab.liveTitle ?? "none"))")
        check(tab.liveURL?.hasPrefix("https://example.com") == true, "typed example.com becomes https://example.com")
        await screenshot("2-page")

        // Pinned into a new folder.
        let folder = browser.newFolder(name: "Lesestoff")
        browser.renaming = nil
        browser.pin(tab, into: folder)
        check(browser.place(of: tab) == .pinned && folder.children.first === tab, "the tab is pinned into the folder")
        check(space.today.isEmpty, "and no longer under the line")
        browser.present(.sidebar)
        await screenshot("3-sidebar")
        await dismiss()

        // Shared as a snapshot link, and opened again.
        do {
            let link = try await browser.sharing.snapshotLink(for: .folder(folder), password: nil)
            print("[selftest] snapshot link \(link.url.absoluteString)")
            let parsed = ShareURL(url: link.url)
            check(parsed == link, "the snapshot link reads back")
            let opened = try await ShareReader.open(link)
            check(opened.payload.name == "Lesestoff" && opened.payload.allTabs.first?.url?.contains("example.com") == true,
                  "the snapshot holds the folder and its tab")
            browser.open(externalURL: link.appURL)
            var importing = false
            if case .importShare? = browser.sheet { importing = true }
            check(importing, "openarch://share opens the add sheet")
            await screenshot("4-import")
            await dismiss()

            browser.sharing.add(opened, asSpace: true, follow: false)
            let added = library.spaces.last
            check(library.spaces.count == 2 && added?.name == "Lesestoff", "added as a space of its own")
            check(added?.pinned.first?.url.contains("example.com") == true, "with the tab pinned")
            check(added?.pinned.first?.id != tab.id, "a copy gets its own IDs")
            await screenshot("5-added-space")
            if let added {
                browser.deleteSpace(added)
                check(library.spaces.count == 1 && browser.space === space, "the space is deleted again")
            }
        } catch {
            check(false, "snapshot sharing: \(error)")
        }

        // With a password.
        do {
            let link = try await browser.sharing.snapshotLink(for: .folder(folder), password: "geheim")
            print("[selftest] password link \(link.url.absoluteString)")
            check(link.needsPassword, "a password link asks for it")
            do {
                _ = try await ShareReader.open(link, password: "falsch")
                check(false, "a wrong password is refused")
            } catch {
                check(error as? ShareError == .wrongPassword, "a wrong password is refused")
            }
            let opened = try await ShareReader.open(link, password: "geheim")
            check(opened.payload.allTabs.count == 1, "the right password opens it")
        } catch {
            check(false, "password sharing: \(error)")
        }

        browser.present(.share(.folder(folder)))
        await screenshot("6-share")
        await dismiss()
        browser.present(.commandBar(.newTab))
        await screenshot("7-command-bar")
        await dismiss()
        browser.present(.settings)
        await screenshot("8-settings")
        await dismiss()

        if let relay = Self.argument("-relay") {
            await liveShare(of: folder, relay: relay)
        }
        await spaceColors(space)

        // Closing a today tab archives it; the library survives a reload.
        browser.go("example.org", mode: .newTab)
        if let second = browser.activeItem {
            browser.close(second)
            check(library.archive.first?.url.contains("example.org") == true, "a closed today tab goes to the archive")
        }
        library.save()
        let reloaded = Library.load()
        check(reloaded.spaces.first?.folders.first?.title == "Lesestoff", "the folder is saved")
        check(reloaded.spaces.first?.folders.first?.children.first?.url.contains("example.com") == true,
              "with its pinned tab")
        finish()
    }

    /// A live share, seen from both ends: this library owns it and follows it.
    private func liveShare(of folder: Item, relay: String) async {
        let library = browser.library
        let sharing = browser.sharing
        library.settings.relay = relay
        check(library.settings.relayURL != nil, "the relay \(relay) is accepted")
        do {
            let share = try await sharing.makeLiveShare(for: .folder(folder), password: nil)
            check(share.version == 1 && share.link.isLive, "the folder is uploaded as version 1")
            print("[selftest] live link \(share.link.appURL.absoluteString)")
            check(ShareURL(url: share.link.url) == share.link, "the live link reads back")

            let opened = try await ShareReader.open(share.link)
            check(opened.version == 1 && opened.payload.allTabs.count == folder.children.count, "the link opens from the relay")
            browser.present(.share(.folder(folder)))
            await screenshot("9-live-share")
            await dismiss()
            browser.present(.importShare(share.link))
            await screenshot("10-live-import")
            await dismiss()

            sharing.add(opened, asSpace: false, follow: true)
            guard let subscription = sharing.records.subscriptions.last,
                  let followed = library.item(id: subscription.target) else {
                return check(false, "the link is added and followed")
            }
            check(subscription.id == share.id && followed.children.count == folder.children.count, "the link is added and followed")
            check(followed !== folder && followed.children.first?.id != folder.children.first?.id, "as a folder of its own")

            // A new tab in the original goes up with the next save…
            folder.children.append(.tab(url: "https://example.org/live", title: "Live-Änderung"))
            library.save()
            let uploaded = await wait(15) { sharing.owned(folder.id)?.version == 2 }
            check(uploaded, "a change is uploaded as version 2 (\(sharing.lastError ?? "no error"))")
            // … and comes down with the next check.
            await sharing.refresh()
            check(followed.children.contains { $0.url == "https://example.org/live" }, "the followed folder shows the new tab")
            check(sharing.subscription(followed.id)?.version == 2, "at version 2")
            check(sharing.subscription(followed.id)?.lastChecked != nil, "and knows when it checked")
            let keptID = followed.children.first?.id

            // Nothing new: nothing happens.
            await sharing.refresh()
            check(followed.children.first?.id == keptID && sharing.subscription(followed.id)?.version == 2, "a check without changes changes nothing")

            // A rename and a removed tab come down too.
            folder.title = "Lesestoff neu"
            folder.children.removeAll { $0.url == "https://example.org/live" }
            library.save()
            _ = await wait(15) { sharing.owned(folder.id)?.version == 3 }
            await sharing.refresh()
            check(followed.displayTitle == "Lesestoff neu", "a rename comes down")
            check(!followed.children.contains { $0.url == "https://example.org/live" }, "a removed tab goes away")
            check(followed.children.first?.id == keptID, "tabs that stay keep their identity")
            browser.present(.sidebar)
            await screenshot("11-followed")
            await dismiss()
            browser.present(.settings)
            await screenshot("12-settings-shares")
            await dismiss()

            folder.title = "Lesestoff"

            // With a password.
            let locked = Item.folder("Geheim")
            locked.children = [.tab(url: "https://example.net/", title: "Example Net")]
            library.insert(locked, into: nil, of: browser.space)
            let lockedShare = try await sharing.makeLiveShare(for: .folder(locked), password: "geheim")
            check(lockedShare.link.needsPassword, "a live link can ask for a password")
            do {
                _ = try await ShareReader.open(lockedShare.link, password: "falsch")
                check(false, "a live link refuses the wrong password")
            } catch {
                check(error as? ShareError == .wrongPassword, "a live link refuses the wrong password")
            }
            let unlocked = try await ShareReader.open(lockedShare.link, password: "geheim")
            check(unlocked.payload.allTabs.first?.url == "https://example.net/", "and opens with the right one")
            try await sharing.end(lockedShare)
            browser.delete(locked)

            // Ended: the link is dead, followers keep what they have.
            try await sharing.end(share)
            check(sharing.owned(folder.id) == nil, "ending forgets the share")
            do {
                _ = try await ShareReader.open(share.link)
                check(false, "an ended link shows nothing")
            } catch {
                check(error as? ShareError == .ended, "an ended link shows nothing (\(error))")
            }
            await sharing.refresh()
            check(sharing.subscription(followed.id)?.ended == true, "the follower sees that it ended")
            check(followed.children.first?.id == keptID, "and keeps the last state")
            browser.delete(followed)
            check(sharing.subscription(followed.id) == nil, "a deleted folder is no longer followed")
        } catch {
            check(false, "live sharing: \(error)")
        }
        library.settings.relay = ""
    }

    /// The sidebar in the space colors that are hardest to read, to look at.
    private func spaceColors(_ space: Space) async {
        let color = space.colorHex
        browser.present(.sidebar)
        for (name, hex) in [("orange", "#E5A33B"), ("olive", "#A0B33A"), ("gray", "#6B7280"), ("pale", "#F4EFD6"), ("black", "#16161A")] {
            space.colorHex = hex
            await screenshot("color-\(name)")
        }
        await dismiss()
        space.colorHex = color
    }

    private func finish() {
        print("[selftest] DONE failures=\(failures)")
        fflush(stdout)
        if ProcessInfo.processInfo.arguments.contains("-hold") { return }
        exit(failures == 0 ? 0 : 1)
    }
}
