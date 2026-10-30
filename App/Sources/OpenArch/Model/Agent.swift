import AppKit
import Observation
import OpenArchCore

/// What an agent chat keeps in the library: the folder Claude Code works
/// in, the session it continues, and what it may do without asking.
struct AgentConfig: Codable, Equatable {
    var folder: String
    /// Claude Code's session, for `--resume`; nil until the first answer.
    var sessionID: String?
    var permissions = AgentPermissions.ask
    /// Allowed after the agent was refused them: "Bash(npm:*)", "Edit",
    /// "mcp__openarch" (the browser).
    var allowedTools: [String] = []

    init(folder: String) {
        self.folder = folder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decode(String.self, forKey: .folder)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        permissions = try container.decodeIfPresent(AgentPermissions.self, forKey: .permissions) ?? .ask
        allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
    }
}

/// How much Claude Code may do on its own. `claude -p` cannot ask in
/// between, so what it is refused shows in the chat with a button to allow it.
enum AgentPermissions: String, Codable, CaseIterable, Identifiable {
    case ask, edits, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Nachfragen"
        case .edits: "Dateien bearbeiten"
        case .all: "Alles erlauben"
        }
    }

    var detail: String {
        switch self {
        case .ask: "Liest Dateien, fragt vor Änderungen, Befehlen und dem Browser"
        case .edits: "Ändert Dateien ohne Rückfrage, fragt vor Befehlen"
        case .all: "Ändert Dateien und führt Befehle aus, ohne zu fragen"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .edits: "pencil"
        case .all: "bolt.fill"
        }
    }

    /// Claude Code's --permission-mode.
    var mode: String {
        switch self {
        case .ask: "default"
        case .edits: "acceptEdits"
        case .all: "bypassPermissions"
        }
    }
}

/// One entry of a chat: what you wrote, what the agent answered, a tool it
/// used, a tool it was refused, or a note.
struct AgentMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, assistant, tool, denied, error, note
    }

    var id = UUID()
    var role: Role
    var text: String
    /// Tools: the tool's name. Refused tools: the rule that allows it.
    var tool: String?
    var toolUseID: String?
    /// Tools: what came back, shortened.
    var output: String?
    var failed = false
    /// Text still arriving.
    var streaming = false
}

/// A chat with Claude Code, on your own login (`claude` in the terminal,
/// your subscription, no API key). Each message is one run of `claude -p`
/// in the chat's folder that continues the same session; its answer comes
/// back as stream-json, a JSON event per line.
@MainActor @Observable
final class AgentSession {
    private(set) var messages: [AgentMessage] = []
    private(set) var isRunning = false
    /// Finished while no window showed the chat.
    var isUnread = false
    var draft = ""
    /// Bumped to put the cursor into the chat's field.
    var focusRequest = 0

    @ObservationIgnored private weak var item: Item?
    private let library: Library
    @ObservationIgnored private var process: AgentProcess?
    /// Counts runs, so a late line of an earlier one is ignored.
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var sawResult = false
    @ObservationIgnored private var stopped = false

    /// Chats with a run going, to stop them when OpenArch quits.
    private static var running: [ObjectIdentifier: AgentSession] = [:]

    init(item: Item, library: Library) {
        self.item = item
        self.library = library
        messages = Self.loadTranscript(item.id)
    }

    // MARK: Running

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isRunning, let item, item.agent != nil else { return }
        messages.append(AgentMessage(role: .user, text: prompt))
        if item.customTitle == nil, item.savedTitle.isEmpty {
            item.savedTitle = Self.title(for: prompt)
            library.setNeedsSave()
        }
        draft = ""
        isRunning = true
        sawResult = false
        stopped = false
        saveTranscript()
        run += 1
        let run = self.run
        Task {
            let environment = await AgentEnvironment.resolved()
            guard run == self.run else { return }
            self.launch(prompt, environment: environment, run: run)
        }
    }

    func stop() {
        guard isRunning else { return }
        stopped = true
        if let process {
            process.stop()
        } else {
            // Still looking for claude: that run never starts.
            run += 1
            messages.append(AgentMessage(role: .note, text: "Angehalten."))
            finish()
        }
    }

    /// Allows what the agent was refused (|message| is the refusal) and
    /// lets it carry on.
    func allow(_ message: AgentMessage) {
        guard let rule = message.tool, let item, !isRunning else { return }
        if item.agent?.allowedTools.contains(rule) == false {
            item.agent?.allowedTools.append(rule)
            library.setNeedsSave()
        }
        send("Ich habe dir \(rule) erlaubt. Bitte mach weiter.")
    }

    func isAllowed(_ rule: String) -> Bool {
        item?.agent?.allowedTools.contains(rule) == true || item?.agent?.permissions == .all
    }

    /// Stops every running chat; OpenArch is quitting.
    static func stopAll() {
        for session in running.values {
            session.process?.stop()
            session.saveTranscript()
        }
        running.removeAll()
    }

    private func launch(_ prompt: String, environment: AgentEnvironment.Resolved, run: Int) {
        guard isRunning, !stopped, let item, let config = item.agent else { return finish() }
        guard let claude = environment.claude else {
            messages.append(AgentMessage(role: .error, text: """
                Claude Code wurde auf diesem Mac nicht gefunden. Installiere es (claude.ai/code) und melde dich \
                einmal im Terminal mit „claude“ an, dann noch einmal senden.
                """))
            AgentEnvironment.forget()
            return finish()
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: config.folder, isDirectory: &isFolder), isFolder.boolValue else {
            messages.append(AgentMessage(role: .error, text: "Den Ordner \(config.folder) gibt es nicht mehr."))
            return finish()
        }
        let process = AgentProcess(executable: claude, arguments: arguments(for: config),
                                   folder: URL(fileURLWithPath: config.folder), environment: environment.variables)
        do {
            try process.start(prompt: prompt, onLine: { line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.receive(line, run: run) } }
            }, onExit: { status, errors in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.exited(status: status, errors: errors, run: run) } }
            })
        } catch {
            messages.append(AgentMessage(role: .error, text: "Claude Code ließ sich nicht starten: \(error.localizedDescription)"))
            return finish()
        }
        self.process = process
        Self.running[ObjectIdentifier(self)] = self
    }

    private func arguments(for config: AgentConfig) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--permission-mode", config.permissions.mode]
        if let session = config.sessionID {
            arguments += ["--resume", session]
        }
        // With AI control on, the agent can work in this browser's tabs.
        let port = OACEngine.remoteDebuggingPort
        if port > 0 {
            arguments += ["--mcp-config", AIControl.mcpConfig(port: port)]
        }
        if !config.allowedTools.isEmpty {
            arguments += ["--allowedTools", config.allowedTools.joined(separator: ",")]
        }
        arguments += ["--append-system-prompt", Self.systemPrompt(folder: config.folder, browser: port > 0)]
        return arguments
    }

    private static func systemPrompt(folder: String, browser: Bool) -> String {
        var prompt = """
            You are a chat in the sidebar of OpenArch, the user's web browser on macOS, working in the folder \
            \(folder). Reply in the language the user writes in, and keep it short: the chat shows Markdown.
            """
        if browser {
            prompt += """
                 The openarch MCP server controls this browser: its real tabs, signed in as the user. Use it for \
                anything on the web or in the user's tabs, and leave the user's tabs where they are unless asked.
                """
        }
        return prompt
    }

    // MARK: Stream

    private func receive(_ line: String, run: Int) {
        guard run == self.run, isRunning,
              let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        // The steps of a subagent (Task tool) stay out of the chat.
        if event["parent_tool_use_id"] is String { return }
        switch event["type"] as? String {
        case "system":
            if event["subtype"] as? String == "init", let id = event["session_id"] as? String {
                remember(sessionID: id)
            }
        case "stream_event":
            streamed(event["event"] as? [String: Any] ?? [:])
        case "assistant":
            for block in Self.content(of: event) {
                assistantBlock(block)
            }
        case "user":
            for block in Self.content(of: event) where block["type"] as? String == "tool_result" {
                toolResult(block)
            }
        case "result":
            result(event)
        default:
            break
        }
    }

    private static func content(of event: [String: Any]) -> [[String: Any]] {
        (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// Text as it is written; the whole block replaces it when it is done.
    private func streamed(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "content_block_start":
            if let block = event["content_block"] as? [String: Any], block["type"] as? String == "text" {
                messages.append(AgentMessage(role: .assistant, text: block["text"] as? String ?? "", streaming: true))
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            if let last = messages.indices.last, messages[last].role == .assistant, messages[last].streaming {
                messages[last].text += text
            } else {
                messages.append(AgentMessage(role: .assistant, text: text, streaming: true))
            }
        default:
            break
        }
    }

    private func assistantBlock(_ block: [String: Any]) {
        switch block["type"] as? String {
        case "text":
            let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The oldest text still streaming is this one.
            if let index = messages.firstIndex(where: { $0.role == .assistant && $0.streaming }) {
                messages[index].text = text
                messages[index].streaming = false
                if text.isEmpty { messages.remove(at: index) }
            } else if !text.isEmpty {
                messages.append(AgentMessage(role: .assistant, text: text))
            }
        case "tool_use":
            let name = block["name"] as? String ?? ""
            let input = block["input"] as? [String: Any] ?? [:]
            messages.append(AgentMessage(role: .tool, text: AgentTool.summary(of: input), tool: name,
                                         toolUseID: block["id"] as? String))
        default:
            break
        }
    }

    private func toolResult(_ block: [String: Any]) {
        guard let id = block["tool_use_id"] as? String,
              let index = messages.lastIndex(where: { $0.role == .tool && $0.toolUseID == id }) else { return }
        messages[index].output = Self.shortened(Self.text(of: block["content"]))
        messages[index].failed = block["is_error"] as? Bool ?? false
    }

    private func result(_ event: [String: Any]) {
        sawResult = true
        if let id = event["session_id"] as? String {
            remember(sessionID: id)
        }
        var rules: [String] = []
        for case let denial as [String: Any] in event["permission_denials"] as? [Any] ?? [] {
            guard let tool = denial["tool_name"] as? String else { continue }
            let input = denial["tool_input"] as? [String: Any] ?? [:]
            let rule = AgentTool.rule(for: tool, input: input)
            guard !rules.contains(rule) else { continue }
            rules.append(rule)
            messages.append(AgentMessage(role: .denied, text: AgentTool.summary(of: input), tool: rule))
        }
        if event["is_error"] as? Bool == true, !stopped {
            let text = (event["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(AgentMessage(role: .error, text: text.isEmpty ? "Claude Code meldet einen Fehler." : text))
        }
    }

    private func exited(status: Int32, errors: String, run: Int) {
        guard run == self.run else { return }
        process = nil
        Self.running[ObjectIdentifier(self)] = nil
        if stopped {
            messages.append(AgentMessage(role: .note, text: "Angehalten."))
        } else if !sawResult, status != 0 {
            var detail = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                detail = "Claude Code hat sich beendet (Status \(status))."
            } else if detail.contains("unknown option") {
                detail += "\n\nEine neuere Version von Claude Code hilft: claude update"
            }
            messages.append(AgentMessage(role: .error, text: detail))
        }
        finish()
    }

    private func finish() {
        for index in messages.indices where messages[index].streaming {
            messages[index].streaming = false
        }
        isRunning = false
        saveTranscript()
        guard let item, item.container != nil, !BrowserWindowController.isShowing(item) else { return }
        isUnread = true
        if !NSApp.isActive, !AppPaths.isSelfTest {
            _ = NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func remember(sessionID: String) {
        guard let item, item.agent != nil, item.agent?.sessionID != sessionID else { return }
        item.agent?.sessionID = sessionID
        library.setNeedsSave()
    }

    // MARK: Helpers

    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = content as? [[String: Any]] ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func shortened(_ text: String, limit: Int = 4000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n…" : text
    }

    /// A chat is named after its first message.
    static func title(for prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 48 ? String(line.prefix(46)) + "…" : line
    }

    // MARK: Transcript

    /// Chats are kept next to the library, one file each.
    static var folder: URL {
        AppPaths.support.appendingPathComponent("Agents", isDirectory: true)
    }

    private static func transcriptURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    private static func loadTranscript(_ id: UUID) -> [AgentMessage] {
        guard let data = try? Data(contentsOf: transcriptURL(id)),
              var messages = try? JSONDecoder().decode([AgentMessage].self, from: data) else { return [] }
        // Text cut off by quitting stays as far as it got.
        for index in messages.indices {
            messages[index].streaming = false
        }
        return messages
    }

    func saveTranscript() {
        // A chat that was deleted while it ran stays deleted.
        guard let item, item.container != nil else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(messages).write(to: Self.transcriptURL(item.id), options: .atomic)
        } catch {
            log("could not save agent chat: \(error)")
        }
    }

    static func deleteTranscript(_ id: UUID) {
        try? FileManager.default.removeItem(at: transcriptURL(id))
    }
}

/// How the chat names the tools Claude Code uses, and what allowing a
/// refused one allows.
enum AgentTool {
    static let browserServer = "mcp__openarch"

    static func title(_ tool: String?) -> String {
        guard let tool else { return "Werkzeug" }
        if tool.hasPrefix(browserServer + "__") {
            return "Browser: " + tool.dropFirst(browserServer.count + 2).replacingOccurrences(of: "_", with: " ")
        }
        switch tool {
        case "Bash": return "Befehl"
        case "Read": return "Liest"
        case "Write": return "Schreibt"
        case "Edit", "MultiEdit", "NotebookEdit": return "Ändert"
        case "Grep", "Glob", "LS": return "Sucht"
        case "WebFetch": return "Lädt"
        case "WebSearch": return "Sucht im Web"
        case "Task": return "Unteragent"
        case "TodoWrite": return "Aufgaben"
        default:
            return tool.hasPrefix("mcp__") ? tool.dropFirst(5).replacingOccurrences(of: "__", with: ": ") : tool
        }
    }

    static func symbol(_ tool: String?) -> String {
        guard let tool else { return "wrench.and.screwdriver" }
        if tool.hasPrefix(browserServer) { return "safari" }
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob", "LS": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "person.2"
        case "TodoWrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    /// The gist of a tool's input: its command, file, pattern or address.
    static func summary(of input: [String: Any]) -> String {
        for key in ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description"] {
            if let value = input[key] as? String, !value.isEmpty {
                let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
                return line.count > 200 ? String(line.prefix(200)) + "…" : line
            }
        }
        return ""
    }

    /// What allowing a refused tool allows: the browser (a whole MCP
    /// server), commands that start the same way ("Bash(npm:*)"), or the tool.
    static func rule(for tool: String, input: [String: Any]) -> String {
        if tool.hasPrefix("mcp__"), let server = tool.dropFirst(5).components(separatedBy: "__").first, !server.isEmpty {
            return "mcp__" + server
        }
        if tool == "Bash", let command = input["command"] as? String,
           let program = command.split(whereSeparator: \.isWhitespace).first {
            return "Bash(\(program):*)"
        }
        return tool
    }

    static func ruleTitle(_ rule: String) -> String {
        if rule == browserServer { return "Browser-Steuerung" }
        if rule.hasPrefix("Bash("), rule.hasSuffix(":*)") {
            return "„\(rule.dropFirst(5).dropLast(3))“-Befehle"
        }
        return title(rule)
    }
}

/// Where claude is, and the PATH of your login shell: an app started from
/// the Dock gets a bare PATH without Homebrew, nvm or ~/.local/bin, where
/// claude and npx (for the browser's MCP server) usually live. Looked up
/// once, in the background.
enum AgentEnvironment {
    struct Resolved: Sendable {
        var claude: String?
        var variables: [String: String]
    }

    @MainActor private static var cached: Resolved?
    /// The self-test's stand-in for claude.
    @MainActor static var stub: Resolved?

    @MainActor static func resolved() async -> Resolved {
        if let stub { return stub }
        if let cached { return cached }
        let found = await Task.detached { AgentEnvironment.lookUp() }.value
        cached = found
        return found
    }

    /// Looks again next time (claude was just installed).
    @MainActor static func forget() {
        cached = nil
    }

    nonisolated static func lookUp() -> Resolved {
        var variables = ProcessInfo.processInfo.environment
        // OpenArch started from Claude Code (while working on it): a claude
        // inside would refuse to run.
        variables["CLAUDECODE"] = nil
        variables["CLAUDE_CODE_ENTRYPOINT"] = nil
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shell = variables["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let marker = "__OPENARCH_AGENT__"
        var claude: String?
        if let output = run(shell, ["-i", "-l", "-c", "echo \(marker); /usr/bin/printenv PATH; command -v claude"]),
           let range = output.range(of: marker + "\n") {
            let lines = output[range.upperBound...].split(separator: "\n").map(String.init)
            if let path = lines.first, path.contains("/") {
                variables["PATH"] = path
            }
            // An alias (as the old installer made one) is not a path.
            claude = lines.dropFirst().first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        } else {
            variables["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (variables["PATH"] ?? "/usr/bin:/bin")
        }
        if claude == nil {
            claude = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return Resolved(claude: claude, variables: variables)
    }

    /// Runs a command and returns what it printed, or nil after |timeout|
    /// seconds (a shell setup that waits for input).
    private nonisolated static func run(_ executable: String, _ arguments: [String], timeout: Double = 10) -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-shell-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        // A file, not a pipe: a chatty shell setup cannot fill it up and stall.
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return try? String(contentsOf: file, encoding: .utf8)
    }
}

/// One run of `claude -p`: the prompt goes in on stdin, the answer comes
/// back line by line on its own threads. Unchecked Sendable: the process is
/// set up before it starts; afterwards only those threads and stop() use it,
/// and the error output is behind a lock.
final class AgentProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var errorTail = Data()
    private let exited = DispatchSemaphore(value: 0)
    private let outputDone = DispatchSemaphore(value: 0)
    private let errorsDone = DispatchSemaphore(value: 0)

    init(executable: String, arguments: [String], folder: URL, environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
    }

    /// |onLine| gets each line of output in order; |onExit| comes after the
    /// last one, with the exit status and the end of the error output.
    func start(prompt: String, onLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        // The prompt from a file: a pipe could fill up before claude reads it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("openarch-prompt-\(UUID().uuidString).txt")
        try Data(prompt.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        process.standardInput = try FileHandle(forReadingFrom: file)
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()

        Thread.detachNewThread { [self] in
            let handle = output.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            outputDone.signal()
        }
        Thread.detachNewThread { [self] in
            let handle = errors.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                errorTail.append(chunk)
                if errorTail.count > 8000 { errorTail = errorTail.suffix(8000) }
                lock.unlock()
            }
            errorsDone.signal()
        }
        Thread.detachNewThread { [self] in
            exited.wait()
            // Something claude started may keep its output open; that is not
            // waited for long.
            _ = outputDone.wait(timeout: .now() + 3)
            _ = errorsDone.wait(timeout: .now() + 1)
            lock.lock()
            let tail = String(decoding: errorTail, as: UTF8.self)
            lock.unlock()
            onExit(process.terminationStatus, tail)
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }
}
