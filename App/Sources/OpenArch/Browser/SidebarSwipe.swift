import AppKit
import SwiftUI

/// Arc's sidebar swipe: a horizontal two-finger swipe (trackpad) or
/// one-finger swipe (Magic Mouse) over the sidebar moves between spaces.
/// Swiping past the first space opens the library; swiping back closes it.
@MainActor
final class SidebarSwipe {
    private unowned let browser: BrowserWindowController
    private var monitor: Any?
    private var active = false
    private var horizontal: Bool?
    private var distance: CGFloat = 0
    private var vertical: CGFloat = 0
    /// Momentum events after a horizontal swipe belong to it too.
    private var swallowMomentum = false

    /// How far the fingers must travel to switch.
    static let threshold: CGFloat = 55

    init(browser: BrowserWindowController) {
        self.browser = browser
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = browser.window, event.window === window, browser.state.sidebarVisible else { return false }
        // Plain mouse wheels have no phases; they only scroll.
        if event.phase.isEmpty {
            return !event.momentumPhase.isEmpty && swallowMomentum
        }
        let point = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
        // Not over the space bar at the bottom, which scrolls sideways itself.
        let inSidebar = point.x < browser.sidebarWidth && point.y > 44
        // With natural scrolling the deltas follow the fingers; normalize so
        // positive always means "fingers moved right".
        let delta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        return update(began: event.phase.contains(.began),
                      changed: event.phase.contains(.changed),
                      ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
                      fingerDelta: delta, verticalDelta: abs(event.scrollingDeltaY), inSidebar: inSidebar)
    }

    /// The gesture logic, separate from NSEvent so the self-test can drive it.
    @discardableResult
    func update(began: Bool, changed: Bool, ended: Bool, fingerDelta: CGFloat, verticalDelta: CGFloat,
                inSidebar: Bool) -> Bool {
        if began {
            active = inSidebar
            horizontal = nil
            distance = 0
            vertical = 0
            swallowMomentum = false
        }
        guard active else { return false }
        if began || changed {
            distance += fingerDelta
            vertical += verticalDelta
            if horizontal == nil, abs(distance) + vertical > 8 {
                horizontal = abs(distance) > vertical
            }
            guard horizontal == true else { return false }
            browser.state.swipeOffset = rubberBand(distance)
            return true
        }
        if ended {
            active = false
            guard horizontal == true else { return false }
            swallowMomentum = true
            finish()
            return true
        }
        return false
    }

    private func rubberBand(_ x: CGFloat) -> CGFloat {
        x / (1 + abs(x) / 280) * 0.7
    }

    private func finish() {
        let state = browser.state
        // Fingers to the right reveal what is on the left: the previous
        // space, or the library before the first one.
        let direction = distance > Self.threshold ? -1 : (distance < -Self.threshold ? 1 : 0)
        let spaces = browser.library.spaces
        let index = spaces.firstIndex { $0 === state.space } ?? 0
        var moved = false
        if direction < 0 {
            if state.libraryVisible {
                moved = false
            } else if index == 0 {
                browser.toggleLibrary()
                moved = true
            } else {
                browser.switchSpace(by: -1)
                moved = true
            }
        } else if direction > 0 {
            if state.libraryVisible {
                browser.toggleLibrary()
                moved = true
            } else if index < spaces.count - 1 {
                browser.switchSpace(by: 1)
                moved = true
            }
        }
        if moved {
            // The new content slides in from the side the fingers came from.
            state.swipeOffset = CGFloat(direction) * 70
        }
        withAnimation(.spring(duration: 0.3, bounce: 0.15)) {
            state.swipeOffset = 0
        }
    }
}
