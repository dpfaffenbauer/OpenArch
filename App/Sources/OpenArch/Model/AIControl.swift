import Foundation

/// AI control: opening Chrome's DevTools protocol on localhost so an
/// external agent (Claude Code with chrome-devtools-mcp, Playwright,
/// Puppeteer) can drive the real browser. WebKit has no DevTools
/// protocol, so external control is unavailable; the browser's own
/// agent tools (BrowserTools) keep working in-app.
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

    /// The port to open at launch: always 0 (no DevTools protocol on
    /// WebKit). Stored settings stay readable for an older value.
    static var port: Int { 0 }

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
