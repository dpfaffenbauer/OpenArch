import Foundation

/// "new doc", "new sheet", "new ticket" … in the command bar: the first row
/// goes straight to a new document, as in Dia. Most of these are the web
/// apps' own ".new" addresses.
struct QuickCreate: Equatable {
    let title: String
    let url: String
    /// Where its icon comes from: the app's own site.
    let icon: String
    /// Words that pick it after "new" or "neu(e/es/er)".
    let keywords: [String]

    static let all: [QuickCreate] = [
        QuickCreate(title: "Neues Google-Dokument", url: "https://docs.new", icon: "https://docs.google.com",
                    keywords: ["doc", "docs", "dokument", "document", "text"]),
        QuickCreate(title: "Neue Google-Tabelle", url: "https://sheets.new", icon: "https://docs.google.com",
                    keywords: ["sheet", "sheets", "tabelle", "table", "spreadsheet"]),
        QuickCreate(title: "Neue Google-Präsentation", url: "https://slides.new", icon: "https://docs.google.com",
                    keywords: ["slide", "slides", "präsentation", "presentation", "folien", "deck"]),
        QuickCreate(title: "Neues Google-Formular", url: "https://forms.new", icon: "https://docs.google.com",
                    keywords: ["form", "forms", "formular", "umfrage"]),
        QuickCreate(title: "Neues Google Meet", url: "https://meet.new", icon: "https://meet.google.com",
                    keywords: ["meet", "meeting", "call"]),
        QuickCreate(title: "Neuer Kalendertermin", url: "https://cal.new", icon: "https://calendar.google.com",
                    keywords: ["event", "termin", "kalender", "calendar", "cal"]),
        QuickCreate(title: "Neuer GitHub-Gist", url: "https://gist.github.com/", icon: "https://gist.github.com",
                    keywords: ["gist", "snippet"]),
        QuickCreate(title: "Neues GitHub-Repository", url: "https://github.com/new", icon: "https://github.com",
                    keywords: ["repo", "repository"]),
        QuickCreate(title: "Neue Notion-Seite", url: "https://notion.new", icon: "https://www.notion.so",
                    keywords: ["notion", "page", "seite", "notiz", "note"]),
        QuickCreate(title: "Neues Linear-Issue", url: "https://linear.new", icon: "https://linear.app",
                    keywords: ["linear", "issue", "ticket"]),
        QuickCreate(title: "Neue Figma-Datei", url: "https://figma.new", icon: "https://www.figma.com",
                    keywords: ["figma", "design"]),
    ]

    /// Jira lives on the company's own site; its address comes from the
    /// history (a visited *.atlassian.net).
    static func jira(host: String) -> QuickCreate {
        QuickCreate(title: "Neues Jira-Ticket", url: "https://\(host)/secure/CreateIssue!default.jspa",
                    icon: "https://\(host)", keywords: ["jira", "ticket", "issue", "task", "aufgabe", "bug"])
    }

    /// The entries the input asks for: "new doc", "neues dokument", "new t" …
    /// Nothing for "new" alone, so typing a site that starts with "new" is
    /// left alone. |jiraHost| is asked only when the input starts with "new".
    static func matching(_ input: String, jiraHost: () -> String?) -> [QuickCreate] {
        let words = input.lowercased().split(separator: " ").map(String.init)
        guard words.count == 2, ["new", "neu", "neue", "neues", "neuer", "neuen"].contains(words[0]) else { return [] }
        let word = words[1]
        var candidates = all
        if let host = jiraHost() { candidates.insert(jira(host: host), at: 0) }
        // An exact keyword first ("ticket" → Jira before Linear), then any
        // that starts with what was typed.
        let exact = candidates.filter { $0.keywords.contains(word) }
        let prefix = candidates.filter { entry in
            !exact.contains(entry) && entry.keywords.contains { $0.hasPrefix(word) }
        }
        return exact + prefix
    }

    /// The company's Jira site among visited |urls|, if there is one.
    static func jiraHost(in urls: [String]) -> String? {
        urls.lazy.compactMap { URL(string: $0)?.host() }.first { $0.hasSuffix(".atlassian.net") }
    }
}
