import Foundation

/// One headless run of `claude -p` for OpenArch's own jobs (the morning
/// brief, tidying tabs): a prompt goes in, the answer comes back as text.
/// Like agent chats it runs on your own login (AgentEnvironment,
/// AgentProcess), in a folder of OpenArch's.
@MainActor
enum ClaudeRun {
    struct Outcome: Sendable {
        /// The answer.
        var text = ""
        /// What went wrong, in Claude Code's words or ours.
        var error: String?
        /// claude is not on this Mac.
        var isMissing = false
        /// claude is there but not signed in.
        var needsLogin = false
        /// The tools Claude Code offered (its init event), MCP servers' included.
        var tools: [String] = []

        var succeeded: Bool { error == nil && !isMissing }
    }

    /// Runs |prompt| in |folder|. With |untilInit|, claude is stopped as
    /// soon as it says which tools it has, before it asks the model anything.
    static func run(_ prompt: String, in folder: URL, arguments: [String] = [], untilInit: Bool = false,
                    timeout: Double = 600) async -> Outcome {
        let environment = await AgentEnvironment.resolved()
        guard let claude = environment.claude else { return Outcome(isMissing: true) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = AgentProcess(executable: claude,
                                   arguments: ["-p", "--output-format", "stream-json", "--verbose"] + arguments,
                                   folder: folder, environment: environment.variables)
        let answer = Answer()
        return await withCheckedContinuation { continuation in
            do {
                try process.start(prompt: prompt, onLine: { line in
                    if answer.take(line), untilInit { process.stop() }
                }, onExit: { status, errors in
                    continuation.resume(returning: answer.outcome(status: status, errors: errors, untilInit: untilInit))
                })
            } catch {
                continuation.resume(returning: Outcome(error: "Claude Code ließ sich nicht starten: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                answer.timedOut(after: timeout)
                process.stop()
            }
        }
    }

    /// Words in an error that mean claude wants a login.
    nonisolated static func needsLogin(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["/login", "log in", "logged in", "login", "invalid api key", "api key", "authenticat", "oauth", "unauthorized"]
            .contains { lower.contains($0) }
    }
}

/// What claude says, gathered on its output thread.
private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String] = []
    private var sawInit = false
    private var result: String?
    private var resultIsError = false
    private var lastText = ""
    private var timeout: Double?

    /// Takes one line of stream-json; true once the init event was seen.
    func take(_ line: String) -> Bool {
        guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return lock.withLock { sawInit }
        }
        return lock.withLock {
            switch event["type"] as? String {
            case "system" where event["subtype"] as? String == "init":
                tools = event["tools"] as? [String] ?? []
                sawInit = true
            case "assistant":
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !text.isEmpty { lastText = text }
            case "result":
                result = event["result"] as? String ?? ""
                resultIsError = event["is_error"] as? Bool ?? false
            default:
                break
            }
            return sawInit
        }
    }

    func timedOut(after seconds: Double) {
        lock.withLock { if result == nil { timeout = seconds } }
    }

    func outcome(status: Int32, errors: String, untilInit: Bool) -> ClaudeRun.Outcome {
        lock.withLock {
            var outcome = ClaudeRun.Outcome(tools: tools)
            let errors = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            if untilInit, sawInit { return outcome }
            if let result, !resultIsError {
                outcome.text = result.isEmpty ? lastText : result
                return outcome
            }
            if let timeout {
                outcome.error = "Claude Code hat nach \(Int(timeout / 60)) Minuten nicht geantwortet."
                return outcome
            }
            var message = (result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty { message = errors }
            if message.isEmpty { message = lastText }
            if message.isEmpty { message = "Claude Code hat sich beendet (Status \(status))." }
            if message.contains("unknown option") { message += "\n\nEine neuere Version von Claude Code hilft: claude update" }
            outcome.error = message
            outcome.needsLogin = ClaudeRun.needsLogin(message)
            return outcome
        }
    }
}
