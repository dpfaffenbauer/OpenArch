import AppKit
import OpenArchCore

/// Calls and videos in a floating window, as in Arc: leaving a tab in a
/// call (by switching tabs or spaces, or when its window goes off screen)
/// moves the call into picture-in-picture, the site's own (Google Meet's
/// tiles with its buttons) or OpenArch's (the call's video tiles with
/// microphone, camera and hang-up buttons, see call.js). A video playing
/// with sound does the same. Coming back closes it.
extension BrowserWindowController {
    /// What to do with |item| as it leaves the screen.
    func pictureInPictureOnLeaving(_ item: Item) {
        guard allowsAutoPictureInPicture(item) else { return }
        if item.isInCall {
            guard library.settings.callPictureInPicture, item.call?.pip.isEmpty != false else { return }
            callCommand(item, "pip")
            PictureInPictureWindows.shared.expect()
        } else if library.settings.autoPictureInPicture, let media = item.media,
                  media.playing, media.video, media.audible, !media.pip {
            // Not muted videos playing by themselves (ads, page backgrounds),
            // nor sound without a picture.
            mediaCommand(item, "pip")
            PictureInPictureWindows.shared.expect()
        }
    }

    /// |item| is on screen again: its floating window closes.
    func pictureInPictureOnReturning(_ item: Item) {
        // A call's window may still be on its way.
        let call = item.call?.pip.isEmpty == false || item.isInCall
        let video = item.media?.pip == true
        guard call || video else { return }
        PictureInPictureWindows.shared.fadeOut {
            if call { self.callCommand(item, "exitpip") }
            if video { self.mediaCommand(item, "exitpip") }
        }
    }

    /// Whether |item|'s site may float by itself (Settings › Allgemein ›
    /// Tabs, and the Site Control Center).
    func allowsAutoPictureInPicture(_ item: Item) -> Bool {
        !KeepAwakeSites.listed(item.currentURL, in: library.settings.pictureInPictureExceptions)
    }

    /// "pip", "exitpip", "microphone", "camera" or "hangup", carried out by
    /// the built-in extension's call.js, as if the user had clicked (Document
    /// Picture-in-Picture needs that).
    func callCommand(_ item: Item, _ command: String) {
        item.pane?.executeJavaScript("document.dispatchEvent(new CustomEvent('openarch-call', {detail: '\(command)'}))",
                                     userGesture: true)
    }

    /// The floating window's ‹ (OpenArch's own): back to the call's tab.
    func returnToCall(_ item: Item) {
        window?.makeKeyAndOrderFront(nil)
        if !AppPaths.isSelfTest { NSApp.activate() }
        select(item)
    }

    /// The window went off screen (minimized, covered, on another desktop)
    /// or came back: the call or video it shows floats, or comes back.
    func windowVisibilityChanged(onScreen: Bool) {
        if onScreen {
            visibleTabs.forEach(pictureInPictureOnReturning)
        } else {
            visibleTabs.forEach(pictureInPictureOnLeaving)
        }
    }

    /// Tabs that never sleep: one in a call, and pinned tabs and favorites of
    /// chat and mail sites (Settings › Allgemein › Tabs).
    func keepsAwake(_ tab: Item) -> Bool {
        if tab.isInCall || tab.call?.pip.isEmpty == false { return true }
        guard library.settings.keepChatSitesAwake, tab.role == .pinned || tab.role == .favorites else { return false }
        return KeepAwakeSites.contains(tab.currentURL, extra: library.settings.keepAwakeSites)
    }
}

/// Chat and mail sites people keep open for their messages and calls, as in
/// Arc: their pinned tabs and favorites never sleep. An entry matches its
/// host and every host below it ("slack.com" also "acme.slack.com"); a host
/// that only looks alike ("notslack.com") does not. The list grows with
/// Settings › Allgemein › Tabs.
enum KeepAwakeSites {
    static let entries = [
        // Mail
        "mail.google.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com", "outlook.cloud.microsoft",
        "mail.proton.me", "app.fastmail.com", "mail.superhuman.com", "app.hey.com", "mail.zoho.com",
        // Chat and calls
        "slack.com", "discord.com", "web.whatsapp.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
        "web.telegram.org", "chat.google.com", "meet.google.com", "messages.google.com", "messenger.com",
        "app.element.io", "zulipchat.com", "app.zoom.us",
        // Calendars
        "calendar.google.com",
    ].compactMap(normalize)

    static func contains(_ url: String, extra: [String] = []) -> Bool {
        listed(url, in: entries + extra)
    }

    /// Whether |url|'s host is one of |sites| or below one.
    static func listed(_ url: String, in sites: [String]) -> Bool {
        guard let host = host(of: url) else { return false }
        return sites.compactMap(normalize).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The host of a web address, without "www.".
    static func host(of url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme,
              scheme == "http" || scheme == "https", var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// "Slack.com", "https://app.slack.com/client" → "slack.com",
    /// "app.slack.com"; nil for an empty entry.
    static func normalize(_ entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        text = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasPrefix(".") || text.hasPrefix("*") { text.removeFirst() }
        return text.isEmpty ? nil : text
    }

    /// A list typed into a field: separated by commas, spaces or lines.
    static func parse(_ text: String) -> [String] {
        text.split { $0 == "," || $0 == " " || $0 == "\n" }.compactMap { normalize(String($0)) }
    }
}

/// Chrome's picture-in-picture windows (a video's, or a page's Document
/// Picture-in-Picture) are windows of OpenArch's own process. OpenArch puts
/// them at the bottom right of the screen, or where you last moved one, and
/// keeps them above other apps, on every desktop and beside full-screen
/// apps.
@MainActor
final class PictureInPictureWindows {
    static let shared = PictureInPictureWindows()
    /// The margin to the screen's edges.
    static let margin: CGFloat = 20

    private var managed: [ObjectIdentifier: NSWindow] = [:]
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var library: Library? { (NSApp.delegate as? AppDelegate)?.library }

    /// The windows on screen now.
    var windows: [NSWindow] { managed.values.filter(\.isVisible) }

    /// A floating window is on its way: look for it a few times.
    func expect() {
        for delay in [0.2, 0.5, 1.0, 1.6, 2.5] {
            after(delay) { [weak self] in self?.adoptNewWindows() }
        }
    }

    /// Closes the floating windows smoothly: they fade, then |close| asks the
    /// page to end its picture-in-picture.
    func fadeOut(then close: @escaping @MainActor () -> Void) {
        let shown = windows
        guard !shown.isEmpty else { return close() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            for window in shown { window.animator().alphaValue = 0 }
        }
        after(0.2) {
            close()
            // One that stays (the page did not close it) shows again.
            after(0.8) {
                for window in shown where window.isVisible { window.alphaValue = 1 }
            }
        }
    }

    private func adoptNewWindows() {
        for window in NSApp.windows where managed[ObjectIdentifier(window)] == nil && Self.isPictureInPicture(window) {
            adopt(window)
        }
    }

    /// Chrome's picture-in-picture windows float (other Chrome windows of a
    /// tab, DevTools or a popup, do not), and are none of OpenArch's own.
    static func isPictureInPicture(_ window: NSWindow) -> Bool {
        guard window.isVisible, window.level.rawValue >= NSWindow.Level.floating.rawValue,
              !(window is NSPanel), OACPane(for: window) == nil else { return false }
        let name = NSStringFromClass(type(of: window))
        return name.contains("NativeWidget") || name.contains("Chrome") || name.contains("BrowserFrame")
    }

    private func adopt(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        managed[id] = window
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.collectionBehavior.remove(.moveToActiveSpace)
        window.setFrame(frame(for: window), display: true)
        window.alphaValue = 1
        let center = NotificationCenter.default
        let moved: (Notification) -> Void = { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.isVisible, self?.placing != true else { return }
                self?.library?.settings.pictureInPictureFrame = window.frame
                self?.library?.setNeedsSave()
            }
        }
        observers[id] = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: moved),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main, using: moved),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forget(id) }
            },
        ]
    }

    private var placing = false

    private func forget(_ id: ObjectIdentifier) {
        managed[id] = nil
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
    }

    /// Where a new floating window goes: where the last one was moved to,
    /// if that is still on a screen, else the bottom right of the screen
    /// with the main window.
    func frame(for window: NSWindow) -> NSRect {
        placing = true
        defer { after(0.3) { [weak self] in self?.placing = false } }
        var size = window.frame.size
        if let saved = library?.settings.pictureInPictureFrame,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(saved) }) {
            size = saved.size
            let visible = screen.visibleFrame
            let x = min(max(saved.minX, visible.minX), visible.maxX - size.width)
            let y = min(max(saved.minY, visible.minY), visible.maxY - size.height)
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        let screen = NSApp.mainWindow?.screen ?? NSApp.windows.first(where: { $0 is BrowserWindow })?.screen
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return window.frame }
        return NSRect(x: visible.maxX - size.width - Self.margin, y: visible.minY + Self.margin,
                      width: size.width, height: size.height)
    }
}
