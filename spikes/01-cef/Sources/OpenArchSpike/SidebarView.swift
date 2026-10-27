import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Suchen oder URL eingeben", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(openAddress)

            if let space = model.selectedSpace {
                Text(space.name)
                    .font(.headline)
                    .foregroundStyle(space.color)
                    .padding(.leading, 4)

                List(selection: tabSelection) {
                    ForEach(space.tabs) { tab in
                        TabRow(tab: tab)
                            .tag(tab.id)
                            .contextMenu {
                                Button("Tab schließen") { model.close(tab) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else {
                Spacer()
            }

            Button {
                addressFocused = true
            } label: {
                Label("Neuer Tab", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 4)

            HStack(spacing: 12) {
                ForEach(model.spaces) { space in
                    Button {
                        model.select(space)
                    } label: {
                        Circle()
                            .fill(space.color)
                            .frame(width: 12, height: 12)
                            .padding(3)
                            .overlay(
                                Circle().stroke(
                                    Color.primary.opacity(space.id == model.selectedSpaceID ? 0.5 : 0),
                                    lineWidth: 1.5
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(space.name)
                }
            }
            .padding(.leading, 2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onChange(of: model.addressFocusRequest) {
            addressFocused = true
        }
    }

    private var tabSelection: Binding<Tab.ID?> {
        Binding(
            get: { model.selectedSpace?.selectedTabID },
            set: { model.selectTab(id: $0) }
        )
    }

    private func openAddress() {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.openInput(address)
        address = ""
        addressFocused = false
    }
}

private struct TabRow: View {
    let tab: Tab

    var body: some View {
        Label {
            Text(tab.title).lineLimit(1)
        } icon: {
            Image(systemName: tab.isLoading ? "circle.dotted" : "globe")
        }
    }
}
