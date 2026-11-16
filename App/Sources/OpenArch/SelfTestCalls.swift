import AppKit
import Network
import OpenArchCore

/// Calls in picture-in-picture and tabs that stay awake, on local test pages
/// with Chromium's fake camera and microphone: a call without a
/// picture-in-picture of its own gets OpenArch's floating window when you
/// leave its tab, space or window, a call like Google Meet's (Document
/// Picture-in-Picture from its media session) gets its own, and both close
/// when you come back. Never for a muted video or sound alone, nor for a
/// site set aside in the settings. A pinned chat site and a call stay awake.
/// `--selftest --call-test` runs only these; their windows pop up.
extension SelfTest {
    func callFeatures(then done: @escaping () -> Void) {
        keepAwakeListTest()
        let server = CallTestServer()
        server.start { port in
            guard let port else {
                self.expect(false, "the local test pages are served")
                return done()
            }
            self.callPictureInPictureTest(base: "http://127.0.0.1:\(port)", server: server, then: done)
        }
    }

    /// Which sites stay awake: by host and the hosts below it.
    private func keepAwakeListTest() {
        expect(KeepAwakeSites.contains("https://app.slack.com/client/T01/C02") && KeepAwakeSites.contains("https://mail.google.com/mail/u/0/")
               && KeepAwakeSites.contains("https://web.whatsapp.com/"),
               "Slack, Gmail and WhatsApp are chat and mail sites")
        expect(!KeepAwakeSites.contains("https://notslack.com/") && !KeepAwakeSites.contains("https://www.google.com/search?q=mail")
               && !KeepAwakeSites.contains("https://slack.com.example.io/"),
               "sites that only look alike, and Google search, are not")
        expect(KeepAwakeSites.contains("https://chat.acme.dev/x", extra: KeepAwakeSites.parse("acme.dev, https://intra.example/")),
               "the list grows with sites of your own")
    }

    private func callPictureInPictureTest(base: String, server: CallTestServer, then done: @escaping () -> Void) {
        let settings = library.settings
        library.settings.autoPictureInPicture = true
        library.settings.callPictureInPicture = true
        library.settings.pictureInPictureExceptions = []
        library.settings.pictureInPictureFrame = nil
        library.settings.keepChatSitesAwake = true
        library.settings.keepAwakeSites = ["127.0.0.1"]
        func tab(_ path: String, _ title: String) -> ItemData {
            ItemData(id: UUID(), kind: .tab, title: title, url: base + path)
        }
        library.replace(with: LibraryData(
            profiles: [ProfileData(id: "Default", name: "Test", favorites: [])],
            spaces: [
                SpaceData(id: UUID(), name: "Calls", icon: "phone.fill", colorHex: "#9A95B5", profileID: "Default",
                          pinned: [tab("/chat", "Chat")],
                          today: [tab("/blank", "Leer"), tab("/call", "Anruf"), tab("/meet", "Meet"),
                                  tab("/muted", "Stummes Video"), tab("/audio", "Nur Ton"), tab("/chat?today", "Chat heute")]),
                SpaceData(id: UUID(), name: "Andere", icon: "house.fill", colorHex: "#E5A33B", profileID: "Default",
                          pinned: [], today: [tab("/blank?other", "Anderer Space")]),
            ]))
        browser.libraryWasReplaced()
        guard let space = library.spaces.first, let other = library.spaces.last, space.today.items.count == 6,
              let chat = space.pinned.items.first else { return done() }
        let today = space.today.items
        let blank = today[0], call = today[1], meet = today[2], muted = today[3], audio = today[4], chatToday = today[5]
        let pip = PictureInPictureWindows.shared

        func join(_ tab: Item, then next: @escaping @MainActor () -> Void) {
            browser.select(tab, focus: false)
            after(2) {
                tab.pane?.executeJavaScript("join()")
                // The fake camera takes a moment the first time.
                self.waitUntil({ tab.isInCall }, then: next)
            }
        }
        func leave(_ tab: Item, then check: @escaping () -> Void) {
            browser.select(blank, focus: false)
            after(3) { check() }
        }
        func describeWindows() -> String {
            NSApp.windows.filter(\.isVisible).map { "\(NSStringFromClass(type(of: $0)))@\($0.level.rawValue)" }.joined(separator: ", ")
        }

        // 1. A call without a picture-in-picture of its own.
        join(call) {
            self.expect(call.isInCall && call.call?.camera == true && call.call?.microphone == true,
                        "a page using the camera and microphone is in a call (\(String(describing: call.call)), \(call.mediaAccess))")
            leave(call) {
                self.expect(call.call?.pip == "own", "leaving the call's tab opens OpenArch's floating window (\(call.call?.pip ?? "nil"))")
                let window = pip.windows.first
                self.expect(window != nil, "the floating window is found (\(describeWindows()))")
                if let window, let visible = window.screen?.visibleFrame {
                    self.expect(abs(window.frame.maxX - (visible.maxX - PictureInPictureWindows.margin)) < 2
                                && abs(window.frame.minY - (visible.minY + PictureInPictureWindows.margin)) < 2,
                                "it sits at the bottom right of the screen (\(window.frame) in \(visible))")
                    self.expect(window.level.rawValue >= NSWindow.Level.floating.rawValue && !window.hidesOnDeactivate
                                && window.collectionBehavior.contains(.canJoinAllSpaces)
                                && window.collectionBehavior.contains(.fullScreenAuxiliary),
                                "it floats above other apps, on every desktop and beside full-screen apps")
                    // Moved by hand: the next one opens there.
                    window.setFrameOrigin(NSPoint(x: visible.minX + 60, y: visible.minY + 80))
                }
                self.browser.select(call, focus: false)
                after(2.5) {
                    self.expect(call.call?.pip == "" && pip.windows.isEmpty,
                                "coming back to the tab closes the floating window (\(call.call?.pip ?? "nil"), \(pip.windows.count))")
                    let saved = self.library.settings.pictureInPictureFrame
                    self.expect(saved.map { abs($0.minX - ((window?.screen?.visibleFrame.minX ?? 0) + 60)) < 2 } == true,
                                "where it was moved to is remembered (\(String(describing: saved)))")
                    self.spaceAndWindow(call: call, other: other, space: space) {
                        self.siteOwnPictureInPicture(meet: meet, leave: leave, join: join) {
                            // Hung up: leaving its tab is like leaving any other.
                            meet.pane?.executeJavaScript("hangUp()")
                            after(2) {
                            self.neverFloating(muted: muted, audio: audio, call: call, blank: blank, leave: leave) {
                                self.keepAwake(chat: chat, chatToday: chatToday, call: call) {
                                    call.pane?.executeJavaScript("hangUp()")
                                    self.library.settings = settings
                                    server.stop()
                                    done()
                                }
                            }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Switching spaces, and the window going off screen, do the same.
    private func spaceAndWindow(call: Item, other: Space, space: Space, then next: @escaping () -> Void) {
        let pip = PictureInPictureWindows.shared
        browser.switchSpace(to: other)
        after(3) {
            self.expect(call.call?.pip == "own", "switching to another space floats the call (\(call.call?.pip ?? "nil"))")
            if let window = pip.windows.first, let saved = self.library.settings.pictureInPictureFrame {
                self.expect(abs(window.frame.minX - saved.minX) < 2 && abs(window.frame.minY - saved.minY) < 2,
                            "the next floating window opens where the last one was moved to (\(window.frame) vs \(saved))")
            }
            self.browser.switchSpace(to: space)
            after(2.5) {
                self.expect(call.call?.pip == "" && self.browser.visibleTabs.contains { $0 === call },
                            "switching back to its space closes it (\(call.call?.pip ?? "nil"))")
                self.browser.windowVisibilityChanged(onScreen: false)
                after(3) {
                    self.expect(call.call?.pip == "own", "the window going off screen floats the call (\(call.call?.pip ?? "nil"))")
                    self.browser.windowVisibilityChanged(onScreen: true)
                    after(2.5) {
                        self.expect(call.call?.pip == "", "the window coming back closes it (\(call.call?.pip ?? "nil"))")
                        // A site set aside in the settings stays in its tab.
                        self.library.settings.pictureInPictureExceptions = ["127.0.0.1"]
                        self.browser.windowVisibilityChanged(onScreen: false)
                        after(2.5) {
                            self.expect(call.call?.pip == "", "a site set aside in the settings does not float (\(call.call?.pip ?? "nil"))")
                            self.browser.windowVisibilityChanged(onScreen: true)
                            self.library.settings.pictureInPictureExceptions = []
                            self.library.settings.callPictureInPicture = false
                            self.browser.windowVisibilityChanged(onScreen: false)
                            after(2.5) {
                                self.expect(call.call?.pip == "", "with calls in picture-in-picture off, nothing floats")
                                self.browser.windowVisibilityChanged(onScreen: true)
                                self.library.settings.callPictureInPicture = true
                                next()
                            }
                        }
                    }
                }
            }
        }
    }

    /// A call whose site has a picture-in-picture of its own, as Google Meet
    /// does: the site's window opens, not OpenArch's.
    private func siteOwnPictureInPicture(meet: Item, leave: @escaping (Item, @escaping () -> Void) -> Void,
                                         join: @escaping (Item, @escaping @MainActor () -> Void) -> Void,
                                         then next: @escaping () -> Void) {
        callChecks = []
        join(meet) {
            self.expect(meet.call?.sitePip == true, "a site with a picture-in-picture of its own is noticed (\(String(describing: meet.call)))")
            leave(meet) {
                self.expect(meet.call?.pip == "site" && self.callChecks.contains("site-pip"),
                            "leaving it opens the site's own floating window (\(meet.call?.pip ?? "nil"), \(self.callChecks))")
                self.expect(PictureInPictureWindows.shared.windows.count == 1, "it floats like OpenArch's")
                self.browser.select(meet, focus: false)
                after(2.5) {
                    self.expect(meet.call?.pip == "" && self.callChecks.contains("site-pip-closed")
                                && PictureInPictureWindows.shared.windows.isEmpty,
                                "coming back closes it, and the page gets its tiles back (\(meet.call?.pip ?? "nil"), \(self.callChecks))")
                    next()
                }
            }
        }
    }

    /// A muted video playing by itself and sound without a picture never
    /// float.
    private func neverFloating(muted: Item, audio: Item, call: Item, blank: Item,
                               leave: @escaping (Item, @escaping () -> Void) -> Void, then next: @escaping () -> Void) {
        browser.select(audio, focus: false)
        browser.toggleMute(audio)
        browser.select(muted, focus: false)
        after(2) {
            muted.pane?.executeJavaScript("play()")
            audio.pane?.executeJavaScript("play()")
            after(1.5) {
                self.expect(muted.media?.playing == true && audio.media?.playing == true,
                            "the muted video and the sound play (\(String(describing: muted.media)), \(String(describing: audio.media)))")
                leave(muted) {
                    self.expect(muted.media?.pip == false && audio.media?.pip == false && (muted.call?.pip ?? "").isEmpty
                                && PictureInPictureWindows.shared.windows.isEmpty,
                                "a muted video and sound alone do not float (\(String(describing: muted.media?.pip)), \(PictureInPictureWindows.shared.windows.count))")
                    next()
                }
            }
        }
    }

    /// A pinned chat site and a call in another tab do not go to sleep; the
    /// same chat site under the line does.
    private func keepAwake(chat: Item, chatToday: Item, call: Item, then next: @escaping () -> Void) {
        // Without a floating window: the call stays awake all the same.
        library.settings.callPictureInPicture = false
        browser.select(chat, focus: false)
        browser.select(chatToday, focus: false)
        browser.select(call, focus: false)
        if let blank = library.spaces.first?.today.items.first { browser.select(blank, focus: false) }
        after(2.5) {
            for tab in [chat, chatToday, call] {
                tab.lastActiveAt = Date().addingTimeInterval(-3 * 3600)
                tab.loadedAt = tab.lastActiveAt
            }
            self.library.settings.callPictureInPicture = true
            after(1) {
                self.browser.sleepInactiveTabs(olderThan: 30)
                after(1.5) {
                    self.expect(!chat.isAsleep && chat.pane != nil, "a pinned chat site stays awake")
                    self.expect(!call.isAsleep && call.pane != nil, "a tab in a call stays awake")
                    self.expect(chatToday.isAsleep, "the same site under the line goes to sleep")
                    self.library.settings.keepChatSitesAwake = false
                    self.browser.sleepInactiveTabs(olderThan: 30)
                    after(1.5) {
                        self.expect(chat.isAsleep, "with the setting off, the pinned chat site sleeps too")
                        next()
                    }
                }
            }
        }
    }
}

extension SelfTest {
    /// Checks |condition| every half second, up to |tries| times, then goes on.
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, tries: Int = 12, then next: @escaping @MainActor () -> Void) {
        after(0.5) {
            if condition() || tries == 0 {
                after(0.5, next)
            } else {
                self.waitUntil(condition, tries: tries - 1, then: next)
            }
        }
    }
}

/// What the call test pages report (`__selftest_call__ …`).
@MainActor private var callTestChecks: [String] = []

extension SelfTest {
    var callChecks: [String] {
        get { callTestChecks }
        set { callTestChecks = newValue }
    }

    func callConsoleMessage(_ message: String) -> Bool {
        let prefix = "__selftest_call__ "
        if message.hasPrefix("__openarch_call__-error") { Swift.print("[selftest] page: \(message)") }
        guard message.hasPrefix(prefix) else { return false }
        callTestChecks.append(String(message.dropFirst(prefix.count)))
        return true
    }
}

/// The call test's pages, on 127.0.0.1 (a secure context, as calls need).
final class CallTestServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "openarch.selftest.calls")

    static let pages: [String: String] = [
        "/blank": "<!doctype html><title>Leer</title><p>Nichts hier.",
        "/chat": "<!doctype html><title>Chat</title><p>Nachrichten",
        // A call without a picture-in-picture of its own.
        "/call": """
            <!doctype html><title>Anruf</title><h1>Anruf</h1><video id=me autoplay muted playsinline width=320></video>
            <script>
            let stream = null;
            async function join() { stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true }); me.srcObject = stream; }
            function hangUp() { stream?.getTracks().forEach((t) => t.stop()); }
            </script>
            """,
        // Like Google Meet: its media session opens Document Picture-in-Picture
        // with the call's tiles, which come back when it closes.
        "/meet": """
            <!doctype html><title>Meet</title><div id=tiles><video id=me autoplay muted playsinline width=320></video></div>
            <script>
            let stream = null;
            const tiles = document.getElementById('tiles');
            async function join() {
              stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
              me.srcObject = stream;
              navigator.mediaSession.setActionHandler('enterpictureinpicture', async () => {
                const pip = await documentPictureInPicture.requestWindow({ width: 320, height: 200 });
                pip.document.body.append(tiles);
                console.debug('__selftest_call__ site-pip');
                pip.addEventListener('pagehide', () => {
                  try {
                    document.body.append(tiles);
                    console.debug('__selftest_call__ site-pip-closed');
                  } catch (error) {
                    console.debug('__selftest_call__ site-pip-error ' + error.message);
                  }
                });
              });
            }
            function hangUp() { stream?.getTracks().forEach((t) => t.stop()); }
            </script>
            """,
        // A muted video playing by itself, as ads do.
        "/muted": """
            <!doctype html><title>Stummes Video</title>
            <script>
            function play() {
              const c = document.createElement('canvas'); c.width = 320; c.height = 180;
              const g = c.getContext('2d'); let i = 0;
              setInterval(() => { g.fillStyle = `hsl(${i++ % 360} 80% 50%)`; g.fillRect(0, 0, 320, 180); }, 50);
              const v = document.createElement('video'); v.muted = true; v.srcObject = c.captureStream(20);
              document.body.append(v); v.play();
            }
            </script>
            """,
        // Sound without a picture (the tab is muted, so nothing is heard).
        "/audio": """
            <!doctype html><title>Nur Ton</title>
            <script>
            function play() {
              const ctx = new AudioContext(); const o = ctx.createOscillator(); const d = ctx.createMediaStreamDestination();
              const gain = ctx.createGain(); gain.gain.value = 0.01; o.connect(gain); gain.connect(d); o.start();
              const a = new Audio(); a.srcObject = d.stream; document.body.append(a); a.play();
            }
            </script>
            """,
    ]

    func start(_ ready: @escaping @MainActor (UInt16?) -> Void) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            Task { @MainActor in ready(nil) }
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = listener.port?.rawValue
                Task { @MainActor in ready(port) }
            case .failed:
                Task { @MainActor in ready(nil) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.prefix { $0 != "?" })
            let page = Self.pages[path]
            let body = Data((page ?? "Not found").utf8)
            let head = "HTTP/1.1 \(page == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
