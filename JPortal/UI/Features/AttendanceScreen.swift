import SwiftUI

/// a subject row. the percentage is always the portal's own, the class list
/// only adds the counts, the recent dots and the verdict.
struct SubjectLine: Identifiable {
    let subject: SubjectAttendance
    let tally: Tally?
    /// class list still on its way, nothing final to show yet
    let counting: Bool
    let checked: Bool
    let percent: Double
    /// the last few classes, oldest first, true for present
    let recent: [Bool]

    var id: String { subject.subjectId }
    var started: Bool { tally != nil || (subject.percent ?? 0) > 0 }

    init(_ subject: SubjectAttendance, _ daily: Resource<DailyAttendance>) {
        self.subject = subject
        let t = daily.data.map { AttendanceMath.tally($0.classes) }
        tally = (t?.total ?? 0) > 0 ? t : nil
        counting = daily.data == nil && daily.error == nil
        checked = daily.checked
        percent = subject.percent ?? 0
        recent = AttendanceMath.sorted(daily.data?.classes ?? []).suffix(7).map(\.isPresent)
    }
}

struct AttendanceScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var editTarget = false

    var body: some View {
        let repo = graph.repo!
        let sel = graph.semesterSelection
        let meta = repo.attendanceMeta.state
        let target = graph.prefs.target
        let semNumber = graph.semesterNumber
        let store = sel.selected.map { repo.attendance($0, semesterNumber: semNumber) }
        let detail = store?.state ?? meta.map { _ in AttendanceDetail() }
        let lines = sel.selected.map { sem in
            (detail.data?.subjects ?? []).map { SubjectLine($0, repo.daily(sem, $0).state) }
        } ?? []
        // cached class lists arrive a few ms after the detail, drawing in between would flash placeholders
        let ready = detail.checked && lines.allSatisfy(\.checked)

        Screen("Attendance", subtitle: detail.fetchedAt.map { "Updated \(ago($0))" }, refresh: { await refreshAll(force: true) }) {
            StaleNotice(res: detail) { Task { await refreshAll(force: true) } }
            if ready || detail.data == nil {
                ResourceGate(res: detail, retry: { Task { await refreshAll(force: true) } }, empty: { $0.subjects.isEmpty },
                             emptyTitle: "No attendance for this semester yet") { _ in
                    Overview(lines: lines, target: target) { editTarget = true }
                    ForEach(lines) { line in
                        NavigationLink(value: Route.subject(semesterCode: sel.selected?.code ?? "", subjectCode: line.subject.code)) {
                            SubjectCard(line: line, target: target)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                SemesterMenu(semesters: sel.all, selected: sel.selected, current: sel.current, bare: true) { _, s in
                    graph.prefs.semester = s.id == sel.current?.id ? nil : s.code
                }
            }
        }
        .sheet(isPresented: $editTarget) {
            TargetSheet(current: target) { graph.prefs.setTarget($0) }
                .presentationDetents([.medium])
        }
        .task(id: "\(sel.selected?.id ?? "-")|\(detail.fetchedAt?.timeIntervalSince1970 ?? 0)") { await refreshAll(force: false) }
    }

    private func refreshAll(force: Bool) async {
        let repo = graph.repo!
        await repo.attendanceMeta.refresh(force: force).value
        // a pin on the semester that's current anyway only goes stale when the next one starts
        if let pinned = graph.prefs.semester, pinned == graph.semesterSelection.current?.code { graph.prefs.semester = nil }
        guard let sem = graph.semesterSelection.selected else { return }
        let detail = await repo.attendance(sem, semesterNumber: graph.semesterNumber).value(force: force)
        // the class lists back the counts and the verdict, fetch them all behind the portal's percentages
        await withTaskGroup(of: Void.self) { group in
            for s in detail.data?.subjects ?? [] {
                let store = repo.daily(sem, s)
                group.addTask { await store.refresh(force: force).value }
            }
        }
    }
}

private struct Overview: View {
    let lines: [SubjectLine]
    let target: Int
    let onTarget: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        let counted = lines.compactMap(\.tally)
        let total = Tally(attended: counted.reduce(0) { $0 + $1.attended }, total: counted.reduce(0) { $0 + $1.total })
        // one number, shown once every subject is in, so it never climbs while lists land
        let waiting = lines.filter(\.counting).count
        let uncounted = lines.filter { $0.started && $0.tally == nil }.count
        let started = lines.filter(\.started)
        let percent: Double = waiting > 0 ? 0 : total.total > 0 ? total.percent : (started.isEmpty ? 0 : started.map(\.percent).reduce(0, +) / Double(started.count))
        let low = lines.filter { $0.started && $0.percent < Double(target) }.count

        HStack(spacing: 20) {
            AttendanceRing(percent: percent, target: target, size: 116, stroke: 12) {
                if waiting > 0 {
                    LoadingBlob(size: 40)
                } else {
                    VStack(spacing: 0) {
                        Text("\(Int(percent.rounded()))").font(.number(36)).minimumScaleFactor(0.5)
                        Text("percent").font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 18)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(waiting > 0 ? "Counting classes" : started.isEmpty ? "No classes yet" : low == 0 ? "All clear" : low == 1 ? "1 subject below target" : "\(low) subjects below target")
                    .font(.title2.weight(.semibold))
                Text(waiting > 0 ? "\(lines.count - waiting) of \(lines.count) subjects in"
                     : total.total == 0 ? "Nothing marked this semester"
                     : uncounted > 0 ? "\(total.attended) of \(total.total) classes, \(uncounted) not counted"
                     : "\(total.attended) of \(total.total) classes attended")
                    .font(.subheadline)
                    .lineLimit(2)
                Button(action: onTarget) {
                    Text("Target \(target)%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(low == 0 ? p.good : p.onSurface)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(p.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change your attendance goal")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(p.onPrimaryContainer)
        .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
        .gutter()
        .padding(.vertical, 8)
    }
}

private struct SubjectCard: View {
    let line: SubjectLine
    let target: Int
    @Environment(\.palette) private var p

    var body: some View {
        let below = line.started && line.percent < Double(target)
        HStack(spacing: 16) {
            AttendanceRing(percent: line.started ? line.percent : 0, target: target, size: 60, stroke: 6, shortfall: true) {
                if line.started || !line.counting {
                    Text(line.started ? "\(Int(line.percent.rounded()))" : "–")
                        .font(.number(17))
                        .foregroundStyle(line.started ? p.onSurface : p.onSurfaceVariant)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 8)
                }
            }
            .accessibilityLabel(line.started ? "\(Int(line.percent.rounded())) percent" : "not started")
            VStack(alignment: .leading, spacing: 4) {
                Text(line.subject.name.titleCase).font(.headline).lineLimit(2).foregroundStyle(p.onSurface)
                HStack(spacing: 6) {
                    ComponentTags(subject: line.subject)
                    if line.counting {
                        Placeholder(width: 34, height: 12)
                    } else if let t = line.tally {
                        Text("\(t.attended)/\(t.total)").font(.caption.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
                            .accessibilityLabel("\(t.attended) of \(t.total) classes")
                        RecentDots(recent: line.recent).padding(.leading, 4)
                    }
                }
                verdict
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card(below ? p.error.opacity(0.10) : p.containerLow)
        .animation(.easeInOut(duration: 0.6), value: below)
        .gutter()
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// exactly one line in every state, a card never changes height when its list lands
    @ViewBuilder private var verdict: some View {
        if line.counting {
            Placeholder(width: 84, height: 12).frame(height: 20, alignment: .leading)
        } else if let t = line.tally {
            let miss = t.canMiss(target), need = t.mustAttend(target)
            Text(need > 0 ? "Attend the next \(need == Int.max ? "all" : String(need))" : miss > 0 ? "Can miss \(miss)" : "Right on the edge, don't miss")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(need > 0 ? p.error : miss > 0 ? p.good : p.warn)
        } else if line.started {
            Text("Portal's %, class list didn't load").font(.subheadline.weight(.medium)).foregroundStyle(p.onSurfaceVariant).lineLimit(1)
        } else {
            Text("No classes marked yet").font(.subheadline.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
        }
    }
}

/// attendance goal picker: slider with a tick of haptics per percent
struct TargetSheet: View {
    let current: Int
    let onDone: (Int) -> Void
    @State private var value: Double = 75
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 16) {
            Text("Attendance goal").font(.title2.weight(.semibold))
            Text("Subjects under this get flagged.").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
            AttendanceRing(percent: value, target: 75, size: 120, stroke: 12) {
                Text("\(Int(value))%").font(.number(30))
            }
            Slider(value: $value, in: 50...100, step: 1)
                .accessibilityValue("\(Int(value)) percent")
                .sensoryFeedback(.selection, trigger: Int(value))
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .presentationBackground(p.surface)
        .onAppear { value = Double(current) }
        .onDisappear { onDone(Int(value)) }
    }
}
