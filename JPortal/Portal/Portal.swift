import Foundation

/// typed calls for one signed in student. payload keys (typos included) and the
/// plain vs encrypted choice come straight from the portal bundle, don't "fix" them.
struct Portal: Sendable {
    let session: Session
    let transport: Transport

    private var iid: JSON { .string(session.instituteId) }

    private func call(_ path: String, _ body: [String: JSON]) async throws -> JSON {
        try await transport.post(path, token: session.token, payload: .object(body), encrypt: false)
    }

    private func listOrEmpty<T>(_ empty: T, _ block: () async throws -> T) async throws -> T {
        do {
            return try await block()
        } catch let e as PortalError where e.isNoData {
            return empty
        }
    }

    // MARK: attendance

    func attendanceMeta() async throws -> AttendanceMeta {
        AttendanceMeta(json: try await call("/StudentClassAttendance/getstudentInforegistrationforattendence", ["instituteid": iid]))
    }

    func attendance(_ semester: Semester, semesterNumber: String) async throws -> AttendanceDetail {
        try await listOrEmpty(AttendanceDetail()) {
            AttendanceDetail(json: try await call("/StudentClassAttendance/getstudentattendancedetail", [
                "instituteid": iid, "registrationcode": .string(semester.code), "registrationid": .string(semester.id),
                "stynumber": .string(semesterNumber),
            ]))
        }
    }

    /// class by class list, pass a subset of components to split L/T/P
    func dailyAttendance(_ semester: Semester, subject: SubjectAttendance, components: [String]? = nil) async throws -> DailyAttendance {
        let comps = components ?? subject.components
        return try await listOrEmpty(DailyAttendance()) {
            DailyAttendance(json: try await call("/StudentClassAttendance/getstudentsubjectpersentage", [
                "instituteid": iid, "subjectid": .string(subject.subjectId), "registrationid": .string(semester.id),
                "cmpidkey": .array(comps.map { ["subjectcomponentid": .string($0)] }),
                "subjectcode": .string(subject.code), "registrationcode": .string(semester.code),
            ]))
        }
    }

    // MARK: subjects

    func subjectSemesters() async throws -> [Semester] {
        try await call("/reqsubfaculty/getregistrationList", ["instituteid": iid])["registrations"].array.map(Semester.init(json:))
    }

    func registeredSubjects(_ semester: Semester) async throws -> RegisteredSubjects {
        try await listOrEmpty(RegisteredSubjects()) {
            RegisteredSubjects(json: try await call("/reqsubfaculty/getfaculties", [
                "studentid": .string(session.memberId), "instituteid": iid, "registrationid": .string(semester.id),
            ]))
        }
    }

    func credits() async throws -> Credits {
        Credits(json: try await call("/feedbackformcontroller/getCreadits", ["enrollmentNo": .string(session.enrollmentNo)]))
    }

    // MARK: exams

    func examSemesters() async throws -> [Semester] {
        try await listOrEmpty([]) {
            try await call("/studentcommonsontroller/getsemestercode-withstudentexamevents", ["clientid": .string(session.clientId), "instituteid": iid])["semesterCodeinfo"]["semestercode"].array.map(Semester.init(json:))
        }
    }

    func examEvents(_ semester: Semester) async throws -> [ExamEvent] {
        try await listOrEmpty([]) {
            try await call("/studentcommonsontroller/getstudentexamevents", ["instituteid": iid, "registationid": .string(semester.id)])["eventcode"]["examevent"].array.map(ExamEvent.init(json:))
        }
    }

    func examSchedule(_ event: ExamEvent) async throws -> [ExamSlot] {
        try await listOrEmpty([]) {
            try await call("/studentsttattview/getstudent-examschedule", [
                "instituteid": iid, "exameventid": .string(event.id), "registrationid": .string(event.semesterId),
            ])["subjectinfo"].array.map(ExamSlot.init(json:))
        }
    }

    // MARK: marks

    func marksSemesters() async throws -> [Semester] {
        try await listOrEmpty([]) {
            try await call("/studentcommonsontroller/getsemestercode-exammarks", ["instituteid": iid])["semestercode"].array.map(Semester.init(json:))
        }
    }

    func marksPdf(_ semester: Semester) async throws -> Data {
        try await transport.bytes("/studentsexamview/printstudent-exammarks/\(session.instituteId)/\(semester.id)/\(semester.code)", token: session.token)
    }

    func marks(_ semester: Semester) async throws -> MarksReport {
        let pdf = try await marksPdf(semester)
        return try await Task.detached(priority: .userInitiated) { try MarksParser.parse(pdf) }.value
    }

    // MARK: grades

    func gradeCardSemesters() async throws -> [Semester] {
        try await listOrEmpty([]) {
            try await call("/studentgradecard/getregistrationList", ["instituteid": iid])["registrations"].array.map(Semester.init(json:))
        }
    }

    func program() async throws -> StudentProgram {
        StudentProgram(json: try await call("/studentgradecard/getstudentinfo", ["instituteid": iid])["studentinfo"])
    }

    func gradeCard(_ semester: Semester, program: StudentProgram) async throws -> GradeCard {
        try await listOrEmpty(GradeCard()) {
            GradeCard(json: try await call("/studentgradecard/showstudentgradecard", [
                "instituteid": iid, "registrationid": .string(semester.id), "branchid": .string(program.branchId),
                "programid": .string(program.programId),
            ]))
        }
    }

    /// sgpa/cgpa for every finished semester
    func semesterResults(currentSemester: String) async throws -> [SemesterResult] {
        try await listOrEmpty([]) {
            try await call("/studentsgpacgpa/getallsemesterdata", [
                "instituteid": iid, "studentid": .string(session.memberId), "stynumber": .string(currentSemester),
            ])["semesterList"].array.map(SemesterResult.init(json:))
        }
    }

    // MARK: me

    func personalInfo() async throws -> PersonalInfo {
        PersonalInfo(json: try await call("/studentpersinfo/getstudent-personalinformation", ["instituteid": iid]))
    }

    func bankInfo() async throws -> BankInfo {
        BankInfo(json: try await call("/studentbankdetails/getstudentbankinfo", ["instituteid": iid])["bankinfo"])
    }

    func hostel() async throws -> HostelAnswer {
        do {
            let h = try await call("/myhostelallocationdetail/gethostelallocationdetail", ["instituteid": iid])["presenthosteldetail"]
            return HostelAnswer(info: h.isNull ? nil : HostelInfo(json: h))
        } catch let e as PortalError where e.meansNoHostel {
            // day scholars get an error, not an empty answer
            return HostelAnswer(info: nil)
        }
    }

    func fees() async throws -> FeeSummary {
        try await listOrEmpty(FeeSummary()) {
            FeeSummary(json: try await call("/studentfeeledger/loadfeesummary", ["instituteid": iid]))
        }
    }

    // MARK: registration, read only

    func choiceSemesters() async throws -> [Semester] {
        try await listOrEmpty([]) {
            try await call("/studentchoiceprint/getsemestercodelist", [:])["registrationcodelist"].array.map(Semester.init(json:))
        }
    }

    func subjectChoices(_ semester: Semester) async throws -> [SubjectChoice] {
        try await listOrEmpty([]) {
            try await call("/studentchoiceprint/getsubjectpreference", [
                "instituteid": iid, "clientid": .string(session.clientId), "registrationid": .string(semester.id),
            ])["subjectpreferencegrid"].array.map(SubjectChoice.init(json:))
        }
    }

    func moocSemesters() async throws -> [Semester] {
        try await listOrEmpty([]) {
            try await call("/moocsubjectstatus/getsemestercodelist", ["instituteid": iid]).array.map(Semester.init(json:))
        }
    }

    func moocStatus(_ semester: Semester) async throws -> MoocStatus {
        try await listOrEmpty(MoocStatus()) {
            MoocStatus(json: try await call("/moocsubjectstatus/getsubjectstatus", ["instituteid": iid, "registrationid": .string(semester.id)]))
        }
    }

    // MARK: feedback

    func feedbackEvents() async throws -> [FeedbackEvent] {
        try await listOrEmpty([]) {
            try await call("/feedbackformcontroller/getFeedbackEvent", ["instituteid": iid, "studentid": .string(session.memberId)])["eventList"].array.map(FeedbackEvent.init(json:))
        }
    }

    /// every teacher and component still to be rated in an open feedback event
    func feedbackGrid(_ event: FeedbackEvent) async throws -> [FeedbackRow] {
        try await listOrEmpty([]) {
            try await call("/feedbackformcontroller/getGriddataForFeedback", [
                "instituteid": iid, "studentid": .string(session.memberId), "eventid": .string(event.id),
            ])["gridData"].array.compactMap { $0.object.map(FeedbackRow.init(raw:)) }
        }
    }

    // question payload key to grid key, as jsjiit maps them
    private static let questionKeys: [(String, String)] = [
        ("facultyid", "employeeid"), ("facultyname", "employeename"), ("registrationid", "registrationid"),
        ("studentid", "studentid"), ("subjectcode", "subjectcode"), ("subjectcomponentcode", "subjectcomponentcode"),
        ("subjectcomponentid", "subjectcomponentid"), ("subjectdescription", "subjectdescription"), ("subjectid", "subjectid"),
    ]

    /// the form for one row. jsjiit's shape, the portal's own screen isn't in the bundle we have
    func feedbackQuestions(_ event: FeedbackEvent, row: FeedbackRow) async throws -> [[String: JSON]] {
        var body: [String: JSON] = ["instituteid": iid, "eventid": .string(event.id), "eventdescription": .string(event.description)]
        for (to, from) in Portal.questionKeys { body[to] = row.raw[from] ?? .null }
        return try await call("/feedbackformcontroller/getIemQuestion", body)["questionList"].array.compactMap(\.object)
    }

    /// rates one row, every question the same. the only call in here that writes:
    /// no retries, and the app shows what's about to go before it calls this.
    func submitFeedback(_ event: FeedbackEvent, row: FeedbackRow, rating: Rating) async throws -> JSON {
        let questions = try await feedbackQuestions(event, row: row)
        if questions.isEmpty { throw PortalError.portal(errors: ["no questions for \(row.subjectCode)"], code: 0) }
        return try await transport.post("/feedbackformcontroller/savedatalist", token: session.token,
                                        payload: feedbackPayload(event: event, row: row, questions: questions, rating: rating),
                                        encrypt: false, retry: false)
    }

    /// savedatalist's body: each question as the portal sent it plus its rating, comments left empty
    func feedbackPayload(event: FeedbackEvent, row: FeedbackRow, questions: [[String: JSON]], rating: Rating) -> JSON {
        .object([
            "instituteid": iid,
            "studentid": .string(session.memberId),
            "eventid": .string(event.id),
            "subjectid": row.raw["subjectid"] ?? .null,
            "facultyid": row.raw["employeeid"] ?? .null,
            "registrationid": row.raw["registrationid"] ?? .null,
            "questionid": .array(questions.map { q in
                var q = q
                q["rating"] = .string(rating.rawValue)
                return .object(q)
            }),
            "facultycomments": .null,
            "coursecomments": .null,
        ])
    }
}
