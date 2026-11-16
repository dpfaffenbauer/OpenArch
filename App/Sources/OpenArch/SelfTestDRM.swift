import AppKit
import OpenArchCore
import WebKit

/// Streaming services in WebKit (ProtectedMedia, WebKitPage): example.org
/// stands in for a listed service. A WebKit page in the same tab, its own
/// store per profile, a Chromium link that moves the tab, a POST that
/// stays, the address field picking again, the media player, find, zoom,
/// sleeping, the setting and Site Controls' switch. Also reports whether
/// Chromium's Widevine component is there and whether pages may use it.
/// `--selftest --drm-test` runs only these.
extension SelfTest {
    private static let standIn = "example.org"

    func drmFeatures(then done: @escaping () -> Void) {
        ProtectedMedia.resetForTesting()
        ProtectedMedia.testHosts = [Self.standIn]
        library.settings.protectedMediaWebKit = true
        library.settings.applyToChromium()
        expect(ProtectedMedia.engine(for: "https://open.spotify.com/track/1") == .webKit
               && ProtectedMedia.engine(for: "https://www.netflix.com/browse") == .webKit
               && ProtectedMedia.engine(for: "https://www.joyn.de/") == .webKit
               && ProtectedMedia.engine(for: "https://www.amazon.de/gp/video/detail/x") == .webKit
               && ProtectedMedia.engine(for: "https://music.amazon.co.uk/") == .webKit,
               "streaming services open in WebKit (Spotify, Netflix, Joyn, Prime Video on Amazon, Amazon Music)")
        expect(ProtectedMedia.engine(for: "https://accounts.spotify.com/login") == .chromium
               && ProtectedMedia.engine(for: "https://www.amazon.de/dp/123") == .chromium
               && ProtectedMedia.engine(for: "https://connect.deezer.com/") == .chromium
               && ProtectedMedia.engine(for: "https://example.com/?u=https://open.spotify.com") == .chromium
               && ProtectedMedia.engine(for: "https://notnetflix.com/") == .chromium,
               "sign-in hosts, the rest of Amazon and look-alikes stay in Chromium")

        let tab = browser.openInNewTab("https://\(Self.standIn)/")
        let first = tab.pane
        expect(first?.engine == .webKit && first is WebKitPage, "a listed site opens as a WebKit page (\(String(describing: first)))")
        eventually({ tab.liveTitle == "Example Domain" && !tab.isLoading }, timeout: 15) { loaded in
            self.expect(loaded && self.browser.state.activeItem === tab,
                        "it loads in the tab, which the sidebar shows with its title (\(tab.liveTitle ?? "none"))")
            self.expect(ProtectedMedia.wasTold(Self.standIn), "the toast tells once that it plays with Safari's engine")
            self.checkWebKitPage(tab) {
                self.checkHandoff {
                    self.checkWidevine(then: done)
                }
            }
        }
    }

    /// User agent, store, media, find, zoom, sleeping.
    private func checkWebKitPage(_ tab: Item, then next: @escaping () -> Void) {
        guard let page = tab.pane as? WebKitPage, let web = page.webView else {
            expect(false, "the WebKit page has a web view")
            return next()
        }
        let store = web.configuration.websiteDataStore
        expect(store.identifier == WebKitStores.identifier(forProfile: "Default") && store.isPersistent,
               "the page keeps its data in the profile's own persistent WebKit store")
        let other = WebKitStores.store(for: OACProfile(directoryName: "Profile 2"))
        expect(other !== store && other.identifier != store.identifier, "another profile has a store of its own")
        expect(!WebKitStores.store(for: OACProfile.makePrivate()).isPersistent, "a private window's store is in memory only")
        page.callDevToolsMethod("Runtime.evaluate",
                                params: ["expression": "document.cookie = 'openarch=1; max-age=600'; navigator.userAgent",
                                         "returnByValue": true]) { result in
            let agent = (result?["result"] as? [String: Any])?["value"] as? String ?? ""
            self.expect(agent.contains("Version/") && agent.hasSuffix("Safari/605.1.15") && !agent.contains("Chrome"),
                        "it tells sites it is Safari (\(agent))")
            store.httpCookieStore.getAllCookies { mine in
                other.httpCookieStore.getAllCookies { theirs in
                    MainActor.assumeIsolated {
                        self.expect(mine.contains { $0.name == "openarch" } && !theirs.contains { $0.name == "openarch" },
                                    "its cookie lands in its profile's store, not another's")
                        self.checkMedia(tab, page, then: next)
                    }
                }
            }
        }
    }

    private func checkMedia(_ tab: Item, _ page: WebKitPage, then next: @escaping () -> Void) {
        page.executeJavaScript("""
            (() => { const c = document.createElement('canvas'); c.width = 320; c.height = 180;
              const g = c.getContext('2d'); let i = 0;
              setInterval(() => { g.fillStyle = `hsl(${i++ % 360} 80% 50%)`; g.fillRect(0, 0, 320, 180); }, 50);
              const v = document.createElement('video'); v.srcObject = c.captureStream(20); v.muted = false; document.body.append(v);
              navigator.mediaSession.metadata = new MediaMetadata({ title: 'Starboy', artist: 'The Weeknd' });
              navigator.mediaSession.setActionHandler('nexttrack', () => {}); })()
            """)
        after(0.5) { self.browser.mediaCommand(tab, "toggle") }
        eventually({ tab.media?.playing == true }, timeout: 5) { playing in
            let media = tab.media ?? MediaState()
            self.expect(playing && media.title == "Starboy" && media.artist == "The Weeknd" && media.next,
                        "the sidebar's player gets what the WebKit page plays, from its media session (\(media))")
            self.browser.mediaCommand(tab, "toggle")
            page.executeChromeCommand(OACChromeCommand.find.rawValue)
            page.executeChromeCommand(OACChromeCommand.zoomPlus.rawValue)
            page.findForTesting("domain")
            after(0.5) {
                self.expect(page.isFindBarVisible && page.findMatchCount >= 2,
                            "⌘F shows a find bar over the page that counts the matches (\(page.findMatchCount))")
                self.expect(page.zoomPercent == 110, "zoom works on the page (\(page.zoomPercent) %)")
                page.executeChromeCommand(OACChromeCommand.zoomNormal.rawValue)
                TabSnapshots.capture(tab)
                after(1.5) {
                    self.expect(tab.snapshot != nil, "the tab switcher and previews get a picture of the page")
                    self.browser.sleep(tab)
                    self.expect(tab.pane == nil && tab.isAsleep, "a WebKit page goes to sleep like any other")
                    self.browser.select(tab)
                    self.expect(tab.pane?.engine == .webKit, "and wakes up in WebKit")
                    next()
                }
            }
        }
    }

    /// A Chromium page's link moves the tab to WebKit, a POST stays, the
    /// address field picks again, the setting and Site Controls' switch.
    private func checkHandoff(then next: @escaping () -> Void) {
        let tab = browser.openInNewTab("https://example.com/")
        expect(tab.pane?.engine == .chromium, "any other site opens in Chromium")
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading && tab.liveTitle == "Example Domain" }, timeout: 15) { _ in
            let chromium = tab.pane
            tab.pane?.executeJavaScript("""
                (() => { const a = document.createElement('a'); a.href = 'https://\(Self.standIn)/?from=link';
                  document.body.append(a); a.click(); })()
                """)
            self.eventually({ tab.pane?.engine == .webKit && tab.currentURL.contains("from=link") }, timeout: 10) { moved in
                self.expect(moved && tab.pane !== chromium && self.browser.state.activeItem === tab,
                            "a Chromium page's link to the service opens it in WebKit, in the same tab (\(tab.currentURL))")
                self.browser.navigate(tab, to: "https://example.com/?typed")
                self.expect(tab.pane?.engine == .chromium, "an address typed for the tab picks the engine again")
                self.eventually({ tab.pane?.isLoaded == true && !tab.isLoading && tab.currentURL.contains("typed") },
                                timeout: 15) { _ in
                    tab.pane?.executeJavaScript("""
                        (() => { const f = document.createElement('form'); f.method = 'post';
                          f.action = 'https://\(Self.standIn)/?from=post'; document.body.append(f); f.submit(); })()
                        """)
                    after(4) {
                        self.expect(tab.pane?.engine == .chromium && tab.currentURL.contains("from=post"),
                                    "a form posted to the service stays in Chromium (\(tab.currentURL))")
                        self.checkChoices(tab, then: next)
                    }
                }
            }
        }
    }

    private func checkChoices(_ tab: Item, then next: @escaping () -> Void) {
        let url = "https://\(Self.standIn)/"
        library.settings.protectedMediaWebKit = false
        library.settings.applyToChromium()
        expect(ProtectedMedia.engine(for: url) == .chromium, "with the setting off, the service opens in Chromium")
        library.settings.protectedMediaWebKit = true
        library.settings.applyToChromium()
        browser.navigate(tab, to: url)
        expect(tab.pane?.engine == .webKit, "with it on again, the address field sends it to WebKit")
        ProtectedMedia.choose(.chromium, for: url)
        browser.replacePage(of: tab, with: url, engine: .chromium)
        let file = AppPaths.support.appendingPathComponent("protected-media.json")
        let saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        expect(ProtectedMedia.engine(for: url) == .chromium && tab.pane?.engine == .chromium && saved.contains(Self.standIn),
               "Site Controls send a site back to Chromium, kept in protected-media.json")
        ProtectedMedia.choose(.webKit, for: url)
        browser.replacePage(of: tab, with: url, engine: .webKit)
        expect(ProtectedMedia.engine(for: url) == .webKit && tab.pane?.engine == .webKit,
               "and to Safari's engine again")
        expect(ProtectedMedia.engine(for: "https://example.net/") == .chromium, "other sites are untouched by it")
        // A site of your own: Site Controls send it to WebKit.
        ProtectedMedia.choose(.webKit, for: "https://www.iana.org/")
        expect(ProtectedMedia.engine(for: "https://www.iana.org/help") == .webKit, "any site can be sent to Safari's engine")
        ProtectedMedia.choose(.chromium, for: "https://www.iana.org/")
        expect(ProtectedMedia.engine(for: "https://www.iana.org/help") == .chromium, "and back")
        browser.close(tab)
        next()
    }

    /// Shaka's public Widevine demo stream (Angel One) in Chromium: its
    /// licence server asks for no Verified Media Path. Plays muted.
    private func playShakaDemo(in tab: Item, then next: @escaping () -> Void) {
        tab.pane?.executeJavaScript("""
            (() => { const s = document.createElement('script');
              s.src = 'https://cdn.jsdelivr.net/npm/shaka-player@4/dist/shaka-player.compiled.js';
              s.onload = async () => { try {
                const v = document.createElement('video'); v.muted = true; document.body.append(v);
                const p = new shaka.Player(); await p.attach(v);
                p.configure({ drm: { servers: { 'com.widevine.alpha': 'https://cwip-shaka-proxy.appspot.com/no_auth' } } });
                await p.load('https://storage.googleapis.com/shaka-demo-assets/angel-one-widevine/dash.mpd');
                await v.play(); window.__shaka = 'playing';
              } catch (e) { window.__shaka = 'error ' + (e.code || '') + ' ' + (e.message || e); } };
              document.head.append(s); })()
            """)
        after(20) {
            let check = "JSON.stringify({ state: window.__shaka || 'loading', time: document.querySelector('video')?.currentTime || 0 })"
            tab.pane?.callDevToolsMethod("Runtime.evaluate", params: ["expression": check, "returnByValue": true]) { result in
                let text = (result?["result"] as? [String: Any])?["value"] as? String ?? "no answer"
                Swift.print("[selftest] info Shaka Angel One (Widevine): \(text)")
                let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                self.expect((json?["time"] as? Double ?? 0) > 2,
                            "Shaka's Widevine demo stream plays in Chromium with the setting on (\(text))")
                next()
            }
        }
    }

    /// Chromium's Widevine: whether the component is registered, and that
    /// pages get it only with the setting on.
    private func checkWidevine(then next: @escaping () -> Void) {
        let components = browser.openInNewTab("chrome://components")
        let probe = browser.openInNewTab("https://example.com/eme", select: false)
        browser.loadInBackground(probe)
        let eme = """
            navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{ initDataTypes: ['cenc'],
              videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }] }])
              .then((a) => 'available ' + a.keySystem, (e) => 'refused ' + e.name)
            """
        func ask(_ done: @escaping (String) -> Void) {
            probe.pane?.callDevToolsMethod("Runtime.evaluate", params: ["expression": eme, "awaitPromise": true,
                                                                        "returnByValue": true]) { result in
                done((result?["result"] as? [String: Any])?["value"] as? String ?? "no answer")
            }
        }
        // --widevine-wait <seconds>: give the component updater time to
        // fetch the module first.
        let wait = CommandLine.arguments.firstIndex(of: "--widevine-wait")
            .flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 8
        after(wait) {
            components.pane?.callDevToolsMethod("Runtime.evaluate", params: [
                "expression": """
                    [...document.querySelectorAll('*')].map((e) => e.innerText || '')
                      .filter((t) => t.includes('Widevine') && t.includes('Status'))
                      .sort((a, b) => a.length - b.length)[0] || 'not listed'
                    """,
                "returnByValue": true,
            ]) { result in
                let text = (result?["result"] as? [String: Any])?["value"] as? String ?? "no answer"
                let widevine = text.replacingOccurrences(of: "\n", with: " | ")
                Swift.print("[selftest] info chrome://components: \(widevine)")
                ask { answer in
                    // --widevine: launched as with the setting on.
                    if CommandLine.arguments.contains("--widevine") {
                        Swift.print("[selftest] info Widevine with the setting on: \(answer)")
                        if widevine.contains("Version: 0.0.0.0") || widevine == "not listed" {
                            Swift.print("[selftest] info (the module is not installed yet; try --widevine-wait 150)")
                        } else {
                            self.expect(answer.hasPrefix("available"), "with the setting on, pages get Widevine (\(answer))")
                            return self.playShakaDemo(in: probe) {
                                self.browser.close(components)
                                self.browser.close(probe)
                                next()
                            }
                        }
                    } else {
                        self.expect(answer.hasPrefix("refused NotSupportedError"),
                                    "pages get no Widevine while the setting is off (\(answer))")
                    }
                    self.browser.close(components)
                    self.browser.close(probe)
                    next()
                }
            }
        }
    }
}
