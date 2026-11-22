import Charts
import SwiftUI

struct SubjectScreen: View {
    let semesterCode: String
    let subjectCode: String

    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var day: Day?

    var body: some View {
        let repo = graph.repo!
        let target = graph.prefs.target
        // attendance, when the portal still keeps it for this semester
        let attSem = repo.attendanceMeta.state.data?.semesters.byCode(semesterCode)
        let detailStore = attSem.map { repo.attendance($0, semesterNumber: graph.semesterNumber) }
        let subject = detailStore?.state.data?.subjects.first { $0.code == subjectCode }
        let dailyStore = attSem.flatMap { s in subject.map { repo.daily(s, $0) } }
        let daily = dailyStore?.state ?? Resource()
        let classes = daily.data?.classes ?? []
        let tally = AttendanceMath.tally(classes)
        // teachers and credits live under the subject registrations
        let faculty = repo.subjectSemesters.state.data?.byCode(semesterCode).map { repo.subjects($0).state.data?.rows.filter { $0.code == subjectCode } ?? [] } ?? []
        // marks for this subject from the semester's marks pdf
        let marks = repo.marksSemesters.state.data?.byCode(semesterCode).flatMap { repo.marks($0).state.data?.subjects.first { $0.code == subjectCode } }
        // and the grade, once the semester is done
        let grade = repo.gradeSemesters.state.data?.byCode(semesterCode).flatMap { repo.gradeCard($0).state.data?.entries.first { $0.code == subjectCode } }
        let name = subject?.name ?? faculty.first?.name ?? grade?.name ?? marks?.name

        Group {
            if let name {
                Screen(name.titleCase, subtitle: "\(subjectCode) · \(prettySemester(semesterCode))", refresh: {
                    async let a: Void = dailyStore?.refresh(force: true).value ?? ()
                    async let b: Void = detailStore?.refresh(force: true).value ?? ()
                    _ = await (a, b)
                }) {
                    StaleNotice(res: daily) { dailyStore?.refresh(force: true) }
                    // once the grade is out the semester is over: the grade leads, and attendance stays below as a
                    // record of how it went, with no "can miss" advice for classes that have already happened
                    let finished = !(grade?.grade.isBlank ?? true)
                    let teachers = Dictionary(faculty.map { ($0.component, $0.facultyName) }, uniquingKeysWith: { a, _ in a })
                    hero(subject: finished ? nil : subject, tally: tally, target: target, grade: grade, credits: faculty.first?.credits ?? grade?.credits)
                    if finished {
                        marksSection(marks)
                        if let subject { attendanceRecord(subject: subject, tally: tally, target: target) }
                        teachersSection(subject: subject, faculty: faculty, teachers: teachers)
                        history(classes, target: target, finished: true)
                    } else {
                        teachersSection(subject: subject, faculty: faculty, teachers: teachers)
                        calendarAndTrend(classes, target: target, finished: false)
                        marksSection(marks)
                        if subject != nil, let f = faculty.first {
                            Text("\(fmt(f.credits)) credits" + (f.isAudit ? " · audit" : ""))
                                .font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                        classList(classes)
                    }
                }
            } else {
                Screen("") { CenteredLoading() }
            }
        }
        .navigationBarTitleDisplayMode(.large)
        .task(id: attSem?.id) {
            detailStore?.refresh()
            repo.subjectSemesters.refresh()
            repo.marksSemesters.refresh()
            repo.gradeSemesters.refresh()
        }
        .task(id: "\(subject?.subjectId ?? "")") { dailyStore?.refresh() }
        .task(id: repo.subjectSemesters.state.data?.count) {
            if let s = repo.subjectSemesters.state.data?.byCode(semesterCode) { repo.subjects(s).refresh() }
        }
        .task(id: repo.marksSemesters.state.data?.count) {
            if let s = repo.marksSemesters.state.data?.byCode(semesterCode) { repo.marks(s).refresh() }
        }
        .task(id: repo.gradeSemesters.state.data?.count) {
            if let s = repo.gradeSemesters.state.data?.byCode(semesterCode) { repo.gradeCard(s).refresh() }
        }
    }

    @ViewBuilder
    private func teachersSection(subject: SubjectAttendance?, faculty: [SubjectFaculty], teachers: [String: String]) -> some View {
        if let subject {
            Components(subject: subject, faculty: teachers)
        } else if !faculty.isEmpty {
            SectionHeader("Taught by")
            CardGroup {
                ForEach(uniqueTeachers(faculty), id: \.component) { f in
                    InfoRow(componentName[f.component] ?? f.component, f.facultyName.nameCase).groupRow(p.containerLow)
                }
            }
        }
    }

    @ViewBuilder
    private func calendarAndTrend(_ classes: [ClassRecord], target: Int, finished: Bool) -> some View {
        let calendar = AttendanceMath.calendar(classes)
        if !calendar.isEmpty {
            SectionHeader("Calendar")
            AttendanceCalendar(marks: calendar, selected: day) { d in day = d == day ? nil : d }
                .padding(.horizontal, 8)
            if let d = day {
                let list = classes.filter { $0.date == d }
                if list.isEmpty {
                    Text(d > Day.today() ? "Nothing marked yet for \(d.format("EEE, d MMM"))" : "No class on \(d.format("EEE, d MMM"))")
                        .font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) { ForEach(list, id: \.self) { ClassRow(c: $0, compact: true) } }
                        .gutter()
                }
            }
        }
        let trend = AttendanceMath.trend(classes)
        if trend.count >= 3 {
            SectionHeader(finished ? "How it went" : "How it's been going")
            TrendChart(points: trend.map(\.1), target: target).padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func history(_ classes: [ClassRecord], target: Int, finished: Bool) -> some View {
        calendarAndTrend(classes, target: target, finished: finished)
        classList(classes)
    }

    @ViewBuilder
    private func classList(_ classes: [ClassRecord]) -> some View {
        if !classes.isEmpty {
            SectionHeader("Every class")
            ForEach(AttendanceMath.sorted(classes).reversed(), id: \.self) { ClassRow(c: $0) }
        }
    }

    @ViewBuilder
    private func marksSection(_ marks: SubjectMarks?) -> some View {
        if let marks, marks.scores.contains(where: { !($0.marks?.isNotApplicable ?? true) }) {
            SectionHeader(text: "Marks") {
                NavigationLink("All marks", value: Route.marks(semesterCode)).font(.subheadline.weight(.semibold))
            }
            FlowLayout {
                ForEach(orderedScores(marks.scores.filter { !($0.marks?.isNotApplicable ?? true) || !($0.weighted?.isNotApplicable ?? true) }), id: \.event) {
                    ScoreChip(score: $0, background: p.containerLow)
                }
            }
            .gutter()
        }
    }

    /// a finished semester's attendance as it ended: the figure, no advice
    @ViewBuilder
    private func attendanceRecord(subject: SubjectAttendance, tally: Tally, target: Int) -> some View {
        let percent = subject.percent ?? 0
        if tally.total > 0 || percent > 0 {
            SectionHeader("Attendance")
            HStack(spacing: 16) {
                AttendanceRing(percent: percent, target: target, size: 60, stroke: 6) {
                    Text("\(Int(percent.rounded()))").font(.number(19))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(percent.rounded()))% attendance").font(.headline)
                    Text(tally.total > 0 ? "\(tally.attended) of \(tally.total) classes" : "The portal's figure")
                        .font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .card(p.containerLow)
            .gutter()
            .accessibilityElement(children: .combine)
        }
    }

    private func uniqueTeachers(_ rows: [SubjectFaculty]) -> [SubjectFaculty] {
        var seen = Set<String>()
        return rows.filter { !$0.facultyName.isBlank && seen.insert($0.component).inserted }
    }

    @ViewBuilder
    private func hero(subject: SubjectAttendance?, tally: Tally, target: Int, grade: GradeEntry?, credits: Double?) -> some View {
        VStack(spacing: 16) {
            if let subject {
                // same rule as the list card: nothing counted and nothing from the portal means it hasn't started
                let percent = subject.percent ?? 0
                let started = tally.total > 0 || percent > 0
                AttendanceRing(percent: started ? percent : 0, target: target, size: 184, stroke: 16, shortfall: true) {
                    VStack(spacing: 2) {
                        Text(started ? "\(Int(percent.rounded()))%" : "–").font(.number(48))
                            .foregroundStyle(started ? p.onSurface : p.onSurfaceVariant)
                        if tally.total > 0 { Text("\(tally.attended) of \(tally.total)").font(.subheadline.weight(.semibold)) }
                    }
                }
                if tally.total > 0 {
                    Verdict(miss: tally.canMiss(target), need: tally.mustAttend(target), target: target, exact: tally.attended * 100 == target * tally.total)
                } else if !started {
                    Text("No classes marked yet").font(.subheadline.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
                }
                if let g = grade?.grade, !g.isBlank {
                    Text("Grade \(g)").font(.headline).foregroundStyle(p.grade(g))
                }
            } else {
                // a finished semester, or one the portal keeps no attendance for: the grade is the headline
                GradeLetter(grade: grade?.grade ?? "", size: 120)
                let line = [credits.map { "\(fmt($0)) credits" }, grade.flatMap { $0.gradePoint > 0 ? "\(fmt($0.gradePoint)) grade points" : nil }]
                    .compactMap { $0 }.joined(separator: " · ")
                Text(line.isEmpty ? "Grade not out yet" : line).font(.headline).foregroundStyle(p.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct Verdict: View {
    let miss: Int
    let need: Int
    let target: Int
    let exact: Bool
    @Environment(\.palette) private var p

    var body: some View {
        let (text, color): (String, Color) = {
            if need == Int.max { return ("Can't reach \(target)% any more this semester", p.error) }
            if need > 0 { return ("Attend the next \(plural(need, "class", "classes")) to reach \(target)%", p.error) }
            if miss > 0 { return ("You can miss \(plural(miss, "class", "classes")) and stay above \(target)%", p.good) }
            // no absence to spare yet not under: 18/27 is 66.7, 18/28 is 64.3
            return ("\(exact ? "Exactly on" : "Just above") \(target)%, the next absence drops you under", p.warn)
        }()
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.14), in: Capsule())
            .padding(.horizontal, 16)
    }
}

private struct Components: View {
    let subject: SubjectAttendance
    let faculty: [String: String]
    @Environment(\.palette) private var p

    var body: some View {
        let rows: [(String, String, Double?)] = [
            subject.lectureComponent.map { _ in ("L", "Lecture", subject.lecturePercent) },
            subject.tutorialComponent.map { _ in ("T", "Tutorial", subject.tutorialPercent) },
            subject.practicalComponent.map { _ in ("P", "Practical", subject.practicalPercent) },
        ].compactMap { $0 }
        if !rows.isEmpty {
            SectionHeader("Components")
            VStack(spacing: 8) {
                ForEach(rows, id: \.0) { k, name, pct in
                    HStack(spacing: 14) {
                        Text(k).font(.headline).frame(width: 36, height: 36).background(p.secondaryContainer, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.subheadline.weight(.semibold))
                            if let t = faculty[k] { Text(t.nameCase).font(.caption).foregroundStyle(p.onSurfaceVariant) }
                        }
                        Spacer()
                        if let pct { Text("\(Int(pct.rounded()))%").font(.number(17)) }
                    }
                    .card(p.containerLow, radius: Radius.medium, padding: 14)
                    .accessibilityElement(children: .combine)
                }
            }
            .gutter()
            Text("Component percentages are the portal's own, updated once a day.")
                .font(.caption).foregroundStyle(p.onSurfaceVariant)
                .padding(.horizontal, 20).padding(.vertical, 8)
        }
    }
}

private struct ClassRow: View {
    let c: ClassRecord
    var compact = false
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: c.isPresent ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(c.isPresent ? p.good : p.error)
                .accessibilityLabel(c.isPresent ? "Present" : "Absent")
            VStack(alignment: .leading, spacing: 2) {
                Text(c.date?.format("EEE, d MMM") ?? c.datetime).font(.body)
                let time = [c.start?.format(), c.end?.format()].compactMap { $0 }.joined(separator: " – ")
                Text([time, c.classType == "Regular" ? "" : c.classType, c.takenBy.nameCase].filter { !$0.isBlank }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(p.onSurfaceVariant)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 4 : 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// a month at a time, days tinted by how the classes on them went
struct AttendanceCalendar: View {
    let marks: [Day: DayMark]
    let selected: Day?
    let onPick: (Day) -> Void
    @Environment(\.palette) private var p
    @State private var month: (Int, Int)?

    var body: some View {
        let latest = marks.keys.max() ?? Day.today()
        let earliest = marks.keys.min() ?? latest
        let (y, m) = month ?? (latest.year, latest.month)
        let first = Day(year: y, month: m, day: 1)
        let next = m == 12 ? Day(year: y + 1, month: 1, day: 1) : Day(year: y, month: m + 1, day: 1)
        let count = first.days(until: next)
        let lead = first.weekday - 1
        let canBack = first > earliest
        let canForward = next <= latest

        VStack(spacing: 8) {
            HStack {
                Text(first.format("MMMM yyyy")).font(.title3.weight(.semibold))
                Spacer()
                Button { shift(-1, y, m) } label: { Image(systemName: "chevron.left") }
                    .disabled(!canBack).padding(.horizontal, 12)
                    .accessibilityLabel("Previous month")
                Button { shift(1, y, m) } label: { Image(systemName: "chevron.right") }
                    .disabled(!canForward)
                    .accessibilityLabel("Next month")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.caption.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
                }
                ForEach(0..<(lead + count), id: \.self) { i in
                    if i < lead {
                        Color.clear.frame(height: 40)
                    } else {
                        cell(first.plus(days: i - lead))
                    }
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40, canForward { shift(1, y, m) }
            if v.translation.width > 40, canBack { shift(-1, y, m) }
        })
    }

    private func shift(_ by: Int, _ y: Int, _ m: Int) {
        let total = y * 12 + (m - 1) + by
        withAnimation(.easeInOut(duration: 0.2)) { month = (total / 12, total % 12 + 1) }
    }

    @ViewBuilder private func cell(_ d: Day) -> some View {
        let mark = marks[d]
        let (bg, fg): (Color, Color) = {
            switch mark {
            case .present?: return (p.goodContainer, p.dark ? p.good : p.onTertiaryContainer)
            case .absent?: return (p.errorContainer, p.dark ? p.error : Color(hex: 0x7F1D1D))
            case .mixed?: return (p.warn.opacity(0.22), p.warn)
            case nil: return (.clear, p.onSurfaceVariant.opacity(0.8))
            }
        }()
        Button { onPick(d) } label: {
            Text("\(d.day)")
                .font(.callout.weight(mark == nil ? .regular : .semibold))
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(bg, in: Circle())
                .overlay(Circle().stroke(selected == d ? p.primary : (d == Day.today() ? p.outlineVariant : .clear), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected == d)
        .accessibilityLabel("\(d.format("EEEE d MMMM")), \(mark.map { $0 == .present ? "present" : $0 == .absent ? "absent" : "mixed" } ?? "no class")")
    }
}

/// the running percentage over the semester, with the goal as a rule
struct TrendChart: View {
    let points: [Double]
    let target: Int
    @Environment(\.palette) private var p

    var body: some View {
        let low = max(0, min(Double(target) - 10, (points.min() ?? 0) - 5))
        Chart {
            RuleMark(y: .value("Goal", target))
                .foregroundStyle(p.onSurfaceVariant.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("\(target)%").font(.caption2).foregroundStyle(p.onSurfaceVariant)
                }
            ForEach(Array(points.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("Class", i), yStart: .value("Base", low), yEnd: .value("Percent", v))
                    .foregroundStyle(LinearGradient(colors: [p.primary.opacity(0.25), p.primary.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Class", i), y: .value("Percent", v))
                    .foregroundStyle(p.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: low...100)
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
        .frame(height: 160)
        .accessibilityLabel("Attendance over the semester, now \(Int((points.last ?? 0).rounded())) percent")
    }
}
