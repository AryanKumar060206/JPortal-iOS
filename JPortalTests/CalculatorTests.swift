import XCTest
@testable import JPortal

final class CalculatorTests: XCTestCase {

    func testGradeScale() {
        XCTAssertEqual(GradeScale.points("A+"), 10)
        XCTAssertEqual(GradeScale.points(" b+ "), 8)
        XCTAssertEqual(GradeScale.points("F"), 0)
        XCTAssertNil(GradeScale.points("X"))
        XCTAssertNil(GradeScale.points(""))
    }

    func testSgpaIsCreditWeighted() {
        let r = GradeCalc.sgpa([(4, "A+"), (3, "B"), (1, "F")])
        XCTAssertEqual(r.sgpa!, 61.0 / 8.0, accuracy: 1e-9)
        XCTAssertTrue(r.complete)
        XCTAssertEqual(r.credits, 8)
    }

    func testPartialSgpaSkipsUngradedCourses() {
        let r = GradeCalc.sgpa([(4, "A"), (3, nil), (0, "A+")])
        XCTAssertEqual(r.sgpa!, 9, accuracy: 1e-9)
        XCTAssertEqual(r.graded, 1)
        XCTAssertEqual(r.total, 2) // a zero credit course isn't a course here
        XCTAssertFalse(r.complete)
        XCTAssertNil(GradeCalc.sgpa([(4, nil)]).sgpa)
    }

    // a real account's four finished semesters: the portal's sgpas are rounded, its grade points aren't
    private let results = [
        SemesterResult(semester: 1, sgpa: 7.8, cgpa: 7.8, courseCredits: 22.5, gradePoints: 176.5),
        SemesterResult(semester: 2, sgpa: 7.8, cgpa: 7.8, courseCredits: 18.5, gradePoints: 144),
        SemesterResult(semester: 3, sgpa: 9.29, cgpa: 8.36, courseCredits: 24, gradePoints: 223),
        SemesterResult(semester: 4, sgpa: 8.21, cgpa: 8.32, courseCredits: 24, gradePoints: 197),
    ]

    func testCgpaLandsOnTheOfficialFigure() {
        let cgpa = GradeCalc.cgpa(results.map(GradeCalc.totals))!
        XCTAssertEqual(String(format: "%.2f", cgpa), "8.32")
        // the rounded sgpas alone would have said 8.31
        let rounded = GradeCalc.cgpa(results.map { ($0.sgpa * $0.courseCredits, $0.courseCredits) })!
        XCTAssertEqual(String(format: "%.2f", rounded), "8.31")
    }

    func testProjectedCgpaAddsThisSemester() {
        let thisTerm = GradeCalc.sgpa(Array(repeating: (3.0, "A" as String?), count: 7))
        let cgpa = GradeCalc.cgpa(results.map(GradeCalc.totals) + [(thisTerm.points, thisTerm.credits)])!
        XCTAssertEqual(cgpa, (740.5 + 189) / 110, accuracy: 1e-9)
    }

    func testCoursesSkipAuditAndPrefillFromTheGradeCard() {
        let sem = SemesterInfo(code: "2026EVESEM", number: 4, result: nil, grades: [], subjects: [
            SubjectInfo(semesterCode: "2026EVESEM", code: "C1", name: "CIRCUITS", credits: 4, teachers: [], audit: false, grade: "A"),
            SubjectInfo(semesterCode: "2026EVESEM", code: "C2", name: "CONSTITUTION", credits: 3, teachers: [], audit: true, grade: "B"),
            SubjectInfo(semesterCode: "2026EVESEM", code: "C3", name: "SEMINAR", credits: 0, teachers: [], audit: false, grade: nil),
            SubjectInfo(semesterCode: "2026EVESEM", code: "C4", name: "SIGNALS", credits: 3, teachers: [], audit: false, grade: nil),
        ], current: false)
        var state = CalculatorState()
        let courses = CalcCourse.list(sem, state)
        XCTAssertEqual(courses.map(\.id), ["C1", "C4"])
        XCTAssertEqual(courses[0].grade(in: sem.code, state), "A")
        XCTAssertTrue(courses[0].fromCard(in: sem.code, state))
        // a pick wins over the grade card, and clearing on purpose keeps it cleared
        state.grades[sem.code] = ["C1": "B+", "C4": "A+"]
        XCTAssertEqual(CalcCourse.sgpa(sem, state).sgpa!, (4 * 8 + 3 * 10) / 7.0, accuracy: 1e-9)
        state.grades[sem.code]?["C1"] = ""
        XCTAssertNil(courses[0].grade(in: sem.code, state))
        // leaving a course out takes it off both sides of the fraction
        state.leftOut[sem.code] = ["C1"]
        XCTAssertEqual(CalcCourse.sgpa(sem, state).sgpa!, 10, accuracy: 1e-9)
        // added courses count like registered ones
        state.added[sem.code] = [AddedCourse(id: "x", name: "Extra", credits: 3)]
        state.grades[sem.code]?["x"] = "C"
        XCTAssertEqual(CalcCourse.sgpa(sem, state).sgpa!, (30 + 15) / 6.0, accuracy: 1e-9)
    }
}
