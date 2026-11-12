import AppKit
import OpenArchLocalization
import EventKit
import Observation

/// The next meeting from the Mac's calendar (every account the Calendar app
/// has), for the card at the bottom of the sidebar: a countdown, and a
/// button that joins the call (Settings › Allgemein › Kalender).
@MainActor @Observable
final class Meetings {
    static let shared = Meetings()

    struct Meeting: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        /// The video call's address, if the invitation has one.
        let joinURL: String?
    }

    /// The meeting the card shows: running, or starting within the hour.
    private(set) var current: Meeting?
    private(set) var access = EKEventStore.authorizationStatus(for: .event)
    /// Moves on every 20 seconds, so the countdown follows.
    private(set) var now = Date()

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var remindedID: String?
    /// Shortly before a meeting starts (OpenArch shows a toast and, in the
    /// background, asks for attention).
    @ObservationIgnored var onReminder: ((Meeting) -> Void)?
    /// The self-test sets its own meeting instead of reading the calendar.
    @ObservationIgnored var testMeeting: Meeting? {
        didSet { tick() }
    }

    var hasAccess: Bool { access == .fullAccess }

    /// Turns the card on or off; the first time on, macOS asks for access.
    func start(enabled: Bool) {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard enabled || testMeeting != nil else {
            current = nil
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { Meetings.shared.tick() }
        }
        guard testMeeting == nil else { return tick() }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { Meetings.shared.tick() }
        }
        access = EKEventStore.authorizationStatus(for: .event)
        if access == .notDetermined {
            store.requestFullAccessToEvents { _, _ in
                Task { @MainActor in
                    Meetings.shared.access = EKEventStore.authorizationStatus(for: .event)
                    Meetings.shared.tick()
                }
            }
        }
        tick()
    }

    func tick() {
        now = Date()
        current = testMeeting ?? (hasAccess ? pick(from: events()) : nil)
        // About a minute before it starts: once per meeting.
        if let meeting = current, meeting.id != remindedID,
           meeting.start.timeIntervalSince(now) <= 70, meeting.start.timeIntervalSince(now) > -60 {
            remindedID = meeting.id
            onReminder?(meeting)
        }
    }

    private func events() -> [Meeting] {
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-8 * 3600),
                                                 end: now.addingTimeInterval(3600), calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled, event.endDate > now,
                  event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined else { return nil }
            let link = Self.joinURL(in: [event.url?.absoluteString, event.location, event.notes])
            // Not a meeting: a block in the calendar with nobody else and no call.
            guard link != nil || (event.attendees?.count ?? 0) > 1 else { return nil }
            let id = (event.calendarItemIdentifier) + "@" + String(event.startDate.timeIntervalSince1970)
            return Meeting(id: id, title: event.title ?? "Meeting", start: event.startDate, end: event.endDate, joinURL: link)
        }
    }

    /// The one starting within ten minutes beats one that is running (you
    /// are about to switch); otherwise the running one, else the next.
    func pick(from meetings: [Meeting]) -> Meeting? {
        let soon = meetings.filter { $0.start > now && $0.start.timeIntervalSince(now) <= 600 }.min { $0.start < $1.start }
        let running = meetings.filter { $0.start <= now }.max { $0.start < $1.start }
        let next = meetings.filter { $0.start > now && $0.start.timeIntervalSince(now) <= 3600 }.min { $0.start < $1.start }
        return soon ?? running ?? next
    }

    /// The first video call link in an invitation: Meet, Zoom, Teams, Webex …
    nonisolated static func joinURL(in texts: [String?]) -> String? {
        let pattern = #"https://[A-Za-z0-9.-]*(meet\.google\.com|zoom\.us|zoom\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|meet\.jit\.si|gotomeeting\.com|chime\.aws)/[^\s<>"')\]]+"#
        for text in texts.compactMap({ $0 }) {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }

    /// "in 5 Min.", "beginnt gleich", "seit 12 Min." …
    func countdown(for meeting: Meeting) -> String {
        let seconds = meeting.start.timeIntervalSince(now)
        if seconds > 90 {
            let minutes = Int((seconds / 60).rounded(.up))
            return minutes >= 60 ? L("in 1 Std.") : L("in %lld Min.", minutes)
        }
        if seconds > -60 { return L("beginnt jetzt") }
        let left = Int((meeting.end.timeIntervalSince(now) / 60).rounded(.up))
        return L("läuft, noch %lld Min.", left)
    }
}
