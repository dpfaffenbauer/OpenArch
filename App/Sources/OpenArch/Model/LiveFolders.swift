import Foundation
import OpenArchCore

/// What fills a live folder: a GitHub search for pull requests or issues.
struct LiveSource: Codable, Equatable {
    enum Kind: String, Codable {
        case pullRequests, issues
    }

    var kind: Kind
    /// A GitHub search, as typed on github.com ("is:pr is:open author:@me").
    var query: String

    static let myPullRequests = LiveSource(kind: .pullRequests, query: "is:pr is:open author:@me archived:false")
    static let reviewRequests = LiveSource(kind: .pullRequests, query: "is:pr is:open review-requested:@me archived:false")
    static let myIssues = LiveSource(kind: .issues, query: "is:issue is:open assignee:@me archived:false")

    var searchURL: URL {
        var components = URLComponents(string: "https://github.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query),
                                 URLQueryItem(name: "type", value: kind == .pullRequests ? "pullrequests" : "issues")]
        return components.url!
    }
}

/// How the last refresh of a live folder went.
enum LiveStatus: Equatable {
    case loading, signedOut, failed
}

/// GitHub live folders, like Arc's: pinned folders that fill themselves with
/// open pull requests or issues. GitHub is asked with the space's own login
/// (its cookies), so no token is needed; signed out, the folder says so.
@MainActor
final class LiveFolders {
    static let shared = LiveFolders()
    private weak var library: Library?
    private var timer: Timer?

    /// Refreshes every live folder now and then every five minutes.
    func start(_ library: Library) {
        self.library = library
        refreshAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { LiveFolders.shared.refreshAll() }
        }
    }

    func refreshAll() {
        guard let library else { return }
        for space in library.spaces {
            for folder in space.pinned.allItems where folder.live != nil {
                refresh(folder)
            }
        }
    }

    func refresh(_ folder: Item) {
        guard let library, let source = folder.live, let space = library.space(containing: folder) else { return }
        let profile = library.profile(id: space.profileID).chromium
        if folder.children.isEmpty { folder.liveStatus = .loading }
        Task {
            let headers = ["Accept": "application/json", "X-Requested-With": "XMLHttpRequest"]
            let (data, status) = await ChromiumFetch.get(source.searchURL, profile: profile, headers: headers)
            guard let data, status == 200, let result = Self.results(from: data, kind: source.kind) else {
                folder.liveStatus = .failed
                return
            }
            guard result.signedIn else {
                folder.liveStatus = .signedOut
                return
            }
            folder.liveStatus = nil
            Self.apply(result.entries, to: folder)
            library.setNeedsSave()
        }
    }

    struct Entry: Equatable {
        let url: String
        let title: String
    }

    /// GitHub's search page as JSON (what github.com itself loads): the
    /// results, and whether the request was signed in.
    nonisolated static func results(from data: Data, kind: LiveSource.Kind) -> (entries: [Entry], signedIn: Bool)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let route = payload["blackbirdSearchRoute"] as? [String: Any],
              let results = route["results"] as? [[String: Any]] else { return nil }
        let path = kind == .pullRequests ? "pull" : "issues"
        let entries = results.compactMap { result -> Entry? in
            guard let number = result["number"] as? Int,
                  let repo = (result["repo"] as? [String: Any])?["repository"] as? [String: Any],
                  let owner = repo["owner_login"] as? String, let name = repo["name"] as? String else { return nil }
            let title = plainText(result["hl_title"] as? String ?? "")
            return Entry(url: "https://github.com/\(owner)/\(name)/\(path)/\(number)",
                         title: title.isEmpty ? "\(name)#\(number)" : title)
        }
        return (entries, route["logged_in"] as? Bool ?? true)
    }

    /// The folder's new tabs, in GitHub's order. Tabs already there stay the
    /// same items (with their pages); a closed or merged one goes, unless its
    /// page is open right now.
    static func apply(_ entries: [Entry], to folder: Item) {
        var existing: [String: Item] = [:]
        for child in folder.children where child.kind == .tab && existing[child.savedURL] == nil {
            existing[child.savedURL] = child
        }
        var children = entries.map { entry -> Item in
            if let item = existing.removeValue(forKey: entry.url) {
                item.savedTitle = entry.title
                return item
            }
            return Item.tab(url: entry.url, title: entry.title)
        }
        children += folder.children.filter { child in child.pane != nil && !children.contains { $0 === child } }
        folder.replaceChildren(with: children)
    }

    /// hl_title marks the search terms with <em> and escapes HTML.
    nonisolated static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}
