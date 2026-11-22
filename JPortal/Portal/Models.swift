import Foundation

// every portal answer as a value type. each has a memberwise init (demo data,
// tests) and init(json:) that reads the portal's names leniently. Codable is
// only for the on-device cache, so it uses swift names.

/// a registration is the portal's word for a semester, e.g. 2026ODDSEM
struct Semester: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var code: String
    var description: String = ""
    /// epoch millis, only the marks list carries these
    var from: Int64? = nil
    var to: Int64? = nil
}

extension Semester {
    init(json j: JSON) {
        self.init(id: j["registrationid"].str, code: j["registrationcode"].str, description: j["registrationdesc"].str,
                  from: j["registrationdatefrom"].long, to: j["registrationdateto"].long)
    }
}

extension Array where Element == Semester {
    func byCode(_ code: String?) -> Semester? { first { $0.code == code } }
}

// MARK: attendance

struct AttendanceHeader: Codable, Hashable, Sendable {
    var branch: String = ""
    var program: String = ""
    var name: String = ""
    var semesterNumber: String = ""
}

extension AttendanceHeader {
    init(json j: JSON) {
        self.init(branch: j["branchdesc"].str, program: j["programdesc"].str, name: j["name"].str, semesterNumber: j["stynumber"].str)
    }
}

struct AttendanceMeta: Codable, Hashable, Sendable {
    var headers: [AttendanceHeader] = []
    var semesters: [Semester] = []
    var header: AttendanceHeader? { headers.first }
}

extension AttendanceMeta {
    init(json j: JSON) {
        self.init(headers: j["headerlist"].array.map(AttendanceHeader.init(json:)), semesters: j["semlist"].array.map(Semester.init(json:)))
    }
}

/// one row of the attendance table. the portal gives only percentages here,
/// counts come from the daily list. component ids are what the daily call wants.
struct SubjectAttendance: Codable, Hashable, Sendable {
    var subjectId: String
    var code: String = ""
    /// "NAME(CODE)"
    var title: String = ""
    var combinedPercent: Double? = nil
    var lecturePercent: Double? = nil
    var tutorialPercent: Double? = nil
    var practicalPercent: Double? = nil
    var lectureComponent: String? = nil
    var tutorialComponent: String? = nil
    var practicalComponent: String? = nil

    var name: String {
        var t = title
        if t.hasSuffix("(\(code))") { t.removeLast(code.count + 2) }
        t = t.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? title : t
    }

    var components: [String] { [lectureComponent, tutorialComponent, practicalComponent].compactMap { $0 }.filter { !$0.isEmpty } }

    /// the portal's headline number: LT if it has lectures, else P
    var percent: Double? {
        if lectureComponent != nil || tutorialComponent != nil { return combinedPercent ?? lecturePercent }
        return practicalPercent
    }
}

extension SubjectAttendance {
    init(json j: JSON) {
        self.init(
            subjectId: j["subjectid"].str, code: j["individualsubjectcode"].str, title: j["subjectcode"].str,
            combinedPercent: j["LTpercantage"].double, lecturePercent: j["Lpercentage"].double,
            tutorialPercent: j["Tpercentage"].double, practicalPercent: j["Ppercentage"].double,
            lectureComponent: j["Lsubjectcomponentid"].string, tutorialComponent: j["Tsubjectcomponentid"].string,
            practicalComponent: j["Psubjectcomponentid"].string
        )
    }
}

struct AttendanceDetail: Codable, Hashable, Sendable {
    var subjects: [SubjectAttendance] = []
    var currentSem: String = ""
}

extension AttendanceDetail {
    init(json j: JSON) {
        self.init(subjects: j["studentattendancelist"].array.map(SubjectAttendance.init(json:)), currentSem: j["currentSem"].str)
    }
}

struct ClassRecord: Codable, Hashable, Sendable {
    /// "18/09/2026 (10:00:AM - 10:50 AM)", yes with that colon
    let datetime: String
    /// Present / Absent
    let present: String
    let takenBy: String
    let classType: String
    let status: String

    let date: Day?
    let start: Clock?
    let end: Clock?

    enum CodingKeys: String, CodingKey { case datetime, present, takenBy, classType, status }

    init(datetime: String = "", present: String = "", takenBy: String = "", classType: String = "", status: String = "") {
        self.datetime = datetime
        self.present = present
        self.takenBy = takenBy
        self.classType = classType
        self.status = status
        let p = ClassRecord.parse(datetime)
        date = p?.0
        start = p?.1
        end = p?.2
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            datetime: try c.decode(String.self, forKey: .datetime), present: try c.decode(String.self, forKey: .present),
            takenBy: try c.decode(String.self, forKey: .takenBy), classType: try c.decode(String.self, forKey: .classType),
            status: try c.decode(String.self, forKey: .status)
        )
    }

    init(json j: JSON) {
        self.init(datetime: j["datetime"].str, present: j["present"].str, takenBy: j["attendanceby"].str,
                  classType: j["classtype"].str, status: j["attendancestatus"].str)
    }

    var isPresent: Bool { present.caseInsensitiveCompare("Present") == .orderedSame }
    /// the portal leaves these out of the class count, so only a present one moves the percentage
    var isExtra: Bool { classType.caseInsensitiveCompare("Extra") == .orderedSame }

    private static let shape = try! NSRegularExpression(
        pattern: #"(\d{2}/\d{2}/\d{4})\s*\((\d{1,2}):(\d{2}):?\s*([AP]M)\s*-\s*(\d{1,2}):(\d{2}):?\s*([AP]M)\)"#)

    static func parse(_ s: String) -> (Day, Clock?, Clock?)? {
        let ns = s as NSString
        guard let m = shape.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
            guard let d = Day(dmy: String(s.prefix(10))) else { return nil }
            return (d, nil, nil)
        }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        func t(_ h: String, _ min: String, _ ap: String) -> Clock? {
            guard let hh = Int(h), let mm = Int(min), (1...12).contains(hh), (0...59).contains(mm) else { return nil }
            let hour = ap.uppercased() == "AM" ? (hh == 12 ? 0 : hh) : (hh == 12 ? 12 : hh + 12)
            return Clock(hour: hour, minute: mm)
        }
        guard let d = Day(dmy: g(1)) else { return nil }
        return (d, t(g(2), g(3), g(4)), t(g(5), g(6), g(7)))
    }
}

struct DailyAttendance: Codable, Hashable, Sendable {
    var classes: [ClassRecord] = []
    /// every present class, extras included, same as the portal's percentage
    var attended: Int { classes.filter(\.isPresent).count }
    /// regular classes only, an extra never adds to the bottom of the fraction
    var total: Int { classes.filter { !$0.isExtra }.count }
}

extension DailyAttendance {
    init(json j: JSON) { self.init(classes: j["studentAttdsummarylist"].array.map(ClassRecord.init(json:))) }
}

// MARK: subjects

/// one (subject, component, teacher) row, a subject with L+T+P shows up three times
struct SubjectFaculty: Codable, Hashable, Sendable {
    var subjectId: String = ""
    var code: String = ""
    var name: String = ""
    var component: String = ""
    var faculty: String = ""
    var facultyCode: String = ""
    var credits: Double = 0
    var audit: String = "N"
    var minor: String = "N"
    var remarks: String = ""
    var type: String = ""

    var isAudit: Bool { audit == "Y" }
    /// portal pads names with runs of spaces
    var facultyName: String { faculty.trimmingCharacters(in: .whitespaces).collapsingSpaces }
}

extension SubjectFaculty {
    init(json j: JSON) {
        self.init(subjectId: j["subjectid"].str, code: j["subjectcode"].str, name: j["subjectdesc"].str, component: j["subjectcomponentcode"].str,
                  faculty: j["employeename"].str, facultyCode: j["employeecode"].str, credits: j["credits"].dbl,
                  audit: j["audtsubject"].string ?? "N", minor: j["minorsubject"].string ?? "N", remarks: j["remarks"].str, type: j["stytype"].str)
    }
}

struct RegisteredSubjects: Codable, Hashable, Sendable {
    var rows: [SubjectFaculty] = []
    var totalCredits: Double = 0
}

extension RegisteredSubjects {
    init(json j: JSON) { self.init(rows: j["registrations"].array.map(SubjectFaculty.init(json:)), totalCredits: j["totalcreditpoints"].dbl) }
}

struct Credits: Codable, Hashable, Sendable {
    var registeredCredits: Int = 0
    var required: Int = 0
    var earned: Int = 0
    var semester: String = ""
}

extension Credits {
    init(json j: JSON) {
        self.init(registeredCredits: j["registeredCredits"].int ?? 0, required: j["totalreqcredit"].int ?? 0,
                  earned: j["earnedcredit"].int ?? 0, semester: j["semester"].str)
    }
}

// MARK: exams

struct ExamEvent: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var code: String = ""
    var description: String = ""
    /// epoch millis
    var from: Int64? = nil
    var semesterId: String = ""
}

extension ExamEvent {
    init(json j: JSON) {
        self.init(id: j["exameventid"].str, code: j["exameventcode"].str, description: j["exameventdesc"].str,
                  from: j["eventfrom"].long, semesterId: j["registrationid"].str)
    }
}

/// one paper. date is dd/MM/yyyy, from is "03:30 pm", until is the whole "03:30 pm to 04:30 pm" window
struct ExamSlot: Codable, Hashable, Sendable {
    var date: String = ""
    var from: String = ""
    var until: String = ""
    var subject: String = ""
    var code: String = ""
    var room: String = ""
    var seat: String = ""

    var subjectName: String {
        String(subject.split(separator: "(", maxSplits: 1, omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    var day: Day? { Day(dmy: date) }

    var start: Clock? { window.0 }
    var end: Clock? { window.1 }

    /// room and seat land about a day before the paper, blank until then
    var seated: Bool { !room.isBlank || !seat.isBlank }

    private var window: (Clock?, Clock?) {
        let start = parseClocks(from).first ?? parseClocks(until).first
        let last = parseClocks(until).last
        let end = last.flatMap { e in (start == nil || e > start!) ? e : nil }
        return (start, end)
    }
}

extension ExamSlot {
    init(json j: JSON) {
        self.init(date: j["datetime"].str, from: j["datetimefrom"].str, until: j["datetimeupto"].str, subject: j["subjectdesc"].str,
                  code: j["subjectcode"].str, room: j["roomcode"].str, seat: j["seatno"].str)
    }
}

// 03:30 pm, 3:30PM, 09:00:AM, 14:00, 14:00:00
private let clockPattern = try! NSRegularExpression(pattern: #"(\d{1,2})[:.](\d{2})(?::\d{2})?(?:\s*:?\s*([ap])\.?m\b\.?)?"#, options: [.caseInsensitive])

/// every clock time in a portal string, in order
func parseClocks(_ s: String) -> [Clock] {
    let ns = s as NSString
    return clockPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
        guard let h = Int(ns.substring(with: m.range(at: 1))), let min = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        let ap = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3)).lowercased()
        let hour: Int
        switch ap {
        case "": hour = h
        case "a": hour = h == 12 ? 0 : h
        default: hour = h == 12 ? 12 : h + 12
        }
        let twelve = ap.isEmpty || (1...12).contains(h)
        return twelve && (0...23).contains(hour) && (0...59).contains(min) ? Clock(hour: hour, minute: min) : nil
    }
}

// MARK: grades

struct SemesterResult: Codable, Hashable, Sendable {
    var semester: Int
    var sgpa: Double = 0
    var cgpa: Double = 0
    var courseCredits: Double = 0
    var gradePoints: Double = 0
    // the portal's names lie: singular "credit" is this semester, plural "credits" is the running total
    var earnedCredits: Double = 0
    var cumulativeCredits: Double = 0
    /// running total too, despite the name
    var cumulativeRegistered: Double = 0
    var cumulativePoints: Double = 0
}

extension SemesterResult {
    init(json j: JSON) {
        self.init(semester: j["stynumber"].int ?? 0, sgpa: j["sgpa"].dbl, cgpa: j["cgpa"].dbl, courseCredits: j["totalcoursecredit"].dbl,
                  gradePoints: j["earnedgradepoints"].dbl, earnedCredits: j["totalearnedcredit"].dbl, cumulativeCredits: j["totalearnedcredits"].dbl,
                  cumulativeRegistered: j["totalregisteredcredit"].dbl, cumulativePoints: j["totalpointsecuredcgpa"].dbl)
    }
}

struct StudentProgram: Codable, Hashable, Sendable {
    var branchId: String = ""
    var programId: String = ""
    var branchCode: String = ""
    var programCode: String = ""
    var branch: String = ""
    var program: String = ""
    var maxSemesters: Int = 0
}

extension StudentProgram {
    init(json j: JSON) {
        self.init(branchId: j["branchid"].str, programId: j["programid"].str, branchCode: j["branchcode"].str, programCode: j["programcode"].str,
                  branch: j["branchdesc"].str, program: j["programdesc"].str, maxSemesters: j["stymax"].int ?? 0)
    }
}

struct GradeEntry: Codable, Hashable, Sendable {
    var subjectId: String = ""
    var code: String = ""
    var name: String = ""
    var grade: String = ""
    var gradePoint: Double = 0
    var credits: Double = 0
    var earned: Double = 0
    var points: Double = 0
    var semester: Int = 0
    var minor: String = "N"
}

extension GradeEntry {
    init(json j: JSON) {
        self.init(subjectId: j["subjectid"].str, code: j["subjectcode"].str, name: j["subjectdesc"].str, grade: j["grade"].str,
                  gradePoint: j["gradepoint"].dbl, credits: j["coursecreditpoint"].dbl, earned: j["earnedcredit"].dbl,
                  points: j["pointsecured"].dbl, semester: j["stynumber"].int ?? 0, minor: j["minorsubject"].string ?? "N")
    }
}

struct GradeCard: Codable, Hashable, Sendable {
    var entries: [GradeEntry] = []
}

extension GradeCard {
    init(json j: JSON) { self.init(entries: j["gradecard"].array.map(GradeEntry.init(json:))) }
}

// MARK: me

struct GeneralInfo: Codable, Hashable, Sendable {
    var name = ""
    var enrollmentNo = ""
    var program = ""
    var branch = ""
    var batch = ""
    var section = ""
    var semester = 0
    var academicYear = ""
    var admissionYear = ""
    var dateOfBirth = ""
    var gender = ""
    var bloodGroup = ""
    var nationality = ""
    var category = ""
    var apaarId = ""
    var phone = ""
    var collegeEmail = ""
    var personalEmail = ""
    var fatherName = ""
    var motherName = ""
    var parentPhone = ""
    var parentEmail = ""
    var permanentAddress1 = ""
    var permanentAddress2 = ""
    var permanentAddress3 = ""
    var permanentCity = ""
    var permanentDistrict = ""
    var permanentState = ""
    var permanentPin = ""
    var currentAddress1 = ""
    var currentAddress3 = ""
    var currentCity = ""
    var currentDistrict = ""
    var currentState = ""
    var currentPin = ""
    var institute = ""
}

extension GeneralInfo {
    init(json j: JSON) {
        self.init(
            name: j["studentname"].str, enrollmentNo: j["registrationno"].str, program: j["programcode"].str, branch: j["branch"].str,
            batch: j["batch"].str, section: j["sectioncode"].str, semester: j["semester"].int ?? 0, academicYear: j["academicyear"].str,
            admissionYear: j["admissionyear"].str, dateOfBirth: j["dateofbirth"].str, gender: j["gender"].str, bloodGroup: j["bloodgroup"].str,
            nationality: j["nationality"].str, category: j["category"].str, apaarId: j["apaarid"].str, phone: j["studentcellno"].str,
            collegeEmail: j["studentemailid"].str, personalEmail: j["studentpersonalemailid"].str, fatherName: j["fathersname"].str,
            motherName: j["mothername"].str, parentPhone: j["parentcellno"].str, parentEmail: j["parentemailid"].str,
            permanentAddress1: j["paddress1"].str, permanentAddress2: j["paddress2"].str, permanentAddress3: j["paddress3"].str,
            permanentCity: j["pcityname"].str, permanentDistrict: j["pdistrict"].str, permanentState: j["pstatename"].str,
            permanentPin: j["ppostalcode"].str, currentAddress1: j["caddress1"].str, currentAddress3: j["caddress3"].str,
            currentCity: j["ccityname"].str, currentDistrict: j["cdistrict"].str, currentState: j["cstatename"].str,
            currentPin: j["cpostalcode"].str, institute: j["institutecode"].str
        )
    }
}

struct Qualification: Codable, Hashable, Sendable {
    var code = ""
    var board = ""
    var year = ""
    var obtained: Double = 0
    var full: Double = 0
    var percent: Double = 0
    var grade = ""
    var cgpa: Double = 0
}

extension Qualification {
    init(json j: JSON) {
        self.init(code: j["qualificationcode"].str, board: j["boardname"].str, year: j["yearofpassing"].str, obtained: j["obtainedmarks"].dbl,
                  full: j["fullmarks"].dbl, percent: j["percentagemarks"].dbl, grade: j["grade"].str, cgpa: j["cgpa"].dbl)
    }
}

struct PersonalInfo: Codable, Hashable, Sendable {
    var general = GeneralInfo()
    var qualifications: [Qualification] = []
    /// base64 jpeg
    var photo: String? = nil
}

extension PersonalInfo {
    init(json j: JSON) {
        self.init(general: GeneralInfo(json: j["generalinformation"]), qualifications: j["qualification"].array.map(Qualification.init(json:)),
                  photo: j["photo&signature"]["photo"].string)
    }
}

struct BankInfo: Codable, Hashable, Sendable {
    var bank = ""
    var account = ""
    var ifsc = ""
    var holder = ""
    var address = ""
    var city = ""
    var state = ""
    var pin = ""
    var holderType = ""
    /// Y once the office locks it
    var frozen = ""
}

extension BankInfo {
    init(json j: JSON) {
        self.init(bank: j["bankname"].str, account: j["bankaccountnumber"].str, ifsc: j["ifsccode"].str, holder: j["accountholdername"].str,
                  address: j["bankaddress"].str, city: j["bankcity"].str, state: j["bankstate"].str, pin: j["bankcitypin"].str,
                  holderType: j["acholdertypeflag"].str, frozen: j["freezed"].str)
    }
}

struct HostelInfo: Codable, Hashable, Sendable {
    var hostel = ""
    var hostelCode = ""
    var room = ""
    var floor = ""
    var bed = ""
    var roomType = ""
    var hostelType = ""
    var from = ""
    var until = ""
    var leftOn: String? = nil
}

extension HostelInfo {
    init(json j: JSON) {
        self.init(hostel: j["hosteldescription"].str, hostelCode: j["hostelcode"].str, room: j["allotedroomno"].str, floor: j["floor"].str,
                  bed: j["beddesc"].str, roomType: j["roomtype"].str, hostelType: j["hosteltypedesc"].str, from: j["allotedfromdate"].str,
                  until: j["allotedtilldate"].str, leftOn: j["hostellefton"].string)
    }
}

/// hostel can be absent, and an absent answer is still worth caching
struct HostelAnswer: Codable, Hashable, Sendable {
    var info: HostelInfo?
}

struct FeeHead: Codable, Hashable, Sendable {
    var semester = 0
    var academicYear = ""
    var type = ""
    var fee: Double = 0
    var paid: Double = 0
    var due: Double = 0
    var waived: Double = 0
    var refunded: Double = 0
    var currency = "INR"
    var registrationAllowedOn = ""
}

extension FeeHead {
    init(json j: JSON) {
        self.init(semester: j["stynumber"].int ?? 0, academicYear: j["academicyear"].str, type: j["stytypedesc"].str, fee: j["feeamount"].dbl,
                  paid: j["receiveamount"].dbl, due: j["dueamount"].dbl, waived: j["waiveramount"].dbl, refunded: j["refundamount"].dbl,
                  currency: j["currencycode"].string ?? "INR", registrationAllowedOn: j["regallowdate"].str)
    }
}

struct AdvanceAmount: Codable, Hashable, Sendable {
    var amount: Double = 0
    var currency = "INR"
}

struct FeeSummary: Codable, Hashable, Sendable {
    var heads: [FeeHead] = []
    var advance: [AdvanceAmount] = []
    var totalDue: Double { heads.reduce(0) { $0 + $1.due } }
}

extension FeeSummary {
    init(json j: JSON) {
        self.init(heads: j["feeHeads"].array.map(FeeHead.init(json:)),
                  advance: j["advanceamount"].array.map { AdvanceAmount(amount: $0["amount"].dbl, currency: $0["currencycode"].string ?? "INR") })
    }
}

struct FeedbackEvent: Codable, Hashable, Sendable, Identifiable {
    var id = ""
    var description = ""
    var code = ""
}

extension FeedbackEvent {
    init(json j: JSON) { self.init(id: j["eventid"].str, description: j["eventdescription"].str, code: j["feedbackcode"].str) }
}

/// one teacher and subject component to rate. kept as the portal's own object,
/// ids go back exactly as they came, whatever json type they were.
struct FeedbackRow: Codable, Hashable, Sendable {
    var raw: [String: JSON]

    private func text(_ k: String) -> String { raw[k]?.str ?? "" }
    var facultyName: String { text("employeename") }
    var subjectCode: String { text("subjectcode") }
    var subjectName: String { text("subjectdescription") }
    /// L, T or P
    var component: String { text("subjectcomponentcode") }
    var key: String { ["employeeid", "subjectid", "subjectcomponentid"].map(text).joined(separator: "/") }
}

/// the portal's five answers, worst to best. every question of a form gets the same one
enum Rating: String, CaseIterable, Codable, Sendable {
    case UNSATISFIED, SATISFIED, GOOD, VERY_GOOD, EXCELLENT

    var label: String {
        switch self {
        case .UNSATISFIED: return "Unsatisfied"
        case .SATISFIED: return "Satisfied"
        case .GOOD: return "Good"
        case .VERY_GOOD: return "Very good"
        case .EXCELLENT: return "Excellent"
        }
    }
}

// MARK: registration, read only

/// one line of the choice print. electives list every pick, core baskets just their subjects
struct SubjectChoice: Codable, Hashable, Sendable {
    var code = ""
    var name = ""
    var basket = ""
    var basketName = ""
    /// "Core", "Departmental Electives"
    var type = ""
    var credits: Double = 0
    /// 1 is the first pick. 0 is a subject you got without picking it
    var preference = 0
    var running = "N"
    var audit = "N"
    var elective = "N"
    /// how many a basket hands out
    var maxSubjects = 0
    /// "24-07-2026 12:29 PM"
    var frozenAt = ""

    var isAllotted: Bool { running == "Y" }
    var isAudit: Bool { audit == "Y" }
    var isElective: Bool { elective == "Y" }
}

extension SubjectChoice {
    init(json j: JSON) {
        self.init(code: j["subjectcode"].str, name: j["subjectdesc"].str, basket: j["basketcode"].str, basketName: j["basketdesc"].str,
                  type: j["subjecttypedesc"].str, credits: j["credits"].dbl, preference: j["preference"].int ?? 0,
                  running: j["running"].string ?? "N", audit: j["auditsubject"].string ?? "N", elective: j["electivetype"].string ?? "N",
                  maxSubjects: j["maxsubject"].int ?? 0, frozenAt: j["freezeddatetime"].str)
    }
}

/// one step of a mooc request's approval
struct MoocStage: Hashable, Sendable {
    let title: String
    let at: Date?
    let by: String?
    let done: Bool
}

struct MoocRequest: Codable, Hashable, Sendable {
    var code = ""
    var name = ""
    /// "CURRENT Againts(16B1NPH533-LASER TECHNOLOGY AND APPLICATIONS)", typo and all
    var choiceType = ""
    var status = ""
    var rawStages: [String] = []

    /// code and name of the subject this mooc stands in for
    var replaces: (String, String)? {
        let ns = choiceType as NSString
        guard let m = MoocRequest.replacesPattern.firstMatch(in: choiceType, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces), ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
    }

    /// skipped stages come back as empty strings, they're left out
    var stages: [MoocStage] { rawStages.compactMap(parseStage) }

    var isApproved: Bool { stages.contains { $0.done && $0.title.caseInsensitiveCompare("Approved") == .orderedSame } }

    private static let replacesPattern = try! NSRegularExpression(pattern: #"\(([^-()]+)-(.+)\)"#)
}

extension MoocRequest {
    init(json j: JSON) {
        self.init(code: j["subjectcode"].str, name: j["subjectdesc"].str, choiceType: j["choicetype"].str, status: j["approvalstatus"].str,
                  rawStages: j["totalStages"].array.map(\.str))
    }
}

struct MoocStatus: Codable, Hashable, Sendable {
    var requests: [MoocRequest] = []
    var rejected: [MoocRequest] = []
    var dues: Double = 0
}

extension MoocStatus {
    init(json j: JSON) {
        self.init(requests: j["totalsubjectDetailList"].array.map(MoocRequest.init(json:)),
                  rejected: j["totalRejsubjectDetailList"].array.map(MoocRequest.init(json:)), dues: j["duesAmount"].dbl)
    }
}

private let stagePattern = try! NSRegularExpression(
    pattern: #"^(.+?)\s+(?:on|Date:-)\s+(\d{1,2}-[A-Za-z]{3}-\d{4} \d{1,2}:\d{2} [AP]M)(?:\s+by\s+([^(]+))?"#)

/// "Submitted on 24-Jul-2026 12:29 PM@D" or
/// "1. Review  Date:- 30-Jul-2026 02:31 PM  by SOME  NAME (REVIEW BY MOOCD )@D".
/// the letter after @ is the stage's state, D once it's done.
func parseStage(_ raw: String) -> MoocStage? {
    let before = raw.range(of: "@", options: .backwards).map { String(raw[..<$0.lowerBound]) } ?? raw
    var text = before.collapsingSpaces.trimmingCharacters(in: .whitespaces)
    if let r = text.range(of: #"^\d+\.\s*"#, options: .regularExpression) { text.removeSubrange(r) }
    if text.isEmpty { return nil }
    let state = raw.range(of: "@", options: .backwards).map { String(raw[$0.upperBound...]).trimmingCharacters(in: .whitespaces) } ?? ""
    let ns = text as NSString
    guard let m = stagePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
        return MoocStage(title: text, at: nil, by: nil, done: state == "D")
    }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "dd-MMM-yyyy hh:mm a"
    let at = f.date(from: ns.substring(with: m.range(at: 2)))
    let by = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
    return MoocStage(title: ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces), at: at,
                     by: (by?.isEmpty ?? true) ? nil : by, done: state == "D")
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// runs of whitespace down to one space
    var collapsingSpaces: String { replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }

    func ifBlank(_ other: @autoclosure () -> String) -> String { isBlank ? other() : self }
}
