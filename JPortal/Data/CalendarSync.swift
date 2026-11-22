import EventKit
import Foundation
import Observation

/// keeps the current semester's upcoming papers in a calendar the user picked.
/// runs whenever the exams data does, there's no background job.
@MainActor
@Observable
final class CalendarSync {
    /// paper keys that have an event, for the sheet's "in your calendar"
    private(set) var synced: Set<String> = []

    @ObservationIgnored let store = EKEventStore()
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let sheet: () async -> [Paper]?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    init(prefs: Prefs, sheet: @escaping () async -> [Paper]?) {
        self.prefs = prefs
        self.sheet = sheet
        synced = Set(read().keys)
    }

    /// the app targets iOS 17+, where full access replaced the old "authorized"
    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var denied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted
    }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            DebugLog.record("calendar", error)
            return false
        }
    }

    /// calendars on the phone that take new events
    func calendars() -> [EKCalendar] {
        store.calendars(for: .event).filter(\.allowsContentModifications)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    func calendar(_ id: String?) -> EKCalendar? { id.flatMap { store.calendar(withIdentifier: $0) } }

    /// turns sync on into calendar, moving what's already synced if it was elsewhere
    func enable(_ calendarId: String) async {
        if prefs.calendarId != calendarId { clear() }
        prefs.calendarId = calendarId
        prefs.calendarSync = true
        prefs.calendarDenied = false
        await sync()
    }

    /// off, and every event it wrote goes with it
    func disable() {
        prefs.calendarSync = false
        clear()
    }

    /// sign out: the next account's sync starts from nothing
    func forget() {
        let was = prefs.calendarSync
        prefs.calendarSync = false
        prefs.calendarId = nil
        if was || !read().isEmpty { clear() }
    }

    /// brings the calendar in line with the current semester's sheet. quiet no-op while off
    func sync() async {
        guard prefs.calendarSync else { return }
        guard hasAccess else {
            // revoked from settings, settings shows why it flipped off
            prefs.calendarSync = false
            prefs.calendarDenied = true
            return
        }
        guard !busy, let cal = calendar(prefs.calendarId) else { return }
        busy = true
        defer { busy = false }
        guard let papers = await sheet(), prefs.calendarSync else { return }
        write(cal, papers)
    }

    private func write(_ cal: EKCalendar, _ sheet: [Paper]) {
        var synced = read()
        // gone from the calendar app or deleted there: the next write adds it back fresh
        let live = synced.filter { _, s in store.event(withIdentifier: s.id)?.calendar.calendarIdentifier == cal.calendarIdentifier }
        for k in synced.keys where live[k] == nil { synced.removeValue(forKey: k) }
        let plan = syncPlan(sheet, now: AppClock.now(), synced: live)
        do {
            for k in plan.drop {
                if let s = live[k], let e = store.event(withIdentifier: s.id) { try store.remove(e, span: .thisEvent, commit: false) }
                synced.removeValue(forKey: k)
            }
            for (p, entry) in plan.add {
                let e = EKEvent(eventStore: store)
                e.calendar = cal
                fill(e, entry)
                try store.save(e, span: .thisEvent, commit: false)
                if let id = e.eventIdentifier { synced[p.key] = SyncedEvent(id: id, hash: entry.hash, over: entry.end) }
            }
            for (id, p, entry) in plan.change {
                guard let e = store.event(withIdentifier: id) else { continue }
                fill(e, entry)
                try store.save(e, span: .thisEvent, commit: false)
                synced[p.key] = SyncedEvent(id: e.eventIdentifier ?? id, hash: entry.hash, over: entry.end)
            }
            try store.commit()
        } catch {
            DebugLog.record("calendar", error)
            store.reset()
        }
        save(synced)
    }

    private func fill(_ e: EKEvent, _ entry: ExamEntry) {
        e.title = entry.title
        e.startDate = entry.begin
        e.endDate = entry.end
        e.isAllDay = entry.allDay
        e.location = entry.location.isEmpty ? nil : entry.location
        e.notes = entry.notes
        e.alarms = entry.reminders.map { EKAlarm(relativeOffset: -Double($0 * 60)) }
    }

    private func clear() {
        let all = read()
        if !all.isEmpty && hasAccess {
            for s in all.values {
                if let e = store.event(withIdentifier: s.id) { try? store.remove(e, span: .thisEvent, commit: false) }
            }
            try? store.commit()
        }
        save([:])
    }

    private func read() -> [String: SyncedEvent] {
        defaults.data(forKey: "calendar.synced").flatMap { try? JSONDecoder().decode([String: SyncedEvent].self, from: $0) } ?? [:]
    }

    private func save(_ m: [String: SyncedEvent]) {
        defaults.set(try? JSONEncoder().encode(m), forKey: "calendar.synced")
        synced = Set(m.keys)
    }
}
