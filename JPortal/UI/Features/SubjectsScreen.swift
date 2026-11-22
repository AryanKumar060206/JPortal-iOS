import SwiftUI

enum SubjectFilter: String, CaseIterable { case current = "This semester", labs = "Labs", graded = "Graded" }

struct SubjectsScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var query = ""
    @State private var filters: Set<SubjectFilter> = []

    var body: some View {
        let data = graph.academics
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let groups = data.semesters.map { s in (s, s.subjects.filter { matches(s, $0, q) }) }.filter { !$0.1.isEmpty }
        Screen("Subjects", refresh: { await graph.refreshAcademics(force: true) }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SubjectFilter.allCases, id: \.self) { f in
                        Chip(label: f.rawValue, selected: filters.contains(f), check: true) {
                            if filters.contains(f) { filters.remove(f) } else { filters.insert(f) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)
        } content: {
            if groups.isEmpty && data.loading {
                CenteredLoading()
            } else if groups.isEmpty {
                MessageState(frog: .look, title: !q.isEmpty ? "Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”"
                             : !filters.isEmpty ? "Nothing matches these filters" : "No subjects yet")
            } else {
                if q.isEmpty && filters.isEmpty {
                    SectionHeader("Registration")
                    RegistrationRows()
                }
                ForEach(groups, id: \.0.code) { s, list in
                    HStack(spacing: 8) {
                        Text([s.number.map { "Semester \($0)" }, prettySemester(s.code)].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
                        if s.current {
                            Text("Now").font(.caption.weight(.semibold)).foregroundStyle(p.onTertiaryContainer)
                                .padding(.horizontal, 10).padding(.vertical, 3).background(p.tertiaryContainer, in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                    CardGroup {
                        ForEach(list) { sub in
                            NavigationLink(value: Route.subject(semesterCode: s.code, subjectCode: sub.code)) { SubjectRow(s: sub, q: q) }
                                .buttonStyle(.plain)
                                .groupRow(p.containerLow)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search subjects, teachers, codes")
        .task { await graph.refreshAcademics(force: false) }
    }

    private func matches(_ s: SemesterInfo, _ sub: SubjectInfo, _ q: String) -> Bool {
        (!filters.contains(.current) || s.current) &&
            (!filters.contains(.labs) || sub.lab) &&
            (!filters.contains(.graded) || sub.grade != nil) &&
            (q.isEmpty || sub.name.lowercased().contains(q) || sub.code.lowercased().contains(q) || sub.teachers.contains { $0.1.lowercased().contains(q) })
    }
}

/// bold and tinted where the query hit, so you can see why a row is here
private func hit(_ text: String, _ q: String, _ color: Color) -> AttributedString {
    var a = AttributedString(text)
    guard !q.isEmpty else { return a }
    var search = a.startIndex..<a.endIndex
    while let r = a[search].range(of: q, options: .caseInsensitive) {
        a[r].foregroundColor = color
        a[r].font = .body.bold()
        search = r.upperBound..<a.endIndex
    }
    return a
}

private struct SubjectRow: View {
    let s: SubjectInfo
    let q: String
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit(s.name.titleCase, q, p.primary)).font(.headline).lineLimit(2).foregroundStyle(p.onSurface)
                Text(hit(s.code + (s.audit ? " · audit" : ""), q, p.primary)).font(.caption.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
                ForEach(s.teachers, id: \.0) { k, name in
                    Text(hit("\(componentName[k] ?? k): \(name.nameCase)", q, p.primary)).font(.caption).foregroundStyle(p.onSurfaceVariant)
                }
            }
            Spacer()
            if let g = s.grade { GradeLetter(grade: g, size: 40) }
            Figure(value: fmt(s.credits), label: "credits", color: p.cgpa).frame(minWidth: 44)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// the semester list and the picked one's answer, for the registration pages
struct Picked<T> {
    let semesters: [Semester]
    let semester: Semester?
    let res: Resource<T>
}

@MainActor
private func picked<T: Codable & Sendable>(_ sems: Store<[Semester]>, _ code: String?, empty: T, _ of: (Semester) -> Store<T>) -> Picked<T> {
    let list = sems.state.data ?? []
    let sem = list.byCode(code) ?? list.first
    let res = sem.map { of($0).state } ?? (sems.state.data != nil ? Resource(data: empty, checked: true) : sems.state.map { _ in empty })
    return Picked(semesters: list, semester: sem, res: res)
}

private struct RegistrationRows: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        let repo = graph.repo!
        let choices = picked(repo.choiceSemesters, nil, empty: [SubjectChoice]()) { repo.choices($0) }
        let mooc = picked(repo.moocSemesters, nil, empty: MoocStatus()) { repo.mooc($0) }
        let electives = choices.res.data.map { Set($0.filter(\.isElective).map(\.basket)).count }
        let moocLine: String? = mooc.res.data.map { m in
            let approved = m.requests.filter(\.isApproved).count
            let waiting = m.requests.count - approved
            return [approved > 0 ? "\(approved) approved" : nil, waiting > 0 ? "\(waiting) in review" : nil, m.rejected.isEmpty ? nil : "\(m.rejected.count) rejected"]
                .compactMap { $0 }.joined(separator: " · ").ifBlank("No requests")
        }
        CardGroup {
            NavigationLink(value: Route.choices) {
                Entry(icon: "checklist", title: "Subject choices",
                      subtitle: choices.semester.map { s in [prettySemester(s.code), electives.flatMap { $0 > 0 ? plural($0, "elective") : nil }].compactMap { $0 }.joined(separator: " · ") })
            }
            .buttonStyle(.plain).groupRow(p.containerLow)
            NavigationLink(value: Route.mooc) {
                Entry(icon: "play.rectangle", title: "MOOC status", subtitle: mooc.semester.map { s in [prettySemester(s.code), moocLine].compactMap { $0 }.joined(separator: " · ") })
            }
            .buttonStyle(.plain).groupRow(p.containerLow)
        }
        .task {
            if let s = await repo.choiceSemesters.value().data?.first { repo.choices(s).refresh() }
            if let s = await repo.moocSemesters.value().data?.first { repo.mooc(s).refresh() }
        }
    }
}

struct ChoicesScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var code: String?

    var body: some View {
        let repo = graph.repo!
        let v = picked(repo.choiceSemesters, code, empty: [SubjectChoice]()) { repo.choices($0) }
        let f = DateFormatter()
        let _ = { f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "dd-MM-yyyy hh:mm a" }()
        let frozen = v.res.data?.lazy.compactMap { f.date(from: $0.frozenAt.trimmingCharacters(in: .whitespaces)) }.first
        Screen("Subject choices", subtitle: frozen.map { "Frozen on \(Day($0).format("d MMM yyyy"))" }, refresh: {
            await repo.choiceSemesters.refresh(force: true).value
            if let s = v.semester { await repo.choices(s).refresh(force: true).value }
        }) {
            SemesterRow(semesters: v.semesters, selected: v.semester, fetchedAt: v.res.fetchedAt) { code = $0 }
            StaleNotice(res: v.res) { if let s = v.semester { repo.choices(s).refresh(force: true) } }
            ResourceGate(res: v.res, retry: { if let s = v.semester { repo.choices(s).refresh(force: true) } }, empty: { $0.isEmpty },
                         emptyTitle: "No choices this semester") { list in
                let baskets = Dictionary(grouping: list, by: \.basket)
                let order = list.map(\.basket).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                ForEach(order, id: \.self) { code in
                    let items = baskets[code] ?? []
                    let ranked = items.contains { $0.isElective }
                    let rows = ranked ? items.sorted { $0.preference < $1.preference } : items
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((items.first?.basketName ?? code).titleCase).font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
                            if ranked {
                                Text("\(items.filter(\.isAllotted).count) of \(items.count) allotted").font(.caption).foregroundStyle(p.onSurfaceVariant)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
                    CardGroup {
                        ForEach(rows, id: \.code) { c in ChoiceRow(c: c, ranked: ranked).groupRow(p.containerLow) }
                    }
                }
            }
        }
        .task(id: v.semester?.id) {
            repo.choiceSemesters.refresh()
            if let s = v.semester { repo.choices(s).refresh() }
        }
    }
}

private struct ChoiceRow: View {
    let c: SubjectChoice
    let ranked: Bool
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 14) {
            if ranked {
                Text(c.preference > 0 ? ordinal(c.preference) : "–")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(c.isAllotted ? p.secondaryContainer : p.container, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name.titleCase).font(.headline).lineLimit(2)
                Text([c.code, c.isAudit ? "audit" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(p.onSurfaceVariant)
            }
            Spacer()
            if c.isAllotted && ranked { Image(systemName: "checkmark.circle.fill").foregroundStyle(p.primary).accessibilityLabel("Allotted") }
            Figure(value: fmt(c.credits), label: "credits", color: p.cgpa)
        }
        .opacity(ranked && !c.isAllotted ? 0.6 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct MoocScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var code: String?

    var body: some View {
        let repo = graph.repo!
        let v = picked(repo.moocSemesters, code, empty: MoocStatus()) { repo.mooc($0) }
        Screen("MOOC status", refresh: {
            await repo.moocSemesters.refresh(force: true).value
            if let s = v.semester { await repo.mooc(s).refresh(force: true).value }
        }) {
            SemesterRow(semesters: v.semesters, selected: v.semester, fetchedAt: v.res.fetchedAt) { code = $0 }
            StaleNotice(res: v.res) { if let s = v.semester { repo.mooc(s).refresh(force: true) } }
            ResourceGate(res: v.res, retry: { if let s = v.semester { repo.mooc(s).refresh(force: true) } },
                         empty: { $0.requests.isEmpty && $0.rejected.isEmpty }, emptyTitle: "No MOOC requests") { m in
                if m.dues > 0 {
                    Label("\(rupees(m.dues)) due", systemImage: "indianrupeesign.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.error)
                        .card(p.errorContainer.opacity(0.5), radius: Radius.medium, padding: 14)
                        .gutter().padding(.vertical, 4)
                }
                ForEach(m.requests, id: \.code) { MoocCard(r: $0, rejected: false) }
                ForEach(m.rejected, id: \.code) { MoocCard(r: $0, rejected: true) }
            }
        }
        .task(id: v.semester?.id) {
            repo.moocSemesters.refresh()
            if let s = v.semester { repo.mooc(s).refresh() }
        }
    }
}

private struct MoocCard: View {
    let r: MoocRequest
    let rejected: Bool
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name.titleCase).font(.headline)
                    Text(r.code).font(.caption.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
                }
                Spacer()
                if rejected { badge("xmark.circle.fill", "Rejected", p.error) }
                else if r.isApproved { badge("checkmark.circle.fill", "Approved", p.primary) }
                else { badge("clock.fill", "In review", p.tertiary) }
            }
            if let rep = r.replaces {
                Text("In place of \(rep.1.titleCase) · \(rep.0)").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
            }
            let stages = r.stages
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.offset) { i, st in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(st.done ? p.primary : p.outlineVariant).frame(width: 12, height: 12).padding(.top, 4)
                            if i < stages.count - 1 {
                                Rectangle().fill(stages[i + 1].done ? p.primary : p.outlineVariant).frame(width: 2).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.title).font(.subheadline.weight(.semibold))
                            let f = DateFormatter()
                            let _ = { f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d MMM yyyy, h:mm a" }()
                            let line = [st.at.map { f.string(from: $0) }, st.by?.nameCase].compactMap { $0 }.joined(separator: " · ")
                            Text(line.ifBlank(st.done ? "Done" : "Waiting")).font(.caption).foregroundStyle(p.onSurfaceVariant)
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .padding(.top, 4)
        }
        .card(p.containerLow)
        .gutter()
        .padding(.vertical, 5)
    }

    private func badge(_ icon: String, _ text: String, _ c: Color) -> some View {
        Label(text, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(c)
    }
}
