import AppKit
import SwiftUI

/// "Neues Profil anlegen", like Arc's dialog: asks for a name and creates a
/// profile with its own logins, history, passwords and extensions.
@MainActor
enum ProfileDialog {
    private final class Result {
        var name: String?
    }

    /// Runs the dialog over |window|. Returns the new profile, or nil.
    @discardableResult
    static func run(library: Library, over window: NSWindow?) -> Profile? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let result = Result()
        let view = ProfileDialogView(
            existing: Set(library.profiles.map { $0.name.lowercased() }),
            onCancel: { NSApp.stopModal() },
            onCreate: { name in
                result.name = name
                NSApp.stopModal()
            })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2 + frame.height * 0.1))
        } else {
            panel.center()
        }
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        guard let name = result.name else { return nil }
        return library.addProfile(name: name)
    }
}

struct ProfileDialogView: View {
    let existing: Set<String>
    let onCancel: () -> Void
    let onCreate: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var isTaken: Bool { existing.contains(trimmed.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color(nsColor: NSColor(hex: "#5E5CB8") ?? .systemIndigo)))
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .green)
                    .offset(x: 3, y: 3)
            }
            .padding(.top, 6)

            Text("Neues Profil anlegen")
                .font(.system(size: 18, weight: .bold))
            Text("Profile trennen deine Spaces wirklich – mit eigenem Verlauf, gespeicherten Passwörtern, Extensions und Logins. Kein Hin und Her mehr zwischen Arbeits- und Privat-Accounts.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Wie soll das Profil heißen?")
                    .font(.system(size: 13, weight: .semibold))
                TextField("Persönlich", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    .focused($focused)
                    .onSubmit { if canCreate { onCreate(trimmed) } }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10))
                    Text(isTaken ? "Ein Profil mit diesem Namen gibt es schon." : "Profile werden **nicht** zwischen Computern synchronisiert.")
                }
                .font(.system(size: 11))
                .foregroundStyle(isTaken ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }

            HStack(spacing: 10) {
                Spacer()
                Button(action: onCancel) {
                    HStack(spacing: 8) {
                        Text("Abbrechen")
                        KeyHint("esc")
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button { onCreate(trimmed) } label: {
                    HStack(spacing: 8) {
                        Text("Profil anlegen")
                        KeyHint("↩")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private var canCreate: Bool { !trimmed.isEmpty && !isTaken }
}

private struct KeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.12)))
    }
}
