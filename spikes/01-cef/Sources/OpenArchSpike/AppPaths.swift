import Foundation

enum AppPaths {
    static func dataDirectory(selfTest: Bool) -> URL {
        let fileManager = FileManager.default
        var directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenArch Spike", isDirectory: true)
        if selfTest {
            // Self-tests start from a clean slate every run.
            directory.appendPathComponent("SelfTest", isDirectory: true)
            try? fileManager.removeItem(at: directory)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Unpacked extensions shipped in Contents/Resources/Extensions.
    static func bundledExtensions() -> [URL] {
        let fileManager = FileManager.default
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Extensions"),
              let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.filter {
            fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }
    }
}

func log(_ message: String) {
    print("[OpenArch] \(message)")
}

@MainActor
func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        work()
    }
}
