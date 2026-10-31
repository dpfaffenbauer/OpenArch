import Foundation
import Observation

/// A Claude Code session on this Mac, as its transcript tells it (one JSON
/// line per step, in ~/.claude/projects/<folder>/<session>.jsonl).
struct ClaudeSession: Identifiable, Equatable, Sendable {
    enum Status: Int, Comparable, Sendable {
        case working, approval, waiting, open, done

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .working: "Arbeitet"
            case .approval: "Wartet vielleicht auf Freigabe"
            case .waiting: "Wartet auf dich"
            case .open: "Offene Todos"
            case .done: "Ruhend"
            }
        }

        var symbol: String {
            switch self {
            case .working: "circle.dotted"
            case .approval: "hand.raised.fill"
            case .waiting: "bubble.left.fill"
            case .open: "checklist"
            case .done: "checkmark.circle"
            }
        }
    }

    /// Whose move it was when the transcript ends.
    enum Turn: Sendable {
        case unknown, prompt, toolResult, answer, toolUse
    }

    let id: String
    let file: URL
    /// Where it runs: claude finds the session again only from there.
    var folder = ""
    var title = ""
    /// The agent's last words, or your last message.
    var lastMessage = ""
    var date: Date
    /// Todos it set itself and has not finished.
    var openTodos = 0
    var turn = Turn.unknown
    var status = Status.done
}

/// The overview of Claude Code sessions (Agents in the sidebar): what is
/// running, what waits for you, what has open todos. Read from Claude
/// Code's transcripts every half minute while agent chats are on; a session
/// counts as running while a claude process works in its folder.
@MainActor @Observable
final class ClaudeSessions {
    static let shared = ClaudeSessions()

    private(set) var sessions: [ClaudeSession] = []
    private(set) var isLoading = false
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshing = false
    /// Sessions already read, by file: only changed transcripts are read again.
    @ObservationIgnored private var cache: [URL: ClaudeSession] = [:]

    /// Sessions that wait for you: answered, or maybe asking for a tool.
    var waitingCount: Int {
        sessions.filter { $0.status == .waiting || $0.status == .approval }.count
    }

    func start(_ library: Library) {
        self.library = library
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeSessions.shared.refreshIfOn() }
        }
        refreshIfOn()
    }

    private func refreshIfOn() {
        if library?.settings.agentChats == true, !AppPaths.isSelfTest {
            refresh()
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        isLoading = sessions.isEmpty
        let cache = self.cache
        Task {
            let (found, read) = await Task.detached {
                ClaudeSessions.scan(root: ClaudeSessions.defaultRoot, now: Date(), running: ClaudeSessions.runningFolders(),
                                    cache: cache)
            }.value
            self.sessions = found
            self.cache = read
            self.refreshing = false
            self.isLoading = false
        }
    }

    // MARK: Reading

    nonisolated static var defaultRoot: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("projects", isDirectory: true)
    }

    nonisolated static func scan(root: URL, now: Date, running: Set<String>) -> [ClaudeSession] {
        scan(root: root, now: now, running: running, cache: [:]).sessions
    }

    /// The sessions of the last 30 days below |root|, those that wait or
    /// work first. |running| are the folders a claude process works in;
    /// transcripts unchanged since |cache| was made are not read again.
    nonisolated static func scan(root: URL, now: Date, running: Set<String>,
                                 cache: [URL: ClaudeSession]) -> (sessions: [ClaudeSession], cache: [URL: ClaudeSession]) {
        let files = FileManager.default
        guard let projects = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return ([], [:]) }
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        var sessions: [ClaudeSession] = []
        var read: [URL: ClaudeSession] = [:]
        for project in projects {
            let entries = (try? files.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey],
                                                          options: [.skipsHiddenFiles])) ?? []
            for file in entries where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard date > cutoff else { continue }
                if let known = cache[file], known.date == date {
                    sessions.append(known)
                    read[file] = known
                } else if let session = self.read(file, date: date) {
                    sessions.append(session)
                    read[file] = session
                }
            }
        }
        // A claude process writes the newest session of its folder (or one
        // that changed a moment ago).
        var newest: [String: Date] = [:]
        for session in sessions {
            newest[session.folder] = max(newest[session.folder] ?? .distantPast, session.date)
        }
        for index in sessions.indices {
            let session = sessions[index]
            let live = running.contains(session.folder)
                && (session.date == newest[session.folder] || now.timeIntervalSince(session.date) < 120)
            sessions[index].status = status(of: session, live: live, now: now)
        }
        return (sessions.sorted { ($0.status, $1.date) < ($1.status, $0.date) }, read)
    }

    nonisolated static func status(of session: ClaudeSession, live: Bool, now: Date) -> ClaudeSession.Status {
        guard live else { return session.openTodos > 0 ? .open : .done }
        switch session.turn {
        case .answer:
            return .waiting
        case .toolUse where now.timeIntervalSince(session.date) > 30:
            // A tool that has not come back for a while: often a question
            // whether it may run, sometimes just a long command.
            return .approval
        default:
            return .working
        }
    }

    /// What a transcript says: its beginning (folder, first message) and
    /// its end (last steps, todos). Sessions without a message are skipped.
    nonisolated static func read(_ file: URL, date: Date) -> ClaudeSession? {
        var session = ClaudeSession(id: file.deletingPathExtension().lastPathComponent, file: file, date: date)
        var firstPrompt = ""
        var summary = ""
        for entry in entries(in: file, head: 64 * 1024, tail: 256 * 1024) {
            if entry["type"] as? String == "summary" {
                summary = entry["summary"] as? String ?? summary
                continue
            }
            if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true { continue }
            if session.folder.isEmpty, let cwd = entry["cwd"] as? String {
                session.folder = cwd
            }
            let content = (entry["message"] as? [String: Any])?["content"]
            switch entry["type"] as? String {
            case "user":
                let blocks = content as? [[String: Any]] ?? []
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    session.turn = .toolResult
                } else if let prompt = prompt(in: content) {
                    if firstPrompt.isEmpty { firstPrompt = prompt }
                    session.lastMessage = "Du: " + prompt
                    session.turn = .prompt
                }
            case "assistant":
                for block in content as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            session.lastMessage = text
                            session.turn = .answer
                        }
                    case "tool_use":
                        session.turn = .toolUse
                        if block["name"] as? String == "TodoWrite",
                           let todos = (block["input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                            session.openTodos = todos.filter { $0["status"] as? String != "completed" }.count
                        }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        guard !firstPrompt.isEmpty || !session.lastMessage.isEmpty else { return nil }
        let title = tidy(summary.isEmpty ? firstPrompt : summary)
        session.title = title.isEmpty ? URL(fileURLWithPath: session.folder).lastPathComponent : title
        return session
    }

    /// A title from a first message: its first line without Markdown marks,
    /// an address without its scheme, spaces evened out.
    nonisolated static func tidy(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        line = line.trimmingCharacters(in: .whitespaces)
        while let first = line.first, "#>*-`_".contains(first) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        for scheme in ["https://", "http://"] where line.hasPrefix(scheme) {
            line.removeFirst(scheme.count)
        }
        if line.hasPrefix("www.") { line.removeFirst(4) }
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > 70 ? String(line.prefix(68)) + "…" : line
    }

    /// Something you typed, not a command's output or a note of claude's
    /// own ("<command-name>…", "<local-command-stdout>…").
    nonisolated private static func prompt(in content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]],
                  let first = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
            text = first
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude Code's own note when you stop it is no message of yours.
        return trimmed.isEmpty || trimmed.hasPrefix("<") || trimmed.hasPrefix("[Request interrupted") ? nil : trimmed
    }

    /// The JSON lines of the first |head| and the last |tail| bytes of a
    /// transcript (they can grow to many megabytes).
    nonisolated private static func entries(in file: URL, head: Int, tail: Int) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        var chunks: [(Data, Bool, Bool)] = []  // data, cut at the start, cut at the end
        try? handle.seek(toOffset: 0)
        let start = (try? handle.read(upToCount: head)) ?? Data()
        chunks.append((start, false, size > start.count))
        if size > start.count {
            let offset = max(start.count, size - tail)
            try? handle.seek(toOffset: UInt64(offset))
            chunks.append(((try? handle.readToEnd()) ?? Data(), offset > 0, false))
        }
        var entries: [[String: Any]] = []
        for (data, cutStart, cutEnd) in chunks {
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            if cutStart, !lines.isEmpty { lines.removeFirst() }
            if cutEnd, !lines.isEmpty { lines.removeLast() }
            for line in lines {
                if let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    /// The end of a transcript as chat messages, for opening it as an agent chat.
    nonisolated static func messages(in file: URL, limit: Int = 200) -> [AgentMessage] {
        var messages: [AgentMessage] = []
        for entry in entries(in: file, head: 0, tail: 512 * 1024) {
            if entry["isSidechain"] as? Bool == true || entry["isMeta"] as? Bool == true { continue }
            let content = (entry["message"] as? [String: Any])?["content"]
            switch entry["type"] as? String {
            case "user":
                let blocks = content as? [[String: Any]] ?? []
                for block in blocks where block["type"] as? String == "tool_result" {
                    guard let id = block["tool_use_id"] as? String,
                          let index = messages.lastIndex(where: { $0.toolUseID == id }) else { continue }
                    var output = AgentSession.text(of: block["content"])
                    if output.count > 4000 { output = String(output.prefix(4000)) + "\n…" }
                    messages[index].output = output
                    messages[index].failed = block["is_error"] as? Bool ?? false
                }
                if let prompt = prompt(in: content), !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    messages.append(AgentMessage(role: .user, text: prompt))
                }
            case "assistant":
                for block in content as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { messages.append(AgentMessage(role: .assistant, text: text)) }
                    case "tool_use":
                        messages.append(AgentMessage(role: .tool, text: AgentTool.summary(of: block["input"] as? [String: Any] ?? [:]),
                                                     tool: block["name"] as? String, toolUseID: block["id"] as? String))
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        return Array(messages.suffix(limit))
    }

    /// The model and the context the last answer filled, from a session's
    /// transcript (found by its id in any project folder).
    nonisolated static func lastUsage(sessionID: String) -> (model: String?, used: Int?) {
        let projects = (try? FileManager.default.contentsOfDirectory(at: defaultRoot, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        guard let file = projects.lazy.map({ $0.appendingPathComponent(sessionID + ".jsonl") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return (nil, nil) }
        for entry in entries(in: file, head: 0, tail: 256 * 1024).reversed() {
            guard entry["type"] as? String == "assistant", entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            return (message["model"] as? String, AgentSession.contextTokens(usage))
        }
        return (nil, nil)
    }

    /// The folders claude processes work in, from ps and lsof.
    nonisolated static func runningFolders() -> Set<String> {
        guard let list = AgentEnvironment.run("/bin/ps", ["-Ao", "pid=,args="]) else { return [] }
        var pids: [String] = []
        for line in list.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = fields.first else { continue }
            // "claude …", "/Users/…/.local/bin/claude …" or "node …/bin/claude …".
            let isClaude = fields.dropFirst().prefix(2).contains { $0.split(separator: "/").last == "claude" }
                || line.contains("@anthropic-ai/claude-code")
            if isClaude { pids.append(String(pid)) }
        }
        guard !pids.isEmpty,
              let open = AgentEnvironment.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids.joined(separator: ",")])
        else { return [] }
        return Set(open.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) })
    }
}
