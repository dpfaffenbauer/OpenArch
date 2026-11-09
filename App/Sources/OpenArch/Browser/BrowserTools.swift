import AppKit
import Network
import OpenArchCore

/// OpenArch's own browser tools for page chats (⌘E): a small MCP server
/// (Streamable HTTP, JSON answers) on 127.0.0.1. Every chat gets an address
/// with a secret token of its own, which only its claude runs learn, and
/// the tools act on the tabs of that chat's space: list and read them,
/// open addresses, click, type, go back. Unlike AI control, no DevTools
/// port opens for other programs and nothing needs Node.
///
/// Reading, looking and scrolling are allowed in every chat (`readingTools`). Everything else is
/// refused until the chat allows "Browser-Steuerung" once.
@MainActor
final class BrowserTools {
    static let shared = BrowserTools()
    nonisolated static let server = "openarch_tabs"
    /// Tools that only read, allowed without asking.
    nonisolated static let readingTools = ["list_tabs", "read_page", "screenshot", "scroll"].map { "mcp__\(server)__\($0)" }

    private var listener: NWListener?
    private(set) var port: UInt16?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var failed = false
    /// Token → the chat's tab.
    private var grants: [String: WeakItem] = [:]

    private final class WeakItem {
        weak var item: Item?
        init(_ item: Item) { self.item = item }
    }

    // MARK: Chats

    /// For a page chat's run: the MCP config that gives it the tools, or nil
    /// while the server is not up.
    func mcpConfig(for tab: Item) -> String? {
        guard let port else { return nil }
        let token: String
        if let known = grants.first(where: { $0.value.item === tab })?.key {
            token = known
        } else {
            token = Self.newToken()
            grants[token] = WeakItem(tab)
        }
        let config: [String: Any] = ["mcpServers": [Self.server: ["type": "http", "url": "http://127.0.0.1:\(port)/mcp/\(token)"]]]
        return (try? JSONSerialization.data(withJSONObject: config)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The chat of |tab| is gone: its address stops working.
    func revoke(_ tab: Item) {
        grants = grants.filter { $0.value.item != nil && $0.value.item !== tab }
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Server

    /// Starts the server once; returns when it listens (or could not).
    func start() async {
        guard port == nil, !failed else { return }
        if listener == nil { listen() }
        guard port == nil, !failed else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func listen() {
        let parameters = NWParameters.tcp
        // Only this Mac can reach it.
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters, on: .any) else {
            failed = true
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .ready:
                    BrowserTools.shared.port = listener.port?.rawValue
                    BrowserTools.shared.resumeWaiting()
                case .failed, .cancelled:
                    BrowserTools.shared.failed = true
                    BrowserTools.shared.listener = nil
                    BrowserTools.shared.resumeWaiting()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { BrowserTools.shared.accept(connection) }
        }
        listener.start(queue: .main)
    }

    private func resumeWaiting() {
        let waiting = self.waiting
        self.waiting = []
        waiting.forEach { $0.resume() }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    Task { await BrowserTools.shared.handle(request, on: connection) }
                } else if isComplete || error != nil || buffer.count > 4 << 20 {
                    connection.cancel()
                } else {
                    BrowserTools.shared.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        let parts = request.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "mcp", let grant = grants[String(parts[1])], let tab = grant.item else {
            return send(status: 401, on: connection)
        }
        switch request.method {
        case "POST":
            guard let body = try? JSONSerialization.jsonObject(with: request.body) else {
                return send(status: 400, json: Self.error(nil, code: -32700, "Parse error"), on: connection)
            }
            if let batch = body as? [[String: Any]] {
                var answers: [[String: Any]] = []
                for message in batch {
                    if let answer = await answer(message, tab: tab) { answers.append(answer) }
                }
                answers.isEmpty ? send(status: 202, on: connection) : send(status: 200, json: answers, on: connection)
            } else if let message = body as? [String: Any], let answer = await answer(message, tab: tab) {
                send(status: 200, json: answer, on: connection)
            } else {
                send(status: 202, on: connection)
            }
        case "DELETE":
            send(status: 200, on: connection)
        default:
            // No stream of its own: everything comes back with the request.
            send(status: 405, on: connection)
        }
    }

    private func send(status: Int, json: Any? = nil, on connection: NWConnection) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 405: "Method Not Allowed"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        if status == 405 { head += "Allow: POST, DELETE\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: MCP

    private func answer(_ message: [String: Any], tab: Item) async -> [String: Any]? {
        // Notifications and the client's own answers get none.
        guard let method = message["method"] as? String, let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return Self.result(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "openarch", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"],
                "instructions": "The tabs of the user's OpenArch browser, signed in as the user. read_page numbers the links, buttons and fields of a page; click and type use those numbers.",
            ])
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if name == "screenshot" {
                let (content, isError) = await screenshot(arguments, chatTab: tab)
                return Self.result(id, ["content": content, "isError": isError])
            }
            let (text, isError) = await call(name, arguments, chatTab: tab)
            return Self.result(id, ["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return Self.error(id, code: -32601, "Method not found: \(method)")
        }
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(_ id: Any?, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static let tabParameter: [String: Any] = [
        "type": "string", "description": "A tab's id from list_tabs. Without it, the page the chat is about.",
    ]

    static let tools: [[String: Any]] = [
        tool("list_tabs", "Lists the tabs of the user's current space: id, title, address, and which is the page this chat is about.",
             [:], [], reads: true),
        tool("read_page", "Reads a tab: its address, title, text, and its links, buttons and fields, each with a number for click and type. Read again after the page changed; the numbers are only valid until then.",
             ["tab": tabParameter], [], reads: true),
        tool("screenshot", "Takes a picture of the visible part of a tab, to see what the text does not say: layout, images, charts, what is highlighted. read_page gives the numbers for click and type.",
             ["tab": tabParameter], [], reads: true),
        tool("scroll", "Scrolls a tab, to see more of it with screenshot: a screen down or up, to the top or bottom, or to an element from read_page. Says which part of the page shows afterwards.",
             ["direction": ["type": "string", "enum": ["down", "up", "top", "bottom"], "description": "Where to scroll. Default: down."],
              "element": ["type": "integer", "description": "Scrolls this element from read_page into view instead."],
              "tab": tabParameter], [], reads: true),
        tool("open_tab", "Opens an address in a new tab next to the chat's page, in the background, and returns its id.",
             ["url": ["type": "string", "description": "The address to open."]], ["url"]),
        tool("navigate", "Opens an address in a tab.",
             ["url": ["type": "string", "description": "The address to open."], "tab": tabParameter], ["url"]),
        tool("click", "Clicks a link, button or other element of a tab, by its number from read_page, as the user would.",
             ["element": ["type": "integer", "description": "The element's number from read_page."], "tab": tabParameter], ["element"]),
        tool("type", "Types text into a field of a tab, by its number from read_page, replacing what is in it. For a menu (select), chooses the option with that text.",
             ["element": ["type": "integer", "description": "The field's number from read_page."],
              "text": ["type": "string", "description": "What to type."],
              "submit": ["type": "boolean", "description": "Presses Enter afterwards, e.g. to search."],
              "tab": tabParameter], ["element", "text"]),
        tool("go_back", "Goes back one page in a tab's history.", ["tab": tabParameter], []),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String],
                             reads: Bool = false) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required],
         "annotations": ["readOnlyHint": reads, "openWorldHint": true]]
    }

    // MARK: Tools

    private func call(_ name: String, _ arguments: [String: Any], chatTab: Item) async -> (String, Bool) {
        guard let browser = Self.window(of: chatTab) else { return ("The chat's window is closed.", true) }
        let space = Self.space(of: chatTab, in: browser.library) ?? browser.state.space
        var tab = chatTab
        if let id = arguments["tab"] as? String, !id.isEmpty {
            guard let other = Self.tabs(of: space).first(where: { Self.shortID($0) == id.lowercased() }) else {
                return ("No tab with the id \(id) in this space; list_tabs lists them.", true)
            }
            tab = other
        }
        switch name {
        case "list_tabs":
            let lines = Self.tabs(of: space).map { item in
                var line = "\(Self.shortID(item)) · \(item.displayTitle) · \(item.currentURL)"
                if item === chatTab { line += " · this chat's page" }
                if item.pane == nil { line += " · not loaded" }
                return line
            }
            return (lines.isEmpty ? "The space has no tabs." : lines.joined(separator: "\n"), false)
        case "read_page":
            guard let pane = await loadedPane(of: tab, in: browser) else { return ("The tab's page did not load.", true) }
            guard let json = await Self.evaluate(Self.snapshotScript, in: pane),
                  let page = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return ("The page did not answer.", true)
            }
            let elements = page["elements"] as? [String] ?? []
            let text = PageContent.tidied(page["text"] as? String ?? "")
            return ("""
                \(page["title"] as? String ?? "") — \(page["url"] as? String ?? "")

                Elements:
                \(elements.isEmpty ? "(none)" : elements.joined(separator: "\n"))

                Text:
                \(text.isEmpty ? "(none)" : text)
                """, false)
        case "open_tab", "navigate":
            guard let url = arguments["url"] as? String, !url.isEmpty else { return ("An address is missing.", true) }
            if name == "open_tab" {
                tab = browser.openInNewTab(url, after: chatTab, select: false)
                browser.loadInBackground(tab)
            } else if let pane = tab.pane {
                pane.loadURL(InternalURL.resolve(url))
            } else {
                tab.liveURL = InternalURL.resolve(url)
                browser.loadInBackground(tab)
            }
            try? await Task.sleep(for: .milliseconds(400))
            _ = await loadedPane(of: tab, in: browser)
            return ("Opened. \(Self.describe(tab))", false)
        case "click", "type":
            guard let element = arguments["element"] as? Int else { return ("The element's number is missing.", true) }
            guard let pane = await loadedPane(of: tab, in: browser) else { return ("The tab's page did not load.", true) }
            let text = arguments["text"] as? String ?? ""
            let script = name == "click" ? Self.locateScript(element) : Self.focusScript(element, text: text)
            guard let json = await Self.evaluate(script, in: pane),
                  let found = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return ("The page did not answer.", true)
            }
            if found["missing"] as? Bool == true {
                return ("There is no element \(element) (any more). Read the page again with read_page.", true)
            }
            let label = found["label"] as? String ?? ""
            if name == "click" {
                let x = found["x"] as? Double ?? 0, y = found["y"] as? Double ?? 0
                if found["clicked"] as? Bool != true {
                    for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
                        _ = await Self.devTools("Input.dispatchMouseEvent", ["type": type, "x": x, "y": y, "button": "left",
                                                                            "buttons": type == "mousePressed" ? 1 : 0,
                                                                            "clickCount": 1], in: pane)
                    }
                }
            } else if found["chose"] == nil {
                _ = await Self.devTools("Input.insertText", ["text": text], in: pane)
            }
            if name == "type", arguments["submit"] as? Bool == true {
                for type in ["keyDown", "keyUp"] {
                    var key: [String: Any] = ["type": type, "key": "Enter", "code": "Enter",
                                              "windowsVirtualKeyCode": 13, "nativeVirtualKeyCode": 13]
                    if type == "keyDown" { key["text"] = "\r" }
                    _ = await Self.devTools("Input.dispatchKeyEvent", key, in: pane)
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
            _ = await loadedPane(of: tab, in: browser)
            let what = label.isEmpty ? "element \(element)" : "„\(label)“"
            return ("\(name == "click" ? "Clicked" : "Typed into") \(what). \(Self.describe(tab))", false)
        case "scroll":
            guard let pane = await loadedPane(of: tab, in: browser) else { return ("The tab's page did not load.", true) }
            let direction = arguments["direction"] as? String ?? "down"
            if let element = arguments["element"] as? Int {
                guard let json = await Self.evaluate(Self.locateScript(element, click: false), in: pane),
                      let found = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                      found["missing"] as? Bool != true else {
                    return ("There is no element \(element) (any more). Read the page again with read_page.", true)
                }
            } else if direction == "top" || direction == "bottom" {
                _ = await Self.evaluate("(() => { const s = document.scrollingElement || document.body; s.scrollTo({ top: \(direction == "top" ? "0" : "s.scrollHeight"), behavior: 'instant' }); return ''; })()", in: pane)
            } else {
                // A real wheel in the middle of the page, so a scrolling box
                // under it scrolls too, as for a person.
                let size = await Self.evaluate("JSON.stringify([innerWidth, innerHeight])", in: pane)
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Double] } ?? [800, 600]
                let width = size.first ?? 800, height = size.last ?? 600
                _ = await Self.devTools("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": width / 2, "y": height / 2,
                                                                    "deltaX": 0, "deltaY": (direction == "up" ? -0.8 : 0.8) * height], in: pane)
            }
            try? await Task.sleep(for: .milliseconds(350))
            return (await Self.evaluate(Self.positionScript, in: pane) ?? "Scrolled.", false)
        case "go_back":
            guard let pane = tab.pane else { return ("The tab has no page.", true) }
            pane.goBack()
            try? await Task.sleep(for: .milliseconds(400))
            _ = await loadedPane(of: tab, in: browser)
            return ("Went back. \(Self.describe(tab))", false)
        default:
            return ("No tool \(name).", true)
        }
    }

    /// A picture of the visible part of a tab, at most 1280 pixels wide.
    private func screenshot(_ arguments: [String: Any], chatTab: Item) async -> ([[String: Any]], Bool) {
        func text(_ message: String) -> ([[String: Any]], Bool) { ([["type": "text", "text": message]], true) }
        guard let browser = Self.window(of: chatTab) else { return text("The chat's window is closed.") }
        var tab = chatTab
        if let id = arguments["tab"] as? String, !id.isEmpty {
            let space = Self.space(of: chatTab, in: browser.library) ?? browser.state.space
            guard let other = Self.tabs(of: space).first(where: { Self.shortID($0) == id.lowercased() }) else {
                return text("No tab with the id \(id) in this space; list_tabs lists them.")
            }
            tab = other
        }
        guard let pane = await loadedPane(of: tab, in: browser) else { return text("The tab's page did not load.") }
        let shot = await Self.devTools("Page.captureScreenshot", ["format": "jpeg", "quality": 80], in: pane, timeout: 8)
        guard let data = shot?["data"] as? String, let image = Self.shrunk(data) else {
            return text("The tab gave no picture. A tab that is not on screen may not draw; read_page reads it anyway.")
        }
        return ([["type": "image", "data": image, "mimeType": "image/jpeg"],
                 ["type": "text", "text": "\(tab.displayTitle) — \(tab.currentURL)"]], false)
    }

    /// A JPEG (base64) at most |width| pixels wide, as base64 JPEG again.
    static func shrunk(_ base64: String, width: CGFloat = 1280) -> String? {
        guard let data = Data(base64Encoded: base64), let source = NSBitmapImageRep(data: data), source.pixelsWide > 0 else { return nil }
        let scale = min(1, width / CGFloat(source.pixelsWide))
        guard scale < 1 else { return base64 }
        let size = NSSize(width: (CGFloat(source.pixelsWide) * scale).rounded(), height: (CGFloat(source.pixelsHigh) * scale).rounded())
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return target.representation(using: .jpeg, properties: [.compressionFactor: 0.75])?.base64EncodedString()
    }

    /// |tab|'s page, loaded in the background first if it has none, and
    /// waited for while it loads (up to 15 seconds).
    private func loadedPane(of tab: Item, in browser: BrowserWindowController) async -> (any OACPage)? {
        if tab.pane == nil { browser.loadInBackground(tab) }
        for _ in 0..<60 {
            if let pane = tab.pane, pane.isLoaded, !tab.isLoading { return pane }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return tab.pane
    }

    private static func describe(_ tab: Item) -> String {
        "The tab now shows: \(tab.displayTitle) — \(tab.currentURL)"
    }

    /// A tab's id for the tools: the start of its UUID.
    static func shortID(_ item: Item) -> String {
        String(item.id.uuidString.lowercased().prefix(8))
    }

    private static func tabs(of space: Space) -> [Item] {
        space.pinned.allTabs + space.today.allTabs
    }

    private static func space(of tab: Item, in library: Library) -> Space? {
        library.spaces.first { space in tabs(of: space).contains { $0 === tab } }
    }

    /// The window to act in: the one showing |tab|, else one on its space.
    private static func window(of tab: Item) -> BrowserWindowController? {
        guard let app = NSApp.delegate as? AppDelegate else { return nil }
        let windows = app.browsers.filter { !$0.isPrivate }
        return windows.first { $0.visibleTabs.contains { $0 === tab } }
            ?? windows.first { tabs(of: $0.state.space).contains { $0 === tab } }
            ?? windows.first
    }

    // MARK: Pages

    private static func evaluate(_ expression: String, in pane: any OACPage) async -> String? {
        let result = await devTools("Runtime.evaluate", ["expression": expression, "returnByValue": true], in: pane)
        return (result?["result"] as? [String: Any])?["value"] as? String
    }

    private static func devTools(_ method: String, _ params: [String: Any], in pane: any OACPage,
                                 timeout: Double = 5) async -> [String: Any]? {
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            let once = Once(continuation)
            pane.callDevToolsMethod(method, params: params) { result in
                let answer = Answer(result)
                MainActor.assumeIsolated { once.resume(answer) }
            }
            after(timeout) { once.resume(Answer(nil)) }
        }
        return answer.value
    }

    /// A DevTools answer, handed from Chromium's callback to the caller.
    private final class Answer: @unchecked Sendable {
        let value: [String: Any]?
        init(_ value: [String: Any]?) { self.value = value }
    }

    @MainActor
    private final class Once {
        private var continuation: CheckedContinuation<Answer, Never>?
        init(_ continuation: CheckedContinuation<Answer, Never>) { self.continuation = continuation }
        func resume(_ value: Answer) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    /// Numbers the page's visible links, buttons and fields (in
    /// data-openarch-ref) and lists them, with the page's text.
    static let snapshotScript = """
        (() => {
          for (const old of document.querySelectorAll('[data-openarch-ref]')) old.removeAttribute('data-openarch-ref');
          const selector = 'a[href], button, input:not([type=hidden]), textarea, select, summary, [role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], [role=option], [role=switch], [role=combobox], [role=textbox], [contenteditable=""], [contenteditable=true], [onclick]';
          const clean = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const lines = [];
          let n = 0;
          for (const el of document.querySelectorAll(selector)) {
            const r = el.getBoundingClientRect();
            const style = getComputedStyle(el);
            if ((r.width === 0 && r.height === 0) || style.visibility === 'hidden' || style.display === 'none') continue;
            n += 1;
            el.setAttribute('data-openarch-ref', String(n));
            const tag = el.tagName.toLowerCase();
            const role = el.getAttribute('role') || (tag === 'a' ? 'link' : tag === 'textarea' ? 'text field'
              : tag === 'select' ? 'menu' : tag === 'summary' ? 'disclosure'
              : tag === 'input' ? ((['button', 'submit', 'reset', 'checkbox', 'radio'].includes(el.type) ? el.type : (el.type || 'text') + ' field'))
              : el.isContentEditable ? 'text field' : 'button');
            const image = el.querySelector && el.querySelector('img[alt]');
            const label = clean(el.getAttribute('aria-label') || (tag === 'input' || tag === 'textarea' ? '' : el.innerText)
              || (el.labels && el.labels[0] && el.labels[0].innerText) || el.placeholder || el.title || el.alt || (image && image.alt)
              || (tag === 'input' && ['button', 'submit'].includes(el.type) ? el.value : '')).slice(0, 100);
            let line = '[' + n + '] ' + role + (label ? ' "' + label + '"' : '');
            if (tag === 'a') line += ' -> ' + el.href.slice(0, 200);
            if ((tag === 'input' || tag === 'textarea') && el.type !== 'password' && el.value && !['button', 'submit'].includes(el.type)) line += ' = "' + clean(el.value).slice(0, 80) + '"';
            if (el.type === 'checkbox' || el.type === 'radio') line += el.checked ? ' (checked)' : ' (not checked)';
            if (tag === 'select' && el.selectedOptions[0]) line += ' = "' + clean(el.selectedOptions[0].text).slice(0, 60) + '"';
            if (el.disabled) line += ' (disabled)';
            lines.push(line);
            if (n >= 400) break;
          }
          const main = document.querySelector('article, main, [role=main]');
          const body = document.body ? document.body.innerText : '';
          const text = main && main.innerText.trim().length > 500 ? main.innerText : body;
          return JSON.stringify({ url: location.href, title: document.title, text: (text || '').slice(0, 40000), elements: lines });
        })()
        """

    /// Brings element |number| into view and says where its middle is,
    /// for a real mouse click there. One without a box is clicked directly.
    static func locateScript(_ number: Int, click: Bool = true) -> String {
        """
        (() => {
          const el = document.querySelector('[data-openarch-ref="\(number)"]');
          if (!el) return JSON.stringify({ missing: true });
          el.scrollIntoView({ block: 'center', inline: 'center' });
          const r = el.getBoundingClientRect();
          const label = String(el.getAttribute('aria-label') || el.innerText || el.value || el.title || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
          if (\(click ? "true" : "false") && (r.width === 0 || r.height === 0)) { el.click(); return JSON.stringify({ clicked: true, label }); }
          return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2, label });
        })()
        """
    }

    /// Which part of the page shows, for after scrolling.
    static let positionScript = """
        (() => {
          const s = document.scrollingElement || document.body;
          const top = Math.round(s.scrollTop), height = Math.round(s.scrollHeight), view = innerHeight;
          const where = top <= 0 ? 'the top' : top + view >= height - 2 ? 'the bottom' : Math.round(100 * top / Math.max(1, height - view)) + ' %';
          return 'Scrolled. The page shows ' + top + '–' + Math.min(height, top + view) + ' of ' + height + ' pixels (' + where + ').';
        })()
        """

    /// Focuses field |number| and selects what is in it, so typing
    /// replaces it; a menu (select) chooses the option named |text| here.
    static func focusScript(_ number: Int, text: String) -> String {
        let quoted = (try? JSONSerialization.data(withJSONObject: [text])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return """
        (() => {
          const el = document.querySelector('[data-openarch-ref="\(number)"]');
          if (!el) return JSON.stringify({ missing: true });
          const text = \(quoted)[0];
          el.scrollIntoView({ block: 'center' });
          const label = String(el.getAttribute('aria-label') || el.placeholder || el.name || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
          if (el.tagName === 'SELECT') {
            const option = [...el.options].find(o => o.text.trim() === text.trim() || o.value === text);
            if (option) { el.value = option.value; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); }
            return JSON.stringify({ chose: !!option, label });
          }
          el.focus();
          if (typeof el.select === 'function') el.select();
          else if (el.isContentEditable) { const range = document.createRange(); range.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(range); }
          return JSON.stringify({ label });
        })()
        """
    }
}

/// One HTTP request, once all of it has arrived.
private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = head.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var length = 0
        for line in head.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? "")
        self.body = Data(body.prefix(length))
    }
}
