import Foundation

/// One of your Claude Code skills (~/.claude/skills/<name>/SKILL.md) or
/// slash commands (~/.claude/commands/<name>.md).
struct ClaudeSkill: Identifiable, Equatable, Sendable {
    enum Kind: Sendable {
        case skill, command
    }

    let name: String
    let description: String
    let kind: Kind

    var id: String { "\(kind):\(name)" }
}

/// The skills and commands the command bar offers to run on the page.
/// Only their names and descriptions are read here; running one is left to
/// Claude Code (see BrowserWindowController.runSkill).
@MainActor
enum ClaudeSkills {
    /// Claude Code's folder: CLAUDE_CONFIG_DIR, else ~/.claude. The
    /// self-test points it elsewhere.
    static var root: URL = {
        if let folder = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: folder)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }()

    private static var cache: (root: URL, date: Date, skills: [ClaudeSkill])?

    /// All of them, read again when the last read is older than ten seconds.
    static var all: [ClaudeSkill] {
        if let cache, cache.root == root, Date().timeIntervalSince(cache.date) < 10 { return cache.skills }
        let skills = load(root: root)
        cache = (root, Date(), skills)
        return skills
    }

    /// Those whose name starts with (or, from three letters on, contains)
    /// |text|; a leading "/" is allowed, and "/" alone lists them all.
    static func matching(_ text: String) -> [ClaudeSkill] {
        var query = text.trimmingCharacters(in: .whitespaces).lowercased()
        let slash = query.hasPrefix("/")
        if slash { query.removeFirst() }
        guard (!query.isEmpty || slash), !query.contains(" ") else { return [] }
        return all
            .filter { skill in
                let name = skill.name.lowercased()
                return name.hasPrefix(query) || (query.count >= 3 && name.contains(query))
            }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.name.lowercased().hasPrefix(query), rhsPrefix = rhs.name.lowercased().hasPrefix(query)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.name < rhs.name
            }
    }

    /// The command bar's rows for |text|: run on the page in front.
    static func commandResults(_ text: String, browser: BrowserWindowController) -> [CommandResult] {
        guard !browser.isPrivate, let tab = browser.state.activeItem, tab.kind == .tab else { return [] }
        return matching(text).prefix(text.hasPrefix("/") ? 6 : 3).map { skill in
            let kind = skill.kind == .skill ? "Skill" : "Befehl"
            return CommandResult(id: "skill:\(skill.id)", icon: .symbol(skill.kind == .skill ? "wand.and.stars" : "slash.circle"),
                                 title: "/" + skill.name,
                                 subtitle: skill.description.isEmpty ? kind : "\(kind) · \(skill.description)",
                                 badge: "Auf diese Seite anwenden",
                                 action: { browser.runSkill(skill, on: tab) })
        }
    }

    // MARK: Reading

    nonisolated static func load(root: URL) -> [ClaudeSkill] {
        let files = FileManager.default
        var skills: [ClaudeSkill] = []
        let skillsFolder = root.appendingPathComponent("skills", isDirectory: true)
        for folder in (try? files.contentsOfDirectory(at: skillsFolder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [] {
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fields = frontmatter(text)
            let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent
            skills.append(ClaudeSkill(name: name, description: shortened(fields["description"] ?? ""), kind: .skill))
        }
        let commands = root.appendingPathComponent("commands", isDirectory: true)
        let walker = files.enumerator(at: commands, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let file = walker?.nextObject() as? URL {
            guard file.pathExtension == "md", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            guard !skills.contains(where: { $0.name == name }) else { continue }
            let description = frontmatter(text)["description"] ?? firstLine(of: text)
            skills.append(ClaudeSkill(name: name, description: shortened(description), kind: .command))
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// The `key: value` lines between the --- lines at the top of a
    /// Markdown file; values may be quoted or folded over several lines.
    nonisolated static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var key: String?
        var parts: [String] = []
        func flush() {
            if let key, !parts.isEmpty { fields[key] = parts.joined(separator: " ") }
            parts = []
        }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if key != nil, line.first?.isWhitespace == true {
                if !trimmed.isEmpty { parts.append(trimmed) }
                continue
            }
            flush()
            key = nil
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace == false else { continue }
            key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if ![">", "|", ">-", "|-", ">+", "|+", ""].contains(value) {
                parts = [unquoted(value)]
            }
        }
        flush()
        return fields
    }

    private nonisolated static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner
    }

    /// A command without a description: its first line of text.
    private nonisolated static func firstLine(of text: String) -> String {
        var body = text[...]
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            body = text[end.upperBound...]
        }
        return body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "---" }
            .map { $0.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private nonisolated static func shortened(_ text: String) -> String {
        text.count > 140 ? String(text.prefix(138)) + "…" : text
    }
}
