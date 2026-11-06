import AppKit
import CoreServices
import Observation
import OpenArchCore

/// Spotify playing on the Mac (the app, not a tab), for the player at the
/// bottom of the sidebar. Spotify tells every app what it plays whenever
/// that changes (a distributed notification), so showing it needs no
/// permission. Its buttons are Apple Events, which macOS asks about the
/// first time one is pressed.
@MainActor @Observable
final class SpotifyPlayer {
    static let shared = SpotifyPlayer()
    nonisolated static let bundleID = "com.spotify.client"

    /// What Spotify plays, nil while it plays nothing or is not open.
    private(set) var media: MediaState?
    /// The player was closed; it comes back when Spotify plays again.
    private(set) var dismissed = false

    @ObservationIgnored private var started = false
    @ObservationIgnored private var last: SpotifyState?
    /// Covers by track (Spotify's own oEmbed); "" while asked or without one.
    @ObservationIgnored private var covers: [String: String] = [:]
    @ObservationIgnored private var appIcon: NSImage?

    /// Spotify's own icon, for a track without a cover.
    var icon: NSImage? {
        if appIcon == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        return appIcon
    }

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { notification in
            let state = SpotifyState(notification.userInfo)
            MainActor.assumeIsolated { SpotifyPlayer.shared.update(state) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSRunningApplication
            guard app?.bundleIdentifier == SpotifyPlayer.bundleID else { return }
            MainActor.assumeIsolated { SpotifyPlayer.shared.update(nil) }
        }
        readIfAllowed()
    }

    func update(_ state: SpotifyState?) {
        guard let state, !state.stopped else {
            last = nil
            media = nil
            return
        }
        if state.playing, media?.playing != true { dismissed = false }
        last = state
        var media = MediaState()
        media.playing = state.playing
        media.audible = true
        media.title = state.title
        media.artist = state.artist
        media.album = state.album
        media.time = state.position
        media.duration = state.duration
        media.previous = true
        media.next = true
        if covers[state.trackID] == nil { fetchCover(state.trackID) }
        media.artwork = covers[state.trackID] ?? ""
        self.media = media
    }

    // MARK: Buttons

    /// "toggle", "previous" or "next", like a tab's player.
    func command(_ command: String) {
        switch command {
        case "toggle": run("playpause")
        case "previous": run("previous track")
        case "next": run("next track")
        default: break
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, var media else { return }
        // At once: Spotify may not say anything about a jump.
        media.time = max(0, seconds)
        media.reportedAt = Date()
        self.media = media
        run("set player position to " + String(format: "%.2f", max(0, seconds)))
    }

    /// Closes the player: Spotify pauses, and the player stays away until it
    /// plays again.
    func dismiss() {
        if media?.playing == true { command("toggle") }
        dismissed = true
    }

    /// Brings Spotify to the front.
    func show() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// A statement for Spotify's AppleScript. It runs in osascript, so that
    /// the first time, while macOS asks whether OpenArch may control
    /// Spotify, OpenArch does not stand still. Refused, the player goes back
    /// to what Spotify last said.
    private func run(_ statement: String) {
        Self.osascript("tell application id \"\(Self.bundleID)\" to \(statement)") { output in
            guard output == nil else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let player = SpotifyPlayer.shared
                    if player.last != nil { player.update(player.last) }
                }
            }
        }
    }

    private nonisolated static func osascript(_ script: String, completion: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                completion(nil)
                return
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            completion(process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
        }
    }

    // MARK: Reading

    /// Spotify only says something when it changes. If it already plays when
    /// OpenArch starts and OpenArch may control it, ask it once; without
    /// that permission the player waits for the next change instead of
    /// making macOS ask out of nowhere.
    private func readIfAllowed() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty,
              Self.mayControl() else { return }
        let script = """
            tell application id "\(Self.bundleID)"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed ¬
                    & (album of t) & linefeed & (id of t) & linefeed & ((duration of t) as integer) & linefeed ¬
                    & ((player position * 1000) as integer)
            end tell
            """
        Self.osascript(script) { output in
            let state = output.flatMap(SpotifyState.init(appleScript:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let player = SpotifyPlayer.shared
                    if player.media == nil, let state { player.update(state) }
                }
            }
        }
    }

    /// Whether macOS already lets OpenArch control Spotify (never asks).
    private nonisolated static func mayControl() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return false }
            return AEDeterminePermissionToAutomateTarget(address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == 0
        }
    }

    /// The cover from Spotify's oEmbed (no login): spotify:track:… and
    /// spotify:episode:… have one, local files and ads do not.
    private func fetchCover(_ trackID: String) {
        let parts = trackID.split(separator: ":").map(String.init)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" || parts[1] == "episode",
              let page = "https://open.spotify.com/\(parts[1])/\(parts[2])".addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://open.spotify.com/oembed?url=\(page)")
        else { return }
        if covers.count > 500 { covers.removeAll() }
        covers[trackID] = ""
        Task {
            let (data, status) = await ChromiumFetch.get(url)
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cover = json["thumbnail_url"] as? String, cover.hasPrefix("https://")
            else { return }
            covers[trackID] = cover
            if last?.trackID == trackID { media?.artwork = cover }
        }
    }
}

/// One of Spotify's notifications (or its AppleScript answer), as plain
/// values.
struct SpotifyState: Sendable, Equatable {
    var playing = false
    var stopped = true
    var title = ""
    var artist = ""
    var album = ""
    var trackID = ""
    /// Seconds.
    var position = 0.0
    var duration = 0.0

    init(_ info: [AnyHashable: Any]?) {
        let info = info ?? [:]
        func string(_ key: String) -> String { info[key] as? String ?? "" }
        func number(_ key: String) -> Double { (info[key] as? NSNumber)?.doubleValue ?? 0 }
        let state = string("Player State")
        playing = state == "Playing"
        stopped = state != "Playing" && state != "Paused"
        title = string("Name")
        artist = string("Artist")
        album = string("Album")
        trackID = string("Track ID")
        position = number("Playback Position")
        // Spotify gives the length in milliseconds.
        duration = number("Duration") / 1000
    }

    /// The lines readIfAllowed asks for: state, name, artist, album, id,
    /// length and position (both in milliseconds).
    init?(appleScript output: String) {
        let lines = output.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        guard lines.count == 7 else { return nil }
        playing = lines[0] == "playing"
        stopped = lines[0] != "playing" && lines[0] != "paused"
        title = lines[1]
        artist = lines[2]
        album = lines[3]
        trackID = lines[4]
        duration = (Double(lines[5]) ?? 0) / 1000
        position = (Double(lines[6]) ?? 0) / 1000
    }
}

/// What the player at the bottom of the sidebar shows.
enum NowPlaying {
    /// Audio or video in a tab that is not on screen.
    case tab(Item)
    /// Spotify on the Mac.
    case spotify(MediaState)
}
