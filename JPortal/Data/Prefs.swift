import Foundation
import Observation

enum ThemeMode: String, CaseIterable, Sendable {
    case system = "System", light = "Light", dark = "Dark"
}

/// user settings, saved as they change
@MainActor
@Observable
final class Prefs {
    @ObservationIgnored private let d = UserDefaults.standard

    var themeMode: ThemeMode { didSet { d.set(themeMode.rawValue, forKey: "theme") } }
    var amoled: Bool { didSet { d.set(amoled, forKey: "amoled") } }
    var target: Int { didSet { d.set(target, forKey: "target") } }
    /// registration code the user pinned, nil means follow the current semester
    var semester: String? { didSet { d.set(semester, forKey: "semester") } }
    /// profile photo off until tapped, people open this app around other people
    var showPhoto: Bool { didSet { d.set(showPhoto, forKey: "show_photo") } }
    /// upcoming papers go to calendarId
    var calendarSync: Bool { didSet { d.set(calendarSync, forKey: "cal_sync") } }
    var calendarId: String? { didSet { d.set(calendarId, forKey: "cal_id") } }
    /// sync flipped off because calendar access went away
    var calendarDenied: Bool { didSet { d.set(calendarDenied, forKey: "cal_denied") } }
    /// a BatchPath key picked by hand, nil means whatever the portal says
    var plannerBatch: String? { didSet { d.set(plannerBatch, forKey: "planner_batch") } }
    /// phase key to category to the elective subjects picked. a phase missing here was never set, so it gets prefilled
    var electives: [String: [String: Set<String>]] {
        didSet { d.set(try? JSONEncoder().encode(electives), forKey: "planner_electives") }
    }
    var timeline: Bool { didSet { d.set(timeline, forKey: "planner_timeline") } }
    /// grades, added courses and what-if semesters in the sgpa/cgpa calculator
    var calculator: CalculatorState { didSet { d.set(try? JSONEncoder().encode(calculator), forKey: "calculator") } }

    init() {
        themeMode = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        amoled = d.bool(forKey: "amoled")
        target = d.object(forKey: "target") as? Int ?? 75
        semester = d.string(forKey: "semester")
        showPhoto = d.bool(forKey: "show_photo")
        calendarSync = d.bool(forKey: "cal_sync")
        calendarId = d.string(forKey: "cal_id")
        calendarDenied = d.bool(forKey: "cal_denied")
        plannerBatch = d.string(forKey: "planner_batch")
        electives = (d.data(forKey: "planner_electives")).flatMap { try? JSONDecoder().decode([String: [String: Set<String>]].self, from: $0) } ?? [:]
        timeline = d.object(forKey: "planner_timeline") as? Bool ?? true
        calculator = d.data(forKey: "calculator").flatMap { try? JSONDecoder().decode(CalculatorState.self, from: $0) } ?? CalculatorState()
    }

    func setTarget(_ v: Int) { target = min(100, max(1, v)) }

    func setElectives(_ phase: String, _ picks: [String: Set<String>]) {
        var all = electives
        all[phase] = picks
        electives = all
    }

    func clearAccountBits() {
        semester = nil
        showPhoto = false
        plannerBatch = nil
        electives = [:]
        calculator = CalculatorState()
    }
}
