import AppKit
import OpenArchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let selfTest: Bool
    private let model = BrowserModel()
    private var windowController: MainWindowController?
    private var selfTestRunner: SelfTest?

    init(selfTest: Bool) {
        self.selfTest = selfTest
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController(model: model)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate()

        if selfTest {
            let runner = SelfTest(model: model)
            selfTestRunner = runner
            runner.start()
        } else {
            openDefaultSpaces()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func openDefaultSpaces() {
        let personal = model.addSpace(name: "Persönlich", color: .purple, profile: OACProfile(identifier: "personal"))
        let work = model.addSpace(name: "Arbeit", color: .blue, profile: OACProfile(identifier: "work"))
        let chromium = model.addSpace(name: "Chromium-Default", color: .gray, profile: .default)
        model.openTab(url: "https://example.com/", in: personal)
        model.openTab(url: "https://www.wikipedia.org/", in: work)
        model.openTab(url: "https://example.com/", in: chromium)
        model.select(personal)
    }

    // MARK: - Menu

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "OpenArch Spike beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "Ablage")
        fileMenu.addItem(item("Neuer Tab", #selector(newTab), "t"))
        fileMenu.addItem(item("Tab schließen", #selector(closeTab), "w"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Chrome-Style-Fenster öffnen", #selector(openChromeStyleWindow), "n", [.command, .shift]))
        addSubmenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "Darstellung")
        viewMenu.addItem(item("Neu laden", #selector(reload), "r"))
        viewMenu.addItem(item("Zurück", #selector(goBack), "["))
        viewMenu.addItem(item("Vorwärts", #selector(goForward), "]"))
        viewMenu.addItem(item("Entwicklertools", #selector(showDevTools), "i", [.command, .option]))
        addSubmenu(viewMenu, to: mainMenu)

        return mainMenu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem()
        item.submenu = submenu
        menu.addItem(item)
    }

    private func item(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func newTab() {
        model.requestAddressFocus()
    }

    @objc private func closeTab() {
        model.closeActiveTab()
    }

    @objc private func reload() {
        model.activeTab?.browserView.reload()
    }

    @objc private func goBack() {
        model.activeTab?.browserView.goBack()
    }

    @objc private func goForward() {
        model.activeTab?.browserView.goForward()
    }

    @objc private func showDevTools() {
        model.activeTab?.browserView.showDevTools()
    }

    @objc private func openChromeStyleWindow() {
        OACBrowserView.openChromeStyleWindow(withURL: "chrome://extensions", profile: .default)
    }
}
