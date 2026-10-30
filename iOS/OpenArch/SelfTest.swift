import OpenArchShared
import UIKit

/// Automated checks in the running app, like the Mac's --selftest: launched
/// with -selftest (ios.yml does that in the simulator), it opens a page,
/// pins it into a folder, shares the folder as a link, adds the link again
/// and checks what came out, with screenshots of the sheets on the way into
/// Documents/selftest. Prints "[selftest] DONE failures=N" and quits.
@MainActor
final class SelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-selftest")
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

    private func finish() {
        print("[selftest] DONE failures=\(failures)")
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
