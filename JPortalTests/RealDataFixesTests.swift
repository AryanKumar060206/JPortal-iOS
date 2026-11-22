import XCTest
@testable import JPortal

/// bugs found running against a real account in november, when the portal
/// already lists next term's registration first
final class RealDataFixesTests: XCTestCase {
    // the order a real attendance list came back in
    private let codes = ["2027EVENSEM", "2026ODDSEM", "SUMMER2026", "2026EVESEM", "2025ODDSEM", "2025EVESEM"]
    private var sems: [Semester] { codes.enumerated().map { Semester(id: "R\($0.offset)", code: $0.element) } }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { Day(year: y, month: m, day: d).at(Clock(hour: 12, minute: 0)) }

    func testCurrentSemesterSkipsNextTermsRegistration() {
        XCTAssertEqual(currentSemester(sems, now: date(2026, 11, 21))?.code, "2026ODDSEM")
        // once january comes the even term is the one going on
        XCTAssertEqual(currentSemester(sems, now: date(2027, 1, 10))?.code, "2027EVENSEM")
        XCTAssertEqual(currentSemester(sems, now: date(2026, 3, 1))?.code, "2026EVESEM")
        XCTAssertNil(currentSemester([], now: date(2026, 11, 21)))
        // nothing started yet: fall back to the head, as before
        XCTAssertEqual(currentSemester([Semester(id: "x", code: "2030ODDSEM")], now: date(2026, 11, 21))?.code, "2030ODDSEM")
    }

    func testSemesterNumbersCountFromTheCurrentTerm() {
        func n(_ code: String) -> Int? { semesterNumber(code, current: "2026ODDSEM", currentNumber: 5) }
        XCTAssertEqual(n("2026ODDSEM"), 5)
        XCTAssertEqual(n("2026EVESEM"), 4)
        XCTAssertEqual(n("2025ODDSEM"), 3)
        XCTAssertEqual(n("2025EVESEM"), 2)
        XCTAssertEqual(n("2024ODDSEM"), 1)
        XCTAssertEqual(n("2027EVENSEM"), 6)
        XCTAssertNil(n("SUMMER2026"))
        XCTAssertNil(n("2023ODDSEM"))
    }

    func testCourseLengthIgnoresRegisteredMax() {
        XCTAssertEqual(courseLength(StudentProgram(programCode: "B.T", program: "BACHELOR OF TECHNOLOGY", maxSemesters: 6)), 8)
        XCTAssertEqual(courseLength(StudentProgram(programCode: "BCA", program: "BACHELOR OF COMPUTER APPLICATIONS", maxSemesters: 2)), 6)
        XCTAssertEqual(courseLength(StudentProgram(programCode: "M.T", program: "MASTER OF TECHNOLOGY", maxSemesters: 2)), 4)
        XCTAssertEqual(courseLength(nil), 8)
        XCTAssertEqual(courseLength(StudentProgram(programCode: "B.T", maxSemesters: 10)), 10)
    }

    func testTitleCaseAcrossHyphensAndVowelAcronyms() {
        XCTAssertEqual("SUMMER TRAINING-II (6 WEEKS)".titleCase, "Summer Training-II (6 Weeks)")
        XCTAssertEqual("INTRODUCTION TO FPGA DESIGN".titleCase, "Introduction to FPGA Design")
        XCTAssertEqual("PHYSICS LAB-I".titleCase, "Physics Lab-I")
        XCTAssertEqual("SELF-STUDY".titleCase, "Self-Study")
        // the cases that already worked still do
        XCTAssertEqual("SUMMER TRAINING - II".titleCase, "Summer Training - II")
        XCTAssertEqual("BLOCKCHAIN AND ITS APPLICATIONS".titleCase, "Blockchain and Its Applications")
    }

    func testSummerTermLabels() {
        XCTAssertEqual(prettySemester("SUMMER2026"), "Summer 2026")
        XCTAssertEqual(prettySemester("2026SUMSEM"), "Summer 2026")
        XCTAssertEqual(prettySemester("2027EVENSEM"), "Even 2027")
    }

    func testShortExamNamesAndOrder() {
        XCTAssertEqual(shortExamName("TEST-2-26ODD-20MARKS"), "T2")
        XCTAssertEqual(shortExamName("TEST-1"), "T1")
        XCTAssertEqual(shortExamName("MAKEUP TEST-20 MARKS"), "Makeup")
        XCTAssertEqual(shortExamName("END TERM 2026"), "End sem")
        XCTAssertEqual(ExamEvent(id: "E", code: "MAKEUP TEST-20 MARKS").short, "Makeup")
        let scores = ["TEST-2-26ODD-20MARKS", "TEST-1", "MAKEUP TEST-20 MARKS"].map { EventScore(event: $0) }
        XCTAssertEqual(orderedScores(scores).map(\.event), ["TEST-1", "TEST-2-26ODD-20MARKS", "MAKEUP TEST-20 MARKS"])
    }

    func testNotAHostellerMeansNoHostel() {
        XCTAssertTrue(PortalError.portal(errors: ["You are not a hosteller student"], code: 200).meansNoHostel)
        XCTAssertTrue(PortalError.portal(errors: ["NO RECORD FOUND"], code: 200).meansNoHostel)
        XCTAssertFalse(PortalError.portal(errors: ["Something else"], code: 200).meansNoHostel)
        XCTAssertFalse(PortalError.emptyResponse.meansNoHostel)
    }

    // a timeout gets one more go from the store, but never the transport's quick-fire retries
    func testTimeoutsAreTriedOnceMoreNotHammered() {
        let slow = PortalError.network("timed out", timedOut: true)
        XCTAssertTrue(slow.timedOut)
        XCTAssertFalse(slow.transient)
        let dropped = PortalError.network("connection lost", timedOut: false)
        XCTAssertFalse(dropped.timedOut)
        XCTAssertTrue(dropped.transient)
        XCTAssertFalse(PortalError.sessionExpired.timedOut)
    }
}
