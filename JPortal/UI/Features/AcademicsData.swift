import Foundation

/// one semester as the academics tab sees it, stitched from results, grade cards and registrations
struct SemesterInfo: Identifiable {
    let code: String
    let number: Int?
    let result: SemesterResult?
    let grades: [GradeEntry]
    let subjects: [SubjectInfo]
    let current: Bool
    var id: String { code }
}

/// a registered subject, its L/T/P rows folded into one
struct SubjectInfo: Identifiable {
    let semesterCode: String
    let code: String
    let name: String
    let credits: Double
    /// component letter to teacher, in L, T, P order
    let teachers: [(String, String)]
    let audit: Bool
    let grade: String?
    var id: String { "\(semesterCode)/\(code)" }
    var lab: Bool { !teachers.isEmpty && teachers.allSatisfy { $0.0 == "P" } }
}

struct Academics {
    let semesters: [SemesterInfo]
    let results: Resource<[SemesterResult]>
    let currentCode: String?
    /// true while any of the lists behind this are still on their way with nothing cached
    let loading: Bool

    func semester(_ code: String) -> SemesterInfo? { semesters.first { $0.code == code } }
}

extension Academics {
    /// semester number to credits, for semesters with no result yet whose credits are actually known.
    /// the portal's credits page says which semester its registered credits belong to; failing that,
    /// the current semester's subjects add up the way the calculator counts them
    func whatIfCredits(_ credits: Credits?, after lastReal: Int) -> [Int: Double] {
        if let c = credits, c.registeredCredits > 0, let n = Int(c.semester), n > lastReal {
            return [n: Double(c.registeredCredits)]
        }
        if let now = semesters.first(where: { $0.current && $0.result == nil }), let n = now.number, n > lastReal {
            let sum = now.subjects.filter { !$0.audit && $0.credits > 0 }.reduce(0) { $0 + $1.credits }
            if sum > 0 { return [n: sum] }
        }
        return [:]
    }
}

private func fold(_ semesterCode: String, _ rows: [SubjectFaculty], _ grades: [GradeEntry]) -> [SubjectInfo] {
    let order = ["L", "T", "P"]
    var codes: [String] = []
    var groups: [String: [SubjectFaculty]] = [:]
    for r in rows {
        if groups[r.code] == nil { codes.append(r.code) }
        groups[r.code, default: []].append(r)
    }
    return codes.map { code in
        let parts = groups[code]!
        var seen = Set<String>()
        let teachers = parts.filter { !$0.facultyName.isBlank }
            .sorted { (order.firstIndex(of: $0.component) ?? 9) < (order.firstIndex(of: $1.component) ?? 9) }
            .map { ($0.component, $0.facultyName) }
            .filter { seen.insert("\($0.0)|\($0.1)").inserted }
        let g = grades.first { $0.code == code }?.grade
        return SubjectInfo(semesterCode: semesterCode, code: code, name: parts[0].name, credits: parts.map(\.credits).max() ?? 0,
                           teachers: teachers, audit: parts.contains(where: \.isAudit), grade: (g?.isBlank ?? true) ? nil : g)
    }
}

/// a semester's number, counted in terms back from the current one. the grade card's
/// stynumber is just today's semester on every card, so it can't be used. summer terms get none
func semesterNumber(_ code: String, current: String?, currentNumber: Int?) -> Int? {
    guard let t = term(code), let anchor = current.flatMap(term), let currentNumber else { return nil }
    let n = currentNumber - (anchor - t)
    return n > 0 ? n : nil
}

extension AppGraph {
    /// everything the academics tab and the grade card page need. every grade card
    /// is read so the subject list can show grades, they're small and cached for half a day
    var academics: Academics {
        let repo = repo!
        let meta = repo.attendanceMeta.state
        let currentNumber = meta.data?.header?.semesterNumber ?? ""
        // the header's stynumber is the semester going on now, which isn't the head of the list once next term's registration opens
        let currentCode = currentSemester(meta.data?.semesters ?? [])?.code
        let results = repo.results(currentNumber).state
        let gradeSems = repo.gradeSemesters.state
        let subjSems = repo.subjectSemesters.state
        let cards = (gradeSems.data ?? []).map { ($0.code, repo.gradeCard($0).state) }
        let regs = (subjSems.data ?? []).map { ($0.code, repo.subjects($0).state) }
        let grades = Dictionary(cards.map { ($0.0, $0.1.data?.entries ?? []) }, uniquingKeysWith: { a, _ in a })
        let rows = Dictionary(regs.map { ($0.0, $0.1.data?.rows ?? []) }, uniquingKeysWith: { a, _ in a })

        let byNumber = Dictionary((results.data ?? []).map { ($0.semester, $0) }, uniquingKeysWith: { a, _ in a })
        func numberOf(_ code: String) -> Int? { JPortal.semesterNumber(code, current: currentCode, currentNumber: Int(currentNumber)) }
        var codes: [String] = []
        for c in [currentCode].compactMap({ $0 }) + regs.map(\.0) + cards.map(\.0) where !codes.contains(c) { codes.append(c) }
        let semesters = codes.map { code -> SemesterInfo in
            let g = grades[code] ?? []
            let n = numberOf(code)
            return SemesterInfo(code: code, number: n, result: n.flatMap { byNumber[$0] }, grades: g,
                                subjects: fold(code, rows[code] ?? [], g), current: code == currentCode)
        }.sorted { a, b in
            if a.current != b.current { return a.current }
            return (term(a.code) ?? 0) > (term(b.code) ?? 0)
        }
        let pending: [Resource<Void>] = [meta.map { _ in () }, gradeSems.map { _ in () }, subjSems.map { _ in () }]
            + cards.map { $0.1.map { _ in () } } + regs.map { $0.1.map { _ in () } }
        let loading = pending.contains { $0.data == nil && $0.error == nil }
        return Academics(semesters: semesters, results: results, currentCode: currentCode, loading: loading)
    }

    /// paints from disk and refreshes whatever's stale behind the academics tab
    func refreshAcademics(force: Bool) async {
        let repo = repo!
        await repo.attendanceMeta.refresh(force: force).value
        let n = semesterNumber
        async let r: Void = n.isEmpty ? () : repo.results(n).refresh(force: force).value
        let gradeSems = await repo.gradeSemesters.value(force: force).data ?? []
        let subjSems = await repo.subjectSemesters.value(force: force).data ?? []
        await withTaskGroup(of: Void.self) { group in
            for s in gradeSems { let st = repo.gradeCard(s); group.addTask { await st.refresh(force: force).value } }
            for s in subjSems { let st = repo.subjects(s); group.addTask { await st.refresh(force: force).value } }
        }
        _ = await r
    }
}
