// Adapted from Ardia's FairPlay bridge (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios/ArdiaFairPlay.mm), Apache License 2.0,
// Copyright 2026 Mantra Patel. Changed for OpenArch. See NOTICE.

import AppKit
import OpenArchCore

/// What a window does for a page that OpenArch plays with Apple's FairPlay:
/// a track in the helper (FairPlay), or a video over the page
/// (ProtectedVideo).
@MainActor
protocol FairPlayHost: AnyObject {
    /// The tab's speaker is off (the sidebar's mute).
    func fairPlayIsMuted(_ page: any OACPage) -> Bool
    /// OpenArch started or stopped playing for the page: Chromium does not
    /// know the tab is audible.
    func fairPlay(_ page: any OACPage, isPlaying: Bool)
    /// The page's track or video could not play.
    func fairPlayFailed(_ page: any OACPage)
    /// Picture in Picture's button back to the tab was pressed.
    func fairPlayBackToTab(_ page: any OACPage)
}

/// Spotify in a Chromium page, played with Apple's FairPlay (Settings ›
/// Allgemein › Geschützte Inhalte › „Streamingdienste in Chromium
/// abspielen“; Netflix's and Disney+'s video is ProtectedVideo.swift).
///
/// Chromium has no DRM that Spotify accepts, WebKit does, so Spotify's
/// player opens in a WebKit page (ProtectedMedia), without Chrome's
/// extensions and logins. With this setting on it stays a Chromium page:
/// fairplay.js (the built-in extension) offers the page FairPlay as Safari
/// would, and hands the track's HLS playlist and Spotify's certificate to
/// this bridge, which plays it in a helper process (OpenArchFairPlay, with
/// Apple's player). macOS makes the key request, the page's own code trades
/// it for the licence with Spotify, the licence goes back to the helper:
/// the audio stays encrypted until Apple's decoder.
///
/// One helper, one track: the page that loads a track owns the helper, and
/// a page that had it reads as paused ("stolen"). Messages from pages come
/// through their console (`marker`), answers go back as an
/// "openarch-fairplay" DOM event.
@MainActor
final class FairPlay {
    static let shared = FairPlay()

    static let marker = "__openarch_fairplay__ "
    /// The pages fairplay.js runs in (the extension's manifest). Their
    /// entries in the WebKit list: ProtectedMediaSites.inChromiumGroups.
    static let origins: Set<String> = ["https://open.spotify.com"]

    /// The setting.
    static var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isOn { shared.switchedOff() }
            if !ProtectedVideo.isOn { ProtectedVideo.shared.switchedOff() }
        }
    }

    /// Whether Spotify's pages stay in Chromium and play through the
    /// helper: the setting, the helper in the app, and the kill switch
    /// `fairPlay` (FeatureSwitches).
    static var isOn: Bool { isEnabled && isAvailable && FeatureSwitches.shared.isOn(.fairPlay) }

    /// Whether this build has the helper (asked once: `isOn` is asked for
    /// every navigation).
    static let isAvailable = FileManager.default.isExecutableFile(atPath: helperPath)

    /// OPENARCH_FAIRPLAY_TRACE=1: what the page's script and the helper do
    /// goes to OpenArch's log (never a key, a licence or a playlist), to
    /// see where a track that does not play gets stuck.
    static let traces = ProcessInfo.processInfo.environment["OPENARCH_FAIRPLAY_TRACE"] == "1"

    /// The self-test's page: its origin, served like Spotify's, and may
    /// play from itself over http.
    static var testOrigins: Set<String> = []

    private static var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/OpenArchFairPlay.app/Contents/MacOS/OpenArchFairPlay").path
    }

    // What a page may send, as in Ardia.
    private static let maxCertificate = 64 * 1024
    private static let maxLicense = 64 * 1024
    private static let maxPlaylistPart = 60 * 1024
    private static let maxPlaylist = 2 * 1024 * 1024
    private static let maxParts = 40
    private static let maxLine = 4 * 1024 * 1024

    /// The helper while it runs (the self-test watches it leave).
    private(set) var process: Process?
    private var input: FileHandle?
    private var output = Data()
    private static let queueName = "openarch.fairplay.writes"
    private let writes = DispatchQueue(label: FairPlay.queueName)

    /// The page whose track the helper has, and that track's number in the
    /// page (the page counts its own; the helper gets `load`).
    private weak var owner: (any OACPage)?
    private var generation = 0
    private var loads = 0
    private var load = 0
    private var failedGeneration = 0
    private(set) var isPlaying = false
    private var pageMuted = false

    /// A playlist arriving in parts.
    private weak var partsPage: (any OACPage)?
    private var partsGeneration = 0
    private var parts: [String]?
    private var certificate = ""

    /// Pages that said hello, to tell them when the setting changes.
    private let pages = NSHashTable<AnyObject>.weakObjects()

    /// Whether the helper plays |page|'s track right now.
    func isPlaying(in page: any OACPage) -> Bool {
        isPlaying && page === owner
    }

    // MARK: From the page

    /// A page's console message: true when it was fairplay.js's.
    func receive(_ message: String, from page: any OACPage) -> Bool {
        guard message.hasPrefix(Self.marker) else { return false }
        guard page.engine == .chromium, let origin = Self.origin(of: page.url), Self.serves(origin),
              let object = try? JSONSerialization.jsonObject(with: Data(message.dropFirst(Self.marker.count).utf8)),
              let message = object as? [String: Any], let op = message["op"] as? String else { return true }
        switch op {
        case "hello":
            pages.add(page)
            deliver(["event": "config", "on": Self.isOn, "trace": Self.traces], to: page)
        case "trace":
            if Self.traces { log("FairPlay: page: \(Self.text(message["what"], 300) ?? "")") }
        case "load":
            loadPart(message, from: page, origin: origin)
        case "failed":
            (page.delegate as? FairPlayHost)?.fairPlayFailed(page)
        default:
            guard page === owner else { return true }
            control(op, message)
        }
        return true
    }

    /// What the page that owns the helper asks of it.
    private func control(_ op: String, _ message: [String: Any]) {
        switch op {
        case "license":
            guard let generation = Self.whole(message["gen"], 1...Int(Int32.max)), generation == self.generation, load != 0,
                  let ckc = Self.text(message["ckc"], Self.maxLicense), !ckc.isEmpty else { return }
            send(["op": "license", "gen": load, "ckc": ckc])
        case "play", "pause":
            send(["op": op])
        case "seek":
            guard let time = Self.finite(message["time"]), time >= 0,
                  let sequence = Self.whole(message["seq"], 0...Int(Int32.max)) else { return }
            send(["op": "seek", "time": time, "seq": sequence])
        case "volume":
            guard let volume = Self.finite(message["volume"]) else { return }
            send(["op": "volume", "volume": min(max(volume, 0), 1)])
        case "muted":
            pageMuted = message["muted"] as? Bool ?? false
            sendMuted()
        case "metadata":
            let artwork = Self.text(message["artwork"], 4096) ?? ""
            send([
                "op": "metadata",
                "title": Self.text(message["title"], 1024) ?? "",
                "artist": Self.text(message["artist"], 1024) ?? "",
                "album": Self.text(message["album"], 1024) ?? "",
                "artwork": URL(string: artwork)?.scheme == "https" ? artwork : "",
            ])
        case "stop":
            stop()
        default:
            break
        }
    }

    /// A track's playlist, in parts a console message carries. With the
    /// last part the page takes the helper.
    private func loadPart(_ message: [String: Any], from page: any OACPage, origin: String) {
        guard let generation = Self.whole(message["gen"], 1...Int(Int32.max)),
              let count = Self.whole(message["parts"], 1...Self.maxParts),
              let part = Self.whole(message["part"], 0...(count - 1)),
              let text = Self.text(message["playlist"], Self.maxPlaylistPart) else { return }
        guard Self.isOn else {
            // Switched off while the page was open.
            if part == 0 { deliver(["event": "failed", "gen": generation, "step": "player"], to: page) }
            return
        }
        if part == 0 {
            partsGeneration = generation
            partsPage = page
            parts = []
            certificate = Self.text(message["cert"], Self.maxCertificate) ?? ""
            if certificate.isEmpty {
                parts = nil
                return deliver(["event": "failed", "gen": generation, "step": "player"], to: page)
            }
        }
        guard page === partsPage, generation == partsGeneration, parts?.count == part, !certificate.isEmpty else { return }
        parts?.append(text)
        guard let all = parts, all.count == count else { return }
        let playlist = all.joined()
        let certificate = self.certificate
        parts = nil
        self.certificate = ""
        guard playlist.utf8.count <= Self.maxPlaylist, playlist.hasPrefix("#EXTM3U"),
              Self.isRemoteOnly(playlist, alsoFrom: Self.testOrigins.contains(origin) ? origin : nil) else {
            if page === owner {
                send(["op": "stop"])
                setPlaying(false)
                self.generation = generation
                load = 0
                failedGeneration = generation
            }
            return deliver(["event": "failed", "gen": generation, "step": "playback"], to: page)
        }
        if page !== owner {
            setPlaying(false)
            if let previous = owner { deliver(["event": "stolen", "gen": self.generation], to: previous) }
            failedGeneration = 0
        }
        owner = page
        self.generation = generation
        load = 0
        pageMuted = message["muted"] as? Bool ?? false
        guard ensureHelper() else { return failed("player", generation: generation) }
        loads += 1
        load = loads
        send([
            "op": "load",
            "gen": load,
            "cert": certificate,
            "playlist": playlist,
            "volume": min(max(Self.finite(message["volume"]) ?? 1, 0), 1),
            "muted": muted,
        ])
        setPlaying(false)
    }

    // MARK: From the app

    /// |page| closes or its tab goes to sleep.
    func pageGone(_ page: any OACPage) {
        pages.remove(page)
        if page === owner { stop() }
    }

    /// The tab's speaker was switched.
    func muteChanged(in page: any OACPage) {
        if page === owner { sendMuted() }
    }

    private var muted: Bool {
        pageMuted || owner.map { ($0.delegate as? FairPlayHost)?.fairPlayIsMuted($0) ?? false } ?? false
    }

    private func sendMuted() {
        send(["op": "muted", "muted": muted])
    }

    /// The setting (or the kill switch) went off: the track stops, and the
    /// open pages learn it.
    private func switchedOff() {
        if let owner { deliver(["event": "stolen", "gen": generation], to: owner) }
        stop()
        for case let page as any OACPage in pages.allObjects {
            deliver(["event": "config", "on": false, "trace": Self.traces], to: page)
        }
    }

    // MARK: The helper

    private func ensureHelper() -> Bool {
        if process?.isRunning == true { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.helperPath)
        var environment = ProcessInfo.processInfo.environment
        if AppPaths.isSelfTest {
            // No sound, and nothing under Now Playing.
            environment["OPENARCH_FAIRPLAY_SILENT"] = "1"
            environment["OPENARCH_FAIRPLAY_SYSTEM_CONTROLS"] = "0"
        }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let id = ObjectIdentifier(process)
        process.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { FairPlay.shared.helperExited(id) } }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { FairPlay.shared.received(data, from: id) } }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            log("FairPlay: the helper did not start: \(error.localizedDescription)")
            return false
        }
        // A helper that died must not take OpenArch with it (SIGPIPE).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = Data()
        return true
    }

    private func send(_ message: [String: Any]) {
        guard let input, let json = try? JSONSerialization.data(withJSONObject: message) else { return }
        let line = json + Data([0x0A])
        writes.async { try? input.write(contentsOf: line) }
    }

    private func received(_ data: Data, from id: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == id else { return }
        output.append(data)
        guard output.count <= Self.maxLine else { return stop() }
        while let newline = output.firstIndex(of: 0x0A) {
            let line = output.subdata(in: output.startIndex..<newline)
            output.removeSubrange(output.startIndex...newline)
            if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { helperEvent(event) }
            guard let current = self.process, ObjectIdentifier(current) == id else { return }
        }
    }

    private func helperEvent(_ event: [String: Any]) {
        // The page is gone, or went somewhere else in its tab.
        guard let owner, owner.isLoaded, Self.origin(of: owner.url).map(Self.serves) == true else { return stop() }
        let name = event["event"] as? String ?? ""
        let current = load != 0 && Self.whole(event["gen"], 1...Int(Int32.max)) == load
        if Self.traces, name != "position" {
            log("FairPlay: helper: \(name)\(current ? "" : " (not the current track)") \(event["step"] as? String ?? "")")
        }
        let generation = self.generation
        switch name {
        case "position" where current:
            setPlaying(event["playing"] as? Bool ?? false)
        case "failed" where current:
            setPlaying(false)
            return failed(event["step"] as? String ?? "playback", generation: generation)
        case "ended" where current:
            setPlaying(false)
        case "remote":
            break
        default:
            guard current else { return }
        }
        var relabeled = event
        if current { relabeled["gen"] = generation }
        deliver(relabeled, to: owner)
    }

    private func failed(_ step: String, generation: Int) {
        guard failedGeneration != generation else { return }
        failedGeneration = generation
        let known = ["license", "playback", "player"].contains(step) ? step : "playback"
        log("FairPlay: the track did not play (\(known))")
        if let owner { deliver(["event": "failed", "gen": generation, "step": known], to: owner) }
    }

    private func deliver(_ event: [String: Any], to page: any OACPage) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        page.executeJavaScript("document.dispatchEvent(new CustomEvent('openarch-fairplay', {detail: \(json)}))")
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if let owner { (owner.delegate as? FairPlayHost)?.fairPlay(owner, isPlaying: playing) }
    }

    private func helperExited(_ id: ObjectIdentifier) {
        guard let process, ObjectIdentifier(process) == id else { return }
        self.process = nil
        input = nil
        output = Data()
        if owner != nil, generation != 0 {
            setPlaying(false)
            failed("player", generation: generation)
        }
    }

    /// Ends the helper (it leaves when its input closes) and forgets the
    /// track.
    func stop() {
        let process = self.process
        if let input {
            writes.async { try? input.close() }
        }
        self.process = nil
        input = nil
        output = Data()
        parts = nil
        partsPage = nil
        certificate = ""
        if let process {
            after(2) { if process.isRunning { process.terminate() } }
        }
        setPlaying(false)
        owner = nil
        generation = 0
        load = 0
        failedGeneration = 0
    }

    // MARK: What a page may send

    static func serves(_ origin: String) -> Bool {
        origins.contains(origin) || testOrigins.contains(origin)
    }

    /// "https://open.spotify.com" for a page there.
    static func origin(of url: String) -> String? {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
    }

    /// Whether everything |playlist| loads is on https (or a key, skd://):
    /// the helper fetches it outside Chromium, so nothing local and nothing
    /// unencrypted. |origin| is the self-test's own.
    static func isRemoteOnly(_ playlist: String, alsoFrom origin: String? = nil) -> Bool {
        func allowed(_ address: String, key: Bool) -> Bool {
            let address = address.lowercased()
            if address.hasPrefix("https://") || (key && address.hasPrefix("skd://")) { return true }
            return origin.map { address.hasPrefix($0 + "/") } ?? false
        }
        let attribute = #/URI="([^"]*)"/#
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !line.hasPrefix("#") {
                if !allowed(line, key: false) { return false }
                continue
            }
            for match in line.matches(of: attribute) where !allowed(String(match.1), key: true) { return false }
        }
        return true
    }

    private static func whole(_ value: Any?, _ range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), double >= Double(range.lowerBound),
              double <= Double(range.upperBound) else { return nil }
        return Int(double)
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func text(_ value: Any?, _ limit: Int) -> String? {
        guard let text = value as? String, text.utf16.count <= limit else { return nil }
        return text
    }
}
