import SwiftUI

/// How far a tab's page has loaded: a band filling from the left that fills
/// up and fades out once the page is there.
struct LoadingProgressBar: View {
    let item: Item?
    let color: Color
    @State private var fraction = 0.0
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(color)
                .frame(width: geometry.size.width * fraction)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear { update(animated: false) }
        .onChange(of: item?.isLoading) { update(animated: true) }
        .onChange(of: item?.loadingProgress) { update(animated: true) }
        // Another tab: its own state, without sliding over from the last one.
        .onChange(of: item?.id) { update(animated: false) }
    }

    private func update(animated: Bool) {
        guard let item, item.isLoading else {
            guard visible else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.15)) { fraction = 1 }
                withAnimation(.easeOut(duration: 0.35).delay(0.15)) { visible = false }
            } else {
                visible = false
            }
            return
        }
        // Chrome starts at a tenth; a sliver shows even before that.
        let target = max(item.loadingProgress, 0.06)
        if animated, visible {
            withAnimation(.easeOut(duration: 0.3)) { fraction = max(fraction, target) }
        } else {
            fraction = target
            visible = true
        }
    }
}

/// The line just above the page, when the sidebar has no address field
/// showing the loading.
struct PageLoadingLine: View {
    let browser: BrowserWindowController

    var body: some View {
        let theme = SpaceTheme(hex: browser.state.space.colorHex)
        if !browser.addressFieldShowsLoading {
            // In the middle of the strip above the page.
            LoadingProgressBar(item: browser.state.activeItem, color: theme.foreground.opacity(0.55))
                .frame(height: 2)
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
        }
    }
}
