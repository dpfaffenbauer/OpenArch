import Foundation

/// The Chrome Web Store extensions installed in Arc, so they can be
/// installed again in OpenArch with one click each.
enum ArcExtensions {
    struct Extension: Hashable {
        var id: String
        var name: String
        var storeURL: String { "https://chromewebstore.google.com/detail/\(id)" }
    }

    static func installed() -> [Extension] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/User Data")
        let fm = FileManager.default
        let profiles = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        var result: [String: Extension] = [:]
        for profile in profiles {
            let extensionsDir = root.appendingPathComponent(profile).appendingPathComponent("Extensions")
            for id in (try? fm.contentsOfDirectory(atPath: extensionsDir.path)) ?? [] where isExtensionID(id) {
                let versions = ((try? fm.contentsOfDirectory(atPath: extensionsDir.appendingPathComponent(id).path)) ?? []).sorted()
                guard let version = versions.last else { continue }
                let dir = extensionsDir.appendingPathComponent(id).appendingPathComponent(version)
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      // Only extensions that come from the Web Store.
                      (manifest["update_url"] as? String)?.contains("google.com") == true
                else { continue }
                result[id] = Extension(id: id, name: localizedName(manifest, dir: dir) ?? id)
            }
        }
        return result.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func isExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }

    private static func localizedName(_ manifest: [String: Any], dir: URL) -> String? {
        guard let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__") else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        let locale = manifest["default_locale"] as? String ?? "en"
        for candidate in ["de", locale, "en"] {
            let file = dir.appendingPathComponent("_locales/\(candidate)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (messageKey, value) in messages where messageKey.lowercased() == key {
                if let message = (value as? [String: Any])?["message"] as? String { return message }
            }
        }
        return nil
    }
}
