import AppKit
import OpenArchCore
import SwiftUI

/// Arc-style window: sidebar on the left, the active tab's browser on the
/// right. Every tab keeps its browser alive; inactive ones are just hidden.
@MainActor
final class MainWindowController: NSWindowController {
    private let model: BrowserModel
    private let browserContainer = NSView()

    init(model: BrowserModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OpenArch Spike"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let sidebar = NSHostingController(rootView: SidebarView(model: model))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360

        let content = NSViewController()
        content.view = makeContentView()

        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()

        model.onTabOpened = { [weak self] tab in self?.host(tab) }
        model.onActiveTabChange = { [weak self] tab in self?.show(tab) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeContentView() -> NSView {
        let view = NSView()
        browserContainer.wantsLayer = true
        browserContainer.layer?.cornerRadius = 10
        browserContainer.layer?.masksToBounds = true
        browserContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browserContainer)
        NSLayoutConstraint.activate([
            browserContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browserContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            browserContainer.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            browserContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        return view
    }

    private func host(_ tab: Tab) {
        let view = tab.browserView
        view.frame = browserContainer.bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = tab !== model.activeTab
        browserContainer.addSubview(view)
    }

    private func show(_ activeTab: Tab?) {
        for case let view as OACBrowserView in browserContainer.subviews {
            view.isHidden = view !== activeTab?.browserView
        }
        if let webContent = activeTab?.browserView.subviews.first {
            window?.makeFirstResponder(webContent)
        }
    }
}
