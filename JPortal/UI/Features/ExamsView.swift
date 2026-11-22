import EventKit
import EventKitUI
import SwiftUI

enum ExamTarget: Identifiable, Hashable {
    case paper(String)
    case day(Day)
    var id: String {
        switch self {
        case .paper(let k): return "p:\(k)"
        case .day(let d): return "d:\(d)"
        }
    }
}

// room and seat land about a day out, so look harder then instead of waiting out the hour long cache
private let seatPoll: TimeInterval = 10 * 60

/// the date sheet for one exam semester, every event's papers flattened
struct ExamsContent: View {
    @Binding var picked: String?
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var showDone = false
    @State private var sheet: ExamTarget?
    /// what the disk had before the network answered, to tell when a seat just landed
    @State private var blank: [String: Set<String>] = [:]

    var body: some View {
        MinuteClock { now in content(now) }
            .sheet(item: $sheet) { target in
                ExamSheet(target: target, papers: currentPapers, plan: ExamPlan.of(currentPapers, now: AppClock.now()), inCalendar: inCalendar)
            }
    }

    private var semester: Semester? {
        let list = graph.repo.examSemesters.state.data ?? []
        return list.byCode(picked) ?? currentSemester(list)
    }

    private var currentPapers: [Paper] {
        guard let sem = semester else { return [] }
        let repo = graph.repo!
        return (repo.examEvents(sem).state.data ?? []).flatMap { ev in (repo.examSchedule(ev).state.data ?? []).map { Paper(event: ev, slot: $0) } }
    }

    private var inCalendar: Set<String> { graph.prefs.calendarSync ? graph.calendar.synced : [] }

    @ViewBuilder
    private func content(_ now: Date) -> some View {
        let repo = graph.repo!
        let sems = repo.examSemesters.state
        let list = sems.data ?? []
        let sem = semester
        let store = sem.map { repo.examEvents($0) }
        // no exam semester at all is an answer too, not a reason to spin forever
        let events: Resource<[ExamEvent]> = store?.state ?? (sems.data != nil ? Resource(data: [], fetchedAt: sems.fetchedAt, checked: true) : sems.map { _ in [] })
        let today = Day(now)
        let sheets = (events.data ?? []).map { ($0, repo.examSchedule($0).state) }
        let papers = sheets.flatMap { ev, r in (r.data ?? []).map { Paper(event: ev, slot: $0) } }
        let loadingPapers = sheets.contains { $0.1.data == nil && $0.1.error == nil }
        let fresh = Set(sheets.flatMap { ev, r in
            (r.data ?? []).filter(\.seated).map { Paper(event: ev, slot: $0).key }.filter { blank[ev.id]?.contains($0) == true }
        })
        let pending = sheets.filter { ev, r in r.data?.isEmpty == true && (ev.fromDay.map { $0 >= today } ?? false) }.map(\.0)
        let plan = ExamPlan.of(papers, now: now)
        let current = sem != nil && sem?.id == currentSemester(list)?.id

        VStack(alignment: .leading, spacing: 0) {
            SemesterRow(semesters: list, selected: sem, fetchedAt: events.fetchedAt) { picked = $0 }
            StaleNotice(res: events) { Task { await ExamsContent.refresh(graph, code: picked, force: true) } }
            ResourceGate(res: events, retry: { Task { await ExamsContent.refresh(graph, code: picked, force: true) } }) { _ in
                if papers.isEmpty {
                    if loadingPapers {
                        CenteredLoading()
                    } else if let first = pending.min(by: { ($0.from ?? .max) < ($1.from ?? .max) }) {
                        MessageState(frog: .look, title: "Date sheet's not out yet",
                                     message: "\(first.short) starts around \(first.fromDay?.format("EEE d MMM") ?? "soon"). It shows up here once the portal has it.")
                    } else {
                        MessageState(frog: .sleep, title: "No exams on the calendar", message: "Enjoy it while it lasts.")
                    }
                } else {
                    if plan.next == nil {
                        MessageState(frog: .party, title: "That's a wrap", message: "Every paper on this sheet is done.")
                    } else if plan.run.count >= 2 {
                        RunStrip(plan: plan, papers: papers) { sheet = .day($0) }
                    }
                    if !plan.days.isEmpty {
                        SectionHeader("Date sheet")
                        ForEach(plan.days, id: \.self) { d in
                            if d.free > 0 { Gap(free: d.free) }
                            DayHeader(day: d.date, today: plan.today)
                            CardGroup {
                                ForEach(Array(d.papers.enumerated()), id: \.element.key) { i, paper in
                                    PaperRow(paper: paper, plan: plan, fresh: fresh.contains(paper.key), up: i > 0, down: i < d.papers.count - 1) {
                                        sheet = .paper(paper.key)
                                    }
                                }
                            }
                        }
                    }
                    if !pending.isEmpty {
                        CardGroup {
                            ForEach(pending) { ev in PendingRow(event: ev).groupRow(p.containerLow) }
                        }
                        .padding(.top, 12)
                    }
                    if !plan.done.isEmpty {
                        Button { withAnimation(.snappy) { showDone.toggle() } } label: {
                            HStack {
                                Text("Done · \(plural(plan.done.count, "paper"))").font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.down").rotationEffect(.degrees(showDone ? 180 : 0))
                            }
                            .foregroundStyle(p.onSurfaceVariant)
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showDone ? "expanded" : "collapsed")
                        if showDone {
                            CardGroup {
                                ForEach(Array(plan.done.enumerated()), id: \.element.key) { i, paper in
                                    PaperRow(paper: paper, plan: plan, fresh: false, up: i > 0, down: i < plan.done.count - 1) { sheet = .paper(paper.key) }
                                }
                            }
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .task(id: sem?.id) {
            repo.examSemesters.refresh()
            store?.refresh()
        }
        .task(id: (events.data ?? []).map(\.id).joined()) {
            for ev in events.data ?? [] {
                let st = repo.examSchedule(ev)
                await st.refresh().value
                if blank[ev.id] == nil, let data = st.state.data {
                    blank[ev.id] = Set(data.filter { !$0.seated }.map { Paper(event: ev, slot: $0).key })
                }
                let due = (st.state.data ?? []).contains { s in !s.seated && (s.day.map { $0 >= today && $0 <= today.plus(days: 2) } ?? false) }
                if due, Date().timeIntervalSince(st.state.fetchedAt ?? .distantPast) > seatPoll { st.refresh(force: true) }
            }
        }
        // the sync follows whatever the portal last said about the current semester
        .task(id: "\(graph.prefs.calendarSync)|\(current)|\(papers.count)|\(loadingPapers)|\(papers.map(\.slot.seat).joined())") {
            if graph.prefs.calendarSync && current && !loadingPapers && events.data != nil { await graph.calendar.sync() }
        }
    }

    static func refresh(_ graph: AppGraph, code: String?, force: Bool) async {
        let repo = graph.repo!
        let list = await repo.examSemesters.value(force: force).data ?? []
        guard let s = list.byCode(code) ?? currentSemester(list) else { return }
        let events = await repo.examEvents(s).value(force: force).data ?? []
        await withTaskGroup(of: Void.self) { group in
            for ev in events { let st = repo.examSchedule(ev); group.addTask { await st.refresh(force: force).value } }
        }
    }
}

/// 3:30 – 4:30 PM, or 11:30 AM – 1:00 PM across noon. the portal's own text when it won't parse
func examWindow(_ p: Paper) -> String? {
    guard let s = p.slot.start else {
        let raw = p.slot.until.ifBlank(p.slot.from).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }
    guard let e = p.slot.end else { return s.format() }
    return "\(s.format(ampm: (s.hour < 12) != (e.hour < 12))) – \(e.format())"
}

func relativeDay(_ day: Day, _ today: Day) -> String {
    let d = today.days(until: day)
    switch d {
    case -1: return "Yesterday"
    case ..<0: return "\(-d) days ago"
    case 0: return "Today"
    case 1: return "Tomorrow"
    default: return "in \(d) days"
    }
}

// some rooms come whole, "G7 : CLASS ROOM G-7  GF ABB1". the badge only needs the code, the sheet shows the rest
private func badgeRoom(_ room: String) -> String {
    let code = (room.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? room).trimmingCharacters(in: .whitespaces)
    return code.isEmpty ? room.trimmingCharacters(in: .whitespaces) : code
}

/// a day in a strip: weekday, date, a dot per paper or class
struct DayPill: View {
    let day: Day
    let count: Int
    let background: Color
    let foreground: Color
    var dim = false
    var today = false
    var selected = false
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 4) {
            Text(String(day.format("EEEEE"))).font(.caption.weight(.semibold))
            Text("\(day.day)").font(.number(20, weight: .semibold))
            HStack(spacing: 3) {
                ForEach(0..<min(count, 3), id: \.self) { _ in Circle().frame(width: 5, height: 5) }
            }
            .frame(height: 6)
        }
        .foregroundStyle(dim ? foreground.opacity(0.6) : foreground)
        .frame(width: 48, height: 72)
        .background(background, in: Capsule())
        .overlay(Capsule().stroke(selected ? p.primary : today ? p.primary.opacity(0.7) : .clear, lineWidth: selected ? 2.5 : 1.5))
    }
}

// the run strip: every day from the first paper to the last, free days left visible
private struct RunStrip: View {
    let plan: ExamPlan
    let papers: [Paper]
    let open: (Day) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        let first = plan.run.first!, last = plan.run.last!
        // a week out, today joins the strip so the prep days before the first paper show too
        let from = plan.today < first && plan.today.days(until: first) <= 7 ? plan.today : first
        let span = (0...max(0, from.days(until: last))).map { from.plus(days: $0) }
        let running = Set(plan.days.flatMap { $0.papers.map(\.event.id) })
        let byDay = Dictionary(grouping: papers.filter { running.contains($0.event.id) }, by: \.day)
        let nextDay = plan.next?.day
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(span, id: \.self) { d in
                        let list = byDay[d] ?? []
                        let exam = !list.isEmpty
                        let done = exam && list.allSatisfy { plan.status($0) == .done }
                        let (bg, fg): (Color, Color) = d == nextDay ? (p.tertiaryContainer, p.onTertiaryContainer)
                            : exam && !done ? (p.secondaryContainer, p.onSecondaryContainer)
                            : exam ? (p.containerHigh, p.onSurfaceVariant) : (.clear, p.onSurfaceVariant)
                        Button { if exam { open(d) } } label: {
                            DayPill(day: d, count: list.count, background: bg, foreground: fg, dim: !(exam && !done), today: d == plan.today)
                        }
                        .buttonStyle(.plain)
                        .id(d)
                        .accessibilityLabel([d.format("EEEE, d MMMM"), d == plan.today ? "today" : nil,
                                             !exam ? "free day" : done ? "done" : plural(list.count, "exam")].compactMap { $0 }.joined(separator: ", "))
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear {
                // land with the day before today in view, so the strip never opens cut against its edge
                if let i = span.firstIndex(where: { $0 >= plan.today }), i > 1 { proxy.scrollTo(span[i - 1], anchor: .leading) }
            }
        }
        .padding(.top, 8)
    }
}

private struct Gap: View {
    let free: Int
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(p.outlineVariant).frame(height: 1)
            Image(systemName: "bed.double").font(.caption)
            Text(free == 1 ? "1 day free" : "\(free) days free").font(.caption.weight(.semibold)).fixedSize()
            Rectangle().fill(p.outlineVariant).frame(height: 1)
        }
        .foregroundStyle(p.onSurfaceVariant)
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
    }
}

private struct DayHeader: View {
    let day: Day?
    let today: Day
    @Environment(\.palette) private var p

    var body: some View {
        HStack {
            Text(day?.format("EEEE, d MMMM") ?? "Date not out yet").font(.subheadline.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
            Spacer()
            if let day { Text(relativeDay(day, today)).font(.subheadline.weight(.semibold)).foregroundStyle(p.primary) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// the rail through a day: a line joining the rows, a dot per paper, thick and green across the next one
struct Rail: View {
    let accent: Bool
    let up: Bool
    let down: Bool
    var dot: CGFloat = 0.5
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { g in
            let x = g.size.width / 2
            let y = g.size.height * dot
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: x, y: up ? 0 : y))
                    path.addLine(to: CGPoint(x: x, y: down ? g.size.height : y))
                }
                .stroke(p.outlineVariant, lineWidth: 2)
                if accent {
                    Path { path in
                        path.move(to: CGPoint(x: x, y: y))
                        path.addLine(to: CGPoint(x: x, y: min(g.size.height - 8, y + 44)))
                    }
                    .stroke(p.tertiary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                }
                Circle()
                    .fill(accent ? p.tertiary : p.outlineVariant)
                    .frame(width: accent ? 16 : 11, height: accent ? 16 : 11)
                    .position(x: x, y: y)
            }
        }
        .frame(width: 24)
    }
}

private struct PaperRow: View {
    let paper: Paper
    let plan: ExamPlan
    let fresh: Bool
    let up: Bool
    let down: Bool
    let open: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        let done = plan.status(paper) == .done
        let next = paper.key == plan.next?.key
        let s = paper.slot
        let clash = plan.clashes[paper.key]
        Button(action: open) {
            HStack(alignment: .center, spacing: 10) {
                timeBlock(done: done).frame(width: 66, alignment: .trailing).padding(.vertical, 14)
                Rail(accent: next, up: up, down: down, dot: 0.32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.subjectName.titleCase).font(.headline).lineLimit(2).minimumScaleFactor(0.85).foregroundStyle(p.onSurface)
                    let meta = [done ? s.start?.format() : nil, paper.duration.map(minutesText)].compactMap { $0 }.joined(separator: " · ")
                    if !meta.isEmpty { Text(meta).font(.subheadline).foregroundStyle(p.onSurfaceVariant) }
                    if let clash, !done {
                        Label("Clashes with \(clash.slot.subjectName.titleCase)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(p.error).padding(.top, 2)
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !done { seatBadge(lifted: next).frame(maxWidth: 92) }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .opacity(done ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .groupRow(next ? p.containerHighest : p.containerLow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speak(next: next, clash: clash))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func timeBlock(done: Bool) -> some View {
        let s = paper.slot
        if done {
            VStack(alignment: .trailing, spacing: 0) {
                Text(s.day.map { "\($0.day)" } ?? "?").font(.number(24)).foregroundStyle(p.primary)
                Text(s.day?.format("MMM").uppercased() ?? "").font(.caption2.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
            }
        } else if let start = s.start {
            VStack(alignment: .trailing, spacing: 0) {
                (Text(start.format(ampm: false)).font(.number(22)) + Text(" " + start.ampm).font(.caption2.weight(.bold)))
                    .foregroundStyle(p.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let end = s.end { Text("to \(end.format(ampm: false))").font(.caption.weight(.semibold)).foregroundStyle(p.onSurfaceVariant) }
            }
        } else if !s.from.isBlank {
            Text(s.from.trimmingCharacters(in: .whitespaces)).font(.caption.weight(.semibold)).foregroundStyle(p.primary).lineLimit(2)
        } else {
            Text("TBA").font(.number(20)).foregroundStyle(p.onSurfaceVariant)
        }
    }

    @ViewBuilder private func seatBadge(lifted: Bool) -> some View {
        let s = paper.slot
        if s.seated {
            VStack(spacing: 0) {
                Text(badgeRoom(s.room).ifBlank("Room ?")).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                if !s.seat.isBlank { Text("seat \(s.seat)").font(.caption2.weight(.medium)).lineLimit(1) }
                if fresh { Text("just in").font(.caption2.weight(.bold)).foregroundStyle(p.tertiary) }
            }
            .foregroundStyle(p.onSurface)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(lifted ? p.surface : p.containerHighest, in: Capsule())
        } else {
            Text("seat soon")
                .font(.caption2.weight(.medium))
                .foregroundStyle(p.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .overlay(Capsule().stroke(p.onSurfaceVariant.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }

    /// one sentence for voiceover, what a sighted glance at the row gets
    private func speak(next: Bool, clash: Paper?) -> String {
        let s = paper.slot
        return [
            s.subjectName.titleCase, paper.event.short, paper.day?.format("EEEE, d MMMM"), examWindow(paper)?.replacingOccurrences(of: " – ", with: " to "),
            s.seated ? [s.room.isBlank ? nil : "room \(s.room)", s.seat.isBlank ? nil : "seat \(s.seat)"].compactMap { $0 }.joined(separator: ", ")
                : plan.status(paper) != .done ? "room and seat not out yet" : nil,
            clash.map { "clashes with \($0.slot.subjectName.titleCase)" }, next ? "next up" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct PendingRow: View {
    let event: ExamEvent
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "calendar.badge.clock").font(.title3).foregroundStyle(p.onSurfaceVariant)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.short) date sheet").font(.headline)
                Text("Not out yet" + (event.fromDay.map { " · starts around \($0.format("EEE d MMM"))" } ?? ""))
                    .font(.subheadline).foregroundStyle(p.onSurfaceVariant)
            }
            Spacer()
        }
        .padding(16)
    }
}

/// a paper's details, or every paper on a day
private struct ExamSheet: View {
    let target: ExamTarget
    let papers: [Paper]
    let plan: ExamPlan
    let inCalendar: Set<String>
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let shown: [Paper] = {
            switch target {
            case .paper(let k): return papers.filter { $0.key == k }
            case .day(let d): return papers.filter { $0.day == d }.sorted { $0.sortKey < $1.sortKey }
            }
        }()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(shown) { PaperDetail(paper: $0, plan: plan, synced: inCalendar.contains($0.key)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .scrollContentBackground(.hidden)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(p.surface)
    }
}

private struct PaperDetail: View {
    let paper: Paper
    let plan: ExamPlan
    let synced: Bool
    @Environment(\.palette) private var p
    @State private var adding = false

    var body: some View {
        let s = paper.slot
        let status = plan.status(paper)
        VStack(alignment: .leading, spacing: 4) {
            Text([paper.event.short, paper.event.outOf.map { "out of \($0)" }, status == .done ? "done" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
            Text(s.subjectName.titleCase).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if !s.code.isBlank { Text(s.code).font(.caption).foregroundStyle(p.onSurfaceVariant) }
            VStack(alignment: .leading, spacing: 14) {
                Fact(icon: "calendar", text: paper.day?.format("EEEE, d MMMM") ?? "Date not out yet", sub: paper.day.map { relativeDay($0, plan.today) })
                Fact(icon: "clock", text: examWindow(paper) ?? "Time not out yet", sub: paper.duration.map(spokenLength))
                if s.seated {
                    Fact(icon: "door.left.hand.open", text: s.room.isBlank ? "Room not out yet" : "Room \(s.room)", sub: nil)
                    Fact(icon: "chair", text: s.seat.isBlank ? "Seat not out yet" : "Seat \(s.seat)", sub: nil)
                } else if status != .done {
                    Fact(icon: "chair", text: "Room and seat not out yet", sub: "They usually come out a day before. This page checks more often as the day gets close.")
                }
                if let c = plan.clashes[paper.key] {
                    Fact(icon: "exclamationmark.triangle", text: "Clashes with \(c.slot.subjectName.titleCase)", sub: examWindow(c), tint: p.error)
                }
            }
            .padding(.top, 16)
            HStack(spacing: 12) {
                if status != .done {
                    Button {
                        adding = true
                    } label: {
                        Label(synced ? "In your calendar" : "Add to calendar", systemImage: synced ? "checkmark" : "calendar.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(synced)
                }
                if let sem = paper.event.semesterId.isEmpty ? nil : paper.event.semesterId, !s.code.isBlank {
                    NavigationLink(value: Route.subject(semesterCode: semesterCode(sem), subjectCode: s.code)) { Text("Subject") }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 20)
        }
        .sheet(isPresented: $adding) { EventEditor(paper: paper).ignoresSafeArea() }
    }

    @Environment(AppGraph.self) private var graph

    /// the subject page wants the semester's code, the exam event only has its id
    private func semesterCode(_ id: String) -> String {
        let repo = graph.repo!
        let all = (repo.examSemesters.state.data ?? []) + (repo.attendanceMeta.state.data?.semesters ?? [])
        return all.first { $0.id == id }?.code ?? id
    }

    private func spokenLength(_ m: Int) -> String {
        if m < 60 { return "\(m) minutes" }
        if m == 60 { return "1 hour" }
        if m % 60 == 0 { return "\(m / 60) hours" }
        return "\(minutesText(m)) long"
    }
}

struct Fact: View {
    let icon: String
    let text: String
    let sub: String?
    var tint: Color?
    @Environment(\.palette) private var p

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.body).foregroundStyle(tint ?? p.onSurfaceVariant).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.body)
                if let sub { Text(sub).font(.caption).foregroundStyle(p.onSurfaceVariant) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// the system's own new-event sheet, filled in with the paper. needs no calendar permission
struct EventEditor: UIViewControllerRepresentable {
    let paper: Paper
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let vc = EKEventEditViewController()
        vc.eventStore = store
        let e = EKEvent(eventStore: store)
        let s = paper.slot
        let begin = paper.start ?? paper.day?.start() ?? Date()
        let room = [s.room.isBlank ? nil : s.room, s.seat.isBlank ? nil : "seat \(s.seat)"].compactMap { $0 }.joined(separator: ", ")
        e.title = "\(paper.event.short): \(s.subjectName.titleCase)"
        e.startDate = begin
        e.endDate = paper.over ?? begin.addingTimeInterval(3 * 3600)
        e.isAllDay = paper.start == nil
        e.location = room.isEmpty ? nil : room
        e.notes = s.code + (room.isEmpty ? ". Room and seat come out about a day before." : "")
        vc.event = e
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: () -> Void
        init(_ done: @escaping () -> Void) { self.done = done }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { done() }
    }
}

/// the current exam semester's date sheet, from the planner's exam banner
struct ExamsScreen: View {
    @State private var picked: String?
    @Environment(AppGraph.self) private var graph

    var body: some View {
        Screen("Exams", refresh: { await ExamsContent.refresh(graph, code: picked, force: true) }) {
            ExamsContent(picked: $picked)
        }
    }
}
