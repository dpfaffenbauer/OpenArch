import AppKit
import OpenArchCore
import SwiftUI

/// Counts the changes to the extensions' actions (installed, removed,
/// pinned, a badge or icon), so views that show them read them again.
/// Chrome reports each change once per page that lists extensions, often
/// several in a row: they count as one.
@MainActor @Observable
final class ExtensionChanges {
    static let shared = ExtensionChanges()

    private(set) var revision = 0
    @ObservationIgnored private var pending = false

    func start() {
        OACPane.extensionsChangedHandler = {
            MainActor.assumeIsolated { ExtensionChanges.shared.changed() }
        }
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        after(0.05) { [self] in
            pending = false
            revision += 1
        }
    }
}

/// The pinned extensions in the sidebar, below the address (as Arc has
/// them), while the toolbar above the page, which has them too, is hidden.
/// A click runs the extension on the page in front; its popup opens at the
/// pointer.
struct SidebarExtensions: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme

    var body: some View {
        let pane = browser.state.activeItem?.kind == .tab ? browser.state.activeItem?.pane as? OACPane : nil
        // Read again on every change, and for each page (badges and whether
        // an action is on are per page).
        let _ = ExtensionChanges.shared.revision
        let _ = browser.state.activeItem?.currentURL
        let pinned = OACPane.panesHaveWindows ? [] : (pane?.extensions ?? []).filter(\.pinned)
        if let pane, !pinned.isEmpty {
            HStack(spacing: 2) {
                ForEach(pinned, id: \.identifier) { info in
                    SidebarExtensionButton(info: info, theme: theme) {
                        pane.runExtension(info.identifier, from: NSRect(origin: NSEvent.mouseLocation, size: .zero))
                    } unpin: {
                        pane.setExtension(info.identifier, pinned: false)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct SidebarExtensionButton: View {
    let info: OACExtensionInfo
    let theme: SpaceTheme
    let run: () -> Void
    let unpin: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            Image(nsImage: info.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .opacity(info.activeOnPage ? 1 : 0.4)
                .frame(width: IconButton.width, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.foreground.opacity(hovering ? 0.1 : 0)))
                .overlay(alignment: .topTrailing) {
                    if !info.badge.isEmpty {
                        Text(info.badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 11)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 2, y: -1)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(info.name)
        .contextMenu {
            Button("Von der Leiste lösen", action: unpin)
        }
    }
}
