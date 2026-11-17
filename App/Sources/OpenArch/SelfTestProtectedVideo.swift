import AppKit
@preconcurrency import AVFoundation
import OpenArchCore
import OpenArchProtectedVideo

/// Netflix and Disney+ in Chromium (ProtectedVideo.swift, protected-video.js,
/// OpenArchProtectedVideo), as part of `--selftest --fairplay-test`: a page
/// of the self-test's own does what the services' players do (a MediaSource
/// with a video and an audio buffer) with a half-minute film without DRM,
/// made here. So everything runs but the licence itself: the page's script
/// and its queue, the fetches, Apple's parser, decoder and player, the view
/// over the <video>, the copy of the page's controls over that, the
/// sidebar's player and its buttons, and closing the tab. Then Netflix's own
/// page (the internet, no login): that the extension's background registers
/// the script and it runs there as Safari.
extension SelfTest {
    /// A film as a MediaSource takes it: an initialization segment and
    /// media segments, for video and for audio.
    struct VideoFixture: Sendable {
        var video: [Data] = []
        var audio: [Data] = []
    }

    private struct VideoPage: Decodable {
        var events: [String] = []
        var time = 0.0
        var paused = true
        var ended = false
        var duration: Double?
        var error = 0
        var width = 0
        var height = 0
        var agent = ""
        var chrome = ""
        var webkitKeys = ""
        var rect: [Double] = []
        var viewportHeight = 0.0
    }

    private nonisolated static let filmSeconds = 30

    private static let videoPage = """
        <!doctype html><title>Video</title>
        <style>
        body { margin: 0; background: #222; }
        #player { position: relative; width: 480px; height: 270px; margin: 40px; }
        video { width: 100%; height: 100%; background: #000; }
        #controls { position: absolute; left: 20px; bottom: 20px; width: 60px; height: 40px; background: rgb(255, 0, 0); }
        </style>
        <div id=player><video id=v></video><div id=controls></div></div>
        <script>
        const events = [];
        const video = document.getElementById('v');
        for (const type of ['loadedmetadata', 'playing', 'pause', 'seeked', 'ended', 'error']) {
          video.addEventListener(type, () => events.push(type));
        }
        navigator.mediaSession.metadata = new MediaMetadata({ title: 'Selbsttest-Film', artist: 'OpenArch' });
        // The player's controls change while it plays, as a real one's do.
        setInterval(() => { document.getElementById('controls').dataset.tick = Date.now(); }, 400);
        // What Netflix's player does: a MediaSource with one buffer for the
        // picture and one for the sound, filled segment by segment.
        async function start(media) {
          try {
            const source = new MediaSource();
            video.src = URL.createObjectURL(source);
            await new Promise((resolve) => source.addEventListener('sourceopen', resolve, { once: true }));
            source.duration = media.duration;
            const append = async (buffer, url) => {
              const bytes = await (await fetch(url)).arrayBuffer();
              await new Promise((resolve) => {
                buffer.addEventListener('updateend', resolve, { once: true });
                buffer.appendBuffer(bytes);
              });
            };
            const tracks = [
              [source.addSourceBuffer('video/mp4; codecs="avc1.640028"'), media.video],
              [source.addSourceBuffer('audio/mp4; codecs="mp4a.40.2"'), media.audio],
            ];
            for (const [buffer, urls] of tracks) for (const url of urls) await append(buffer, url);
            source.endOfStream();
            video.muted = true;
            await video.play();
            return 'started';
          } catch (error) {
            return 'refused ' + error.name + ' ' + error.message;
          }
        }
        function state() {
          const r = video.getBoundingClientRect();
          return JSON.stringify({ events, time: video.currentTime, paused: video.paused, ended: video.ended,
            duration: video.duration, error: video.error ? video.error.code : 0, width: video.videoWidth,
            height: video.videoHeight, agent: navigator.userAgent, chrome: typeof window.chrome,
            webkitKeys: typeof window.WebKitMediaKeys, rect: [r.left, r.top, r.width, r.height],
            viewportHeight: innerHeight });
        }
        </script>
        """

    private func videoState(_ tab: Item, then done: @escaping (VideoPage, String) -> Void) {
        fairPlayEvaluate(tab, "state()") { text in
            done((try? JSONDecoder().decode(VideoPage.self, from: Data(text.utf8))) ?? VideoPage(), text)
        }
    }

    /// The view over |pane|'s page whose identifier starts with |identifier|
    /// (each page's video and copy have their own).
    private func overlay(_ identifier: String, of pane: any OACPage) -> NSView? {
        (pane as? OACPane)?.window?.contentView?.subviews.first { $0.identifier?.rawValue.hasPrefix(identifier) == true }
    }

    /// The same, in whichever window it is (full screen, the page has a
    /// window of its own).
    private func overlayAnywhere(_ identifier: String) -> NSView? {
        NSApp.windows.lazy.compactMap { window in
            window.contentView?.subviews.first { $0.identifier?.rawValue.hasPrefix(identifier) == true }
        }.first
    }

    func checkProtectedVideo(origin: String, server: FairPlayTestServer, then next: @escaping () -> Void) {
        let stats = AppPaths.support.appendingPathComponent("VideoMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: stats, withIntermediateDirectories: true)
        OAVideoMirror.statsDirectory = stats.path
        Task {
            let fixture = await Self.makeVideoFixture()
            guard let fixture, fixture.video.count >= 3, fixture.audio.count >= 2 else {
                self.expect(false, "AVFoundation makes the test film (\(fixture?.video.count ?? 0) video and \(fixture?.audio.count ?? 0) audio segments)")
                return next()
            }
            var media: [String: Any] = ["duration": Self.filmSeconds]
            for (kind, segments) in [("video", fixture.video), ("audio", fixture.audio)] {
                media[kind] = segments.enumerated().map { index, segment in
                    let path = "/media/\(kind)-\(index).mp4"
                    server.add(path, type: "video/mp4", body: segment)
                    return origin + path
                }
            }
            server.add("/play/video", type: "text/html; charset=utf-8", body: Data(Self.videoPage.utf8))
            self.playProtectedVideo(origin: origin, media: media, stats: stats, then: next)
        }
    }

    private func playProtectedVideo(origin: String, media: [String: Any], stats: URL, then next: @escaping () -> Void) {
        let script = Bundle.main.resourceURL?.appendingPathComponent("BuiltinExtensions/openarch/protected-video.js")
        let source = script.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        expect(!source.isEmpty, "protected-video.js is in the built-in extension")
        let tab = browser.openInNewTab(origin + "/play/video")
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading && tab.liveTitle == "Video" }, timeout: 15) { loaded in
            self.expect(loaded, "the self-test's video page loads (\(tab.liveTitle ?? "no title"))")
            guard let pane = tab.pane else { return next() }
            pane.executeJavaScript("globalThis.__openarchFairPlayTest = true;\n" + source)
            let list = (try? JSONSerialization.data(withJSONObject: media)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            self.checkProtectedVideoQueue(tab, pane) {
                self.startProtectedVideo(tab, pane, list: list, stats: stats, then: next)
            }
        }
    }

    private func startProtectedVideo(_ tab: Item, _ pane: any OACPage, list: String, stats: URL, then next: @escaping () -> Void) {
        fairPlayEvaluate(tab, "start(\(list))") { answer in
            self.expect(answer == "started", "the page fills a MediaSource as Netflix's player does and starts it (\(answer))")
            self.eventually({ tab.media?.playing == true && ProtectedVideo.shared.isPlaying(in: pane) }, timeout: 15) { playing in
                let state = tab.media ?? MediaState()
                self.expect(playing && state.video && state.title == "Selbsttest-Film"
                            && abs(state.duration - Double(Self.filmSeconds)) < 0.5,
                            "Apple's player plays the film, and the sidebar's player shows it as a video with its length (\(state))")
                after(1.5) { self.checkProtectedVideoPicture(tab, pane, stats: stats, then: next) }
            }
        }
    }

    /// What the way from the page to OpenArch carries: 400 messages the
    /// size of the script's own (45 kB), 18 MB in all. Netflix's 4K is about
    /// 3 MB a second in this form.
    private func checkProtectedVideoQueue(_ tab: Item, _ pane: any OACPage, then next: @escaping () -> Void) {
        let total = 400 * 45000
        let began = Date()
        let push = "(() => { const chunk = 'A'.repeat(45000); "
            + "for (let i = 0; i < 400; i++) __openarchPVSend('bench', { data: chunk, i }); return 'sent'; })()"
        fairPlayEvaluate(tab, push) { _ in
            self.eventually({ ProtectedVideo.shared.received(from: pane) >= total }, timeout: 30) { arrived in
                let seconds = max(Date().timeIntervalSince(began), 0.001)
                let rate = Double(ProtectedVideo.shared.received(from: pane)) / seconds / 1_000_000
                self.expect(arrived && rate > 6,
                            "the page's queue carries more than a 4K film needs (\(String(format: "%.1f", rate)) MB a second)")
                next()
            }
        }
    }

    /// The page's side, the picture over the <video>, and the copy of the
    /// page's controls.
    private func checkProtectedVideoPicture(_ tab: Item, _ pane: any OACPage, stats: URL, then next: @escaping () -> Void) {
        videoState(tab) { state, text in
            self.expect(state.time > 0.5 && !state.paused && state.width == 320 && state.height == 180
                        && state.events.contains("loadedmetadata") && state.events.contains("playing"),
                        "the page's <video> reads as playing, with the player's time and the film's size (\(text))")
            self.expect(state.agent.contains("Version/") && state.agent.hasSuffix("Safari/605.1.15") && !state.agent.contains("Chrome")
                        && state.chrome == "undefined" && state.webkitKeys == "function",
                        "the page sees Safari, with its FairPlay keys (\(state.agent), chrome \(state.chrome), WebKitMediaKeys \(state.webkitKeys))")
            let frames = ProtectedVideo.shared.shownFrames(in: pane)
            self.expect(frames > 10, "Apple's player decodes and shows the film's frames (\(frames))")
            let picture = self.overlay("openarch.protectedVideo", of: pane)
            let window = (pane as? OACPane)?.window
            let page = window.map { $0.convertFromScreen((pane as? OACPane)?.screenFrame ?? .zero) } ?? .zero
            // The pane's frame may have OpenArch's toolbar on top: the page
            // is its lower part, as high as the viewport.
            let expected = state.rect.count == 4
                ? NSRect(x: page.minX + state.rect[0], y: page.minY + state.viewportHeight - state.rect[1] - state.rect[3],
                         width: state.rect[2], height: state.rect[3]) : .zero
            let frame = picture.map { $0.convert($0.bounds, to: nil) } ?? .zero
            func near(_ a: NSRect, _ b: NSRect) -> Bool {
                abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
            }
            self.expect(picture?.isHidden == false && near(frame, expected),
                        "the picture lies over the page's <video> (\(frame), the <video> at \(expected))")
            self.eventually({
                let text = (try? String(contentsOf: stats.appendingPathComponent("video-mirror.json"), encoding: .utf8)) ?? ""
                return text.contains("\"shown\":true") && FileManager.default.fileExists(atPath: stats.appendingPathComponent("video-mirror.png").path)
            }, timeout: 8) { mirrored in
                let copy = self.overlay("openarch.videoMirror", of: pane)
                let subviews = (pane as? OACPane)?.window?.contentView?.subviews ?? []
                let above = copy.flatMap { c in picture.flatMap { p in
                    subviews.firstIndex(of: c).flatMap { ci in subviews.firstIndex(of: p).map { ci > $0 } } } } ?? false
                self.expect(mirrored && copy?.isHidden == false && above,
                            "a copy of the page's controls lies over the picture")
                // The page's red button, where the page has it.
                let button = Self.color(in: stats.appendingPathComponent("video-mirror.png"),
                                        at: CGPoint(x: 40 + 20 + 30, y: 40 + 270 - 20 - 20), pageWidth: Double(page.width))
                self.expect(button.map { $0.red > 0.8 && $0.green < 0.3 && $0.blue < 0.3 } ?? false,
                            "the copy shows the page's own button (\(button.map { "\($0)" } ?? "no picture"))")
                // --fairplay-fullscreen: the player full screen too. That
                // takes over the screen, and Chromium grants it only to the
                // app in front, so it is not part of the normal run: start
                // it yourself, from an app that lets OpenArch come forward.
                if CommandLine.arguments.contains("--fairplay-fullscreen") {
                    self.checkProtectedVideoFullScreen(tab, pane) { self.checkProtectedVideoControls(tab, pane, then: next) }
                } else {
                    self.checkProtectedVideoControls(tab, pane, then: next)
                }
            }
        }
    }

    /// The page's player full screen: the page gets a window of its own
    /// there, and the picture and the copy of the controls go with it and
    /// come back.
    private func checkProtectedVideoFullScreen(_ tab: Item, _ pane: any OACPage, then next: @escaping () -> Void) {
        // Chromium lets the page go full screen that the user is in: the
        // one with the focus in the key window, else Chrome's own active
        // tab, which running a Chrome command for the page makes it (the
        // self-test's window is not key while the Mac is in use).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        browser.window?.orderFrontRegardless()
        func screenFrame(_ view: NSView?) -> NSRect {
            view.flatMap { view in view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) } } ?? .zero
        }
        func near(_ a: NSRect, _ b: NSRect) -> Bool {
            abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
        }
        after(1) {
            self.browser.window?.makeKey()
            pane.focus()
            pane.executeChromeCommand(OACChromeCommand.zoomNormal.rawValue)
        }
        var granted = "no answer"
        after(2) {
            pane.callDevToolsMethod("Runtime.evaluate", params: [
                "expression": "document.getElementById('player').requestFullscreen().then(() => 'granted', (e) => 'refused: ' + e.message)",
                "awaitPromise": true, "returnByValue": true, "userGesture": true,
            ]) { result in
                granted = (result?["result"] as? [String: Any])?["value"] as? String ?? "no answer"
            }
            // The player fills the screen, and so does its <video>.
            self.eventually({
                guard pane.isFullScreen, let picture = self.overlayAnywhere("openarch.protectedVideo"), !picture.isHidden,
                      let window = picture.window, window !== self.browser.window, window.styleMask.contains(.fullScreen),
                      let copy = self.overlayAnywhere("openarch.videoMirror"), !copy.isHidden, copy.window === window
                else { return false }
                return near(screenFrame(picture), window.frame)
            }, timeout: 10) { followed in
                let picture = self.overlayAnywhere("openarch.protectedVideo")
                self.expect(followed, "full screen, the picture and the copy of the controls fill the page's own window "
                            + "(the page's request: \(granted); OpenArch active \(NSApp.isActive), its window key "
                            + "\(self.browser.window?.isKeyWindow == true); page full screen \(pane.isFullScreen), "
                            + "picture \(screenFrame(picture)) in \(picture?.window?.frame ?? .zero), hidden \(picture?.isHidden ?? true))")
                let frames = ProtectedVideo.shared.shownFrames(in: pane)
                after(1.5) {
                    self.expect(ProtectedVideo.shared.shownFrames(in: pane) > frames + 10,
                                "and the film goes on there (\(ProtectedVideo.shared.shownFrames(in: pane) - frames) frames in 1.5 s)")
                    pane.executeJavaScript("document.exitFullscreen()")
                    self.eventually({
                        guard !pane.isFullScreen, let picture = self.overlay("openarch.protectedVideo", of: pane), !picture.isHidden,
                              let copy = self.overlay("openarch.videoMirror", of: pane), !copy.isHidden else { return false }
                        return picture.window === self.browser.window && picture.frame.width < 500
                    }, timeout: 10) { back in
                        let picture = self.overlayAnywhere("openarch.protectedVideo")
                        self.expect(back, "leaving full screen brings both back over the page in OpenArch's window "
                                    + "(picture \(picture?.frame ?? .zero), in the window \(picture?.window === self.browser.window))")
                        next()
                    }
                }
            }
        }
    }

    /// Picture in Picture, as when the tab is left while the film plays.
    private func checkProtectedVideoControls(_ tab: Item, _ pane: any OACPage, then next: @escaping () -> Void) {
        browser.mediaCommand(tab, "pip")
        eventually({ tab.media?.pip == true }, timeout: 8) { floating in
            let panel = NSApp.windows.contains { $0.isVisible && NSStringFromClass(type(of: $0)).contains("PIPPanel") }
            self.expect(floating && panel, "Picture in Picture is macOS's own window, and the page knows it floats (\(tab.media?.pip == true), window \(panel))")
            self.browser.mediaCommand(tab, "exitpip")
            self.eventually({ tab.media?.pip == false }, timeout: 8) { back in
                self.expect(back && self.overlay("openarch.protectedVideo", of: pane)?.isHidden == false,
                            "leaving it brings the picture back over the page")
                self.checkProtectedVideoButtons(tab, pane, then: next)
            }
        }
    }

    private func checkProtectedVideoButtons(_ tab: Item, _ pane: any OACPage, then next: @escaping () -> Void) {
        browser.mediaCommand(tab, "toggle")
        eventually({ tab.media?.playing == false && !ProtectedVideo.shared.isPlaying(in: pane) }, timeout: 5) { paused in
            self.videoState(tab) { state, text in
                self.expect(paused && state.paused && state.events.contains("pause"),
                            "the sidebar's pause button pauses the player and the page (\(text))")
                self.browser.seekMedia(tab, to: Double(Self.filmSeconds) - 1.5)
                self.browser.mediaCommand(tab, "toggle")
                after(5) {
                    self.videoState(tab) { state, text in
                        self.expect(state.ended && state.events.contains("seeked") && state.events.contains("ended")
                                    && abs(state.time - Double(Self.filmSeconds)) < 0.5 && state.error == 0,
                                    "a jump in the sidebar's player moves the film, which then plays to its end (\(text))")
                        self.browser.close(tab)
                        after(0.5) {
                            let left = NSApp.windows.flatMap { $0.contentView?.subviews ?? [] }.filter {
                                let identifier = $0.identifier?.rawValue ?? ""
                                return identifier.hasPrefix("openarch.protectedVideo") || identifier.hasPrefix("openarch.videoMirror")
                            }
                            self.expect(left.isEmpty && !ProtectedVideo.shared.isPlaying(in: pane),
                                        "closing the tab takes the picture and the copy away")
                            OAVideoMirror.statsDirectory = nil
                            next()
                        }
                    }
                }
            }
        }
    }

    /// Netflix's own page: the extension's relay learns that the setting is
    /// on, its background registers protected-video.js and loads the page
    /// again, and the script runs there; the requests say Safari
    /// (OptionalExtensions/safari-user-agent).
    func checkProtectedVideoNetflix(then next: @escaping () -> Void) {
        let tab = browser.openInNewTab("https://www.netflix.com/")
        expect(tab.pane?.engine == .chromium, "with the setting on, Netflix opens as a Chromium page")
        let probe = """
            JSON.stringify({ agent: navigator.userAgent, chrome: typeof window.chrome, keys: typeof window.WebKitMediaKeys,
              script: !document.dispatchEvent(new CustomEvent('openarch-pv-ping', { cancelable: true })),
              server: String(window.netflix?.reactContext?.models?.browserInfo?.data?.name) })
            """
        var answer = ""
        func ask() {
            guard tab.pane != nil else { return }
            self.fairPlayEvaluate(tab, probe) { answer = $0 }
        }
        // The first load is without the script; the background's reload
        // brings it.
        for delay in stride(from: 3.0, through: 21.0, by: 3.0) { after(delay) { ask() } }
        eventually({ answer.contains("\"script\":true") && answer.contains("Safari/605.1.15") && !answer.contains("Chrome/") },
                   timeout: 24) { ran in
            self.expect(ran && answer.contains("\"chrome\":\"undefined\"") && answer.contains("\"keys\":\"function\""),
                        "in Netflix's page the extension's script runs before the page's, as Safari (\(answer))")
            // What Netflix's server made of the request (the page's own data).
            self.expect(answer.contains("\"server\":\"Safari\""),
                        "and the request itself told Netflix it came from Safari")
            self.browser.close(tab)
            next()
        }
    }

    /// The color at |point| (CSS pixels from the page's top left) of the
    /// picture in |file|, which shows a page |pageWidth| points wide.
    private static func color(in file: URL, at point: CGPoint, pageWidth: Double) -> (red: Double, green: Double, blue: Double)? {
        guard let data = try? Data(contentsOf: file), let image = NSBitmapImageRep(data: data), pageWidth > 0 else { return nil }
        let scale = Double(image.pixelsWide) / pageWidth
        guard let color = image.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB) else { return nil }
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    // MARK: The film

    private final class Segments: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [Data] = []
        var all: [Data] { lock.withLock { data } }

        func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType) {
            lock.withLock { data.append(segmentData) }
        }
    }

    /// The film: 320×180 at 24 frames a second in H.264 and a quiet tone in
    /// AAC, each as fragmented MP4 in segments of two seconds.
    private nonisolated static func makeVideoFixture() async -> VideoFixture? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-video-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func writer(_ segments: Segments) -> AVAssetWriter {
            let writer = AVAssetWriter(contentType: .mpeg4Movie)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
            writer.initialSegmentStartTime = .zero
            writer.delegate = segments
            return writer
        }

        // The picture: a color that moves through the hues.
        let pictures = Segments()
        let film = writer(pictures)
        let width = 320, height = 180, rate: Int32 = 24
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 48, AVVideoAllowFrameReorderingKey: false],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard film.canAdd(input) else { return nil }
        film.add(input)
        guard film.startWriting() else { return nil }
        film.startSession(atSourceTime: .zero)
        for frame in 0..<(filmSeconds * Int(rate)) {
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 2000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                waited += 1
            }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let color = NSColor(hue: CGFloat(frame % 144) / 144, saturation: 0.8, brightness: 0.9, alpha: 1).usingColorSpace(.sRGB)
                let pixel: [UInt8] = [UInt8((color?.blueComponent ?? 0) * 255), UInt8((color?.greenComponent ?? 0) * 255),
                                      UInt8((color?.redComponent ?? 0) * 255), 255]
                let row = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<height {
                    let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { for c in 0..<4 { line[x * 4 + c] = pixel[c] } }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: rate)) else { return nil }
        }
        input.markAsFinished()
        await film.finishWriting()
        guard film.status == .completed else { return nil }

        // The sound: the FairPlay test's tone.
        let wave = folder.appendingPathComponent("tone.wav")
        guard (try? fairPlayWave(seconds: filmSeconds).write(to: wave)) != nil else { return nil }
        let asset = AVURLAsset(url: wave)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        let sounds = Segments()
        let tone = writer(sounds)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000,
        ])
        guard tone.canAdd(audio) else { return nil }
        tone.add(audio)
        guard reader.startReading(), tone.startWriting() else { return nil }
        tone.startSession(atSourceTime: .zero)
        while let sample = output.copyNextSampleBuffer() {
            var waited = 0
            while !audio.isReadyForMoreMediaData, waited < 2000 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                waited += 1
            }
            guard audio.append(sample) else { return nil }
        }
        audio.markAsFinished()
        await tone.finishWriting()
        guard tone.status == .completed else { return nil }
        return VideoFixture(video: pictures.all, audio: sounds.all)
    }
}
