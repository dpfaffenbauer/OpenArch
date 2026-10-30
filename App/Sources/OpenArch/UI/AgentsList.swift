import AppKit
import SwiftUI

/// Agents (⌃0, the ✨ in the space bar): in place of a space's tabs, every
/// agent chat and every Claude Code session of the last week, grouped by
/// what they are doing or by project. The page or chat in front stays.
struct AgentsList: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    @AppStorage("agentGrouping") private var grouping = AgentGrouping.status

    var body: some View {
        let entries = AgentEntry.all(browser: browser)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                Text("Agents").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $grouping) {
                    ForEach(AgentGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                IconButton(symbol: "plus", help: "Neuer Agent-Chat") { browser.newAgentChat() }
            }
            .foregroundStyle(theme.secondary)
            .padding(.leading, 10)
            .frame(height: 30)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        Text("Noch keine Agents. Starte einen Agent-Chat mit +. Sessions von claude im Terminal oder im Editor aus der letzten Woche erscheinen hier auch.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                    ForEach(groups(of: entries)) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(group.title) · \(group.entries.count)")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.secondary)
                                .padding(.leading, 10)
                                .padding(.bottom, 2)
                            ForEach(group.entries) { entry in
                                AgentListRow(browser: browser, entry: entry, theme: theme, showsProject: grouping == .status)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .task {
            // Fresher while you look at it.
            ClaudeSessions.shared.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                ClaudeSessions.shared.refresh()
            }
        }
    }

    private func groups(of entries: [AgentEntry]) -> [AgentGroup] {
        switch grouping {
        case .status:
            let byStatus = Dictionary(grouping: entries, by: \.status)
            return [ClaudeSession.Status.working, .approval, .waiting, .open, .done].compactMap { status in
                guard let group = byStatus[status], !group.isEmpty else { return nil }
                let sorted = group.sorted { $0.date > $1.date }
                return AgentGroup(title: status.title, entries: status == .done ? Array(sorted.prefix(30)) : sorted)
            }
        case .project:
            let byFolder = Dictionary(grouping: entries, by: \.folder)
            return byFolder.values
                .map { $0.sorted { $0.date > $1.date } }
                .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
                .map { group in AgentGroup(title: group.first?.project ?? "Ohne Ordner", entries: group) }
        }
    }
}

struct AgentGroup: Identifiable {
    let title: String
    let entries: [AgentEntry]
    var id: String { title + (entries.first?.folder ?? "") }
}

enum AgentGrouping: String, CaseIterable, Identifiable {
    case status, project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: "Status"
        case .project: "Projekt"
        }
    }
}

/// One agent in the list: a chat in the sidebar (with its session, if
/// Claude Code knows it) or a session from the terminal or an editor.
struct AgentEntry: Identifiable {
    let id: String
    var title: String
    var folder: String
    var status: ClaudeSession.Status
    var date: Date
    /// The last answer.
    var detail: String
    var openTodos = 0
    var isUnread = false
    var chat: Item?
    var session: ClaudeSession?

    var project: String {
        folder.isEmpty ? "Ohne Ordner" : URL(fileURLWithPath: folder).lastPathComponent
    }

    @MainActor static func all(browser: BrowserWindowController) -> [AgentEntry] {
        let sessions = ClaudeSessions.shared.sessions
        let chats = browser.library.spaces.flatMap { ($0.pinned.allItems + $0.today.allItems).filter { $0.kind == .agent } }
        var entries: [AgentEntry] = []
        var linked = Set<String>()
        for chat in chats {
            let session = chat.agent?.sessionID.flatMap { id in sessions.first { $0.id == id } }
            if let id = chat.agent?.sessionID { linked.insert(id) }
            let live = chat.agentSession
            // A chat counts as it is in the sidebar: at work while it runs,
            // waiting while its answer is unread or something was refused.
            var status = session?.status == .open ? ClaudeSession.Status.open : .done
            if live?.isRunning == true {
                status = .working
            } else if let last = live?.messages.last, last.role == .denied, live?.isAllowed(last.tool ?? "") == false {
                status = .approval
            } else if live?.isUnread == true {
                status = .waiting
            }
            let answer = live?.messages.last { $0.role == .assistant }?.text ?? session?.lastMessage ?? ""
            entries.append(AgentEntry(id: "chat:\(chat.id)", title: chat.displayTitle, folder: chat.agent?.folder ?? "",
                                      status: status, date: max(chat.lastActiveAt, session?.date ?? .distantPast),
                                      detail: answer, openTodos: session?.openTodos ?? 0,
                                      isUnread: live?.isUnread == true, chat: chat, session: session))
        }
        for session in sessions where !linked.contains(session.id) {
            entries.append(AgentEntry(id: "session:\(session.id)", title: session.title, folder: session.folder,
                                      status: session.status, date: session.date, detail: session.lastMessage,
                                      openTodos: session.openTodos, session: session))
        }
        return entries
    }
}

private struct AgentListRow: View {
    let browser: BrowserWindowController
    let entry: AgentEntry
    let theme: SpaceTheme
    /// Grouped by status, a row names its project; grouped by project, its status.
    let showsProject: Bool
    @State private var hovering = false

    var body: some View {
        let isActive = entry.chat != nil && browser.state.activeItem === entry.chat
        HStack(spacing: 10) {
            Group {
                if entry.status == .working {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: entry.chat == nil ? entry.status.symbol : "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(entry.status == .done ? 0.6 : 1)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.system(size: 13.5)).lineLimit(1)
                Text("\(showsProject ? entry.project : entry.status.title) · \(entry.date, style: .relative)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if entry.openTodos > 0 {
                Text("\(entry.openTodos)")
                    .font(.system(size: 10.5, weight: .bold))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(theme.tile))
                    .help("\(entry.openTodos) offene Todos")
            }
            if entry.isUnread || entry.status == .waiting || entry.status == .approval {
                Circle().fill(entry.status == .approval ? Color.orange : theme.foreground).frame(width: 7, height: 7)
                    .padding(.trailing, 4)
            }
        }
        .rowStyle(depth: 0, isActive: isActive, hovering: hovering, theme: theme, dropZone: nil)
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .help(entry.detail.isEmpty ? entry.folder : "\(entry.folder)\n\n\(entry.detail.prefix(300))")
        .contextMenu {
            Button(entry.chat == nil ? "Als Agent-Chat öffnen" : "Öffnen") { open() }
            if let session = entry.session {
                Button("Im Terminal fortsetzen") { BrowserWindowController.resumeInTerminal(session) }
            }
            if !entry.folder.isEmpty {
                Button("Ordner im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.folder)])
                }
            }
            if let session = entry.session {
                Button("Session-ID kopieren") { copy(session.id) }
            }
            if let chat = entry.chat {
                Divider()
                Button("Chat löschen") { browser.deleteAgentChat(chat) }
            }
        }
    }

    private func open() {
        if let chat = entry.chat {
            browser.select(chat)
        } else if let session = entry.session {
            browser.openClaudeSession(session)
        }
    }
}
