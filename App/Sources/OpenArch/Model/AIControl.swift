import Foundation

/// AI control: OpenArch opens Chrome's DevTools protocol on localhost so an
/// agent (Claude Code with chrome-devtools-mcp, Playwright, Puppeteer) can
/// drive the real browser. Off by default: any program on this Mac could
/// then control the browser, including logged-in tabs.
enum AIControl {
    private static let enabledKey = "aiControlEnabled"
    private static let portKey = "aiControlPort"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var configuredPort: Int {
        get {
            let port = UserDefaults.standard.integer(forKey: portKey)
            return port > 0 ? port : 9222
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// The port to open at launch, 0 when AI control is off.
    static var port: Int {
        isEnabled ? configuredPort : 0
    }

    /// For Claude Code: adds Google's DevTools MCP server, pointed at
    /// OpenArch.
    static func claudeCommand(port: Int) -> String {
        "claude mcp add openarch -- npx -y chrome-devtools-mcp@latest --browser-url=http://127.0.0.1:\(port)"
    }

    /// The same server for one run of claude (`--mcp-config`): agent chats
    /// in the sidebar get it while AI control is on.
    static func mcpConfig(port: Int) -> String {
        #"{"mcpServers":{"openarch":{"command":"npx","args":["-y","chrome-devtools-mcp@latest","--browser-url=http://127.0.0.1:\#(port)"]}}}"#
    }
}
