import Foundation

enum AppPaths {
    /// Set once at startup, before anything reads a path.
    nonisolated(unsafe) static var isSelfTest = false

    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

    /// Unpacked extensions in a Resources subfolder: "BuiltinExtensions" are
    /// part of OpenArch, "Extensions" only serve the self-test.
    static func bundledExtensions(_ folder: String) -> [String] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent(folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        return names.sorted().map { root.appendingPathComponent($0).path }
    }
}

func log(_ message: String) {
    print("[OpenArch] \(message)")
}

@MainActor
func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
}
