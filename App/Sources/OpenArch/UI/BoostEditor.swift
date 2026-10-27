import AppKit
import Observation
import SwiftUI

/// The Boost editor: a small panel next to the page that changes the site
/// live.
@MainActor
final class BoostPanelController: NSObject, NSWindowDelegate {
    private(set) static var current: BoostPanelController?

    let model: BoostEditorModel
    private let panel: NSPanel

    private init(model: BoostEditorModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 620),
                        styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: BoostEditorView(model: model))
    }

    /// Opens the editor for the site of |item|.
    @discardableResult
    static func show(for item: Item, browser: BrowserWindowController) -> BoostPanelController? {
        guard let boost = BoostStore.shared.boostForEditing(item.currentURL) else {
            NSSound.beep()
            return nil
        }
        current?.close()
        let controller = BoostPanelController(model: BoostEditorModel(boost: boost, item: item, browser: browser))
        current = controller
        controller.panel.title = "Boost · \(boost.host)"
        if let window = browser.window {
            let content = window.convertToScreen(browser.contentRect)
            controller.panel.setFrameTopLeftPoint(NSPoint(x: content.maxX - 360, y: content.maxY - 20))
        }
        if AppPaths.isSelfTest {
            controller.panel.orderBack(nil)
        } else {
            controller.panel.makeKeyAndOrderFront(nil)
        }
        return controller
    }

    func close() {
        model.stopZap()
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopZap()
        if Self.current === self { Self.current = nil }
    }
}

@MainActor @Observable
final class BoostEditorModel {
    var boost: Boost {
        didSet { if boost != oldValue { BoostStore.shared.update(boost) } }
    }
    var isZapping = false
    @ObservationIgnored let item: Item
    @ObservationIgnored unowned let browser: BrowserWindowController

    init(boost: Boost, item: Item, browser: BrowserWindowController) {
        self.boost = boost
        self.item = item
        self.browser = browser
    }

    func startZap() {
        isZapping = true
        browser.select(item)
        item.pane?.executeJavaScript(BoostStore.zapScript)
        item.pane?.focus()
    }

    func stopZap() {
        guard isZapping else { return }
        isZapping = false
        item.pane?.executeJavaScript(BoostStore.stopZapScript)
    }

    /// A zapped element, reported by the page.
    func zapped(_ selector: String) {
        guard !boost.zapped.contains(selector) else { return }
        boost.zapped.append(selector)
    }

    func delete() {
        stopZap()
        BoostStore.shared.delete(boost)
        BoostPanelController.current?.close()
    }
}

struct BoostEditorView: View {
    @Bindable var model: BoostEditorModel

    static let fonts = ["", "Helvetica Neue", "Avenir Next", "Futura", "Georgia", "Iowan Old Style", "Charter", "Menlo", "Comic Sans MS"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    FaviconView(item: model.item, size: 20)
                    Text(model.boost.host).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Toggle("", isOn: $model.boost.isEnabled).labelsHidden().toggleStyle(.switch)
                        .help(model.boost.isEnabled ? "Boost ausschalten" : "Boost einschalten")
                }

                group("Farbe") {
                    HStack {
                        Slider(value: $model.boost.hue, in: -180...180, step: 5)
                        Button("Aus") { model.boost.hue = 0 }.disabled(model.boost.hue == 0)
                    }
                    LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color(hue: $0, saturation: 0.7, brightness: 0.9) },
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 6).clipShape(Capsule()).opacity(0.8)
                }

                group("Schrift") {
                    Picker("", selection: $model.boost.font) {
                        ForEach(Self.fonts, id: \.self) { font in
                            Text(font.isEmpty ? "Wie die Seite" : font).tag(font)
                        }
                    }
                    .labelsHidden()
                }

                group("Elemente ausblenden") {
                    Button(model.isZapping ? "Fertig" : "Zap: Elemente anklicken …") {
                        model.isZapping ? model.stopZap() : model.startZap()
                    }
                    if model.isZapping {
                        Text("Klicke auf der Seite auf alles, was verschwinden soll. Esc beendet.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(model.boost.zapped, id: \.self) { selector in
                        HStack {
                            Text(selector).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Button {
                                model.boost.zapped.removeAll { $0 == selector }
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Wieder einblenden")
                        }
                    }
                }

                group("CSS") {
                    code($model.boost.css)
                }
                group("JavaScript", note: "Läuft einmal pro Seitenaufruf; Änderungen wirken nach dem Neuladen.") {
                    code($model.boost.javaScript)
                }

                Button("Boost löschen", role: .destructive) { model.delete() }
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 18)
        }
        .frame(width: 340, height: 620)
    }

    private func group<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func code(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }
}
