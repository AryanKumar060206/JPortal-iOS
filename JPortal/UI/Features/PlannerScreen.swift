import SwiftUI

enum PlannerSheet: Identifiable, Hashable {
    case batch
    case klass(Klass)
    var id: String {
        switch self {
        case .batch: return "batch"
        case .klass(let k): return "k:\(k.day)\(k.start.minutes)\(k.subject)\(k.venue)"
        }
    }
}

/// one batch's week off the cdn timetable, a day at a time
struct PlannerScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var sheet: PlannerSheet?
    @State private var picked: Day?
    @State private var examPapers: [Paper]?

    var body: some View {
        let repo = graph.repo!
        let prefs = graph.prefs
        let res = graph.timetable.state
        let tt = res.data
        let general = repo.personal.state.data?.general
        let detected = general.flatMap { g in tt?.detect(batch: g.batch, semester: g.semester, program: g.program) }
        let path = BatchPath.parse(prefs.plannerBatch).flatMap { tt?.batch($0) != nil ? $0 : nil } ?? detected
        let batch = path.flatMap { tt?.batch($0) }
        let catalog = batch?.electives() ?? []
        let picks = path.flatMap { prefs.electives[$0.phaseKey] }
        let week = batch?.week(picks ?? [:]) ?? []

        MinuteClock { now in
            let today = Day(now)
            let counts = Dictionary(grouping: week, by: \.day).mapValues(\.count)
            // sunday has no column unless something's on it, so a sunday looks at the week ahead
            let sunday = counts[7] != nil
            let monday = today.weekday == 7 && !sunday ? today.plus(days: 1) : today.monday
            let days = (0..<(sunday ? 7 : 6)).map { monday.plus(days: $0) }
            let day = picked.flatMap { days.contains($0) ? $0 : nil } ?? (days.contains(today) ? today : days[0])
            let plan = DayPlan.of(week.filter { $0.day == day.weekday }, now: day == today ? Clock(now) : nil)
            let exams = (examPapers ?? []).filter { $0.day == today && $0.status(now) != .done }.sorted { $0.sortKey < $1.sortKey }

            Screen("Planner", refresh: {
                async let a: Void = graph.timetable.refresh(force: true).value
                async let b: Void = repo.personal.refresh(force: true).value
                _ = await (a, b)
            }) {
                StaleNotice(res: res) { graph.timetable.refresh(force: true) }
                ResourceGate(res: res, retry: { graph.timetable.refresh(force: true) }) { _ in
                    if batch == nil {
                        MessageState(frog: .look, title: "Which batch are you in?",
                                     message: "Couldn't match yours from the portal. Pick it once and your week shows up here.",
                                     action: "Pick batch") { sheet = .batch }
                    } else {
                        if !exams.isEmpty { ExamBanner(papers: exams) }
                        DayStrip(days: days, counts: counts, day: day, today: today) { picked = $0 }
                        HStack {
                            Text(day.format("EEEE, d MMMM")).font(.subheadline.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
                            Spacer()
                            let d = today.days(until: day)
                            if let rel = d == 0 ? "Today" : d == 1 ? "Tomorrow" : d == -1 ? "Yesterday" : nil {
                                Text(rel).font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
                            } else {
                                Button("Today") { picked = nil }.font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                        if plan.rows.isEmpty {
                            let unpicked = !catalog.isEmpty && (picks ?? [:]).values.allSatisfy(\.isEmpty)
                            if unpicked {
                                MessageState(frog: .look, title: "Nothing on, so far", message: "No electives picked yet, they might be hiding here.",
                                             action: "Pick electives") { sheet = .batch }
                            } else {
                                MessageState(frog: .party, title: "Free day", message: "Nothing on the timetable.")
                            }
                        } else {
                            CardGroup {
                                ForEach(Array(plan.rows.enumerated()), id: \.offset) { i, row in
                                    switch row {
                                    case .klass(let k):
                                        ClassRow(k: k, live: plan.live.contains(k), timeline: prefs.timeline, up: i > 0, down: i < plan.rows.count - 1) {
                                            sheet = .klass(k)
                                        }
                                    case .free(let m):
                                        FreeRow(minutes: m, timeline: prefs.timeline)
                                    }
                                }
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let batch {
                        Button { sheet = .batch } label: {
                            HStack(spacing: 6) {
                                Text(batch.name).font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.down").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(p.onSurface)
                            .padding(.horizontal, 4)
                        }
                        .accessibilityLabel("Batch, \(batch.name)")
                    }
                }
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .batch:
                if let tt { PickerSheet(timetable: tt, path: path, detected: detected, catalog: catalog, picks: picks ?? [:], batch: batch) }
            case .klass(let k):
                ClassSheet(k: k)
            }
        }
        // a phase nobody has picked for yet starts from the portal's registrations
        .task(id: "\(path?.phaseKey ?? "")|\(catalog.isEmpty)|\(picks == nil)") {
            if let path, let batch, !catalog.isEmpty, picks == nil { _ = await matchPortal(graph, path: path, batch: batch) }
        }
        .task {
            graph.timetable.refresh()
            repo.personal.refresh()
            examPapers = await repo.examSheet()
        }
    }
}

/// picks from what's registered on the portal, false when that couldn't be read
@MainActor
func matchPortal(_ graph: AppGraph, path: BatchPath, batch: Timetable.Batch) async -> Bool {
    let repo = graph.repo!
    // this term's registrations, not next term's that the portal lists first once they open
    guard let sem = currentSemester(await repo.subjectSemesters.value().data ?? []),
          let rows = await repo.subjects(sem).value().data?.rows else { return false }
    graph.prefs.setElectives(path.phaseKey, batch.prefill(rows.map { ($0.code, $0.name) }))
    return true
}

private struct ExamBanner: View {
    let papers: [Paper]
    @Environment(\.palette) private var p

    var body: some View {
        NavigationLink(value: Route.exams) {
            HStack(spacing: 14) {
                Image(systemName: "pencil.and.list.clipboard").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(papers.count == 1 ? "Exam today" : "\(papers.count) exams today").font(.subheadline.weight(.semibold))
                    Text(papers.map { [$0.slot.subjectName.titleCase, $0.slot.start?.format()].compactMap { $0 }.joined(separator: ", ") }.joined(separator: " · "))
                        .font(.subheadline).lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(p.onTertiaryContainer)
            .card(p.tertiaryContainer, radius: Radius.large)
        }
        .buttonStyle(.plain)
        .gutter()
        .padding(.vertical, 8)
    }
}

private struct DayStrip: View {
    let days: [Day]
    let counts: [Int: Int]
    let day: Day
    let today: Day
    let pick: (Day) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { d in
                let n = counts[d.weekday] ?? 0
                let on = d == day
                Button { pick(d) } label: {
                    DayPill(day: d, count: n, background: on ? p.secondaryContainer : .clear, foreground: p.onSurface,
                            dim: n == 0, today: d == today, selected: on)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .sensoryFeedback(.selection, trigger: on)
                .accessibilityLabel([d.format("EEEE d MMMM"), d == today ? "today" : nil, on ? "selected" : nil,
                                     n == 0 ? "free day" : plural(n, "class", "classes")].compactMap { $0 }.joined(separator: ", "))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

private struct ClassRow: View {
    let k: Klass
    let live: Bool
    let timeline: Bool
    let up: Bool
    let down: Bool
    let open: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .trailing, spacing: 0) {
                    (Text(k.start.format(ampm: false)).font(.number(22, weight: live ? .regular : .bold)) + Text(" " + k.start.ampm).font(.caption2.weight(.bold)))
                        .foregroundStyle(p.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("to \(k.end.format(ampm: false))").font(.caption.weight(.semibold)).foregroundStyle(p.onSurfaceVariant).lineLimit(1)
                }
                .frame(width: 66, alignment: .trailing)
                .padding(.vertical, 14)
                if timeline { Rail(accent: live, up: up, down: down, dot: 0.3) } else { Spacer().frame(width: 4) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(k.subject).font(.headline).lineLimit(2).minimumScaleFactor(0.85).foregroundStyle(p.onSurface)
                    Text([componentName[k.type] ?? k.type, k.teacher.isBlank ? nil : k.teacher].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(p.onSurfaceVariant).lineLimit(1)
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !k.venue.isBlank {
                    Text(k.venue)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(live ? p.surface : p.containerHighest, in: Capsule())
                        .frame(maxWidth: 84)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .groupRow(live ? p.containerHighest : p.containerLow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([k.subject, componentName[k.type] ?? k.type, "\(k.start.format()) to \(k.end.format())",
                             k.venue.isBlank ? nil : "in \(k.venue)", live ? "on now" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

private struct FreeRow: View {
    let minutes: Int
    let timeline: Bool
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 66)
            if timeline {
                Rectangle().fill(p.outlineVariant.opacity(0.8)).frame(width: 2).frame(maxHeight: .infinity)
                    .mask(VStack(spacing: 3) { ForEach(0..<8, id: \.self) { _ in Rectangle().frame(height: 3) } })
                    .frame(width: 24)
            }
            Label("\(minutesText(minutes)) free", systemImage: "bed.double").font(.caption.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
            Spacer()
        }
        .frame(height: 44)
        .padding(.leading, 4)
        .groupRow(p.containerLow)
    }
}

/// one class, tapped on the timeline
private struct ClassSheet: View {
    let k: Klass
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([componentName[k.type] ?? k.type, k.elective ? k.category : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
            Text(k.subject).font(.title2.weight(.semibold))
            if !k.code.isBlank { Text(k.code).font(.caption).foregroundStyle(p.onSurfaceVariant) }
            VStack(alignment: .leading, spacing: 14) {
                let weekday = Day.today().monday.plus(days: k.day - 1).format("EEEE")
                Fact(icon: "clock", text: "\(weekday), \(k.start.format(ampm: (k.start.hour < 12) != (k.end.hour < 12))) – \(k.end.format())",
                     sub: minutesText(k.end.minutes - k.start.minutes))
                if !k.venue.isBlank { Fact(icon: "door.left.hand.open", text: k.venue, sub: nil) }
                if !k.teacher.isBlank { Fact(icon: "person", text: k.teacher, sub: nil) }
                if !k.batches.isEmpty { Fact(icon: "person.3", text: k.batches.joined(separator: ", "), sub: k.batches.count == 1 ? "batch" : "batches together") }
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(p.surface)
    }
}

// the picker: course, semester, phase and batch walked top down, then the electives of the batch picked
private struct PickerSheet: View {
    let timetable: Timetable
    let path: BatchPath?
    let detected: BatchPath?
    let catalog: [(String, [String])]
    let picks: [String: Set<String>]
    let batch: Timetable.Batch?

    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @State private var course: String?
    @State private var sem: String?
    @State private var phase: String?
    @State private var failed = false

    var body: some View {
        let c = timetable.courses.first { $0.id == course }
        let s = c?.semesters.first { $0.id == sem }
        let ph = s?.phases.first { $0.id == phase }
        let here = path != nil && path?.course == course && path?.semester == sem && path?.phase == phase
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let detected, path != detected {
                        Button("Go back to the portal's batch, \(timetable.batch(detected)?.name ?? "")") {
                            graph.prefs.plannerBatch = nil
                            course = detected.course
                            sem = detected.semester
                            phase = detected.phase
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.bottom, 8)
                    } else if detected == nil {
                        Text("The portal's batch didn't match one here, so it's up to you.")
                            .font(.subheadline).foregroundStyle(p.onSurfaceVariant).padding(.bottom, 8)
                    }
                    choices("Course", timetable.courses.map { ($0.id, $0.name) }, course) { id in
                        course = id
                        let only = timetable.courses.first { $0.id == id }?.semesters.count == 1 ? timetable.courses.first { $0.id == id }?.semesters.first : nil
                        sem = only?.id
                        phase = only?.phases.count == 1 ? only?.phases.first?.id : nil
                    }
                    if let c {
                        choices("Semester", c.semesters.map { ($0.id, $0.name) }, sem) { id in
                            sem = id
                            let phases = c.semesters.first { $0.id == id }?.phases ?? []
                            phase = phases.count == 1 ? phases.first?.id : nil
                        }
                    }
                    // nearly always a single phase, no point asking
                    if let s, s.phases.count > 1 {
                        choices("Phase", s.phases.map { ($0.id, $0.name) }, phase) { phase = $0 }
                    }
                    if let c, let s, let ph {
                        choices("Batch", ph.batches.map { ($0.id, $0.name) }, here ? path?.batch : nil) { id in
                            let picked = BatchPath(course: c.id, semester: s.id, phase: ph.id, batch: id)
                            graph.prefs.plannerBatch = picked == detected ? nil : picked.key
                        }
                    }
                    if here && !catalog.isEmpty {
                        Divider().padding(.top, 24).padding(.bottom, 16)
                        Text("Electives").font(.headline)
                        Text("Pick the ones you take, the rest stay off your week.").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                        ForEach(catalog, id: \.0) { category, subjects in
                            let on = picks[category] ?? []
                            label(category.ifBlank("Electives"))
                            FlowLayout {
                                ForEach(subjects, id: \.self) { subject in
                                    Chip(label: subject, selected: on.contains(subject), check: true) {
                                        var next = picks
                                        next[category] = on.contains(subject) ? on.subtracting([subject]) : on.union([subject])
                                        if let path { graph.prefs.setElectives(path.phaseKey, next) }
                                    }
                                }
                            }
                        }
                        Button {
                            Task {
                                if let path, let batch { failed = !(await matchPortal(graph, path: path, batch: batch)) }
                            }
                        } label: {
                            Label("Match my portal subjects", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 20)
                        if failed {
                            Text("Couldn't read your subjects off the portal").font(.caption).foregroundStyle(p.error).padding(.top, 6)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Your timetable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(p.surface)
        .onAppear {
            course = path?.course
            sem = path?.semester
            phase = path?.phase
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(p.onSurfaceVariant).padding(.top, 18).padding(.bottom, 8)
    }

    @ViewBuilder
    private func choices(_ title: String, _ options: [(String, String)], _ selected: String?, pick: @escaping (String) -> Void) -> some View {
        label(title)
        FlowLayout {
            ForEach(options, id: \.0) { id, name in Chip(label: name, selected: id == selected) { pick(id) } }
        }
    }
}
