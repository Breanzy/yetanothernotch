import EventKit
import SwiftUI

@MainActor
final class CalendarService: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var events: [EKEvent] = []
    @Published var selectedDate = Calendar.current.startOfDay(for: Date()) {
        didSet { if !resettingDate { reload() } }
    }
    private var resettingDate = false

    /// Created only when the panel opens and released a while after it closes —
    /// an idle EKEventStore holds a database connection and caches several MB.
    private var _store: EKEventStore?
    private var observer: NSObjectProtocol?
    private var releaseWork: DispatchWorkItem?

    private var store: EKEventStore {
        if let s = _store { return s }
        let s = EKEventStore()
        _store = s
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: s, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        return s
    }

    /// Call when the notch closes: drops events now and the store after 30 s of being closed.
    func suspend() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.events = []
                // Next time it opens on today (not on a day picked earlier, or yesterday after midnight).
                self.resettingDate = true
                self.selectedDate = Calendar.current.startOfDay(for: Date())
                self.resettingDate = false
                if let o = self.observer { NotificationCenter.default.removeObserver(o) }
                self.observer = nil
                self._store = nil
            }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    func refreshAuthorization() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
        // Events load when the panel opens (see reload()), not at launch.
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
            reload()
        }
    }

    func reload() {
        releaseWork?.cancel()
        // Islet may have been running since yesterday: a "today" selection rolls over to the new day.
        let today = Calendar.current.startOfDay(for: Date())
        if !Calendar.current.isDate(selectedDate, inSameDayAs: today), !weekStripDays(around: today).contains(selectedDate) {
            resettingDate = true
            selectedDate = today
            resettingDate = false
        }
        guard access == .granted else { events = []; return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: selectedDate)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    /// The days shown in the week strip (2 days back, 4 ahead).
    func weekStripDays(around today: Date) -> [Date] {
        (-2...4).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }
}
