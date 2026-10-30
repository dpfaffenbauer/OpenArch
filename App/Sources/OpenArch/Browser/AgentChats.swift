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

    /// Whether a window shows |item| right now.
    static func isShowing(_ item: Item) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        return app.browsers.contains { $0.state.activeItem === item && $0.window?.isVisible == true }
    }
}
