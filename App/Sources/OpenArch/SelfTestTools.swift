import AppKit
import OpenArchCore

/// OpenArch's own browser tools for page chats (BrowserTools), called over
/// HTTP as claude calls them, and how a chat shows the tools it used and
/// asks once before acting in the browser.
extension SelfTest {
    func browserToolsTest(_ stub: ClaudeStub, then next: @escaping () -> Void) {
        let shown = browser.state.activeItem
        let tab = browser.openInNewTab("https://example.com/?tools")
        func finish() {
            browser.close(tab)
            if let shown, shown.container != nil { browser.select(shown, focus: false) }
            next()
        }
        eventually({ tab.pane?.isLoaded == true && !tab.isLoading }, timeout: 15) { _ in
            tab.pane?.executeJavaScript("""
                document.body.insertAdjacentHTML('afterbegin', '<input id="openarch-q" placeholder="Suchbegriff">'
                  + '<button onclick="document.title = \\'clicked:\\' + document.getElementById(\\'openarch-q\\').value">Los</button>');
                """)
            Task { @MainActor in
                await self.checkToolServer(tab)
                self.toolRowsTest(stub, tab: tab, then: finish)
            }
        }
    }

    private func checkToolServer(_ tab: Item) async {
        await BrowserTools.shared.start()
        guard let config = BrowserTools.shared.mcpConfig(for: tab),
              let object = (try? JSONSerialization.jsonObject(with: Data(config.utf8))) as? [String: Any],
              let server = (object["mcpServers"] as? [String: Any])?[BrowserTools.server] as? [String: Any],
              let url = server["url"] as? String else {
            return expect(false, "the browser tools listen on 127.0.0.1 (port \(BrowserTools.shared.port ?? 0))")
        }
        expect(url.hasPrefix("http://127.0.0.1:") && server["type"] as? String == "http"
               && BrowserTools.shared.mcpConfig(for: tab) == config,
               "a page chat's tools have an address of their own on 127.0.0.1, the same for every run")

        let stranger = await Self.mcp(String(url.dropLast(4)) + "0000", ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        expect(stranger.status == 401, "an address without a chat's token is refused (\(stranger.status))")

        let hello = await Self.mcp(url, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                    "clientInfo": ["name": "selftest", "version": "1"]]])
        let notified = await Self.mcp(url, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        let listed = await Self.mcp(url, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((listed.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        expect(hello.status == 200 && (hello.json?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18"
               && notified.status == 202
               && names == ["list_tabs", "read_page", "screenshot", "open_tab", "navigate", "click", "type", "go_back"],
               "the tools answer MCP over HTTP: initialize, notifications, tools/list (\(names))")

        var id = 10
        func call(_ name: String, _ arguments: [String: Any] = [:]) async -> (text: String, isError: Bool) {
            id += 1
            let answer = await Self.mcp(url, ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                              "params": ["name": name, "arguments": arguments]])
            let result = answer.json?["result"] as? [String: Any]
            let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return (text, result?["isError"] as? Bool ?? true)
        }

        let tabs = await call("list_tabs")
        expect(!tabs.isError && tabs.text.contains("\(BrowserTools.shortID(tab)) · ") && tabs.text.contains("this chat's page"),
               "list_tabs lists the space's tabs with their ids and marks the chat's page")

        let page = await call("read_page")
        let field = Self.number(of: "text field \"Suchbegriff\"", in: page.text)
        let button = Self.number(of: "button \"Los\"", in: page.text)
        expect(!page.isError && page.text.contains("Example Domain") && field != nil && button != nil,
               "read_page gives the page's text and numbers its fields and buttons (\(page.text.prefix(160)))")

        id += 1
        let shot = await Self.mcp(url, ["jsonrpc": "2.0", "id": id, "method": "tools/call",
                                        "params": ["name": "screenshot", "arguments": [String: Any]()]])
        let content = (shot.json?["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let picture = (content.first?["data"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSBitmapImageRep.init(data:))
        expect(content.first?["type"] as? String == "image" && content.first?["mimeType"] as? String == "image/jpeg"
               && (picture?.pixelsWide ?? 0) > 200 && (picture?.pixelsWide ?? 0) <= 1280
               && (content.last?["text"] as? String)?.contains("example.com") == true,
               "screenshot gives Claude a picture of the page, at most 1280 pixels wide (\(picture?.pixelsWide ?? 0)×\(picture?.pixelsHigh ?? 0))")

        let typed = await call("type", ["element": field ?? 0, "text": "hallo"])
        let clicked = await call("click", ["element": button ?? 0])
        let after = await call("read_page")
        expect(!typed.isError && !clicked.isError && after.text.hasPrefix("clicked:hallo — "),
               "type and click work on the page like a person would (\(clicked.text.prefix(80)); now \(after.text.prefix(40)))")

        let gone = await call("click", ["element": 9999])
        expect(gone.isError && gone.text.contains("read_page"), "an element that is not there says to read the page again")

        let count = browser.state.space.today.allTabs.count
        let opened = await call("open_tab", ["url": "https://example.org/?tools"])
        let new = browser.state.space.today.allTabs.first { $0.currentURL.hasPrefix("https://example.org/?tools") }
        expect(!opened.isError && new != nil && browser.state.space.today.allTabs.count == count + 1
               && browser.state.activeItem === tab,
               "open_tab opens a tab in the background, next to the chat's page (\(opened.text.prefix(80)))")
        if let new { browser.close(new) }
    }

    /// A chat's tool rows: the whole command behind a long one, no wheel
    /// left turning when a run ends without the tool's answer, and the
    /// browser tools asked for once per chat.
    private func toolRowsTest(_ stub: ClaudeStub, tab: Item, then next: @escaping () -> Void) {
        let chat = browser.openPageChat(tab)
        let command = "gh api repos/openarch/test/branches \\\n  --jq '.[].name'"
        stub.answer([
            ClaudeStub.initEvent(session: "selftest-tools"),
            ClaudeStub.json(["type": "assistant", "message": ["content": [
                ["type": "tool_use", "id": "tool-1", "name": "Bash", "input": ["command": command]],
            ]]]),
            ClaudeStub.json(["type": "result", "subtype": "success", "is_error": false, "session_id": "selftest-tools",
                             "result": "Ich darf nicht klicken.",
                             "permission_denials": [["tool_name": "mcp__\(BrowserTools.server)__click", "tool_input": ["element": 3]]]]),
        ])
        chat.session.draft = "Lösch die Branches"
        browser.sendPageChat(tab)
        eventually({ !chat.isPreparing && !chat.session.isRunning && chat.session.messages.count >= 3 }, timeout: 15) { answered in
            let row = chat.session.messages.first { $0.role == .tool }
            self.expect(answered && row?.text == "gh api repos/openarch/test/branches \\" && row?.detail == command && row?.output == "",
                        "a command shows its first line and opens to the whole; one left unanswered stops turning (\(row?.output.map { "\"\($0)\"" } ?? "nil"))")
            let arguments = stub.lastArguments
            self.expect(arguments.contains("--mcp-config\n") && arguments.contains("\"\(BrowserTools.server)\"")
                        && arguments.contains("mcp__\(BrowserTools.server)__read_page")
                        && !arguments.contains("mcp__\(BrowserTools.server),"),
                        "a page chat gets OpenArch's browser tools, reading allowed and acting not yet")
            let refusal = chat.session.messages.first { $0.role == .denied }
            self.expect(refusal?.tool == "mcp__\(BrowserTools.server)" && AgentTool.ruleTitle(refusal?.tool ?? "") == "Browser-Steuerung",
                        "a refused click asks for „Browser-Steuerung“ (\(refusal?.tool ?? "none"))")
            guard let refusal else { return next() }
            stub.answer([ClaudeStub.initEvent(session: "selftest-tools"), ClaudeStub.textEvent("Erledigt."),
                         ClaudeStub.resultEvent(session: "selftest-tools")])
            chat.session.allow(refusal)
            self.eventually({ !chat.session.isRunning && chat.session.messages.last?.text == "Erledigt." }, timeout: 10) { _ in
                self.expect(stub.lastArguments.contains("mcp__\(BrowserTools.server),"),
                            "once allowed, the chat may act in the browser in every further run")
                next()
            }
        }
    }

    /// The number read_page gave the element described as |description|.
    private static func number(of description: String, in page: String) -> Int? {
        for line in page.split(separator: "\n") where line.hasSuffix("] " + description) || line.contains("] " + description + " ") {
            if let close = line.firstIndex(of: "]"), let number = Int(line.dropFirst().prefix(upTo: close)) {
                return number
            }
        }
        return nil
    }

    /// One JSON-RPC message to |url| by curl, as claude would send it: the
    /// HTTP status and the JSON that came back. Runs off the main thread,
    /// where the tools answer.
    static func mcp(_ url: String, _ message: [String: Any]) async -> (status: Int, json: [String: Any]?) {
        let body = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        let output: Data = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "-X", "POST", "-H", "Content-Type: application/json",
                                 "-H", "Accept: application/json, text/event-stream",
                                 "--data-binary", "@-", "-w", "\n%{http_code}", "--max-time", "30", url]
            let input = Pipe(), result = Pipe()
            process.standardInput = input
            process.standardOutput = result
            guard (try? process.run()) != nil else { return Data() }
            input.fileHandleForWriting.write(body)
            try? input.fileHandleForWriting.close()
            let data = result.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        let text = String(decoding: output, as: UTF8.self)
        guard let split = text.lastIndex(of: "\n") else { return (Int(text) ?? 0, nil) }
        let json = (try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8))) as? [String: Any]
        return (Int(text[text.index(after: split)...]) ?? 0, json)
    }
}
