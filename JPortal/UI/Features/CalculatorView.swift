import SwiftUI

/// one course in the calculator, registered on the portal or added by hand
struct CalcCourse: Identifiable {
    let id: String
    let name: String
    let code: String
    let credits: Double
    let added: Bool
    /// the grade card's grade, for a semester that has one
    let actual: String?

    /// the semester's courses that count: audit and zero credit ones never do
    static func list(_ sem: SemesterInfo, _ state: CalculatorState) -> [CalcCourse] {
        sem.subjects.filter { !$0.audit && $0.credits > 0 }
            .map { CalcCourse(id: $0.code, name: $0.name.titleCase, code: $0.code, credits: $0.credits, added: false, actual: $0.grade) }
            + (state.added[sem.code] ?? []).map { CalcCourse(id: $0.id, name: $0.name, code: "", credits: $0.credits, added: true, actual: nil) }
    }

    /// what's picked, or the grade card's grade when nothing is
    func grade(in sem: String, _ state: CalculatorState) -> String? {
        if let picked = state.grades[sem]?[id] { return picked.isEmpty ? nil : picked }
        return actual.flatMap { GradeScale.points($0) != nil ? $0 : nil }
    }

    func fromCard(in sem: String, _ state: CalculatorState) -> Bool {
        state.grades[sem]?[id] == nil && actual.flatMap(GradeScale.points) != nil
    }

    /// a semester's sgpa as the calculator has it
    static func sgpa(_ sem: SemesterInfo, _ state: CalculatorState) -> SgpaResult {
        let left = Set(state.leftOut[sem.code] ?? [])
        return GradeCalc.sgpa(list(sem, state).filter { !left.contains($0.id) }.map { ($0.credits, $0.grade(in: sem.code, state)) })
    }
}

private func label(_ s: SemesterInfo) -> String {
    [s.number.map { "Semester \($0)" }, prettySemester(s.code)].compactMap { $0 }.joined(separator: " · ")
}

private func two(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }

private func creditsText(_ c: Double) -> String { c == 1 ? "1 credit" : "\(fmt(c)) credits" }

/// an sgpa and cgpa calculator like the ones students pass around, filled in from the portal:
/// the semester's registered courses, and every finished semester's sgpa and credits
struct CalculatorContent: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var picked: String?
    @State private var adding = false
    @State private var showHow = false

    var body: some View {
        let data = graph.academics
        let gradeable = data.semesters.filter { !$0.subjects.isEmpty }
        if let sem = gradeable.first(where: { $0.code == picked }) ?? gradeable.first(where: \.current) ?? gradeable.first {
            content(data, gradeable, sem)
        } else if data.loading {
            CenteredLoading()
        } else {
            MessageState(frog: .sleep, title: "No subjects to grade yet")
        }
    }

    @ViewBuilder
    private func content(_ data: Academics, _ gradeable: [SemesterInfo], _ sem: SemesterInfo) -> some View {
        let state = graph.prefs.calculator
        let courses = CalcCourse.list(sem, state)
        let left = Set(state.leftOut[sem.code] ?? [])
        let res = CalcCourse.sgpa(sem, state)
        let results = (data.results.data ?? []).sorted { $0.semester < $1.semester }
        let earlier = results.filter { r in sem.number.map { r.semester < $0 } ?? true }
        let projected = res.complete && sem.result == nil ? GradeCalc.cgpa(earlier.map(GradeCalc.totals) + [(res.points, res.credits)]) : nil

        SectionHeader(text: "Your courses") { actions(sem, courses, state) }
        Menu {
            ForEach(gradeable) { s in
                Button { picked = s.code } label: {
                    if s.code == sem.code { Label(label(s) + (s.current ? "  ·  now" : ""), systemImage: "checkmark") }
                    else { Text(label(s) + (s.current ? "  ·  now" : "")) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(sem)).font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption.weight(.bold))
            }
            .foregroundStyle(p.onSurface)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(p.secondaryContainer, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .accessibilityLabel("Semester, \(label(sem))")

        if courses.isEmpty {
            MessageState(frog: .sleep, title: "No credited courses this semester")
        } else {
            CardGroup {
                ForEach(courses) { c in
                    CourseRow(
                        course: c, grade: c.grade(in: sem.code, state), fromCard: c.fromCard(in: sem.code, state), leftOut: left.contains(c.id),
                        // a clear only needs remembering when a grade card grade would otherwise come back
                        pick: { g in update { $0.grades[sem.code, default: [:]][c.id] = g ?? (c.actual != nil ? "" : nil) } },
                        toggle: {
                            update { s in
                                var l = Set(s.leftOut[sem.code] ?? [])
                                if l.contains(c.id) { l.remove(c.id) } else { l.insert(c.id) }
                                s.leftOut[sem.code] = Array(l)
                            }
                        },
                        remove: c.added ? { update { $0.added[sem.code]?.removeAll { $0.id == c.id } } } : nil
                    )
                    .groupRow(p.containerLow)
                }
            }
            Text("Long-press a course to leave it out of the SGPA.")
                .font(.caption).foregroundStyle(p.onSurfaceVariant)
                .padding(.horizontal, 20).padding(.top, 8)
        }

        SgpaCard(res: res, finished: sem.result, projected: projected, current: sem.result == nil)

        allSemesters(data, results, state)

        DisclosureGroup(isExpanded: $showHow) {
            HowItWorks().padding(.top, 10)
        } label: {
            Text("How it's worked out").font(.headline).foregroundStyle(p.onSurface)
        }
        .card(p.containerLow)
        .gutter()
        .padding(.top, 20)
        .sheet(isPresented: $adding) {
            AddCourseSheet { name, credits in
                update { $0.added[sem.code, default: []].append(AddedCourse(id: UUID().uuidString, name: name, credits: credits)) }
            }
        }
    }

    private func update(_ change: (inout CalculatorState) -> Void) {
        var s = graph.prefs.calculator
        change(&s)
        graph.prefs.calculator = s
    }

    private func actions(_ sem: SemesterInfo, _ courses: [CalcCourse], _ state: CalculatorState) -> some View {
        Menu {
            Menu("Set every grade to") {
                ForEach(GradeScale.grades, id: \.letter) { g in
                    Button(g.letter) { update { s in for c in courses { s.grades[sem.code, default: [:]][c.id] = g.letter } } }
                }
            }
            if courses.contains(where: { $0.actual != nil }) {
                Button("Use grade card grades", systemImage: "doc.text") { update { $0.grades[sem.code] = nil } }
            }
            Button("Clear grades", systemImage: "eraser") {
                update { s in for c in courses { s.grades[sem.code, default: [:]][c.id] = c.actual != nil ? "" : nil } }
            }
            Divider()
            Button("Add a course", systemImage: "plus") { adding = true }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3)
        }
        .accessibilityLabel("Calculator options")
    }

    // MARK: the big picture: every semester's sgpa, this one's from above, and what-ifs after it

    @ViewBuilder
    private func allSemesters(_ data: Academics, _ results: [SemesterResult], _ state: CalculatorState) -> some View {
        let current = data.semesters.first(where: \.current)
        let open = current.flatMap { $0.result == nil ? $0 : nil }
        let openRes = open.map { CalcCourse.sgpa($0, state) }
        let lastNumber = max(results.map(\.semester).max() ?? 0, open?.number ?? 0)
        let maxSem = max(courseLength(graph.repo.program.state.data), lastNumber)
        var parts = results.map(GradeCalc.totals)
        let _ = { if let r = openRes, r.complete { parts.append((r.points, r.credits)) } }()
        let _ = { for plan in state.plans { parts.append((plan.sgpa * plan.credits, plan.credits)) } }()
        let cgpa = GradeCalc.cgpa(parts)
        let credits = parts.reduce(0) { $0 + $1.credits }
        let whatIf = !state.plans.isEmpty || (openRes?.complete ?? false)

        SectionHeader(text: "All semesters") {
            if lastNumber + state.plans.count < maxSem {
                Button {
                    let base = openRes.flatMap { $0.complete ? $0 : nil }
                    let sgpa = ((base?.sgpa ?? results.last?.sgpa ?? 8) * 10).rounded() / 10
                    let cr = base?.credits ?? results.last.map { GradeCalc.totals($0).credits } ?? 22
                    update { $0.plans.append(PlannedSemester(id: UUID().uuidString, sgpa: min(10, sgpa), credits: cr)) }
                } label: {
                    Label("Add semester", systemImage: "plus").font(.subheadline.weight(.semibold))
                }
            }
        }
        CardGroup {
            ForEach(results, id: \.semester) { r in
                let code = data.semesters.first { $0.number == r.semester }?.code
                SemesterLine(title: "Semester \(r.semester)", subtitle: code.map(prettySemester) ?? "From the portal",
                             sgpa: r.sgpa, credits: GradeCalc.totals(r).credits)
                    .groupRow(p.containerLow)
            }
            if let open, let res = openRes {
                SemesterLine(title: open.number.map { "Semester \($0)" } ?? prettySemester(open.code),
                             subtitle: prettySemester(open.code) + (res.complete ? " · from your grades above" : " · grade every course above"),
                             sgpa: res.complete ? res.sgpa : nil, credits: res.complete ? res.credits : nil, now: true)
                    .groupRow(p.containerLow)
            }
            ForEach(Array(state.plans.enumerated()), id: \.element.id) { i, plan in
                PlanRow(number: lastNumber + i + 1, plan: plan,
                        sgpa: Binding(get: { plan.sgpa }, set: { v in update { s in if let j = s.plans.firstIndex(where: { $0.id == plan.id }) { s.plans[j].sgpa = (v * 10).rounded() / 10 } } }),
                        credits: Binding(get: { plan.credits }, set: { v in update { s in if let j = s.plans.firstIndex(where: { $0.id == plan.id }) { s.plans[j].credits = v } } }),
                        remove: { update { $0.plans.removeAll { $0.id == plan.id } } })
                    .groupRow(p.containerLow)
            }
        }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(whatIf ? "CGPA with these" : "CGPA").font(.subheadline.weight(.semibold))
                Text(two(cgpa)).font(.number(48)).foregroundStyle(p.cgpa).contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("Credits counted").font(.subheadline.weight(.semibold))
                Text(fmt(credits)).font(.number(32))
            }
        }
        .foregroundStyle(p.onPrimaryContainer)
        .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
        .gutter()
        .padding(.top, 10)
        .animation(.snappy, value: cgpa)
    }
}

private struct CourseRow: View {
    let course: CalcCourse
    let grade: String?
    let fromCard: Bool
    let leftOut: Bool
    let pick: (String?) -> Void
    let toggle: () -> Void
    let remove: (() -> Void)?
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name).font(.headline).lineLimit(2).foregroundStyle(p.onSurface)
                Text([course.added ? "added by you" : course.code, creditsText(course.credits), leftOut ? "left out" : fromCard ? "from grade card" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(p.onSurfaceVariant)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(GradeScale.grades, id: \.letter) { g in
                    Button { pick(g.letter) } label: {
                        if g.letter == grade { Label("\(g.letter)  ·  \(Int(g.points)) points", systemImage: "checkmark") }
                        else { Text("\(g.letter)  ·  \(Int(g.points)) points") }
                    }
                }
                if grade != nil {
                    Divider()
                    Button("No grade", role: .destructive) { pick(nil) }
                }
            } label: {
                GradeLetter(grade: grade ?? "", size: 44)
                    .overlay(alignment: .bottomTrailing) {
                        if grade == nil {
                            Image(systemName: "chevron.down.circle.fill").font(.caption).foregroundStyle(p.primary).background(p.containerLow, in: Circle()).offset(x: 4, y: 4)
                        }
                    }
            }
            .disabled(leftOut)
            .sensoryFeedback(.selection, trigger: grade)
            .accessibilityLabel("Grade for \(course.name)")
            .accessibilityValue(grade ?? "none")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .opacity(leftOut ? 0.5 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button(leftOut ? "Count it" : "Leave it out", systemImage: leftOut ? "plus.circle" : "minus.circle", action: toggle)
            if let remove { Button("Remove course", systemImage: "trash", role: .destructive, action: remove) }
        }
    }
}

private struct SgpaCard: View {
    let res: SgpaResult
    let finished: SemesterResult?
    let projected: Double?
    let current: Bool
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(res.graded > 0 && !res.complete ? "Partial SGPA" : "SGPA").font(.subheadline.weight(.semibold))
                    Text(two(res.sgpa)).font(.number(48)).foregroundStyle(p.sgpa).contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    if let finished {
                        Text("Portal's SGPA").font(.subheadline.weight(.semibold))
                        Text(two(finished.sgpa)).font(.number(32))
                    } else {
                        Text("Projected CGPA").font(.subheadline.weight(.semibold))
                        Text(two(projected)).font(.number(32)).foregroundStyle(p.cgpa).contentTransition(.numericText())
                    }
                }
            }
            Text(caption).font(.subheadline)
        }
        .foregroundStyle(p.onPrimaryContainer)
        .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
        .gutter()
        .padding(.top, 12)
        .animation(.snappy, value: res)
    }

    private var caption: String {
        if res.total == 0 { return "Nothing here counts towards the SGPA." }
        if res.graded == 0 { return "Pick a grade for each course to get started." }
        if !res.complete {
            return "\(res.graded) of \(res.total) courses graded" + (current ? ". The CGPA needs every grade." : ".")
        }
        return "All \(res.total) courses graded · \(fmt(res.credits)) credits"
    }
}

private struct SemesterLine: View {
    let title: String
    let subtitle: String
    let sgpa: Double?
    let credits: Double?
    var now = false
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if now {
                        Text("Now").font(.caption.weight(.semibold)).foregroundStyle(p.onTertiaryContainer)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(p.tertiaryContainer, in: Capsule())
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(p.onSurfaceVariant)
            }
            Spacer()
            Figure(value: two(sgpa), label: "SGPA", color: p.sgpa)
            Figure(value: credits.map(fmt) ?? "—", label: "credits", color: p.cgpa).frame(minWidth: 44)
        }
        .foregroundStyle(p.onSurface)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct PlanRow: View {
    let number: Int
    let plan: PlannedSemester
    @Binding var sgpa: Double
    @Binding var credits: Double
    let remove: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Semester \(number)").font(.headline)
                Text("what-if").font(.caption.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
                    .padding(.horizontal, 8).padding(.vertical, 2).overlay(Capsule().stroke(p.outlineVariant))
                Spacer()
                Text(String(format: "%.1f", sgpa)).font(.number(24)).foregroundStyle(p.sgpa).contentTransition(.numericText())
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(p.error)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove semester \(number)")
            }
            Slider(value: $sgpa, in: 0...10, step: 0.1)
                .accessibilityLabel("SGPA for semester \(number)")
                .accessibilityValue(String(format: "%.1f", sgpa))
                .sensoryFeedback(.selection, trigger: Int((sgpa * 2).rounded()))
            Stepper(value: $credits, in: 1...40, step: 0.5) {
                Text(creditsText(credits)).font(.subheadline)
            }
        }
        .foregroundStyle(p.onSurface)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct HowItWorks: View {
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            formula("SGPA", "Σ (credits × grade points) ÷ Σ credits", p.sgpa)
            formula("CGPA", "Σ (semester credits × SGPA) ÷ Σ credits", p.cgpa)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(GradeScale.grades, id: \.letter) { g in
                    HStack(spacing: 4) {
                        Text(g.letter).font(.subheadline.weight(.bold)).foregroundStyle(p.grade(g.letter))
                        Text("\(Int(g.points))").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(p.containerHigh, in: Capsule())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                note("Courses and credits come from your registration on the portal. Audit courses don't count.")
                note("Finished semesters use the portal's exact grade points, so the CGPA here lands on your official one.")
                note("An F counts as 0 and its credits still count.")
                note("Without every grade you get a partial SGPA, and no CGPA projection.")
                note("Your picks are saved on this phone.")
            }
        }
        .foregroundStyle(p.onSurface)
    }

    private func formula(_ name: String, _ text: String, _ c: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.subheadline.weight(.bold)).foregroundStyle(c)
            Text("= " + text).font(.subheadline.monospaced())
        }
    }

    private func note(_ text: String) -> some View {
        Label { Text(text).font(.caption) } icon: { Image(systemName: "circle.fill").font(.system(size: 4)) }
            .foregroundStyle(p.onSurfaceVariant)
    }
}

private struct AddCourseSheet: View {
    let save: (String, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var credits = 3.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Course name", text: $name)
                Stepper(creditsText(credits), value: $credits, in: 0.5...20, step: 0.5)
                Section {} footer: { Text("Use the course's registered credits. Audit courses don't count towards the SGPA.") }
            }
            .navigationTitle("Add a course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        save(name.trimmingCharacters(in: .whitespaces), credits)
                        dismiss()
                    }
                    .disabled(name.isBlank)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
