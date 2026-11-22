import Foundation

/// attended / total with the target-driven verdicts jportal users know
struct Tally: Hashable, Sendable {
    let attended: Int
    let total: Int

    static let zero = Tally(attended: 0, total: 0)

    var percent: Double { total == 0 ? 0 : Double(attended) * 100 / Double(total) }

    /// classes you can skip and still sit at or above target%
    func canMiss(_ target: Int) -> Int {
        if target <= 0 || total == 0 { return 0 }
        return max(0, Int(((100.0 * Double(attended) - Double(target * total)) / Double(target)).rounded(.down)))
    }

    /// classes in a row you need to climb back to target%
    func mustAttend(_ target: Int) -> Int {
        if target >= 100 { return attended < total ? Int.max : 0 }
        return max(0, Int(((Double(target * total) - 100.0 * Double(attended)) / Double(100 - target)).rounded(.up)))
    }
}

enum DayMark: Sendable { case present, absent, mixed }

enum AttendanceMath {
    /// the portal's rule: every present class over the regular ones, an extra can only help
    static func tally(_ classes: [ClassRecord]) -> Tally {
        Tally(attended: classes.filter(\.isPresent).count, total: classes.filter { !$0.isExtra }.count)
    }

    /// per day: all present, all absent, or a split day
    static func calendar(_ classes: [ClassRecord]) -> [Day: DayMark] {
        var out: [Day: DayMark] = [:]
        for (day, list) in Dictionary(grouping: classes.filter { $0.date != nil }, by: { $0.date! }) {
            let p = list.filter(\.isPresent).count
            out[day] = p == list.count ? .present : p == 0 ? .absent : .mixed
        }
        return out
    }

    static func sorted(_ classes: [ClassRecord]) -> [ClassRecord] {
        classes.filter { $0.date != nil }.sorted { a, b in
            if a.date! != b.date! { return a.date! < b.date! }
            return (a.start?.minutes ?? -1) < (b.start?.minutes ?? -1)
        }
    }

    /// running percentage after each class, oldest first, for the trend line
    static func trend(_ classes: [ClassRecord]) -> [(Day, Double)] {
        var present = 0
        var regular = 0
        return sorted(classes).compactMap { c in
            if c.isPresent { present += 1 }
            if !c.isExtra { regular += 1 }
            // an extra before any regular class has no bottom to divide by yet
            return regular == 0 ? nil : (c.date!, Double(present) * 100 / Double(regular))
        }
    }
}

/// one point on the gpa chart, real or projected
struct GpaPoint: Hashable, Sendable {
    let semester: Int
    var sgpa: Double
    let credits: Double
    var cgpa: Double
    var projected: Bool
}

/// port of jportal's gpaCalculations: cgpa is credit weighted sgpa over every
/// semester so far. projections are extra semesters the user drags around.
enum Gpa {
    /// credits: semester number to credits, for the future semesters whose credits are known.
    /// a what-if anywhere else would have to guess how much it weighs, so it isn't drawn
    static func points(_ results: [SemesterResult], projections: [Int: Double], credits: [Int: Double], maxSemesters: Int) -> [GpaPoint] {
        let real = results.sorted { $0.semester < $1.semester }.map {
            GpaPoint(semester: $0.semester, sgpa: $0.sgpa, credits: creditsOf($0), cgpa: $0.cgpa, projected: false)
        }
        let next = (real.map(\.semester).max() ?? 0) + 1
        let future: [GpaPoint] = next <= maxSemesters ? (next...maxSemesters).compactMap { s in
            guard let v = projections[s], let c = credits[s], c > 0 else { return nil }
            return GpaPoint(semester: s, sgpa: v, credits: c, cgpa: 0, projected: true)
        } : []
        let adjusted = real.map { p -> GpaPoint in
            guard let v = projections[p.semester] else { return p }
            var q = p
            q.sgpa = v
            q.projected = true
            return q
        }
        return recompute(adjusted + future, keepReal: true)
    }

    private static func creditsOf(_ r: SemesterResult) -> Double { r.courseCredits > 0 ? r.courseCredits : r.earnedCredits }

    /// recomputes cgpa down the line; real untouched semesters keep the portal's own figure
    static func recompute(_ points: [GpaPoint], keepReal: Bool) -> [GpaPoint] {
        var gp = 0.0
        var cr = 0.0
        var anyProjected = false
        return points.map { p in
            gp += p.sgpa * p.credits
            cr += p.credits
            anyProjected = anyProjected || p.projected
            if keepReal && !anyProjected { return p }
            var q = p
            q.cgpa = cr > 0 ? gp / cr : 0
            return q
        }
    }
}
