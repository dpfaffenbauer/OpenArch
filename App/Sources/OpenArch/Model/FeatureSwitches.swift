import Foundation
import OpenArchLocalization
import os

/// Features that can be switched off without an update, so one that a new
/// Chromium broke does not hold back an update with everything else in it.
/// Two places switch them off:
///
/// - the hidden default `disabledFeatures`, for one Mac:
///   `defaults write dev.openarch.browser disabledFeatures -array peek boosts`
/// - feature-switches.json on openarch.app, for everyone, fetched at launch
///   and every six hours. Only from that address, over https, with no
///   redirect; anything that goes wrong (offline, no file, a file that does
///   not parse) leaves every feature on.
///
/// The file:
///
///     {"disabled": [{"feature": "peek", "minBuild": 500, "maxBuild": 512,
///                    "chromium": "156.0.15", "reason": "…"}]}
///
/// Every key but "feature" is optional: a build range, and the start of the
/// Chromium version (OACEngine.versionString) it applies to.
enum Feature: String, CaseIterable, Identifiable, Sendable {
    case peek, tabPreviews, agentChats, boosts, drmWebKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .peek: "Peek"
        case .tabPreviews: L("Vorschau beim Überfahren")
        case .agentChats: L("Agent-Chats")
        case .boosts: "Boosts"
        case .drmWebKit: L("Geschützte Videos über WebKit")
        }
    }
}

final class FeatureSwitches: Sendable {
    static let shared = FeatureSwitches()
    static let remoteURL = "https://openarch.app/feature-switches.json"
    static let defaultsKey = "disabledFeatures"

    private struct State {
        /// nil: from UserDefaults; the self-test sets its own.
        var local: Set<Feature>?
        var remote: [Feature: String] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Whether |feature| may run. Any thread.
    func isOn(_ feature: Feature) -> Bool {
        !disabled.keys.contains(feature)
    }

    /// The features switched off, with why.
    var disabled: [Feature: String] {
        let (local, remote) = state.withLock { ($0.local, $0.remote) }
        var result = remote
        for feature in local ?? Self.localDefaults() {
            result[feature] = L("auf diesem Mac abgeschaltet")
        }
        return result
    }

    private static func localDefaults() -> Set<Feature> {
        Set((UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []).compactMap(Feature.init(rawValue:)))
    }

    /// The self-test's switches, in place of the hidden default (nil: back
    /// to it).
    func setLocalForTesting(_ features: Set<Feature>?) {
        state.withLock { $0.local = features }
        notify()
    }

    func setRemote(_ disabled: [Feature: String]) {
        let changed = state.withLock { state -> Bool in
            defer { state.remote = disabled }
            return state.remote != disabled
        }
        if changed { notify() }
    }

    static let didChange = Notification.Name("OpenArchFeatureSwitchesDidChange")

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }

    // MARK: The remote list

    private struct RemoteFile: Decodable {
        struct Entry: Decodable {
            let feature: String
            let minBuild: Int?
            let maxBuild: Int?
            let chromium: String?
            let reason: String?
        }
        let disabled: [Entry]
    }

    /// The features |data| switches off for this build and Chromium. Data
    /// that does not parse switches nothing off.
    static func parse(_ data: Data, build: Int, chromium: String) -> [Feature: String] {
        guard let file = try? JSONDecoder().decode(RemoteFile.self, from: data) else { return [:] }
        var result: [Feature: String] = [:]
        for entry in file.disabled {
            guard let feature = Feature(rawValue: entry.feature),
                  build >= entry.minBuild ?? Int.min, build <= entry.maxBuild ?? Int.max,
                  entry.chromium.map({ chromium.hasPrefix($0) }) ?? true else { continue }
            result[feature] = entry.reason ?? L("vorübergehend abgeschaltet")
        }
        return result
    }

    /// Fetches the remote list; on any failure every feature is on again.
    func refresh(build: Int, chromium: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-switches-\(UUID().uuidString).json")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // No -L: the answer must come from openarch.app itself.
        task.arguments = ["-fsS", "--proto", "=https", "--max-time", "20", "--max-filesize", "65536",
                          "-o", file.path, Self.remoteURL]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] process in
            defer { try? FileManager.default.removeItem(at: file) }
            let data = process.terminationStatus == 0 ? (try? Data(contentsOf: file)) : nil
            self?.setRemote(data.map { Self.parse($0, build: build, chromium: chromium) } ?? [:])
        }
        do {
            try task.run()
        } catch {
            setRemote([:])
        }
    }
}
