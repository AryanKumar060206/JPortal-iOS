import Foundation

/// jiit's ten point scale, as the grade cards print it
enum GradeScale {
    static let grades: [(letter: String, points: Double)] = [
        ("A+", 10), ("A", 9), ("B+", 8), ("B", 7), ("C+", 6), ("C", 5), ("D", 4), ("F", 0),
    ]

    static func points(_ letter: String) -> Double? {
        let l = letter.trimmingCharacters(in: .whitespaces).uppercased()
        return grades.first { $0.letter == l }?.points
    }
}

/// a semester's sgpa from whatever grades are picked so far
struct SgpaResult: Equatable {
    let sgpa: Double?
    let graded: Int
    let total: Int
    /// credits of the graded courses
    let credits: Double
    /// Σ credits × grade points over the graded courses
    let points: Double

    var complete: Bool { total > 0 && graded == total }
}

enum GradeCalc {
    /// SGPA = Σ (credits × grade points) ÷ Σ credits, over the courses that have a grade.
    /// an F counts 0 and keeps its credits in the bottom of the fraction
    static func sgpa(_ courses: [(credits: Double, grade: String?)]) -> SgpaResult {
        let counted = courses.filter { $0.credits > 0 }
        var credits = 0.0, points = 0.0, graded = 0
        for c in counted {
            guard let g = c.grade, let p = GradeScale.points(g) else { continue }
            credits += c.credits
            points += c.credits * p
            graded += 1
        }
        return SgpaResult(sgpa: credits > 0 ? points / credits : nil, graded: graded, total: counted.count, credits: credits, points: points)
    }

    /// a finished semester's points and credits. the portal's sgpa is rounded, its earned grade points aren't,
    /// so adding those up lands exactly on the official cgpa
    static func totals(_ r: SemesterResult) -> (points: Double, credits: Double) {
        let credits = r.courseCredits > 0 ? r.courseCredits : r.earnedCredits
        return (r.gradePoints > 0 ? r.gradePoints : r.sgpa * credits, credits)
    }

    /// CGPA = Σ points ÷ Σ credits across semesters
    static func cgpa(_ parts: [(points: Double, credits: Double)]) -> Double? {
        let credits = parts.reduce(0) { $0 + $1.credits }
        return credits > 0 ? parts.reduce(0) { $0 + $1.points } / credits : nil
    }
}

/// what the calculator remembers between visits, saved on the phone
struct CalculatorState: Codable, Equatable {
    /// semester code to course id to the grade picked. "" means cleared on purpose, so a grade card grade doesn't come back
    var grades: [String: [String: String]] = [:]
    /// semester code to course ids left out of the sgpa
    var leftOut: [String: [String]] = [:]
    /// semester code to courses added by hand
    var added: [String: [AddedCourse]] = [:]
    /// what-if semesters after the current one
    var plans: [PlannedSemester] = []
}

struct AddedCourse: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var credits: Double
}

struct PlannedSemester: Codable, Equatable, Identifiable {
    var id: String
    var sgpa: Double
    var credits: Double
}
