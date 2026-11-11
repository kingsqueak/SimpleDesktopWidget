import EventKit
import SwiftUI

struct EventItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    let location: String?
}

struct CalendarInfo: Identifiable {
    let id: String
    let title: String
    let source: String
    let color: Color
}

@MainActor
final class CalendarModel: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published var access: Access = .unknown
    @Published var events: [EventItem] = []
    @Published var calendars: [CalendarInfo] = []

    private let store = EKEventStore()
    private var timer: Timer?
    private let settings = Settings.shared

    func start() {
        updateAccess()
        if access == .unknown { requestAccess() } else { reload() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Once a minute: finished events fade and the list rolls over at midnight.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor in
                self?.updateAccess()
                self?.reload()
            }
        }
    }

    func reload() {
        updateAccess()
        guard access == .granted else { events = []; calendars = []; return }

        let all = store.calendars(for: .event)
        calendars = all
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "",
                                color: Color(nsColor: $0.color ?? .systemBlue)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }

        let excluded = Set(settings.excludedCalendars)
        let chosen = all.filter { !excluded.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { events = []; return }

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
        let now = Date()

        events = store.events(matching: pred)
            .filter { !(settings.hideFinishedEvents && !$0.isAllDay && $0.endDate <= now) }
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
            .map {
                EventItem(id: ($0.eventIdentifier ?? UUID().uuidString) + "\($0.startDate.timeIntervalSince1970)",
                          title: $0.title ?? "(No title)", start: $0.startDate, end: $0.endDate,
                          allDay: $0.isAllDay, color: Color(nsColor: $0.calendar?.color ?? .systemBlue),
                          location: $0.location)
            }
    }
}
