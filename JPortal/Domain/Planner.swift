import Foundation

/// one slot on the weekly timetable, shared by every batch it lists
struct Klass: Hashable, Sendable {
    /// iso weekday, 1 is monday
    let day: Int
    let start: Clock
    let end: Clock
    let subject: String
    let code: String
    let teacher: String
    let venue: String
    /// L, T or P
    let type: String
    let category: String?
    let elective: Bool
    let batches: [String]
}

/// every course's weekly timetable, as the planner cdn publishes it
struct Timetable: Sendable {
    struct Course: Sendable { let id: String; let name: String; let semesters: [Semester] }
    struct Semester: Sendable { let id: String; let name: String; let phases: [Phase] }
    struct Phase: Sendable { let id: String; let name: String; let batches: [Batch] }
    /// classes already holds every elective the batch could sit, picks narrow it down
    struct Batch: Sendable { let id: String; let name: String; let classes: [Klass] }

    let version: String
    let courses: [Course]

    func batch(_ path: BatchPath) -> Batch? {
        courses.first { $0.id == path.course }?
            .semesters.first { $0.id == path.semester }?
            .phases.first { $0.id == path.phase }?
            .batches.first { $0.id == path.batch }
    }

    /// the student's batch, from what the portal calls it: the one batch with that
    /// id in their semester. batch ids don't repeat across courses within a
    /// semester, so program only breaks a tie. none or still a tie means the picker asks.
    func detect(batch: String, semester: Int, program: String) -> BatchPath? {
        let want = batch.trimmingCharacters(in: .whitespaces)
        if want.isEmpty || semester <= 0 { return nil }
        var hits: [BatchPath] = []
        for c in courses {
            for s in c.semesters where s.id == "sem\(semester)" {
                for p in s.phases {
                    for b in p.batches where b.id.caseInsensitiveCompare(want) == .orderedSame {
                        hits.append(BatchPath(course: c.id, semester: s.id, phase: p.id, batch: b.id))
                    }
                }
            }
        }
        if hits.count <= 1 { return hits.first }
        let bca = program.range(of: "BCA", options: .caseInsensitive) != nil
        let narrowed = hits.filter { $0.course.hasPrefix("bca") == bca }
        return narrowed.count == 1 ? narrowed[0] : nil
    }
}

struct BatchPath: Hashable, Sendable {
    let course: String
    let semester: String
    let phase: String
    let batch: String

    var key: String { "\(course)/\(semester)/\(phase)/\(batch)" }
    /// electives are picked per phase, a batch change inside it keeps them
    var phaseKey: String { "\(course)/\(semester)/\(phase)" }

    static func parse(_ key: String?) -> BatchPath? {
        guard let p = key?.split(separator: "/", omittingEmptySubsequences: false), p.count == 4 else { return nil }
        return BatchPath(course: String(p[0]), semester: String(p[1]), phase: String(p[2]), batch: String(p[3]))
    }
}

extension Timetable.Batch {
    /// what the picker offers: elective category to its subjects
    func electives() -> [(String, [String])] {
        Dictionary(grouping: classes.filter(\.elective), by: { $0.category ?? "" })
            .map { ($0.key, Array(Set($0.value.map(\.subject))).sorted()) }
            .sorted { $0.0 < $1.0 }
    }

    /// picks from the subjects registered on the portal, matched on code, then on name
    func prefill(_ registered: [(String, String)]) -> [String: Set<String>] {
        let codes = Set(registered.map { $0.0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })
        let names = Set(registered.map { $0.1.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        let hits = classes.filter {
            $0.elective && (codes.contains($0.code.trimmingCharacters(in: .whitespaces).uppercased()) ||
                names.contains($0.subject.trimmingCharacters(in: .whitespaces).lowercased()))
        }
        return Dictionary(grouping: hits, by: { $0.category ?? "" }).mapValues { Set($0.map(\.subject)) }
    }

    /// the batch's week: everything that isn't an elective, and the electives picked in their category
    func week(_ picks: [String: Set<String>]) -> [Klass] {
        classes.filter { !$0.elective || (picks[$0.category ?? ""] ?? []).contains($0.subject) }
            .sorted { a, b in
                if a.day != b.day { return a.day < b.day }
                if a.start != b.start { return a.start < b.start }
                return a.end < b.end
            }
    }
}

/// one day of the week as the planner draws it, classes with the free stretches between them
struct DayPlan {
    enum Row: Hashable {
        case klass(Klass)
        case free(Int)
    }

    let rows: [Row]
    let live: Set<Klass>

    static let minFree = 30

    /// classes sorted by start. now only on the day it is, nil on every other
    static func of(_ classes: [Klass], now: Clock?) -> DayPlan {
        var rows: [Row] = []
        // measured from the latest end so far, two overlapping slots never fake a gap
        var until: Clock?
        for k in classes {
            if let u = until, k.start.minutes - u.minutes >= minFree { rows.append(.free(k.start.minutes - u.minutes)) }
            rows.append(.klass(k))
            until = until.map { max($0, k.end) } ?? k.end
        }
        let live = now.map { n in Set(classes.filter { n >= $0.start && n < $0.end }) } ?? []
        return DayPlan(rows: rows, live: live)
    }
}
