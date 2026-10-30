import AppKit

/// Agent chats in the sidebar: Claude Code next to the tabs, shown in the
/// content area where a page would be (see AgentSession).
extension BrowserWindowController {
    /// A new agent chat at the top of the tabs under the line, with the
    /// cursor in its field; |prompt| is sent right away.
    @discardableResult
    func newAgentChat(prompt: String? = nil) -> Item? {
        guard !isPrivate else { return nil }
        guard library.settings.agentChats else {
            (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai)
            return nil
        }
        let item = Item(kind: .agent)
        item.agent = AgentConfig(folder: library.settings.agentFolderPath)
        state.space.today.insert(item, at: 0)
        select(item)
        if let prompt {
            agentSession(for: item).send(prompt)
        }
        library.setNeedsSave()
        return item
    }

    /// The chat of |item|, made the first time it is needed.
    func agentSession(for item: Item) -> AgentSession {
        if let session = item.agentSession { return session }
        let session = AgentSession(item: item, library: library)
        item.agentSession = session
        return session
    }

    func focusAgentChat(_ item: Item) {
        if !AppPaths.isSelfTest {
            window?.makeKey()
        }
        item.agentSession?.focusRequest += 1
    }

    /// Removes a chat after asking, if it is still at work.
    func deleteAgentChat(_ item: Item) {
        guard item.kind == .agent else { return }
        if item.agentSession?.isRunning == true {
            let alert = NSAlert()
            alert.messageText = "„\(item.displayTitle)“ arbeitet noch."
            alert.informativeText = "Der Agent wird angehalten und der Chat entfernt."
            alert.addButton(withTitle: "Entfernen")
            alert.addButton(withTitle: "Abbrechen")
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let wasActive = state.activeItem === item
        let next = wasActive ? neighbor(forClosing: item) : nil
        discardAgentChat(item)
        if wasActive {
            if let next { select(next) } else { showNothing() }
        } else {
            layoutContent()
        }
        library.setNeedsSave()
    }

    /// Ends a chat for good: its run stops and its transcript goes. Claude
    /// Code keeps the session itself (`claude --resume` in its folder).
    func discardAgentChat(_ item: Item) {
        item.agentSession?.stop()
        item.agentSession = nil
        AgentSession.deleteTranscript(item.id)
        item.detach()
    }

    /// The overview of Claude Code sessions, in the content area.
    func showAgentOverview() {
        guard library.settings.agentChats else {
            (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai)
            return
        }
        showNothing()
        state.agentOverviewVisible = true
        layoutContent()
        ClaudeSessions.shared.refresh()
    }

    /// A session from the overview as an agent chat: the one in the sidebar
    /// that continues it, or a new one with its history.
    func openClaudeSession(_ session: ClaudeSession) {
        if let chat = agentChat(forSession: session.id) {
            return select(chat)
        }
        guard !isPrivate else { return }
        let item = Item(kind: .agent, title: session.title)
        var config = AgentConfig(folder: session.folder)
        config.sessionID = session.id
        item.agent = config
        var messages = ClaudeSessions.messages(in: session.file)
        if session.status == .working || session.status == .waiting || session.status == .approval {
            messages.append(AgentMessage(role: .note, text: "Diese Session läuft noch in einem Terminal. Was du hier schreibst, setzt sie getrennt davon fort."))
        }
        AgentSession.writeTranscript(messages, for: item.id)
        state.space.today.insert(item, at: 0)
        select(item)
        library.setNeedsSave()
    }

    /// The sidebar's chat that continues |id|, in any space.
    func agentChat(forSession id: String) -> Item? {
        library.spaces
            .flatMap { $0.pinned.allItems + $0.today.allItems }
            .first { $0.kind == .agent && $0.agent?.sessionID == id }
    }

    /// Continues a session in Terminal, as `claude --resume` in its folder.
    static func resumeInTerminal(_ session: ClaudeSession) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("OpenArch \(session.id).command")
        let folder = session.folder.replacingOccurrences(of: "'", with: "'\\''")
        let text = "#!/bin/sh\ncd '\(folder)' && exec \"${SHELL:-/bin/zsh}\" -l -i -c 'claude --resume \(session.id)'\n"
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            log("could not open the session in Terminal: \(error)")
        }
    }

    /// Whether a window shows |item| right now.
    static func isShowing(_ item: Item) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        return app.browsers.contains { $0.state.activeItem === item && $0.window?.isVisible == true }
    }
}
