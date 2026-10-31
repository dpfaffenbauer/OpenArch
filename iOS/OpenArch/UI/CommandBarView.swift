import SwiftUI

/// The address field: an address or a search, suggestions from the search
/// engine, and the tabs, favorites and archived tabs that match.
struct CommandBarView: View {
    let browser: Browser
    let mode: CommandBarMode
    @State private var text = ""
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        let query = text.trimmingCharacters(in: .whitespaces)
        let engine = browser.library.settings.searchEngine
        NavigationStack {
            List {
                if !query.isEmpty {
                    if let address = URLInput.url(from: query) {
                        ResultRow(symbol: "globe", title: URLInput.short(address), detail: "Öffnen") {
                            browser.go(query, mode: mode)
                        }
                    }
                    ResultRow(symbol: "magnifyingglass", title: query, detail: engine.name) {
                        browser.go(engine.url(for: query), mode: mode)
                    }
                    ForEach(suggestions.prefix(5).filter { $0.lowercased() != query.lowercased() }, id: \.self) { suggestion in
                        ResultRow(symbol: "magnifyingglass", title: suggestion, detail: nil) {
                            browser.go(engine.url(for: suggestion), mode: mode)
                        }
                    }
                }
                let tabs = matchingTabs(query)
                if !tabs.isEmpty {
                    Section(query.isEmpty ? "Tabs" : "Zu Tab wechseln") {
                        ForEach(tabs) { item in
                            Button {
                                browser.select(item)
                                browser.sheet = nil
                            } label: {
                                HStack(spacing: 12) {
                                    FaviconView(host: item.host, size: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.displayTitle).lineLimit(1)
                                        Text(URLInput.short(item.currentURL)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                let archived = matchingArchive(query)
                if !archived.isEmpty {
                    Section("Archiv") {
                        ForEach(archived) { tab in
                            ResultRow(symbol: "archivebox", title: tab.title, detail: URLInput.short(tab.url)) {
                                browser.reopen(tab)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Suchen oder Adresse eingeben", text: $text)
                        .focused($focused)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { browser.go(text, mode: mode) }
                    if !text.isEmpty {
                        Button {
                            text = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Leeren")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle(mode == .edit ? "Adresse" : "Neuer Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { browser.sheet = nil }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if mode == .edit, let item = browser.activeItem { text = item.currentURL }
            focused = true
        }
        .task(id: text) { await fetchSuggestions(for: text) }
        #if DEBUG
        .onChange(of: browser.demoQuery) { _, query in text = query ?? text }
        #endif
    }

    private func matchingTabs(_ query: String) -> [Item] {
        let library = browser.library
        let all = library.favorites + library.spaces.flatMap { space in
            space.pinned.flatMap { [$0] + $0.descendants } + space.today
        }
        let tabs = all.filter { $0.kind == .tab && $0 !== browser.activeItem }
        guard !query.isEmpty else { return Array(browser.space.today.filter { $0 !== browser.activeItem }.prefix(5)) }
        let needle = query.lowercased()
        return Array(tabs.filter {
            $0.displayTitle.lowercased().contains(needle) || $0.currentURL.lowercased().contains(needle)
        }.prefix(6))
    }

    private func matchingArchive(_ query: String) -> [ArchivedTab] {
        guard query.count >= 2 else { return [] }
        let needle = query.lowercased()
        return Array(browser.library.archive.filter {
            $0.title.lowercased().contains(needle) || $0.url.lowercased().contains(needle)
        }.prefix(4))
    }

    private func fetchSuggestions(for input: String) async {
        let query = input.trimmingCharacters(in: .whitespaces)
        let settings = browser.library.settings
        guard settings.searchSuggestions, query.count >= 2, URLInput.url(from: query) == nil,
              mode == .newTab || query != browser.activeItem?.currentURL,
              let endpoint = settings.searchEngine.suggestionURL(for: query) else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled,
              let response = try? await URLSession.shared.data(from: endpoint),
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [Any],
              json.count > 1, let list = json[1] as? [String], !Task.isCancelled else { return }
        suggestions = list
    }
}

private struct ResultRow: View {
    let symbol: String
    let title: String
    let detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                Text(title).lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
