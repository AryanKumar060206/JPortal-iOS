import Foundation

/// every portal answer the app shows, as a cached Store. keys carry the
/// registration id so semesters never bleed into each other.
@MainActor
final class Repository {
    let cache: Cache
    let sessions: SessionManager
    let limiter = Limiter(6)
    /// class lists get a queue of their own: the portal is slow with them, and a first load asks for
    /// one per subject, which shouldn't hold up every other screen
    let classLists = Limiter(3)
    /// false while the demo student is in, whose stores only ever read the disk
    let live: () -> Bool

    private var stores: [String: AnyObject] = [:]

    init(cache: Cache, sessions: SessionManager, live: @escaping () -> Bool) {
        self.cache = cache
        self.sessions = sessions
        self.live = live
    }

    private func store<T: Codable & Sendable>(_ key: String, minutes: Double, limiter: Limiter? = nil, _ fetch: @escaping @Sendable (Portal) async throws -> T) -> Store<T> {
        if let s = stores[key] as? Store<T> { return s }
        let s = Store<T>(key: key, maxAge: minutes * 60, repo: self, limiter: limiter, fetch: fetch)
        stores[key] = s
        return s
    }

    // attendance

    var attendanceMeta: Store<AttendanceMeta> { store("att_meta", minutes: 12 * 60) { try await $0.attendanceMeta() } }

    func attendance(_ sem: Semester, semesterNumber: String) -> Store<AttendanceDetail> {
        store("att:\(sem.id)", minutes: 10) { try await $0.attendance(sem, semesterNumber: semesterNumber) }
    }

    func daily(_ sem: Semester, _ subject: SubjectAttendance) -> Store<DailyAttendance> {
        store("daily:\(sem.id):\(subject.subjectId)", minutes: 10, limiter: classLists) { try await $0.dailyAttendance(sem, subject: subject) }
    }

    // subjects

    var subjectSemesters: Store<[Semester]> { store("subj_sems", minutes: 12 * 60) { try await $0.subjectSemesters() } }

    func subjects(_ sem: Semester) -> Store<RegisteredSubjects> {
        store("subj:\(sem.id)", minutes: 6 * 60) { try await $0.registeredSubjects(sem) }
    }

    var credits: Store<Credits> { store("credits", minutes: 6 * 60) { try await $0.credits() } }

    // exams

    var examSemesters: Store<[Semester]> { store("exam_sems", minutes: 6 * 60) { try await $0.examSemesters() } }

    func examEvents(_ sem: Semester) -> Store<[ExamEvent]> {
        store("exam_ev:\(sem.id)", minutes: 60) { try await $0.examEvents(sem) }
    }

    func examSchedule(_ ev: ExamEvent) -> Store<[ExamSlot]> {
        store("exam_sch:\(ev.id)", minutes: 60) { try await $0.examSchedule(ev) }
    }

    /// every paper of the current exam semester, or nil while any part of it is missing
    func examSheet() async -> [Paper]? {
        guard let sem = currentSemester(await examSemesters.value().data ?? []) else { return nil }
        guard let events = await examEvents(sem).value().data else { return nil }
        var papers: [Paper] = []
        for ev in events {
            guard let slots = await examSchedule(ev).value().data else { return nil }
            papers += slots.map { Paper(event: ev, slot: $0) }
        }
        return papers
    }

    // marks and grades

    var marksSemesters: Store<[Semester]> { store("marks_sems", minutes: 6 * 60) { try await $0.marksSemesters() } }

    func marks(_ sem: Semester) -> Store<MarksReport> { store("marks:\(sem.id)", minutes: 30) { try await $0.marks(sem) } }

    var gradeSemesters: Store<[Semester]> { store("gc_sems", minutes: 12 * 60) { try await $0.gradeCardSemesters() } }

    var program: Store<StudentProgram> { store("program", minutes: 24 * 60) { try await $0.program() } }

    func gradeCard(_ sem: Semester) -> Store<GradeCard> {
        store("gc:\(sem.id)", minutes: 12 * 60) { p in try await p.gradeCard(sem, program: try await p.program()) }
    }

    func results(_ currentSemester: String) -> Store<[SemesterResult]> {
        store("results", minutes: 12 * 60) { try await $0.semesterResults(currentSemester: currentSemester) }
    }

    // me

    var personal: Store<PersonalInfo> { store("personal", minutes: 24 * 60) { try await $0.personalInfo() } }
    var bank: Store<BankInfo> { store("bank", minutes: 24 * 60) { try await $0.bankInfo() } }
    var hostel: Store<HostelAnswer> { store("hostel", minutes: 24 * 60) { try await $0.hostel() } }
    var fees: Store<FeeSummary> { store("fees", minutes: 6 * 60) { try await $0.fees() } }
    var feedback: Store<[FeedbackEvent]> { store("feedback", minutes: 60) { try await $0.feedbackEvents() } }

    // registration, read only

    var choiceSemesters: Store<[Semester]> { store("choice_sems", minutes: 6 * 60) { try await $0.choiceSemesters() } }
    func choices(_ sem: Semester) -> Store<[SubjectChoice]> { store("choices:\(sem.id)", minutes: 6 * 60) { try await $0.subjectChoices(sem) } }
    var moocSemesters: Store<[Semester]> { store("mooc_sems", minutes: 6 * 60) { try await $0.moocSemesters() } }
    func mooc(_ sem: Semester) -> Store<MoocStatus> { store("mooc:\(sem.id)", minutes: 6 * 60) { try await $0.moocStatus(sem) } }

    func wipe() {
        stores.removeAll()
        cache.clear()
    }
}
