import AppKit
import SwiftUI

/// A menu command's keyboard shortcut, stored like macOS's own App
/// Shortcuts: modifier marks (^ ⌃, ~ ⌥, $ ⇧, @ ⌘) and then the key.
struct KeyShortcut: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        // An uppercase key means ⇧ in a menu; keep it lowercase with ⇧.
        var modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if key != key.lowercased() { modifiers.insert(.shift) }
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    init?(string: String) {
        guard let key = string.last else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for mark in string.dropLast() {
            switch mark {
            case "^": modifiers.insert(.control)
            case "~": modifiers.insert(.option)
            case "$": modifiers.insert(.shift)
            case "@": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(key: String(key), modifiers: modifiers)
    }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        self.init(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    /// A key pressed while recording: needs ⌘ or ⌃, like every OpenArch shortcut.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !modifiers.intersection([.command, .control]).isEmpty,
              let key = event.characters(byApplyingModifiers: [])?.first, !key.isWhitespace || key == " " || key == "\t"
        else { return nil }
        self.init(key: String(key), modifiers: modifiers)
    }

    var string: String {
        var marks = ""
        if modifiers.contains(.control) { marks += "^" }
        if modifiers.contains(.option) { marks += "~" }
        if modifiers.contains(.shift) { marks += "$" }
        if modifiers.contains(.command) { marks += "@" }
        return marks + key
    }

    /// As menus show it: ⌃⌥⇧⌘ and the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let names: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
                                        "\t": "⇥", " ": "Leertaste", "\r": "↩", "\u{1B}": "⎋",
                                        "\u{7F}": "⌫", "\u{F728}": "⌦"]
        return text + (names[key] ?? key.uppercased())
    }

    func apply(to item: NSMenuItem) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
    }
}

/// A menu command whose shortcut can be changed in Settings › Tastatur.
struct MenuCommand: Identifiable, Equatable {
    /// The action's selector and the item's tag: stable across versions.
    let id: String
    let menu: String
    let title: String
    let defaultShortcut: KeyShortcut?
}

extension MainMenu {
    /// The commands of the menu as last built, with their own shortcuts.
    @MainActor static var commands: [MenuCommand] = []

    static func commandID(_ item: NSMenuItem) -> String? {
        guard let action = item.action else { return nil }
        return NSStringFromSelector(action) + "#\(item.tag)"
    }

    /// Notes every command with its default shortcut, then puts the user's
    /// shortcuts in. Hidden second shortcuts (⌥⌘B for the library) stay.
    @MainActor
    static func applyShortcuts(_ main: NSMenu, custom: [String: String]) {
        var commands: [MenuCommand] = []
        var seen = Set<String>()
        for holder in main.items {
            guard let submenu = holder.submenu else { continue }
            for item in flatten(submenu) where !item.isHidden && !item.isSeparatorItem {
                guard let id = commandID(item), !seen.contains(id) else { continue }
                seen.insert(id)
                commands.append(MenuCommand(id: id, menu: holder.title, title: item.title,
                                            defaultShortcut: KeyShortcut(item: item)))
                if let value = custom[id] {
                    if let shortcut = KeyShortcut(string: value) {
                        shortcut.apply(to: item)
                    } else {
                        item.keyEquivalent = ""
                    }
                }
            }
        }
        self.commands = commands
    }

    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in item.submenu.map(flatten) ?? [item] }
    }
}

/// Catches the next key press for the shortcut being recorded, before the
/// menu or the page sees it (ShortcutMonitor asks it first).
@MainActor
final class ShortcutRecorder {
    static let shared = ShortcutRecorder()
    private var handler: ((NSEvent) -> Void)?

    var isRecording: Bool { handler != nil }

    func start(_ handler: @escaping (NSEvent) -> Void) { self.handler = handler }
    func stop() { handler = nil }

    /// True when the key went to the recorder.
    func capture(_ event: NSEvent) -> Bool {
        guard let handler else { return false }
        handler(event)
        return true
    }
}

/// Settings › Tastatur: every menu command with its shortcut; a click on
/// a shortcut records a new one.
struct ShortcutsPage: View {
    let app: AppDelegate
    @Bindable var library: Library
    @State private var filter = ""
    @State private var recordingID: String?
    @State private var note: String?
    @State private var commands = MainMenu.commands

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Befehl suchen", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Alle zurücksetzen") {
                    library.settings.shortcuts = [:]
                    rebuild()
                }
                .disabled(library.settings.shortcuts.isEmpty)
            }
            Text(note ?? "Klick auf ein Kürzel und drück die neuen Tasten, mit ⌘ oder ⌃. ⌫ nimmt das Kürzel weg, ⎋ bricht ab.")
                .font(.system(size: 11)).foregroundStyle(note == nil ? .secondary : Color.orange)
            ForEach(menus, id: \.self) { menu in
                VStack(alignment: .leading, spacing: 8) {
                    Text(menu).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        let rows = shown.filter { $0.menu == menu }
                        ForEach(rows) { command in
                            row(command)
                            if command != rows.last { Divider().padding(.leading, 14).opacity(0.6) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                }
            }
        }
        .onDisappear { ShortcutRecorder.shared.stop() }
    }

    private var shown: [MenuCommand] {
        let needle = filter.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return commands }
        return commands.filter { $0.title.lowercased().contains(needle) || $0.menu.lowercased().contains(needle) }
    }

    private var menus: [String] {
        var seen: [String] = []
        for command in shown where !seen.contains(command.menu) { seen.append(command.menu) }
        return seen
    }

    private func current(_ command: MenuCommand) -> KeyShortcut? {
        guard let value = library.settings.shortcuts[command.id] else { return command.defaultShortcut }
        return KeyShortcut(string: value)
    }

    private func row(_ command: MenuCommand) -> some View {
        let isCustom = library.settings.shortcuts[command.id] != nil
        let recording = recordingID == command.id
        return HStack(spacing: 10) {
            Text(command.title).font(.system(size: 13))
            Spacer(minLength: 12)
            if isCustom {
                Button {
                    library.settings.shortcuts[command.id] = nil
                    rebuild()
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Zurück zu \(command.defaultShortcut?.display ?? "keinem Kürzel")")
            }
            Button {
                recording ? stopRecording() : record(command)
            } label: {
                Text(recording ? "Tasten drücken …" : (current(command)?.display ?? "–"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 86)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Color.accentColor : .clear))
                    .foregroundStyle(isCustom ? Color.accentColor : .primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func record(_ command: MenuCommand) {
        recordingID = command.id
        note = nil
        ShortcutRecorder.shared.start { event in
            switch event.keyCode {
            case 53:  // ⎋
                stopRecording()
            case 51 where event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty:  // ⌫
                library.settings.shortcuts[command.id] = command.defaultShortcut == nil ? nil : ""
                stopRecording()
                rebuild()
            default:
                guard let shortcut = KeyShortcut(event: event) else {
                    note = "Ein Kürzel braucht ⌘ oder ⌃."
                    return
                }
                // The shortcut moves here from whatever had it.
                if let other = commands.first(where: { $0.id != command.id && current($0) == shortcut }) {
                    library.settings.shortcuts[other.id] = ""
                    note = "\(shortcut.display) gehörte zu „\(other.title)“ und gilt jetzt hier."
                }
                library.settings.shortcuts[command.id] = shortcut == command.defaultShortcut ? nil : shortcut.string
                stopRecording()
                rebuild()
            }
        }
    }

    private func stopRecording() {
        recordingID = nil
        ShortcutRecorder.shared.stop()
    }

    private func rebuild() {
        library.setNeedsSave()
        app.rebuildMenu()
        commands = MainMenu.commands
    }
}
