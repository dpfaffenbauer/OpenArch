import Foundation

enum AppPaths {
    /// Set once at startup, before anything reads a path.
    nonisolated(unsafe) static var isSelfTest = false

    /// Whether showing a tab activates OpenArch, as in everyday use. The
    /// self-test keeps it in the background, except the memory bench, which
    /// has to show and hide tabs the way everyday use does.
    static var panesActivate: Bool {
        !isSelfTest || CommandLine.arguments.contains("--memory-bench")
    }

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The Chromium engine (docs/chromium-engine.md) keeps its own data
        // while it is tried next to OpenArch on CEF: Chrome would move a
        // profile to its newer format, which CEF's older Chromium can't read.
        let engine = Bundle.main.bundleIdentifier?.hasSuffix(".engine") == true
        let name = isSelfTest ? "OpenArch SelfTest" : (engine ? "OpenArch Engine" : "OpenArch")
        let url = base.appendingPathComponent(name, isDirectory: true)
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
