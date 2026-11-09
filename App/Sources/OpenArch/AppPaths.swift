import Foundation

enum AppPaths {
    /// Set once at startup, before anything reads a path.
    nonisolated(unsafe) static var isSelfTest = false

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // OPENARCH_DATA_DIR: a data folder of its own, so a test build runs
        // next to the OpenArch in use without touching its data.
        if !isSelfTest, let custom = ProcessInfo.processInfo.environment["OPENARCH_DATA_DIR"], !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = base.appendingPathComponent(isSelfTest ? "OpenArch SelfTest" : "OpenArch", isDirectory: true)
        // A fresh folder per test run; --keep-data starts a second instance on
        // the running test's data (the second-launch test).
        if isSelfTest && !CommandLine.arguments.contains("--keep-data") {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Chromium's user data directory; profiles live directly below it.
    static var chromiumData: URL {
        let url = support.appendingPathComponent("Chromium", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A directory for a new profile: "Profile N" that none of |used| has
    /// and Chromium keeps no data under, so a new profile never starts out
    /// with the logins of one that was there before.
    static func unusedProfileDirectory(besides used: Set<String>) -> String {
        var index = 2
        while used.contains("Profile \(index)")
            || FileManager.default.fileExists(atPath: chromiumData.appendingPathComponent("Profile \(index)").path) {
            index += 1
        }
        return "Profile \(index)"
    }

    /// Unpacked extensions in a Resources subfolder: "BuiltinExtensions" are
    /// part of OpenArch, "Extensions" only serve the self-test. Chromium
    /// writes into an unpacked extension's folder (_metadata for its rules),
    /// which would break the app's signature, so they load from a copy in
    /// Application Support, made again whenever the app's copy changes.
    static func bundledExtensions(_ folder: String) -> [String] {
        let files = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(folder),
              let names = try? files.contentsOfDirectory(atPath: source.path).filter({ !$0.hasPrefix(".") })
        else { return [] }
        let target = support.appendingPathComponent(folder, isDirectory: true)
        let stampFile = target.appendingPathComponent(".source")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let stamp = "\(build) \(newestModification(in: source))"
        if (try? String(contentsOf: stampFile, encoding: .utf8)) != stamp {
            do {
                try? files.removeItem(at: target)
                try files.copyItem(at: source, to: target)
                try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
            } catch {
                log("could not copy \(folder): \(error)")
                return names.sorted().map { source.appendingPathComponent($0).path }
            }
        }
        return names.sorted().map { target.appendingPathComponent($0).path }
    }

    private static func newestModification(in folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        var newest = 0.0
        while let file = files?.nextObject() as? URL {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            newest = max(newest, date?.timeIntervalSince1970 ?? 0)
        }
        return Int(newest)
    }
}

func log(_ message: String) {
    print("[OpenArch] \(message)")
}

@MainActor
func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
}
