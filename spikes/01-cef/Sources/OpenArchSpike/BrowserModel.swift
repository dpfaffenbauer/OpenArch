import AppKit
import Observation
import OpenArchCore
import SwiftUI

@MainActor
@Observable
final class Tab: NSObject, Identifiable, OACBrowserViewDelegate {
    let id = UUID()
    let browserView: OACBrowserView
    private(set) var title: String
    private(set) var url: String
    private(set) var isLoading = false

    @ObservationIgnored weak var space: Space?
    @ObservationIgnored var onConsoleMessage: ((String) -> Void)?
    @ObservationIgnored var onFinishLoading: (() -> Void)?

    init(url: String, profile: OACProfile) {
        self.url = url
        self.title = url
        browserView = OACBrowserView(profile: profile, url: url)
        super.init()
        browserView.delegate = self
    }

    func browserView(_ view: OACBrowserView, titleDidChange title: String) {
        self.title = title
    }

    func browserView(_ view: OACBrowserView, addressDidChange url: String) {
        self.url = url
    }

    func browserView(
        _ view: OACBrowserView,
        loadingStateDidChange isLoading: Bool,
        canGoBack: Bool,
        canGoForward: Bool
    ) {
        self.isLoading = isLoading
    }

    func browserViewDidFinishLoading(_ view: OACBrowserView) {
        onFinishLoading?()
    }

    func browserView(_ view: OACBrowserView, consoleMessage message: String, source: String, line: Int) {
        onConsoleMessage?(message)
    }

    func browserView(_ view: OACBrowserView, wantsNewTabWithURL url: String) {
        guard let space else { return }
        space.model?.openTab(url: url, in: space)
    }

    func browserViewDidClose(_ view: OACBrowserView) {
        view.removeFromSuperview()
    }
}

@MainActor
@Observable
final class Space: Identifiable {
    let id = UUID()
    let name: String
    let color: Color
    let profile: OACProfile
    fileprivate(set) var tabs: [Tab] = []
    fileprivate(set) var selectedTabID: Tab.ID?

    @ObservationIgnored fileprivate(set) weak var model: BrowserModel?

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    init(name: String, color: Color, profile: OACProfile) {
        self.name = name
        self.color = color
        self.profile = profile
    }
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var spaces: [Space] = []
    private(set) var selectedSpaceID: Space.ID?
    /// Bumped to ask the sidebar to focus its address field (⌘T).
    private(set) var addressFocusRequest = 0

    @ObservationIgnored var onTabOpened: ((Tab) -> Void)?
    @ObservationIgnored var onActiveTabChange: ((Tab?) -> Void)?

    var selectedSpace: Space? {
        spaces.first { $0.id == selectedSpaceID }
    }

    var activeTab: Tab? {
        selectedSpace?.selectedTab
    }

    @discardableResult
    func addSpace(name: String, color: Color, profile: OACProfile) -> Space {
        let space = Space(name: name, color: color, profile: profile)
        space.model = self
        spaces.append(space)
        if selectedSpaceID == nil {
            selectedSpaceID = space.id
        }
        return space
    }

    @discardableResult
    func openTab(url: String, in space: Space? = nil) -> Tab? {
        guard let space = space ?? selectedSpace else { return nil }
        let tab = Tab(url: url, profile: space.profile)
        tab.space = space
        space.tabs.append(tab)
        space.selectedTabID = tab.id
        onTabOpened?(tab)
        if space.id == selectedSpaceID {
            onActiveTabChange?(activeTab)
        }
        return tab
    }

    func openInput(_ input: String) {
        openTab(url: Self.url(fromInput: input))
    }

    func select(_ space: Space) {
        selectedSpaceID = space.id
        onActiveTabChange?(activeTab)
    }

    func selectTab(id: Tab.ID?) {
        guard let id, let space = selectedSpace, space.tabs.contains(where: { $0.id == id }) else { return }
        space.selectedTabID = id
        onActiveTabChange?(activeTab)
    }

    func close(_ tab: Tab) {
        guard let space = tab.space, let index = space.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        space.tabs.remove(at: index)
        tab.browserView.close()
        if space.selectedTabID == tab.id {
            space.selectedTabID = space.tabs.isEmpty ? nil : space.tabs[min(index, space.tabs.count - 1)].id
        }
        onActiveTabChange?(activeTab)
    }

    func closeActiveTab() {
        if let activeTab {
            close(activeTab)
        }
    }

    func requestAddressFocus() {
        addressFocusRequest += 1
    }

    static func url(fromInput input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("://") {
            return trimmed
        }
        if trimmed.contains("."), !trimmed.contains(" ") {
            return "https://" + trimmed
        }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "https://www.google.com/search?q=" + query
    }
}
