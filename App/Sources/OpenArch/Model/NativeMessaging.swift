import Foundation

/// Native messaging lets extensions talk to desktop apps (1Password,
/// Google Drive, Apple Passwords). Chromium looks for the host manifests in
/// <user data>/NativeMessagingHosts, so OpenArch copies the ones that Arc and
/// Chrome already have.
enum NativeMessaging {
    static func importHosts(into chromiumData: URL) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let sources = [
            home.appendingPathComponent("Library/Application Support/Arc/User Data/NativeMessagingHosts"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
        ]
        let target = chromiumData.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for source in sources {
            for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] where name.hasSuffix(".json") {
                let destination = target.appendingPathComponent(name)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try? fm.copyItem(at: source.appendingPathComponent(name), to: destination)
            }
        }
    }
}
