import AppKit
import OpenArchCore
import SwiftUI

/// The content area while an agent chat is shown: the chat, as a card where
/// a page would be.
struct AgentContentView: View {
    let browser: BrowserWindowController

    var body: some View {
        if let item = browser.state.activeItem, item.kind == .agent, let session = item.agentSession {
            AgentChatView(browser: browser, item: item, session: session)
                .id(item.id)
        }
    }
}

struct AgentChatView: View {
    let browser: BrowserWindowController
    let item: Item
    @Bindable var session: AgentSession
    @FocusState private var inputFocused: Bool
    /// The chat follows new text only while it is scrolled to the end.
    @State private var followsEnd = true
    @AppStorage("agentInspector") private var showsInspector = true

    private let end = "end"

    var body: some View {
        HStack(spacing: 0) {
            chat
            if showsInspector {
                Divider().opacity(0.6)
                AgentInspector(item: item, session: session)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { inputFocused = true }
        .onChange(of: session.focusRequest) { inputFocused = true }
    }

    private var chat: some View {
        VStack(spacing: 0) {
            AgentHeader(browser: browser, item: item, session: session)
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.messages.isEmpty {
                            AgentEmptyState(item: item)
                        }
                        ForEach(session.messages) { message in
                            AgentMessageRow(session: session, message: message)
                        }
                        if session.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude arbeitet …").font(.system(size: 12.5)).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id(end)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 60
                } action: { _, atEnd in
                    followsEnd = atEnd
                }
                .onChange(of: scrollKey) {
                    if followsEnd { proxy.scrollTo(end, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(end, anchor: .bottom) }
            }
            AgentInput(session: session, focused: $inputFocused)
        }
    }

    /// Changes whenever the chat grows.
    private var scrollKey: String {
        "\(session.messages.count) \(session.messages.last?.text.count ?? 0) \(session.messages.last?.output?.count ?? 0) \(session.isRunning)"
    }
}

/// Title, the folder the agent works in, and what it may do.
private struct AgentHeader: View {
    let browser: BrowserWindowController
    let item: Item
    let session: AgentSession

    var body: some View {
        let config = item.agent ?? AgentConfig(folder: "")
        let folder = URL(fileURLWithPath: config.folder)
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Text(item.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 12)
            Menu {
                Button("Ordner wählen …") { chooseFolder() }
                    .disabled(config.sessionID != nil)
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            } label: {
                Label(folder.lastPathComponent.isEmpty ? "Ordner" : folder.lastPathComponent, systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(config.sessionID == nil ? config.folder
                  : "\(config.folder)\nDer Ordner bleibt, solange der Chat läuft: Claude Code setzt die Sitzung nur dort fort.")
            Menu {
                Picker("Darf", selection: Binding(
                    get: { item.agent?.permissions ?? .ask },
                    set: {
                        item.agent?.permissions = $0
                        browser.library.setNeedsSave()
                    })) {
                    ForEach(AgentPermissions.allCases) { permissions in
                        Text("\(permissions.title) – \(permissions.detail)").tag(permissions)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(config.permissions.title, systemImage: config.permissions.symbol)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Was der Agent ohne Rückfrage darf")
            Button { showsInspector.toggle() } label: {
                Image(systemName: "sidebar.right").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(showsInspector ? "Infos ausblenden" : "Infos einblenden: Umgebung, Kontext, Connectors, Änderungen, Ausgabe")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @AppStorage("agentInspector") private var showsInspector = true

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Wählen"
        panel.message = "In welchem Ordner soll der Agent arbeiten?"
        if let folder = item.agent?.folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        item.agent?.folder = url.path
        browser.library.setNeedsSave()
        session.focusRequest += 1
    }
}

/// Beside the chat, like the Claude app: where the agent works, how full
/// its context is, its connectors, the files it changed and what its
/// commands printed.
private struct AgentInspector: View {
    let item: Item
    let session: AgentSession
    @State private var workspace: AgentWorkspace?
    @State private var diff: AgentDiff?

    var body: some View {
        let folder = item.agent?.folder ?? ""
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Umgebung") {
                    line("laptopcomputer", "Lokal")
                    line("folder", URL(fileURLWithPath: folder).lastPathComponent)
                        .help(folder)
                    if let repository = workspace?.repository {
                        line("shippingbox", repository)
                    }
                    if let branch = workspace?.branch {
                        line("arrow.triangle.branch", branch)
                    }
                    if let model = session.model {
                        line("cpu", model)
                    }
                }
                section("Kontext") { context }
                section("Connectors") {
                    if session.connectors.isEmpty {
                        note("Claude Code nennt sie beim nächsten Lauf.")
                    }
                    ForEach(session.connectors) { connector in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(connector.status == "connected" ? Color.green : (connector.status == "failed" ? Color.red : Color.orange))
                                .frame(width: 6, height: 6)
                            Text(connector.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if connector.status != "connected" {
                                Text(connector.status).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                section(changesTitle) { changes(folder: folder) }
                section("Ausgabe") {
                    let commands = session.messages.filter { $0.role == .tool && $0.tool == "Bash" }.suffix(5).reversed()
                    if commands.isEmpty {
                        note("Noch keine Befehle.")
                    }
                    ForEach(Array(commands)) { message in
                        AgentToolRow(message: message, isRunning: session.isRunning)
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(16)
        }
        .frame(width: 280)
        .background(Color.primary.opacity(0.025))
        // Again after each run, and every ten seconds while it is open.
        .task(id: session.isRunning) {
            while !Task.isCancelled {
                workspace = await Task.detached { AgentWorkspace.read(folder: folder) }.value
                if session.contextUsed == nil, let id = item.agent?.sessionID {
                    let usage = await Task.detached { ClaudeSessions.lastUsage(sessionID: id) }.value
                    session.noteUsage(model: usage.model, used: usage.used)
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .sheet(item: $diff) { diff in
            AgentDiffView(diff: diff) { self.diff = nil }
        }
    }

    private var changesTitle: String {
        guard let count = workspace?.changes.count, count > 0 else { return "Änderungen" }
        return "Änderungen · \(count)"
    }

    @ViewBuilder private var context: some View {
        if let used = session.contextUsed {
            let window = session.contextWindow ?? AgentSession.defaultContextWindow(for: session.model)
            let fraction = min(1, Double(used) / Double(max(window, 1)))
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .tint(fraction > 0.85 ? Color.orange : Color.accentColor)
                Text("\(Int((fraction * 100).rounded())) % · \(used / 1000)k von \(window / 1000)k Tokens")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        } else {
            note("Nach der ersten Antwort.")
        }
    }

    @ViewBuilder private func changes(folder: String) -> some View {
        if let workspace {
            if !workspace.isRepository {
                note("Kein Git-Repository.")
            } else if workspace.changes.isEmpty {
                note("Keine Änderungen seit dem letzten Commit.")
            }
            ForEach(workspace.changes.prefix(100)) { change in
                Button {
                    Task {
                        let text = await Task.detached { AgentWorkspace.diff(folder: folder, change: change) }.value
                        diff = AgentDiff(path: change.path, text: text)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(URL(fileURLWithPath: change.path).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if change.isNew {
                            Text("neu").foregroundStyle(.green)
                        } else {
                            if let added = change.added { Text("+\(added)").foregroundStyle(.green) }
                            if let removed = change.removed { Text("−\(removed)").foregroundStyle(.red) }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(change.path)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16).foregroundStyle(.secondary)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}

struct AgentDiff: Identifiable {
    let path: String
    let text: String
    var id: String { path }
}

/// A file's diff, lines colored as in a terminal.
private struct AgentDiffView: View {
    let diff: AgentDiff
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(diff.path).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Fertig", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(3000).enumerated()),
                            id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(of: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(background(of: line))
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private func color(of line: Substring) -> Color {
        if line.hasPrefix("@@") { return .blue }
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .green }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .red }
        return .primary
    }

    private func background(of line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return Color.green.opacity(0.08) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return Color.red.opacity(0.08) }
        return .clear
    }
}

private struct AgentEmptyState: View {
    let item: Item

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text("Claude Code").font(.system(size: 18, weight: .semibold))
            Text(explanation)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.bottom, 20)
    }

    private var explanation: String {
        let folder = (item.agent?.folder).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~"
        let browser = OACEngine.remoteDebuggingPort > 0
            ? "Mit der KI-Steuerung kann er auch deine Tabs bedienen."
            : "Mit der KI-Steuerung (Einstellungen › KI) kann er auch deine Tabs bedienen."
        return "Arbeitet in \(folder) mit deinem Claude-Login, ohne API-Schlüssel. \(browser)"
    }
}

private struct AgentMessageRow: View {
    let session: AgentSession
    let message: AgentMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.accentColor.opacity(0.16)))
            }
        case .assistant:
            MarkdownText(text: message.text)
        case .tool:
            AgentToolRow(message: message, isRunning: session.isRunning)
        case .denied:
            AgentDeniedRow(session: session, message: message)
        case .error:
            Label {
                Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 12.5))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.1)))
        case .note:
            Text(message.text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A tool the agent used: what it did, and on a click what came back.
private struct AgentToolRow: View {
    let message: AgentMessage
    let isRunning: Bool
    @State private var expanded = false

    var body: some View {
        let output = message.output ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Button { if !output.isEmpty { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: AgentTool.symbol(message.tool)).frame(width: 16).foregroundStyle(.secondary)
                    Text(AgentTool.title(message.tool)).fontWeight(.medium)
                    Text(message.text).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if message.output == nil, isRunning {
                        ProgressView().controlSize(.mini)
                    } else if message.failed {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red.opacity(0.8))
                    }
                    if !output.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// Something the agent was not allowed to do, with the button to allow it.
private struct AgentDeniedRow: View {
    let session: AgentSession
    let message: AgentMessage

    var body: some View {
        let rule = message.tool ?? ""
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(AgentTool.ruleTitle(rule)) nicht erlaubt").fontWeight(.medium)
                if !message.text.isEmpty {
                    Text(message.text).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if session.isAllowed(rule) {
                Label("Erlaubt", systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
                Button("Erlauben und weiter") { session.allow(message) }
                    .disabled(session.isRunning)
                    .help("Erlaubt \(rule) in diesem Chat")
            }
        }
        .font(.system(size: 12.5))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.1)))
    }
}

/// The field at the bottom: ↩ sends, ⌥↩ starts a new line.
private struct AgentInput: View {
    @Bindable var session: AgentSession
    var focused: FocusState<Bool>.Binding

    var body: some View {
        let empty = session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let placeholder: String = session.isRunning ? "Claude arbeitet …" : "Schreib dem Agent …"
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .focused(focused)
                .onSubmit { session.send(session.draft) }
                .padding(.vertical, 5)
            if session.isRunning {
                Button { session.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Anhalten")
            } else {
                Button { session.send(session.draft) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(empty ? Color.secondary : Color.accentColor)
                .disabled(empty)
                .help("Senden (↩), neue Zeile mit ⌥↩")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }
}

/// The agent's Markdown: code blocks in a box, headings and lists made
/// readable, the rest (bold, code, links) as SwiftUI shows inline Markdown.
struct MarkdownText: View {
    let text: String

    struct Block {
        var text: String
        var isCode: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                if block.isCode {
                    ScrollView(.horizontal) {
                        Text(block.text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                } else {
                    Text(Self.attributed(block.text))
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: readable(text), options: options)) ?? AttributedString(text)
    }

    /// Splits off ``` code blocks.
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var lines: [Substring] = []
        var inCode = false
        func flush() {
            let chunk = lines.joined(separator: "\n")
            if inCode || !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(Block(text: inCode ? chunk : chunk.trimmingCharacters(in: .newlines), isCode: inCode))
            }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Headings in bold and list bullets as dots: inline Markdown leaves
    /// both as they are typed.
    private static func readable(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            let indent = String(repeating: " ", count: line.count - trimmed.count)
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                return "**\(trimmed.dropFirst(hashes + 1))**"
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return "\(indent)• \(trimmed.dropFirst(2))"
            }
            return String(line)
        }
        .joined(separator: "\n")
    }
}
