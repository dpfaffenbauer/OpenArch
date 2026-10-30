import AppKit
import SwiftUI

/// Agents: every Claude Code session on this Mac from the last week, those
/// that work or wait for you first. A click opens one as an agent chat.
struct AgentOverviewView: View {
    let browser: BrowserWindowController

    var body: some View {
        let store = ClaudeSessions.shared
        let groups = Dictionary(grouping: store.sessions) { status(of: $0) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents").font(.system(size: 20, weight: .bold))
                    Text("Claude-Code-Sessions auf diesem Mac aus der letzten Woche")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Neu einlesen")
                Button("Neuer Agent-Chat") { browser.newAgentChat() }
            }
            .padding(.horizontal, 28)
            .frame(height: 72)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.sessions.isEmpty, !store.isLoading {
                        Text("Keine Sessions in der letzten Woche. Sessions von claude im Terminal, in deinem Editor und aus den Agent-Chats erscheinen hier.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach([ClaudeSession.Status.working, .approval, .waiting, .open, .done], id: \.self) { status in
                        if let sessions = groups[status], !sessions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(status.title) · \(sessions.count)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(sessions.prefix(status == .done ? 25 : 100)) { session in
                                    AgentSessionRow(browser: browser, session: session, status: status)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task {
            // Fresher while you look at it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                store.refresh()
            }
        }
    }

    /// A session that continues in a sidebar chat counts as that chat does:
    /// at work while it runs, waiting while its answer is unread.
    private func status(of session: ClaudeSession) -> ClaudeSession.Status {
        guard let chat = browser.agentChat(forSession: session.id), let live = chat.agentSession else { return session.status }
        if live.isRunning { return .working }
        if live.isUnread { return .waiting }
        return session.status == .open ? .open : .done
    }
}

private struct AgentSessionRow: View {
    let browser: BrowserWindowController
    let session: ClaudeSession
    let status: ClaudeSession.Status
    @State private var hovering = false

    var body: some View {
        let folder = (session.folder as NSString).abbreviatingWithTildeInPath
        let inSidebar = browser.agentChat(forSession: session.id) != nil
        HStack(alignment: .top, spacing: 12) {
            Group {
                if status == .working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status.symbol).foregroundStyle(color)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if inSidebar {
                        chip("In der Sidebar")
                    }
                    if session.openTodos > 0 {
                        chip("\(session.openTodos) offen")
                    }
                }
                Text("\(folder) · \(session.date, style: .relative)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !session.lastMessage.isEmpty {
                    Text(session.lastMessage.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if hovering {
                Text(inSidebar ? "Zum Chat" : "Öffnen").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.07 : 0.035)))
        .contentShape(Rectangle())
        .onTapGesture { browser.openClaudeSession(session) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(inSidebar ? "Zum Agent-Chat" : "Als Agent-Chat öffnen") { browser.openClaudeSession(session) }
            Button("Im Terminal fortsetzen") { BrowserWindowController.resumeInTerminal(session) }
            Button("Ordner im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.folder)])
            }
            Divider()
            Button("Session-ID kopieren") { copy(session.id) }
        }
        .help(session.folder)
    }

    private var color: Color {
        switch status {
        case .working: .blue
        case .approval: .orange
        case .waiting: .accentColor
        case .open: .purple
        case .done: .secondary
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}
