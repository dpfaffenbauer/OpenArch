import AppKit
import OpenArchLocalization

/// Links to addresses another app opens (bambustudioopen:, zoommtg:,
/// mailto: ...): OpenArch asks before it opens the app, like Chrome, and can
/// remember the answer for the site.
@MainActor
enum ExternalApps {
    /// The app that opens |url|, if the Mac has one.
    static func app(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    static func open(_ url: String, from site: String, in window: NSWindow?, library: Library,
                     toast: (String) -> Void) {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased() else { return }
        guard let app = app(for: target) else {
            toast(L("Keine App für %@: gefunden", scheme))
            return
        }
        let host = URL(string: site)?.host() ?? ""
        let key = "\(host) \(scheme)"
        if !host.isEmpty, library.settings.allowedExternalApps.contains(key) {
            NSWorkspace.shared.open(target)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = L("„%@“ öffnen?", name)
        alert.informativeText = host.isEmpty ? L("Ein Link möchte diese App öffnen.") : L("%@ möchte diese App öffnen.", host)
        alert.icon = NSWorkspace.shared.icon(forFile: app.path)
        alert.addButton(withTitle: L("Öffnen"))
        alert.addButton(withTitle: L("Abbrechen"))
        if !host.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("Links von %@ immer in „%@“ öffnen", host, name)
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on, !library.settings.allowedExternalApps.contains(key) {
                library.settings.allowedExternalApps.append(key)
                library.setNeedsSave()
            }
            NSWorkspace.shared.open(target)
        }
        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
    }
}
