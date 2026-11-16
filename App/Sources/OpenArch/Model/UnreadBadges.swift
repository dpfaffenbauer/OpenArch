import Foundation

/// Sites that count what is unread in their page title, like Arc's: Gmail
/// ("Posteingang (3) - …"), X ("(2) Home / X"), WhatsApp, Slack ("* Slack |
/// …" or "! Slack | …"), Outlook, LinkedIn. Their favorites and pinned tabs
/// get a dot while the count is there. Other sites are left alone: "(2024)"
/// in a film's title is not a count.
enum UnreadBadges {
    static let hosts: Set<String> = [
        "mail.google.com", "app.slack.com", "x.com", "twitter.com", "web.whatsapp.com",
        "linkedin.com", "outlook.office.com", "outlook.office365.com", "outlook.live.com",
        "web.telegram.org", "discord.com", "teams.microsoft.com", "messenger.com", "chat.google.com",
    ]

    /// Whether |url|'s site reports unread items in its title.
    static func countsUnread(_ url: String) -> Bool {
        guard var host = URL(string: url)?.host()?.lowercased() else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return hosts.contains(host)
    }

    /// How many unread items |title| reports: "(3)", "(99+)"; Slack's
    /// leading "*" or "!" counts as one. nil when it reports none.
    static func count(inTitle title: String) -> Int? {
        let text = title.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"\((\d+)\+?\)"#, options: .regularExpression),
           let count = Int(text[range].filter(\.isNumber)), count > 0 {
            return count
        }
        if text.hasPrefix("* ") || text.hasPrefix("! ") { return 1 }
        return nil
    }

    /// Google Calendar: its favicon shows today's date, also while the tab
    /// is not loaded (the saved icon would show the day it was saved).
    static func isCalendar(_ url: String) -> Bool {
        URL(string: url)?.host()?.lowercased() == "calendar.google.com"
    }
}

extension Item {
    /// The unread count its open page reports in the title, for favorites
    /// and pinned tabs of sites that do (UnreadBadges). A tab that is not
    /// loaded reports nothing: its saved title is old news.
    var unreadCount: Int? {
        guard kind == .tab, role != .today, let liveTitle, UnreadBadges.countsUnread(currentURL) else { return nil }
        return UnreadBadges.count(inTitle: liveTitle)
    }
}
