import Foundation

/// a calendar date with no time or zone, java's LocalDate. day math goes through
/// the epoch day so it never trips over daylight saving or time zones.
struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// days since 1970-01-01
    var epochDay: Int {
        // howard hinnant's days_from_civil
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    init(epochDay z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    /// iso weekday, 1 is monday and 7 is sunday
    var weekday: Int { ((epochDay % 7) + 7 + 3) % 7 + 1 }

    func plus(days: Int) -> Day { Day(epochDay: epochDay + days) }
    func minus(days: Int) -> Day { Day(epochDay: epochDay - days) }
    func days(until other: Day) -> Int { other.epochDay - epochDay }

    /// monday of this date's week
    var monday: Day { minus(days: weekday - 1) }

    static func < (a: Day, b: Day) -> Bool { a.epochDay < b.epochDay }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init?(iso: String) {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        self.init(year: p[0], month: p[1], day: p[2])
    }

    /// dd/MM/yyyy, the portal's favourite
    init?(dmy: String, separator: Character = "/") {
        let p = dmy.trimmingCharacters(in: .whitespaces).split(separator: separator)
        guard p.count == 3, let d = Int(p[0]), let m = Int(p[1]), let y = Int(p[2].prefix(4)),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// midnight at the start of this day, in the device's zone
    func start(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    func at(_ clock: Clock, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: clock.hour, minute: clock.minute)) ?? start(calendar: calendar)
    }

    static func today() -> Day { Day(AppClock.now()) }

    func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: at(Clock(hour: 12, minute: 0)))
    }
}

/// a wall clock time, java's LocalTime, as minutes since midnight
struct Clock: Hashable, Comparable, Codable, Sendable {
    let minutes: Int

    init(minutes: Int) { self.minutes = minutes }
    init(hour: Int, minute: Int) { minutes = hour * 60 + minute }

    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }

    static func < (a: Clock, b: Clock) -> Bool { a.minutes < b.minutes }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// "9:30" or "9:30 AM"
    func format(ampm: Bool = true) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let base = String(format: "%d:%02d", h12, minute)
        return ampm ? base + (hour < 12 ? " AM" : " PM") : base
    }

    var ampm: String { hour < 12 ? "AM" : "PM" }
}

/// the ui's idea of now, one place to pin it
enum AppClock {
    nonisolated(unsafe) static var offset: TimeInterval = 0
    static func now() -> Date { Date().addingTimeInterval(offset) }
    static func millis() -> Int64 { Int64(now().timeIntervalSince1970 * 1000) }
}
