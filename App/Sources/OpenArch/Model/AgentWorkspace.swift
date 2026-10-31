import Foundation

/// The folder an agent works in, as git sees it: repository, branch and the
/// files changed since the last commit. Read with git in the background for
/// the panel beside an agent chat.
struct AgentWorkspace: Sendable, Equatable {
    struct Change: Identifiable, Sendable, Equatable {
        let path: String
        /// Lines added and removed; nil for a new file git does not track yet.
        var added: Int?
        var removed: Int?
        var isNew = false
        var id: String { path }
    }

    var isRepository = false
    /// "owner/repo" from the origin remote.
    var repository: String?
    var branch: String?
    var changes: [Change] = []

    static let git = "/usr/bin/git"

    nonisolated static func read(folder: String) -> AgentWorkspace {
        var workspace = AgentWorkspace()
        guard let branch = run(folder, ["rev-parse", "--abbrev-ref", "HEAD"]) else { return workspace }
        workspace.isRepository = true
        workspace.branch = branch
        workspace.repository = run(folder, ["remote", "get-url", "origin"]).flatMap(repositoryName)
        var changes: [String: Change] = [:]
        for line in (run(folder, ["diff", "--numstat", "HEAD"]) ?? "").split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            let path = String(fields[2])
            // Binary files count "-".
            changes[path] = Change(path: path, added: Int(fields[0]), removed: Int(fields[1]))
        }
        for line in (run(folder, ["status", "--porcelain", "--untracked-files=all"]) ?? "").split(separator: "\n")
        where line.hasPrefix("??") {
            let path = String(line.dropFirst(3))
            changes[path] = Change(path: path, isNew: true)
        }
        workspace.changes = changes.values.sorted { $0.path < $1.path }
        return workspace
    }

    /// The diff of one changed file, or a new file's text as added lines.
    nonisolated static func diff(folder: String, change: Change) -> String {
        if change.isNew {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(change.path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "(Binärdatei)" }
            return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(2000).map { "+" + $0 }.joined(separator: "\n")
        }
        return run(folder, ["diff", "HEAD", "--", change.path]) ?? ""
    }

    /// "owner/repo" from "git@github.com:owner/repo.git" or
    /// "https://github.com/owner/repo".
    nonisolated static func repositoryName(_ remote: String) -> String? {
        var path = remote
        if let colon = remote.range(of: ":"), !remote.contains("://") {
            path = String(remote[colon.upperBound...])
        } else if let url = URL(string: remote) {
            path = url.path
        }
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }

    /// git's output, trimmed, or nil when it failed (not a repository, no
    /// remote).
    private nonisolated static func run(_ folder: String, _ arguments: [String]) -> String? {
        guard let output = AgentEnvironment.run(git, ["-C", folder] + arguments, timeout: 10) else { return nil }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty && arguments.first != "diff" && arguments.first != "status" ? nil : text
    }
}
