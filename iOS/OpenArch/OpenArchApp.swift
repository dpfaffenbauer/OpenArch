import OpenArchShared
import SwiftUI

@main
struct OpenArchApp: App {
    // The self-test starts from a fresh library per run, as on the Mac.
    @State private var browser = Browser(library: Demo.prepared(Library.load(fresh: SelfTest.isRequested || Demo.isRequested)))
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(browser: browser)
                .onOpenURL { browser.open(externalURL: $0) }
                // Followed shares are checked every five minutes while open.
                .task {
                    if SelfTest.isRequested {
                        await SelfTest(browser: browser).run()
                        return
                    }
                    #if DEBUG
                    if Demo.isRequested {
                        await DemoDirector(browser: browser).run()
                        return
                    }
                    #endif
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
