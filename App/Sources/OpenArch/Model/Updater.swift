import AppKit
import CryptoKit
import Observation

/// Updates from the "nightly" release on GitHub. CI publishes latest.json
/// next to OpenArch.zip; OpenArch compares its build number, downloads the
/// newer build, checks its SHA-256, unpacks it next to the cache and swaps
/// the app when it quits or restarts. Downloads go through curl (URLSession
/// fails inside Chromium's process), which also leaves no quarantine flag.
@MainActor @Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(Double)
        case ready(Int)
        case failed(String)
    }

    struct Manifest: Decodable {
        let build: Int
        let commit: String
        let sha256: String
        let size: Int?
        let url: String
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let shared = Updater()
    static let releaseManifest = "https://github.com/dpfaffenbauer/OpenArch/releases/download/nightly/latest.json"

    private(set) var phase = Phase.idle
    private(set) var lastCheck: Date?
    var isEnabled = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "autoUpdate")
            schedule()
        }
    }
    /// Where latest.json comes from; the self-test points it at a local file.
    var manifestURL = releaseManifest
    let currentBuild: Int
    let currentCommit: String

    private var stagedApp: URL?
    private var timer: Timer?
    private var installing = false

    init(bundle: Bundle = .main) {
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        currentCommit = bundle.object(forInfoDictionaryKey: "OpenArchCommit") as? String ?? ""
    }

    /// Builds made with App/build.sh outside CI have build number 0 and do
    /// not update themselves.
    var isDevelopmentBuild: Bool { currentBuild == 0 }

    var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        if isDevelopmentBuild { return "\(version) (eigener Build)" }
        return "\(version) (Nightly \(currentBuild)\(currentCommit.isEmpty ? "" : ", \(currentCommit)"))"
    }

    /// Checks shortly after launch and then every six hours.
    func start() {
        schedule()
        guard isEnabled, !isDevelopmentBuild else { return }
        after(20) { [weak self] in self?.check(automatic: true) }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, !isDevelopmentBuild else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(automatic: true) }
        }
    }

    /// Automatic checks stay quiet when they fail (offline, GitHub down).
    func check(automatic: Bool = false) {
        switch phase {
        case .checking, .downloading, .ready: return
        default: break
        }
        if isDevelopmentBuild && manifestURL == Self.releaseManifest {
            phase = .failed("Selbst gebaute Versionen aktualisieren sich nicht; Updates gibt es für die Nightly-Builds.")
            return
        }
        phase = .checking
        Task {
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: try await Self.fetch(manifestURL))
                lastCheck = Date()
                guard manifest.build > currentBuild else {
                    phase = .upToDate
                    return
                }
                try await download(manifest)
            } catch {
                phase = automatic ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ manifest: Manifest) async throws {
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("Keine Schreibrechte für \(target.deletingLastPathComponent().path).")
        }
        let folder = Self.cacheFolder
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("OpenArch.zip")

        phase = .downloading(0)
        let progress = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let size = manifest.size, size > 0,
                      let done = try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
                self.phase = .downloading(min(1, Double(done) / Double(size)))
            }
        }
        defer { progress.invalidate() }
        try await Self.run("/usr/bin/curl", ["-fsSL", "--max-time", "1800", "-o", zip.path, manifest.url])

        guard try Self.sha256(of: zip) == manifest.sha256.lowercased() else {
            throw UpdateError("Die heruntergeladene Datei stimmt nicht mit der Prüfsumme überein.")
        }
        let unpacked = folder.appendingPathComponent("unpacked")
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent(target.lastPathComponent)
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") == manifest.build else {
            throw UpdateError("Das Update enthält keine passende OpenArch-App.")
        }
        try? FileManager.default.removeItem(at: zip)
        stagedApp = app
        phase = .ready(manifest.build)
    }

    /// "Neu starten": swaps the app once OpenArch has quit, then opens it.
    func installAndRelaunch() {
        install(relaunch: true)
        NSApp.terminate(nil)
    }

    /// On quit, a downloaded update is put in place for the next launch.
    func installOnQuit() {
        install(relaunch: false)
    }

    private func install(relaunch: Bool) {
        guard case .ready = phase, let staged = stagedApp, !installing else { return }
        installing = true
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            old="$3.old-update"
            rm -rf "$old"
            if mv "$3" "$old" && mv "$2" "$3"; then
              rm -rf "$old"
              xattr -dr com.apple.quarantine "$3" 2>/dev/null
              /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3"
            elif [ -d "$old" ] && [ ! -d "$3" ]; then
              mv "$old" "$3"
            fi
            [ "$4" = 1 ] && /usr/bin/open "$3"
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)",
                          staged.path, Bundle.main.bundleURL.path, relaunch ? "1" : "0"]
        try? task.run()
    }

    // MARK: Helpers

    static var cacheFolder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(AppPaths.isSelfTest ? "OpenArch SelfTest Update" : "OpenArch Update")
    }

    private static func fetch(_ url: String) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-latest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try await run("/usr/bin/curl", ["-fsSL", "--max-time", "30", "-o", file.path, url])
        return try Data(contentsOf: file)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw UpdateError(tool.hasSuffix("curl") ? "Download fehlgeschlagen (curl \(status))." : "Entpacken fehlgeschlagen.")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
