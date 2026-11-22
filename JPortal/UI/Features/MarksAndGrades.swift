import SwiftUI

/// the marks pdf, read into something you'd actually want to look at. exam
/// columns keep the portal's own names and order, the college's scheme is the college's business.
struct MarksContent: View {
    @Binding var picked: String?
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        let repo = graph.repo!
        let sems = repo.marksSemesters.state
        let list = sems.data ?? []
        let sem = list.byCode(picked) ?? currentSemester(list)
        let store = sem.map { repo.marks($0) }
        // no marks semesters at all is an answer too, not something to wait on
        let report: Resource<MarksReport> = store?.state ?? (sems.data != nil ? Resource(data: .empty, checked: true) : sems.map { _ in .empty })
        VStack(alignment: .leading, spacing: 0) {
            SemesterRow(semesters: list, selected: sem, fetchedAt: report.fetchedAt) { picked = $0 }
            StaleNotice(res: report) { store?.refresh(force: true) }
            ResourceGate(res: report, retry: { repo.marksSemesters.refresh(force: true); store?.refresh(force: true) },
                         empty: { $0.subjects.isEmpty }, emptyTitle: "No marks uploaded yet") { r in
                Summary(report: r)
                ForEach(r.subjects, id: \.code) { s in
                    if let code = sem?.code {
                        NavigationLink(value: Route.subject(semesterCode: code, subjectCode: s.code)) { SubjectMarksCard(s: s) }
                            .buttonStyle(.plain)
                    } else {
                        SubjectMarksCard(s: s)
                    }
                }
            }
        }
        .task(id: sem?.id) {
            repo.marksSemesters.refresh()
            store?.refresh()
        }
    }

    static func refresh(_ graph: AppGraph, code: String?, force: Bool) async {
        let list = await graph.repo.marksSemesters.value(force: force).data ?? []
        if let s = list.byCode(code) ?? currentSemester(list) { await graph.repo.marks(s).refresh(force: force).value }
    }
}

private func weighted(_ s: SubjectMarks) -> [(Double, Double)] {
    s.scores.compactMap { if case .value(let o, let m)? = $0.weighted { return (o, m) } else { return nil } }
}

private struct Summary: View {
    let report: MarksReport
    @Environment(\.palette) private var p

    var body: some View {
        let all = report.subjects.flatMap(weighted)
        let got = all.reduce(0) { $0 + $1.0 }
        let max = all.reduce(0) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 4) {
            Text("So far, all subjects").font(.subheadline.weight(.semibold))
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(fmt(got)).font(.number(52))
                Text(" of \(fmt(max))").font(.headline)
                Spacer()
                if max > 0 { Text("\(Int(got * 100 / max))%").font(.number(28)) }
            }
        }
        .foregroundStyle(p.onPrimaryContainer)
        .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
        .gutter()
        .padding(.vertical, 8)
    }
}

private struct SubjectMarksCard: View {
    let s: SubjectMarks
    @Environment(\.palette) private var p

    var body: some View {
        let shown = orderedScores(s.scores.filter { !($0.marks?.isNotApplicable ?? true) || !($0.weighted?.isNotApplicable ?? true) })
        let w = weighted(s)
        let got = w.reduce(0) { $0 + $1.0 }
        let max = w.reduce(0) { $0 + $1.1 }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name.titleCase).font(.headline).lineLimit(2)
                    Text(s.code).font(.caption.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
                }
                Spacer()
                if max > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(fmt(got)).font(.number(26))
                        Text("of \(fmt(max)) so far").font(.caption2.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
                    }
                }
            }
            if max > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(p.containerHighest)
                        Capsule().fill(p.marks(got / max)).frame(width: g.size.width * min(1, got / max))
                    }
                }
                .frame(height: 6)
                .padding(.top, 10)
            }
            if !shown.isEmpty {
                FlowLayout {
                    ForEach(shown, id: \.event) { ScoreChip(score: $0, background: p.containerHigh) }
                }
                .padding(.top, 12)
            }
        }
        .foregroundStyle(p.onSurface)
        .card(p.containerLow)
        .gutter()
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// a subject's "all marks" button lands here, the same view as the tab
struct MarksScreen: View {
    let code: String
    @State private var picked: String?
    @Environment(AppGraph.self) private var graph

    var body: some View {
        Screen("Marks", refresh: { await MarksContent.refresh(graph, code: picked ?? code, force: true) }) {
            MarksContent(picked: Binding(get: { picked ?? code }, set: { picked = $0 }))
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// one semester's grade card: the results up top, then every subject with its grade and credits
struct GradeCardScreen: View {
    let code: String
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        let data = graph.academics
        let sem = data.semester(code)
        let entries = sem?.grades ?? []
        Screen("Grade card", subtitle: [sem?.number.map { "Semester \($0)" }, prettySemester(code)].compactMap { $0 }.joined(separator: " · "),
               refresh: { await graph.refreshAcademics(force: true) }) {
            if entries.isEmpty && data.loading {
                CenteredLoading()
            } else if entries.isEmpty {
                MessageState(frog: .sleep, title: "Grades aren't out yet")
            } else {
                let credits = (sem?.result?.earnedCredits ?? 0) > 0 ? sem!.result!.earnedCredits : entries.reduce(0) { $0 + $1.credits }
                // points secured, the portal's semester total (the course rows' points add up to it)
                let points = (sem?.result?.gradePoints ?? 0) > 0 ? sem!.result!.gradePoints : entries.reduce(0) { $0 + $1.points }
                // four big numbers fit across most phones, a narrow one gets them a size down
                ViewThatFits(in: .horizontal) {
                    stats(sem?.result, credits: credits, points: points, size: 44, spacing: 28)
                    stats(sem?.result, credits: credits, points: points, size: 34, spacing: 18)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                CardGroup {
                    ForEach(entries, id: \.code) { e in
                        NavigationLink(value: Route.subject(semesterCode: code, subjectCode: e.code)) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.name.titleCase).font(.headline).lineLimit(2)
                                    Text(e.code).font(.caption.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
                                }
                                Spacer()
                                GradeLetter(grade: e.grade, size: 44)
                                Figure(value: fmt(e.credits), label: "credits", color: p.cgpa).frame(minWidth: 44)
                            }
                            .foregroundStyle(p.onSurface)
                            .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .groupRow(p.containerLow)
                    }
                }
                .padding(.top, 8)
            }
        }
        .navigationBarTitleDisplayMode(.large)
    }

    private func stats(_ r: SemesterResult?, credits: Double, points: Double, size: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if let r {
                stat("SGPA", String(format: "%.1f", r.sgpa), p.sgpa, size)
                stat("CGPA", String(format: "%.2f", r.cgpa), p.cgpa, size)
            }
            stat("Credits", fmt(credits), p.cgpa, size)
            stat("Points", fmt(points), p.sgpa, size)
        }
        .fixedSize()
    }

    private func stat(_ label: String, _ value: String, _ c: Color, _ size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
            Text(value).font(.number(size)).foregroundStyle(c)
        }
        .accessibilityElement(children: .combine)
    }
}
