import XCTest
@testable import JPortal

final class DomainTests: XCTestCase {

    func testCanMissAndMustAttendMatchJPortal() {
        XCTAssertEqual(Tally(attended: 18, total: 24).canMiss(75), 0)
        XCTAssertEqual(Tally(attended: 18, total: 24).mustAttend(75), 0)
        XCTAssertEqual(Tally(attended: 20, total: 24).canMiss(75), 2)
        XCTAssertEqual(Tally(attended: 10, total: 20).mustAttend(75), 20)
        XCTAssertEqual(Tally(attended: 3, total: 4).mustAttend(100), Int.max)
    }

    func testExtrasOnlyCountWhenAttended() {
        func c(_ p: Bool, _ type: String) -> ClassRecord {
            ClassRecord(datetime: "01/09/2026 (09:00:AM - 09:50 AM)", present: p ? "Present" : "Absent", classType: type)
        }
        XCTAssertEqual(AttendanceMath.tally([c(true, "Regular"), c(true, "Regular"), c(false, "Regular"), c(true, "Extra")]), Tally(attended: 3, total: 3))
        XCTAssertEqual(AttendanceMath.tally([c(true, "Regular"), c(true, "Regular"), c(false, "Regular"), c(false, "Extra")]), Tally(attended: 2, total: 3))
    }

    func testTitleCaseKeepsAcronyms() {
        XCTAssertEqual("BLOCKCHAIN AND ITS APPLICATIONS".titleCase, "Blockchain and Its Applications")
        XCTAssertEqual("DATABASE SYSTEMS AND WEB".titleCase, "Database Systems and Web")
        XCTAssertEqual("FUNDAMENTALS OF IOT ANALYTICS LAB".titleCase, "Fundamentals of IOT Analytics Lab")
        XCTAssertEqual("DIGITAL SIGNAL PROCESSING (DSP)".titleCase, "Digital Signal Processing (DSP)")
        XCTAssertEqual("AN INTRODUCTION TO DBMS".titleCase, "An Introduction to DBMS")
        XCTAssertEqual("SUMMER TRAINING - II".titleCase, "Summer Training - II")
        XCTAssertEqual("DR. A.K.  RAO".nameCase, "Dr. A.K. Rao")
        XCTAssertEqual(prettySemester("2026ODDSEM"), "Odd 2026")
        XCTAssertEqual(prettySemester("2025EVESEM"), "Even 2025")
    }

    func testDayMath() {
        let d = Day(year: 2026, month: 9, day: 24)
        XCTAssertEqual(d.weekday, 4) // a thursday
        XCTAssertEqual(Day(epochDay: d.epochDay), d)
        XCTAssertEqual(d.plus(days: 8), Day(year: 2026, month: 10, day: 2))
        XCTAssertEqual(d.monday, Day(year: 2026, month: 9, day: 21))
        XCTAssertEqual(Day(year: 2024, month: 3, day: 1).minus(days: 1), Day(year: 2024, month: 2, day: 29))
    }

    func testProjectedCgpaIsCreditWeighted() {
        let results = [SemesterResult(semester: 1, sgpa: 8, cgpa: 8, courseCredits: 20), SemesterResult(semester: 2, sgpa: 9, cgpa: 8.5, courseCredits: 20)]
        // semester 4 has a what-if but no known credits, so it isn't drawn
        let pts = Gpa.points(results, projections: [3: 10, 4: 9], credits: [3: 20], maxSemesters: 8)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[1].cgpa, 8.5, accuracy: 1e-9)
        XCTAssertEqual(pts[2].cgpa, 9.0, accuracy: 1e-9)
        XCTAssertTrue(pts[2].projected)
    }

    func testWhatIfCreditsOnlyWhereKnown() {
        let now = SemesterInfo(code: "2026ODDSEM", number: 5, result: nil, grades: [], subjects: [
            SubjectInfo(semesterCode: "2026ODDSEM", code: "A", name: "A", credits: 4, teachers: [], audit: false, grade: nil),
            SubjectInfo(semesterCode: "2026ODDSEM", code: "B", name: "B", credits: 3, teachers: [], audit: true, grade: nil),
            SubjectInfo(semesterCode: "2026ODDSEM", code: "C", name: "C", credits: 2, teachers: [], audit: false, grade: nil),
        ], current: true)
        let a = Academics(semesters: [now], results: Resource(), currentCode: now.code, loading: false)
        // the credits page names its semester
        XCTAssertEqual(a.whatIfCredits(Credits(registeredCredits: 21, semester: "5"), after: 4), [5: 21])
        // credits for a semester that already has a result don't count, the current subjects add up instead
        XCTAssertEqual(a.whatIfCredits(Credits(registeredCredits: 21, semester: "4"), after: 4), [5: 6])
        XCTAssertEqual(a.whatIfCredits(nil, after: 4), [5: 6])
        // once this semester's result is in, nothing ahead has known credits
        XCTAssertEqual(a.whatIfCredits(nil, after: 5), [:])
    }

    func testPaperStatusAndPlan() {
        let ev = ExamEvent(id: "E2", code: "TEST-2-26ODD-20MARKS")
        let today = Day(year: 2026, month: 10, day: 12)
        let a = Paper(event: ev, slot: ExamSlot(date: "12/10/2026", from: "03:30 pm", until: "03:30 pm to 04:30 pm", subject: "A(X1)", code: "X1"))
        let b = Paper(event: ev, slot: ExamSlot(date: "12/10/2026", from: "04:00 pm", until: "04:00 pm to 05:00 pm", subject: "B(X2)", code: "X2"))
        let c = Paper(event: ev, slot: ExamSlot(date: "15/10/2026", from: "09:00 am", until: "09:00 am to 10:00 am", subject: "C(X3)", code: "X3"))
        XCTAssertEqual(a.status(today.at(Clock(hour: 15, minute: 29))), .upcoming)
        XCTAssertEqual(a.status(today.at(Clock(hour: 15, minute: 30))), .live)
        XCTAssertEqual(a.status(today.at(Clock(hour: 16, minute: 30))), .done)
        let plan = ExamPlan.of([c, b, a], now: today.at(Clock(hour: 9, minute: 0)))
        XCTAssertEqual(plan.next?.key, a.key)
        XCTAssertEqual(plan.days.count, 2)
        XCTAssertEqual(plan.days[1].free, 2)
        XCTAssertEqual(plan.clashes[a.key]?.key, b.key)
        XCTAssertEqual(ev.short, "T2")
        XCTAssertEqual(ev.outOf, 20)
        XCTAssertEqual(ExamEvent(id: "E3", code: "END TERM 2026").short, "End sem")
    }

    func testPaperBecomesCalendarEntry() {
        let ev = ExamEvent(id: "E2", code: "T2")
        let p = Paper(event: ev, slot: ExamSlot(date: "12/10/2026", from: "09:30 am", until: "09:30 am to 11:00 am",
                                               subject: "COMPILER DESIGN(15B11CI712)", code: "15B11CI712", room: "CR-4", seat: "B12"))
        let e = p.entry!
        XCTAssertEqual(e.title, "T2 · Compiler Design")
        XCTAssertEqual(e.location, "CR-4, seat B12")
        XCTAssertEqual(e.notes, "15B11CI712 · synced by JPortal")
        XCTAssertEqual(e.reminders, [13 * 60 + 30, 60])
        let plan = syncPlan([p], now: Day(year: 2026, month: 10, day: 1).start(), synced: [:])
        XCTAssertEqual(plan.add.count, 1)
    }

    func testTimetableFromTheCdn() throws {
        let url = try XCTUnwrap(Bundle(for: DomainTests.self).url(forResource: "planner.cbor", withExtension: "gz"))
        let t = try decodeTimetable(try Data(contentsOf: url))
        XCTAssertFalse(t.version.isEmpty)
        XCTAssertFalse(t.courses.isEmpty)
        let batches = t.courses.flatMap(\.semesters).flatMap(\.phases).flatMap(\.batches)
        XCTAssertFalse(batches.isEmpty)
        let classes = batches.flatMap(\.classes)
        XCTAssertFalse(classes.isEmpty)
        XCTAssertTrue(classes.allSatisfy { (1...7).contains($0.day) && $0.start < $0.end && !$0.subject.isEmpty })
    }

    func testDayPlanFindsGaps() {
        func k(_ s: Int, _ e: Int) -> Klass {
            Klass(day: 1, start: Clock(hour: s, minute: 0), end: Clock(hour: e, minute: 0), subject: "S\(s)", code: "", teacher: "",
                  venue: "", type: "L", category: nil, elective: false, batches: [])
        }
        let plan = DayPlan.of([k(9, 10), k(10, 11), k(14, 15)], now: Clock(hour: 10, minute: 30))
        XCTAssertEqual(plan.rows.count, 4)
        XCTAssertEqual(plan.rows[2], .free(180))
        XCTAssertEqual(plan.live.count, 1)
    }

    @MainActor
    func testDemoSeedsEveryStore() async throws {
        let cache = Cache(name: "test-demo")
        cache.clear()
        Demo.seed(cache)
        func decode<T: Decodable>(_ key: String, _: T.Type) throws -> T {
            let e = try XCTUnwrap(cache.get(key), key)
            return try JSONDecoder().decode(T.self, from: e.data)
        }
        let meta = try decode("att_meta", AttendanceMeta.self)
        XCTAssertEqual(meta.semesters.first?.code, "2026ODDSEM")
        let detail = try decode("att:D26O", AttendanceDetail.self)
        XCTAssertEqual(detail.subjects.count, 7)
        let daily = try decode("daily:D26O:S1", DailyAttendance.self)
        XCTAssertGreaterThan(daily.classes.count, 20)
        XCTAssertGreaterThan(try decode("marks:D26O", MarksReport.self).subjects.count, 0)
        XCTAssertEqual(try decode("results", [SemesterResult].self).count, 6)
        XCTAssertNotNil(try decode("hostel", HostelAnswer.self).info)
        cache.clear()
    }
}
