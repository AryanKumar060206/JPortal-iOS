import Foundation

struct Paper: Hashable, Sendable, Identifiable {
    let event: ExamEvent
    let slot: ExamSlot

    var id: String { key }
    var key: String { "\(event.id)|\(slot.code)|\(slot.date)" }
    var day: Day? { slot.day }
    var start: Date? { day.flatMap { d in slot.start.map { d.at($0) } } }
    var end: Date? { day.flatMap { d in slot.end.map { d.at($0) } } }
    var duration: Int? {
        guard let s = slot.start, let e = slot.end else { return nil }
        return e.minutes - s.minutes
    }

    /// when it's surely over. no end time, three hours covers the longest sitting
    var over: Date? { end ?? start?.addingTimeInterval(3 * 3600) ?? day?.plus(days: 1).start() }

    enum Status: Sendable { case upcoming, live, done }

    func status(_ now: Date) -> Status {
        guard let o = over else { return .upcoming }
        if now >= o { return .done }
        if let s = start, now >= s { return .live }
        return .upcoming
    }

    /// what to sort the sheet by, a paper with no date goes last
    var sortKey: Date { start ?? day?.start() ?? .distantFuture }
}

/// a day on the date sheet, free is the clear days since the exam day before it
struct ExamDay: Hashable {
    let date: Day?
    let papers: [Paper]
    let free: Int
}

/// the flat paper list turned into what the exams view draws, so the ui holds no date math
struct ExamPlan {
    let now: Date
    let next: Paper?
    let days: [ExamDay]
    let done: [Paper]
    /// paper key to the paper it overlaps
    let clashes: [String: Paper]
    /// every exam day of the events still running, for the strip
    let run: [Day]

    var today: Day { Day(now) }

    func status(_ p: Paper) -> Paper.Status { p.status(now) }

    static func of(_ papers: [Paper], now: Date) -> ExamPlan {
        let done = papers.filter { $0.status(now) == .done }
        let upcoming = papers.filter { $0.status(now) != .done }.sorted { $0.sortKey < $1.sortKey }
        var prev: Day?
        var days: [ExamDay] = []
        var groups: [(Day?, [Paper])] = []
        for p in upcoming {
            if let i = groups.firstIndex(where: { $0.0 == p.day }) { groups[i].1.append(p) } else { groups.append((p.day, [p])) }
        }
        for (date, list) in groups {
            var free = 0
            if let prev, let date { free = max(0, prev.days(until: date) - 1) }
            if let date { prev = date }
            days.append(ExamDay(date: date, papers: list, free: free))
        }
        var clashes: [String: Paper] = [:]
        for (day, list) in Dictionary(grouping: papers, by: \.day) where day != nil {
            for a in list { for b in list where a.key != b.key && overlaps(a, b) { if clashes[a.key] == nil { clashes[a.key] = b } } }
        }
        // the strip spans the events still running, done days included so you see how far in you are
        let running = Set(upcoming.map(\.event.id))
        let run = Array(Set(papers.filter { running.contains($0.event.id) }.compactMap(\.day))).sorted()
        return ExamPlan(now: now, next: upcoming.first, days: days, done: done.sorted { $0.sortKey > $1.sortKey },
                        clashes: clashes, run: run)
    }

    /// both windows known: they overlap. otherwise only the same start counts, a guessed end would cry wolf
    private static func overlaps(_ a: Paper, _ b: Paper) -> Bool {
        guard let s1 = a.start, let s2 = b.start else { return false }
        if let e1 = a.end, let e2 = b.end { return s1 < e2 && s2 < e1 }
        return s1 == s2
    }
}

func minutesText(_ m: Int) -> String {
    if m < 60 { return "\(m)m" }
    if m % 60 == 0 { return "\(m / 60)h" }
    return "\(m / 60)h \(m % 60)m"
}

// a test number, but not the weight in "TEST-20 MARKS"
private let testPattern = try! NSRegularExpression(pattern: #"\b(?:TEST|T)[-\s]?(\d++)(?!\s*-?\s*MARKS)"#)
private let marksPattern = try! NSRegularExpression(pattern: #"(\d+)\s*-?\s*MARKS"#)

/// what people call an exam: TEST-2-26ODD-20MARKS -> T2, MAKEUP TEST-20 MARKS -> Makeup
func shortExamName(_ raw: String) -> String {
    let c = raw.uppercased()
    let ns = c as NSString
    let t = testPattern.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)).map { "T" + ns.substring(with: $0.range(at: 1)) }
    if c.contains("MAKEUP") || c.contains("MAKE UP") || c.contains("MAKE-UP") { return t.map { "Makeup \($0)" } ?? "Makeup" }
    if let t { return t }
    if c.contains("END") { return "End sem" }
    if c.contains("MID") { return "Mid sem" }
    return raw.titleCase
}

/// where an exam falls in a semester, so marks read in the order they were sat
func examOrder(_ raw: String) -> Int {
    let s = shortExamName(raw)
    if s.hasPrefix("Makeup") { return 300 }
    if s.hasPrefix("T"), let n = Int(s.dropFirst()) { return n }
    if s == "Mid sem" { return 100 }
    if s == "End sem" { return 200 }
    return 250
}

/// a subject's scores in exam order. the pdf lists events in no particular order
func orderedScores(_ scores: [EventScore]) -> [EventScore] {
    scores.enumerated().sorted { a, b in
        let x = examOrder(a.element.event), y = examOrder(b.element.event)
        return x != y ? x < y : a.offset < b.offset
    }.map(\.element)
}

extension ExamEvent {
    /// TEST-2-26ODD-20MARKS -> T2
    var short: String { shortExamName(code.ifBlank(description)) }

    /// the paper's weight when the event code carries it, TEST-2-26ODD-20MARKS -> 20
    var outOf: Int? {
        let c = code.uppercased()
        let ns = c as NSString
        guard let m = marksPattern.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    var fromDay: Day? { from.map { Day(Date(timeIntervalSince1970: Double($0) / 1000)) } }
}

/// a paper the way it lands in the calendar. no start time means an all day event
struct ExamEntry: Hashable {
    let title: String
    let begin: Date
    let end: Date
    let allDay: Bool
    let location: String
    let notes: String
    /// minutes before begin
    let reminders: [Int]

    /// changes whenever anything the calendar shows does, so untouched papers skip the write
    var hash: String {
        let s = "\(title)|\(begin.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(allDay)|\(location)|\(notes)|\(reminders)"
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }
}

extension Paper {
    var entry: ExamEntry? {
        guard let day else { return nil }
        // 8 pm the evening before, to revise, and an hour before, to leave
        let eve = day.minus(days: 1).at(Clock(hour: 20, minute: 0))
        let begin = start ?? day.start()
        let s = slot
        let location = [s.room.isBlank ? nil : s.room, s.seat.isBlank ? nil : "seat \(s.seat)"].compactMap { $0 }.joined(separator: ", ")
        return ExamEntry(
            title: "\(event.short) · \(s.subjectName.titleCase)",
            begin: begin,
            end: start != nil ? (end ?? begin.addingTimeInterval(3 * 3600)) : day.plus(days: 1).start(),
            allDay: start == nil,
            location: location,
            notes: [s.code.isBlank ? nil : s.code, "synced by JPortal"].compactMap { $0 }.joined(separator: " · "),
            reminders: start != nil ? [Int(begin.timeIntervalSince(eve) / 60), 60] : [Int(day.start().timeIntervalSince(eve) / 60)]
        )
    }
}

/// an event this app wrote
struct SyncedEvent: Codable, Hashable {
    let id: String
    let hash: String
    let over: Date
}

struct SyncPlan {
    let add: [(Paper, ExamEntry)]
    let change: [(String, Paper, ExamEntry)]
    /// paper keys whose events go
    let drop: [String]
}

/// what to write so the calendar matches the sheet. upcoming papers get added or
/// updated, a paper gone from the sheet loses its event. past events are left
/// alone, a new semester's sheet shouldn't wipe the last one's history.
func syncPlan(_ sheet: [Paper], now: Date, synced: [String: SyncedEvent]) -> SyncPlan {
    let want = sheet.filter { $0.status(now) != .done }.compactMap { p in p.entry.map { (p, $0) } }
    let known = Set(sheet.map(\.key))
    return SyncPlan(
        add: want.filter { synced[$0.0.key] == nil },
        change: want.compactMap { p, e in
            guard let s = synced[p.key], s.hash != e.hash else { return nil }
            return (s.id, p, e)
        },
        drop: synced.filter { !known.contains($0.key) && $0.value.over > now }.map(\.key)
    )
}
