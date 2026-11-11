import AppKit
import OpenArchLocalization
import SwiftUI

/// The panel right of the page while its chat is open (⌘E).
struct PageChatContainer: View {
    let browser: BrowserWindowController
    let model = PageChatPanelModel()

    var body: some View {
        if let tab = model.tab, let chat = tab.pageChat {
            PageChatView(browser: browser, tab: tab, chat: chat)
                .id(ObjectIdentifier(chat))
        }
    }
}

struct PageChatView: View {
    let browser: BrowserWindowController
    let tab: Item
    @Bindable var chat: PageChat
    @FocusState private var inputFocused: Bool
    @State private var followsEnd = true

    private let end = "end"

    var body: some View {
        let session = chat.session
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if session.messages.isEmpty, !chat.isPreparing {
                            PageChatEmptyState(chat: chat) { question in
                                session.draft = question
                                browser.sendPageChat(tab)
                            }
                        }
                        ForEach(session.messages) { message in
                            AgentMessageRow(session: session, message: message)
                        }
                        if chat.isPreparing || session.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L(chat.isPreparing ? "Liest die Seite …" : "Claude denkt nach …"))
                                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id(end)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
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
            PageChatInput(browser: browser, tab: tab, chat: chat, focused: $inputFocused)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { inputFocused = true }
        .onChange(of: session.focusRequest) { inputFocused = true }
        .onExitCommand { browser.closePageChat(tab) }
        // Links in answers open as tabs, next to the page.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.hasPrefix("http") == true else { return .systemAction }
            browser.openInNewTab(url.absoluteString, after: tab)
            return .handled
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Text(tab.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { browser.restartPageChat(tab) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .disabled(chat.session.messages.isEmpty || chat.session.isRunning)
            .help("Neuer Chat zu dieser Seite")
            Button { browser.closePageChat(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Schließen (⌘E)")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// Changes whenever the chat grows.
    private var scrollKey: String {
        let messages = chat.session.messages
        return "\(messages.count) \(messages.last?.text.count ?? 0) \(chat.session.isRunning) \(chat.isPreparing)"
    }
}

/// Before the first message: what the chat knows, and a few questions to start with.
private struct PageChatEmptyState: View {
    let chat: PageChat
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frag Claude zu dieser Seite")
                .font(.system(size: 15, weight: .semibold))
            Text("Claude bekommt Adresse, Titel und Text der Seite. Markierter Text wird zum Fokus, mit @ nimmst du weitere Tabs dazu. Läuft mit deinem Claude-Login, ohne API-Schlüssel.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.self) { question in
                    let label = L(question)
                    Button { ask(question) } label: {
                        Text(label)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    private var suggestions: [String] {
        chat.selection != nil
            ? ["Erkläre die Auswahl", "Übersetze die Auswahl ins Deutsche", "Fasse die Seite zusammen"]
            : ["Fasse die Seite zusammen", "Was sind die wichtigsten Punkte?", "Welche Fragen lässt die Seite offen?"]
    }
}

/// The field at the bottom, with the selection and the tabs named with @
/// above it. ↩ sends, ⌥↩ starts a new line, @ lists the space's tabs.
private struct PageChatInput: View {
    let browser: BrowserWindowController
    let tab: Item
    @Bindable var chat: PageChat
    var focused: FocusState<Bool>.Binding
    @State private var highlighted = 0
    /// Esc closed the list of tabs for this @.
    @State private var dismissedMention: String?

    var body: some View {
        let session = chat.session
        let candidates = mentionCandidates
        VStack(alignment: .leading, spacing: 8) {
            if !candidates.isEmpty {
                mentionList(candidates)
            }
            if let selection = chat.selection {
                SelectionQuote(text: selection) { chat.selection = nil }
            }
            if !chat.mentions.isEmpty {
                mentionChips
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L(placeholder), text: Binding(get: { session.draft }, set: { session.draft = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...8)
                    .focused(focused)
                    .disabled(chat.isPreparing)
                    .onSubmit { submit(candidates) }
                    .onKeyPress(.downArrow) { move(1, in: candidates) }
                    .onKeyPress(.upArrow) { move(-1, in: candidates) }
                    .onKeyPress(.tab) {
                        guard candidates.indices.contains(highlighted) else { return .ignored }
                        pick(candidates[highlighted])
                        return .handled
                    }
                    .onExitCommand {
                        if let query = mentionQuery, !candidates.isEmpty {
                            dismissedMention = query
                        } else {
                            browser.closePageChat(tab)
                        }
                    }
                    .onChange(of: chat.session.draft) { highlighted = 0 }
                    .padding(.vertical, 4)
                if session.isRunning {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .help("Anhalten")
                } else {
                    let empty = session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { browser.sendPageChat(tab) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(empty ? Color.secondary : Color.accentColor)
                    .disabled(empty || chat.isPreparing)
                    .help("Senden (↩), neue Zeile mit ⌥↩")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var placeholder: String {
        if chat.session.isRunning { return L("Claude denkt nach …") }
        return chat.selection != nil ? L("Frag zur Auswahl …") : L("Frag zu dieser Seite … (@ für Tabs)")
    }

    // MARK: @

    /// The @ being typed at the end of the field: the text after it.
    private var mentionQuery: String? {
        let draft = chat.session.draft
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = String(draft[draft.index(after: at)...])
        guard !query.contains(where: \.isNewline), query.count <= 40 else { return nil }
        return query
    }

    private var mentionCandidates: [Item] {
        guard let query = mentionQuery, query != dismissedMention else { return [] }
        return browser.pageChatMentionCandidates(for: tab, query: query)
    }

    private func move(_ offset: Int, in candidates: [Item]) -> KeyPress.Result {
        guard !candidates.isEmpty else { return .ignored }
        highlighted = (highlighted + offset + candidates.count) % candidates.count
        return .handled
    }

    private func submit(_ candidates: [Item]) {
        if candidates.indices.contains(highlighted) {
            pick(candidates[highlighted])
        } else {
            browser.sendPageChat(tab)
        }
        focused.wrappedValue = true
    }

    /// The tab goes along with the next message; the @ in the text becomes its name.
    private func pick(_ other: Item) {
        guard let query = mentionQuery else { return }
        var draft = chat.session.draft
        draft.removeLast(query.count + 1)
        chat.session.draft = draft + "„\(PageChat.shortTitle(other.displayTitle))“ "
        if !chat.mentions.contains(where: { $0 === other }) {
            chat.mentions.append(other)
        }
        focused.wrappedValue = true
    }

    private func mentionList(_ candidates: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Tab dazunehmen").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, other in
                HStack(spacing: 8) {
                    FaviconView(item: other, size: 14)
                    Text(other.displayTitle).font(.system(size: 12.5)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(CommandBarModel.shortURL(other.currentURL)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(index == highlighted ? Color.accentColor.opacity(0.18) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { pick(other) }
                .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private var mentionChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(chat.mentions) { other in
                    HStack(spacing: 5) {
                        FaviconView(item: other, size: 12)
                        Text(PageChat.shortTitle(other.displayTitle)).font(.system(size: 11.5)).lineLimit(1)
                        Button { chat.mentions.removeAll { $0 === other } } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Nicht mitschicken")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(other.currentURL)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// The selected text, highlighted as what the next question is about.
private struct SelectionQuote: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Auswahl").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text(text).font(.system(size: 12)).lineLimit(4).foregroundStyle(.primary.opacity(0.85))
            }
            Spacer(minLength: 4)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Auswahl nicht mitschicken")
        }
        .padding(8)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }
}
