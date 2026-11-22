import XCTest
@testable import JPortal

private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
    let bundle = Bundle(for: PortalTests.self)
    guard let url = bundle.url(forResource: name, withExtension: ext) else {
        throw XCTSkip("missing fixture \(name).\(ext)")
    }
    return try Data(contentsOf: url)
}

/// the `response` part of a captured portal envelope
private func response(_ name: String) throws -> JSON {
    try JSON(parsing: try fixture(name))["response"]
}

private func iso(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)!
}

final class PortalTests: XCTestCase {

    // vectors from an independent python implementation, the same ones ktjiit checks
    func testCipherVectors() {
        let vectors = [
            ("2026-09-23T20:44:33+05:30", "2023396", "0OE33AqLdJLsiqun/b7P0ebzcZlU9Zex+WARnofRJmk="),
            ("2026-09-20T23:59:59+05:30", "2020096", "6OcujOtkGhS78wcGcPqDz/SQLWnIHprl1x2aIuWVdq8="),
            ("2026-09-20T18:30:00+00:00", "2021196", "NFduuMZDQ4pnjC6rENqxPC3BIz9Ss0uI1lxVmttCoNg="),
            ("2027-01-01T00:00:00+05:30", "0025117", "QaE6RaKmOSXveL+WS5Yjun1r6o39jDJ10IwjB69Hk2Q="),
        ]
        for (at, seq, cipher) in vectors {
            let t = iso(at)
            XCTAssertEqual(dateSeq(t), seq, at)
            XCTAssertEqual(PortalCipher.encrypt(#"{"instituteid":"TEST"}"#, at: t), cipher, at)
            XCTAssertEqual(PortalCipher.decrypt(cipher, at: t), #"{"instituteid":"TEST"}"#, at)
        }
    }

    func testUtcEveningIsTomorrowInIST() {
        XCTAssertEqual(dateSeq(iso("2026-09-20T18:30:00Z")), "2021196")
        XCTAssertEqual(dateSeq(iso("2026-09-20T18:29:59Z")), "2020096")
    }

    func testLocalNameCarriesDateSeq() {
        let t = iso("2026-09-23T15:14:33Z")
        let plain = PortalCipher.decrypt(PortalCipher.localName(t), at: t)!
        XCTAssertEqual(plain.count, 16)
        XCTAssertEqual(String(Array(plain)[4..<11]), dateSeq(t))
    }

    func testClockFollowsServerDate() {
        let local = iso("2026-09-23T15:44:00Z")
        let clock = PortalClock { local }
        clock.observe("Wed, 23 Sep 2026 15:35:32 GMT")
        XCTAssertEqual(clock.skew, -508, accuracy: 0.001)
        XCTAssertEqual(clock.now(), iso("2026-09-23T15:35:32Z"))
        clock.observe("garbage")
        XCTAssertEqual(clock.skew, -508, accuracy: 0.001)
    }

    func testEnvelopeUnwrap() throws {
        let t = Transport()
        let ok = Transport.Raw(code: 200, body: Data(#"{"status":{"responseStatus":"Success"},"response":{"a":1}}"#.utf8), contentType: "application/json")
        XCTAssertEqual(try t.unwrap(ok)["a"].int, 1)
        let none = Transport.Raw(code: 200, body: Data(#"{"status":{"responseStatus":"Failure","errors":["NO ATTENDANCE FOUND"]}}"#.utf8), contentType: nil)
        XCTAssertThrowsError(try t.unwrap(none)) { e in XCTAssertTrue((e as? PortalError)?.isNoData == true) }
        XCTAssertThrowsError(try t.unwrap(Transport.Raw(code: 200, body: Data(), contentType: nil))) { e in
            guard case .emptyResponse = e as? PortalError else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try t.unwrap(Transport.Raw(code: 401, body: Data(), contentType: nil))) { e in
            guard case .sessionExpired = e as? PortalError else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try t.unwrap(Transport.Raw(code: 502, body: Data(), contentType: nil))) { e in
            guard case .serverUnavailable = e as? PortalError else { return XCTFail("\(e)") }
        }
    }

    func testSessionCodeRoundTrip() {
        let s = Session(token: "a.b.c", username: "u", instituteId: "i", enrollmentNo: "99", name: "N", obtainedAt: 42)
        let code = encodeSessionCode(s)!
        XCTAssertEqual(decodeSessionCode(code), s)
        XCTAssertNil(decodeSessionCode("not a code"))
    }

    func testJwtExpiry() {
        // {"exp":1790000000}
        let payload = Data(#"{"exp":1790000000}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let s = Session(token: "x.\(payload).y", username: "", instituteId: "i")
        XCTAssertEqual(s.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    // MARK: models off captured responses

    func testAttendanceModels() throws {
        let meta = AttendanceMeta(json: try response("att_meta"))
        XCTAssertEqual(meta.header?.semesterNumber, "5")
        XCTAssertEqual(meta.semesters.first?.code, "2026ODDSEM")
        XCTAssertEqual(meta.semesters.count, 4)

        let detail = AttendanceDetail(json: try response("att_detail_2026ODDSEM"))
        XCTAssertFalse(detail.subjects.isEmpty)
        for s in detail.subjects {
            XCTAssertFalse(s.subjectId.isEmpty)
            XCTAssertFalse(s.name.hasSuffix(")"), s.title)
        }

        let daily = DailyAttendance(json: try response("daily_26B16CS315"))
        XCTAssertFalse(daily.classes.isEmpty)
        let first = daily.classes[0]
        XCTAssertEqual(first.date, Day(year: 2026, month: 9, day: 21))
        XCTAssertEqual(first.start, Clock(hour: 8, minute: 0))
        XCTAssertEqual(first.end, Clock(hour: 9, minute: 50))
        XCTAssertTrue(daily.classes.allSatisfy { $0.date != nil })
    }

    func testOtherModels() throws {
        XCTAssertFalse(RegisteredSubjects(json: try response("faculties")).rows.isEmpty)
        XCTAssertFalse(GradeCard(json: try response("gradecard_2026EVESEM")).entries.isEmpty)
        let results = try response("sgpa_all")["semesterList"].array.map(SemesterResult.init(json:))
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.semester > 0 && $0.sgpa > 0 })
        let info = PersonalInfo(json: try response("personal"))
        XCTAssertFalse(info.general.name.isEmpty)
        XCTAssertFalse(FeeSummary(json: try response("fees")).heads.isEmpty)
        let events = try response("exam_events")["eventcode"]["examevent"].array.map(ExamEvent.init(json:))
        XCTAssertFalse(events.isEmpty)
        let slots = try response("exam_schedule")["subjectinfo"].array.map(ExamSlot.init(json:))
        XCTAssertFalse(slots.isEmpty)
        XCTAssertTrue(slots.allSatisfy { $0.day != nil && $0.start != nil }, "\(slots.map(\.from))")
        let mooc = MoocStatus(json: try response("mooc_status"))
        XCTAssertFalse(mooc.requests.isEmpty && mooc.rejected.isEmpty)
        XCTAssertFalse(try response("choices")["subjectpreferencegrid"].array.map(SubjectChoice.init(json:)).isEmpty)
        let grid = try response("fb_grid")["gridData"].array.compactMap { $0.object.map(FeedbackRow.init(raw:)) }
        XCTAssertFalse(grid.isEmpty)
        XCTAssertFalse(grid[0].facultyName.isEmpty)
    }

    func testClockParsing() {
        XCTAssertEqual(parseClocks("03:30 pm to 04:30 pm"), [Clock(hour: 15, minute: 30), Clock(hour: 16, minute: 30)])
        XCTAssertEqual(parseClocks("09:00:AM"), [Clock(hour: 9, minute: 0)])
        XCTAssertEqual(parseClocks("14:00:00"), [Clock(hour: 14, minute: 0)])
        XCTAssertEqual(parseClocks("12:15 AM"), [Clock(hour: 0, minute: 15)])
        let slot = ExamSlot(date: "26/09/2026", from: "09:30 am", until: "09:30 am to 11:00 am")
        XCTAssertEqual(slot.start, Clock(hour: 9, minute: 30))
        XCTAssertEqual(slot.end, Clock(hour: 11, minute: 0))
    }

    func testMoocStages() {
        let a = parseStage("Submitted on 24-Jul-2026 12:29 PM@D")!
        XCTAssertEqual(a.title, "Submitted")
        XCTAssertTrue(a.done)
        XCTAssertNotNil(a.at)
        let b = parseStage("1. Review  Date:- 30-Jul-2026 02:31 PM  by SOME  NAME (REVIEW BY MOOCD )@D")!
        XCTAssertEqual(b.title, "Review")
        XCTAssertEqual(b.by, "SOME NAME")
        XCTAssertNil(parseStage("@P"))
        let r = MoocRequest(choiceType: "CURRENT Againts(16B1NPH533-LASER TECHNOLOGY AND APPLICATIONS)")
        XCTAssertEqual(r.replaces?.0, "16B1NPH533")
        XCTAssertEqual(r.replaces?.1, "LASER TECHNOLOGY AND APPLICATIONS")
    }

    // MARK: the marks pdf, every sample ktjiit checks against

    func testMarksParser() throws {
        let names = ["cse1-seven-events", "cse2-seven-events", "cse3-nine-events-wrapped", "cse5-seven-events", "cse5-single-event",
                     "ece8-absent", "empty", "wa1", "wa2", "wa3", "wa4", "wa5", "wa6", "wa7"]
        for name in names {
            let expected = try JSONDecoder().decode(MarksReport.self, from: try fixture(name))
            let got = try MarksParser.parse(try fixture(name, "pdf"))
            XCTAssertEqual(got.student, expected.student, name)
            XCTAssertEqual(got.events, expected.events, name)
            XCTAssertEqual(got.subjects.map(\.code), expected.subjects.map(\.code), name)
            for (g, e) in zip(got.subjects, expected.subjects) {
                XCTAssertEqual(g.name, e.name, "\(name) \(e.code)")
                XCTAssertEqual(g.scores, e.scores, "\(name) \(e.code)")
            }
            if !expected.generated.isEmpty { XCTAssertEqual(got.generated, expected.generated, name) }
        }
    }

    func testNotAPdf() {
        XCTAssertThrowsError(try MarksParser.parse(Data("hello".utf8)))
    }
}
