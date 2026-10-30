import OpenArchShared
import SwiftUI

@main
struct OpenArchApp: App {
    @State private var browser = Browser(library: Library.load())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(browser: browser)
                .onOpenURL { browser.open(externalURL: $0) }
                // Followed shares are checked every five minutes while open.
                .task {
                    while !Task.isCancelled {
                        await browser.sharing.refresh()
                        try? await Task.sleep(for: .seconds(300))
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                browser.archiveStaleTabs()
                Task { await browser.sharing.refresh() }
            case .background:
                browser.library.save()
            default:
                break
            }
        }
    }
}
