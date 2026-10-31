import AppKit
import SwiftUI

/// Agents (⌃0, the ✨ in the space bar): in place of a space's tabs, every
/// agent chat and every Claude Code session of the last 30 days, one line
/// each, grouped like the Claude app: what waits for you, what works, what
/// has open todos, what rests. The page or chat in front stays.
struct AgentsList: View {
    let browser: BrowserWindowController
    let theme: SpaceTheme
    @AppStorage("agentGrouping") private var grouping = AgentGrouping.status
    @State private var query = ""
    /// Groups closed by hand; resting sessions start closed.
    @State private var collapsed: Set<String> = [AgentGroup.restingTitle]
    /// Groups showing all their rows, not the first few.
    @State private var expanded: Set<String> = []

    var body: some View {
        let entries = AgentEntry.all(browser: browser).filter(matches)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("Agents").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Picker("Gruppieren nach", selection: $grouping) {
                        ForEach(AgentGrouping.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 28, height: 24)
                .help("Gruppieren nach Status oder Projekt")
                IconButton(symbol: "square.and.pencil", help: "Neuer Agent-Chat") { browser.newAgentChat() }
            }
            .foregroundStyle(theme.secondary)
            .padding(.leading, 10)
            .frame(height: 28)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).opacity(0.6)
                TextField("Suchen", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(theme.tile))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if entries.isEmpty {
                        Text(query.isEmpty
                             ? "Noch keine Agents. Starte einen Agent-Chat oben rechts. Sessions von claude im Terminal oder im Editor erscheinen hier auch."
                             : "Nichts gefunden.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                    }
                    ForEach(groups(of: entries)) { group in
                        groupView(group)
                    }
                }
                .padding(.top, 4)
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

    @ViewBuilder
    private func groupView(_ group: AgentGroup) -> some View {
        let isCollapsed = collapsed.contains(group.title) && query.isEmpty
        let limit = expanded.contains(group.title) || !query.isEmpty ? group.entries.count : 8
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if collapsed.contains(group.title) { collapsed.remove(group.title) } else { collapsed.insert(group.title) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(group.title).font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .opacity(0.7)
                    Spacer()
                    if isCollapsed {
                        Text("\(group.entries.count)").font(.system(size: 11)).opacity(0.8)
                    }
                }
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !isCollapsed {
                ForEach(group.entries.prefix(limit)) { entry in
                    AgentListRow(browser: browser, entry: entry, theme: theme, showsProject: grouping == .status)
                }
                if group.entries.count > limit {
                    Button("\(group.entries.count - limit) weitere zeigen") { expanded.insert(group.title) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                }
            }
        }
    }

    private func matches(_ entry: AgentEntry) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = "\(entry.title) \(entry.project) \(entry.detail)".lowercased()
        return needle.split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    private func groups(of entries: [AgentEntry]) -> [AgentGroup] {
        switch grouping {
        case .status:
            // Like the Claude app: what needs you first, resting last.
            let order: [(String, [ClaudeSession.Status])] = [
                ("Wartet auf dich", [.approval, .waiting]),
                ("Arbeitet", [.working]),
                ("Offene Todos", [.open]),
                (AgentGroup.restingTitle, [.done]),
            ]
            return order.compactMap { title, statuses in
                let group = entries.filter { statuses.contains($0.status) }.sorted { $0.date > $1.date }
                return group.isEmpty ? nil : AgentGroup(title: title, entries: group)
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
    static let restingTitle = "Ruhend"

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

    /// How long ago, coarsely: a list that ticks every second looks busy.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "jetzt" }
        if seconds < 3600 { return "\(Int(seconds / 60)) Min." }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) Std." }
        if Calendar.current.isDateInYesterday(date) { return "gestern" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
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
            entries.append(AgentEntry(id: "chat:\(chat.id)", title: ClaudeSessions.tidy(chat.displayTitle), folder: chat.agent?.folder ?? "",
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

/// One line, like the Claude app: the title, and on the right what needs
/// you (a dot), what works (a wheel), or on hover how long ago.
private struct AgentListRow: View {
    let browser: BrowserWindowController
    let entry: AgentEntry
    let theme: SpaceTheme
    /// Grouped by status, the project goes in the tooltip line.
    let showsProject: Bool
    @State private var hovering = false

    var body: some View {
        let isActive = entry.chat != nil && browser.state.activeItem === entry.chat
        HStack(spacing: 8) {
            Text(entry.title)
                .font(.system(size: 13.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if hovering {
                Text(showsProject ? "\(entry.project) · \(AgentEntry.age(entry.date))" : AgentEntry.age(entry.date))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            } else {
                if entry.openTodos > 0 {
                    Text("\(entry.openTodos)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(theme.secondary)
                        .help("\(entry.openTodos) offene Todos")
                }
                indicator
            }
        }
        .frame(height: 30)
        .rowStyle(depth: 0, isActive: isActive, hovering: hovering, theme: theme, dropZone: nil)
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .help(tooltip)
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

    /// Working: a wheel. Needs you: a dot, orange when it may be waiting to
    /// be allowed something. Resting: nothing.
    @ViewBuilder private var indicator: some View {
        switch entry.status {
        case .working:
            ProgressView().controlSize(.mini).frame(width: 12)
        case .approval:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        case .waiting:
            Circle().fill(Color.yellow).frame(width: 7, height: 7)
        case .open:
            Circle().strokeBorder(theme.secondary, lineWidth: 1.2).frame(width: 7, height: 7)
        case .done:
            if entry.isUnread {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
            }
        }
    }

    private var tooltip: String {
        var lines = ["\(entry.project) · \(entry.status.title) · \(AgentEntry.age(entry.date))"]
        if !entry.detail.isEmpty { lines.append(String(entry.detail.prefix(300))) }
        return lines.joined(separator: "\n\n")
    }

    private func open() {
        if let chat = entry.chat {
            browser.select(chat)
        } else if let session = entry.session {
            browser.openClaudeSession(session)
        }
    }
}
