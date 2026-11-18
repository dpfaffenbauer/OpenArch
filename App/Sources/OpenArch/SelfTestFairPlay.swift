import AppKit
import Network
import OpenArchCore

/// Spotify in Chromium (FairPlay.swift, fairplay.js, the OpenArchFairPlay
/// helper): which engine Spotify gets with the setting on and off, what a
/// playlist may load, and the whole chain with a page of the self-test's own
/// that does what Spotify's player does in Safari. Its track is a tone
/// without DRM, so everything runs but the licence itself: the page's
/// script, the bridge, the helper and Apple's player, the sidebar's player
/// and its buttons, the end of the track, a key request that fails, a
/// playlist the bridge refuses, closing the tab, and the setting off. Then
/// Spotify's own page (it needs the internet, and without a login plays
/// nothing): that the extension's script runs there before Spotify's.
/// Netflix and Disney+ (SelfTestProtectedVideo.swift) run in between.
/// `--selftest --fairplay-test` runs these. The helper plays without sound.
extension SelfTest {
    func fairPlayFeatures(then done: @escaping () -> Void) {
        checkFairPlayRules()
        guard FairPlay.isAvailable, let tone = Self.fairPlayTone() else {
            expect(false, "the FairPlay helper is in the app, and afconvert makes the test tone")
            return done()
        }
        let server = FairPlayTestServer(tone: tone)
        server.start { port in
            guard let port else {
                self.expect(false, "the FairPlay test server starts")
                return done()
            }
            let origin = "http://127.0.0.1:\(port)"
            FairPlay.testOrigins = [origin]
            ProtectedVideo.testOrigins = [origin]
            self.library.settings.fairPlayInChromium = true
            self.library.settings.applyToChromium()
            self.checkFairPlayPlayback(origin: origin) {
                self.checkProtectedVideo(origin: origin, server: server) {
                    self.checkFairPlaySpotify {
                        self.checkProtectedVideoNetflix {
                            self.checkFairPlayOff(origin: origin) {
                                FairPlay.testOrigins = []
                                ProtectedVideo.testOrigins = []
                                server.stop()
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Which engine Spotify gets, and what a playlist may load.
    private func checkFairPlayRules() {
        let spotify = "https://open.spotify.com/track/1"
        ProtectedMedia.resetForTesting()
        library.settings.protectedMediaWebKit = true
        library.settings.fairPlayInChromium = false
        library.settings.applyToChromium()
        expect(FairPlay.isAvailable, "the FairPlay helper is in the app")
        let netflix = "https://www.netflix.com/watch/1", disney = "https://www.disneyplus.com/play/1"
        expect(!FairPlay.isOn && !ProtectedVideo.isOn && ProtectedMedia.engine(for: spotify) == .webKit
               && ProtectedMedia.engine(for: netflix) == .webKit,
               "with \"Streamingdienste in Chromium\" off, Spotify and Netflix open in WebKit")
        library.settings.fairPlayInChromium = true
        library.settings.applyToChromium()
        expect(FairPlay.isOn && ProtectedVideo.isOn && ProtectedMedia.engine(for: spotify) == .chromium
               && ProtectedMedia.engine(for: netflix) == .chromium && ProtectedMedia.engine(for: disney) == .chromium
               && ProtectedMedia.engine(for: "https://www.primevideo.com/detail/1") == .webKit,
               "with it on, Spotify, Netflix and Disney+ stay in Chromium, and Prime Video still opens in WebKit")
        ProtectedVideo.safariUserAgentLoaded = false
        expect(ProtectedMedia.engine(for: netflix) == .webKit && ProtectedMedia.engine(for: disney) == .chromium,
               "until OpenArch has started with the setting on, Netflix keeps Safari's engine and Disney+ plays in Chromium")
        ProtectedVideo.safariUserAgentLoaded = true
        FeatureSwitches.shared.setLocalForTesting([.fairPlayVideo])
        expect(FairPlay.isOn && !ProtectedVideo.isOn && ProtectedMedia.engine(for: spotify) == .chromium
               && ProtectedMedia.engine(for: netflix) == .webKit,
               "the kill switch fairPlayVideo sends Netflix to WebKit again and leaves Spotify in Chromium")
        FeatureSwitches.shared.setLocalForTesting(nil)
        ProtectedMedia.choose(.webKit, for: spotify)
        expect(ProtectedMedia.engine(for: spotify) == .webKit, "Site Controls still send Spotify to Safari's engine")
        ProtectedMedia.choose(.chromium, for: spotify)
        expect(ProtectedMedia.engine(for: spotify) == .chromium && !ProtectedMedia.choices.removed.contains("open.spotify.com"),
               "and back to Chromium, without taking it off the list")
        FeatureSwitches.shared.setLocalForTesting([.fairPlay])
        expect(!FairPlay.isOn && !ProtectedVideo.isOn && ProtectedMedia.engine(for: spotify) == .webKit
               && ProtectedMedia.engine(for: netflix) == .webKit,
               "the kill switch fairPlay sends them all to WebKit again")
        FeatureSwitches.shared.setLocalForTesting(nil)
        library.settings.fairPlayInChromium = false
        library.settings.applyToChromium()
        expect(ProtectedMedia.engine(for: spotify) == .webKit, "with the setting off again, Spotify opens in WebKit")

        let head = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n"
        let key = "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://track\",KEYFORMAT=\"com.apple.streamingkeydelivery\"\n"
        expect(FairPlay.isRemoteOnly(head + key + "#EXTINF:6,\nhttps://audio.example/a.mp4\n#EXT-X-ENDLIST\n"),
               "a playlist with an skd:// key and https segments may play")
        expect(!FairPlay.isRemoteOnly(head + "#EXTINF:6,\nhttp://audio.example/a.mp4\n")
               && !FairPlay.isRemoteOnly(head + "#EXTINF:6,\nfile:///etc/passwd\n")
               && !FairPlay.isRemoteOnly(head + "#EXTINF:6,\nsegment.mp4\n")
               && !FairPlay.isRemoteOnly(head + "#EXT-X-MAP:URI=\"http://127.0.0.1:9/init.mp4\"\n#EXTINF:6,\nhttps://a.example/a.mp4\n")
               && !FairPlay.isRemoteOnly(head + "#EXTINF:6,\nskd://track\n"),
               "one that loads over http, from a file, a relative address or the Mac itself may not")
        expect(FairPlay.isRemoteOnly(head + "#EXTINF:6,\nhttp://127.0.0.1:9/a.aac\n", alsoFrom: "http://127.0.0.1:9")
               && !FairPlay.isRemoteOnly(head + "#EXTINF:6,\nhttp://127.0.0.1:90/a.aac\n", alsoFrom: "http://127.0.0.1:9"),
               "the self-test's own page may play from itself, and from nowhere else")
    }

    private struct FairPlayPage: Decodable {
        var events: [String] = []
        var time = 0.0
        var paused = true
        var ended = false
        var duration: Double?
        var error = 0
    }

    func fairPlayEvaluate(_ tab: Item, _ expression: String, then done: @escaping (String) -> Void) {
        guard let pane = tab.pane else { return done("no page") }
        pane.callDevToolsMethod("Runtime.evaluate", params: ["expression": expression, "awaitPromise": true,
                                                             "returnByValue": true]) { result in
            done((result?["result"] as? [String: Any])?["value"] as? String ?? "no answer")
        }
    }

    private func fairPlayState(_ tab: Item, then done: @escaping (FairPlayPage, String) -> Void) {
        fairPlayEvaluate(tab, "state()") { text in
            done((try? JSONDecoder().decode(FairPlayPage.self, from: Data(text.utf8))) ?? FairPlayPage(), text)
        }
    }

    /// Opens the player page, runs fairplay.js in it as the extension does
    /// on Spotify, and starts |playlist| the way Spotify's player does.
    private func fairPlayStart(_ tab: Item, playlist: String, then done: @escaping (String) -> Void) {
        let literal = (try? JSONEncoder().encode(playlist)).flatMap { String(data: $0, encoding: .utf8) } ?? "''"
        fairPlayEvaluate(tab, "start(\(literal))", then: done)
    }

    private func openFairPlayPage(_ origin: String, then done: @escaping (Item) -> Void) {
        let script = Bundle.main.resourceURL?.appendingPathComponent("BuiltinExtensions/openarch/fairplay.js")
        let source = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        expect(!source.isEmpty, "fairplay.js is in the built-in extension")
        let tab = browser.openInNewTab(origin + "/player")
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading && tab.liveTitle == "FairPlay" }, timeout: 15) { loaded in
            self.expect(loaded, "the self-test's player page loads (\(tab.liveTitle ?? "no title"))")
            tab.pane?.executeJavaScript("globalThis.__openarchFairPlayTest = true;\n" + source)
            done(tab)
        }
    }

    private func checkFairPlayPlayback(origin: String, then next: @escaping () -> Void) {
        let segment = "#EXTINF:6.0,\n\(origin)/tone.aac\n#EXT-X-ENDLIST\n"
        let head = "#EXTM3U\n#EXT-X-VERSION:5\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        // A key only in a comment: the page's script takes the playlist for
        // a FairPlay one, Apple's player finds nothing to ask a key for.
        let clear = head + "# URI=\"skd://openarch-selftest\"\n" + segment
        let keyed = head + "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://openarch-selftest\","
            + "KEYFORMAT=\"com.apple.streamingkeydelivery\",KEYFORMATVERSIONS=\"1\"\n" + segment
        let elsewhere = head + "# URI=\"skd://openarch-selftest\"\n#EXTINF:6.0,\nhttp://127.0.0.1:9/tone.aac\n#EXT-X-ENDLIST\n"
        openFairPlayPage(origin) { tab in
            guard let pane = tab.pane else { return next() }
            self.fairPlayStart(tab, playlist: clear) { answer in
                self.expect(answer == "started", "the page gets FairPlay as in Safari and starts its track (\(answer))")
                self.eventually({ tab.media?.playing == true && FairPlay.shared.isPlaying(in: pane) }, timeout: 12) { playing in
                    let media = tab.media ?? MediaState()
                    self.expect(playing && media.title == "Selbsttest" && media.artist == "OpenArch" && media.next
                                && abs(media.duration - 6) < 0.5 && !media.video,
                                "the helper plays it, and the sidebar's player shows it with its length (\(media))")
                    self.expect(tab.isAudible, "the tab shows its speaker, though Chromium plays nothing")
                    after(1) {
                        self.fairPlayState(tab) { state, text in
                            self.expect(state.time > 0.3 && !state.paused && abs((state.duration ?? 0) - 6) < 0.5
                                        && state.events.contains("loadedmetadata") && state.events.contains("playing")
                                        && state.events.contains("encrypted"),
                                        "the page's <audio> reads as playing, with the helper's time (\(text))")
                            self.checkFairPlayControls(tab, pane, keyed: keyed, elsewhere: elsewhere, clear: clear, then: next)
                        }
                    }
                }
            }
        }
    }

    /// The sidebar's buttons, the end of the track, a key request, a
    /// refused playlist, and closing the tab.
    private func checkFairPlayControls(_ tab: Item, _ pane: any OACPage, keyed: String, elsewhere: String, clear: String,
                                       then next: @escaping () -> Void) {
        browser.mediaCommand(tab, "toggle")
        eventually({ tab.media?.playing == false && !FairPlay.shared.isPlaying(in: pane) && !tab.isAudible }, timeout: 5) { paused in
            self.fairPlayState(tab) { state, text in
                self.expect(paused && state.paused && state.events.contains("pause"),
                            "the sidebar's pause button pauses the helper and the page (\(text))")
                self.browser.seekMedia(tab, to: 4.5)
                self.browser.mediaCommand(tab, "toggle")
                after(5) {
                    self.fairPlayState(tab) { state, text in
                        self.expect(state.ended && state.events.contains("seeked") && state.events.contains("ended")
                                    && abs(state.time - 6) < 0.5 && tab.media?.playing == false,
                                    "a jump in the sidebar's player moves the track, which then plays to its end (\(text))")
                        self.browser.toast?.orderOut(nil)
                        // A real key: macOS is asked for the key request and
                        // refuses the self-test's made-up certificate.
                        self.fairPlayStart(tab, playlist: keyed) { _ in
                            self.eventually({ self.browser.toast?.isVisible == true }, timeout: 10) { told in
                                self.fairPlayState(tab) { state, text in
                                    self.expect(told && state.error == 3 && state.events.contains("error"),
                                                "a track whose key cannot be had fails in the page, and a toast offers Safari's engine (\(text))")
                                    self.fairPlayStart(tab, playlist: elsewhere) { _ in
                                        after(1) {
                                            self.fairPlayState(tab) { state, text in
                                                self.expect(state.events.filter { $0 == "error" }.count == 2,
                                                            "a playlist that loads from somewhere it may not is refused (\(text))")
                                                self.checkFairPlayClose(tab, pane, clear: clear, then: next)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func checkFairPlayClose(_ tab: Item, _ pane: any OACPage, clear: String, then next: @escaping () -> Void) {
        fairPlayStart(tab, playlist: clear) { _ in
            self.eventually({ FairPlay.shared.isPlaying(in: pane) }, timeout: 12) { playing in
                let helper = FairPlay.shared.process
                self.expect(playing && helper?.isRunning == true, "after a failure the next track plays again")
                self.browser.close(tab)
                self.expect(!FairPlay.shared.isPlaying(in: pane) && FairPlay.shared.process == nil,
                            "closing the tab stops its track")
                after(3) {
                    self.expect(helper?.isRunning == false, "and the helper leaves")
                    next()
                }
            }
        }
    }

    /// Spotify's own page: a Chromium page, in which the built-in extension
    /// has run fairplay.js, so the page is offered FairPlay and no Widevine.
    private func checkFairPlaySpotify(then next: @escaping () -> Void) {
        let tab = browser.openInNewTab("https://open.spotify.com/")
        expect(tab.pane?.engine == .chromium, "with the setting on, Spotify opens as a Chromium page")
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading && tab.currentURL.contains("open.spotify.com") }, timeout: 30) { _ in
            let probe = """
                (async () => {
                  const ask = (system) => navigator.requestMediaKeySystemAccess(system, [{ initDataTypes: ['cenc', 'skd'],
                    audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }]).then(() => 'offered', () => 'refused');
                  return 'FairPlay ' + await ask('com.apple.fps.1_0') + ', Widevine ' + await ask('com.widevine.alpha');
                })()
                """
            self.fairPlayEvaluate(tab, probe) { answer in
                self.expect(answer == "FairPlay offered, Widevine refused",
                            "in Spotify's page the extension's script offers FairPlay, and no Widevine (\(answer))")
                self.browser.close(tab)
                next()
            }
        }
    }

    /// With the setting off the page gets no FairPlay, and no helper starts.
    private func checkFairPlayOff(origin: String, then next: @escaping () -> Void) {
        library.settings.fairPlayInChromium = false
        library.settings.applyToChromium()
        openFairPlayPage(origin) { tab in
            self.fairPlayStart(tab, playlist: "#EXTM3U\n") { answer in
                self.expect(answer == "refused NotSupportedError" && FairPlay.shared.process == nil,
                            "with the setting off, the page gets no FairPlay and no helper starts (\(answer))")
                self.browser.close(tab)
                next()
            }
        }
    }

    /// Six seconds of that tone as AAC (ADTS), which an HLS playlist can
    /// name as its only segment.
    private static func fairPlayTone() -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-fairplay-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("tone.wav"), target = folder.appendingPathComponent("tone.aac")
        let convert = Process()
        convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        convert.arguments = ["-f", "adts", "-d", "aac", source.path, target.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        do {
            try fairPlayWave(seconds: 6).write(to: source)
            try convert.run()
        } catch {
            return nil
        }
        convert.waitUntilExit()
        return convert.terminationStatus == 0 ? try? Data(contentsOf: target) : nil
    }

    /// A quiet tone as a WAV file.
    nonisolated static func fairPlayWave(seconds: Int) -> Data {
        let rate = 44100
        var samples = Data(capacity: rate * seconds * 2)
        for index in 0..<(rate * seconds) {
            let value = Int16(2000 * sin(2 * Double.pi * 440 * Double(index) / Double(rate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        func little<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var wave = Data("RIFF".utf8) + little(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        wave += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1)) + little(UInt32(rate))
        wave += little(UInt32(rate * 2)) + little(UInt16(2)) + little(UInt16(16))
        wave += Data("data".utf8) + little(UInt32(samples.count)) + samples
        return wave
    }
}

/// The FairPlay test's pages, its track and its video, on 127.0.0.1.
final class FairPlayTestServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "openarch.selftest.fairplay")
    private let tone: Data
    private let lock = NSLock()
    private var routes: [String: (type: String, body: Data)] = [:]

    /// Serves |body| at |path| from now on.
    func add(_ path: String, type: String, body: Data) {
        lock.withLock { routes[path] = (type, body) }
    }

    /// What Spotify's player does in Safari: asks for FairPlay, sets the
    /// service's certificate, gives its <audio> the keys and an HLS playlist
    /// as a data: address, and answers "encrypted" with a key session.
    static let player = """
        <!doctype html><title>FairPlay</title><audio id=a></audio>
        <script>
        const events = [];
        const audio = document.getElementById('a');
        for (const type of ['loadedmetadata', 'playing', 'pause', 'seeked', 'ended', 'error', 'encrypted']) {
          audio.addEventListener(type, () => events.push(type));
        }
        navigator.mediaSession.metadata = new MediaMetadata({ title: 'Selbsttest', artist: 'OpenArch' });
        navigator.mediaSession.setActionHandler('nexttrack', () => events.push('next'));
        async function start(playlist) {
          try {
            const access = await navigator.requestMediaKeySystemAccess('com.apple.fps.1_0', [{ initDataTypes: ['skd'],
              audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }]);
            const keys = await access.createMediaKeys();
            await keys.setServerCertificate(new Uint8Array([1, 2, 3, 4]));
            await audio.setMediaKeys(keys);
            audio.addEventListener('encrypted', (event) => {
              const session = keys.createSession();
              session.addEventListener('message', () => events.push('key-request'));
              session.generateRequest(event.initDataType, event.initData);
            }, { once: true });
            audio.src = 'data:application/vnd.apple.mpegurl;base64,' + btoa(playlist);
            await audio.play();
            return 'started';
          } catch (error) {
            return 'refused ' + error.name;
          }
        }
        function state() {
          return JSON.stringify({ events, time: audio.currentTime, paused: audio.paused, ended: audio.ended,
            duration: audio.duration, error: audio.error ? audio.error.code : 0 });
        }
        </script>
        """

    init(tone: Data) {
        self.tone = tone
    }

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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [tone, weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.prefix { $0 != "?" })
            let (type, body): (String, Data?) = switch path {
            case "/player": ("text/html; charset=utf-8", Data(Self.player.utf8))
            case "/tone.aac": ("audio/aac", tone)
            default: self?.lock.withLock { self?.routes[path] }.map { ($0.type, Optional($0.body)) } ?? ("text/plain", nil)
            }
            let head = "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \((body ?? Data()).count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + (body ?? Data()), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
