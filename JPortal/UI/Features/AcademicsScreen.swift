import Charts
import SwiftUI

enum AcademicsView: String, CaseIterable { case overview = "Overview", marks = "Marks", exams = "Exams", calculator = "Calculator" }

struct AcademicsScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var view: AcademicsView = .overview
    /// projected sgpa per semester, survives tab switches
    @State private var projections: [Int: Double] = [:]
    @State private var marksPick: String?
    @State private var examsPick: String?

    var body: some View {
        let repo = graph.repo!
        // marks and exams start on whatever semester the rest of the app is on
        let start = graph.semesterSelection.selected?.code
        Screen("Academics", refresh: { await refresh(force: true) }) {
            Picker("View", selection: $view) {
                ForEach(AcademicsView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .gutter()
            .padding(.bottom, 8)
            .sensoryFeedback(.selection, trigger: view)
        } content: {
            switch view {
            case .overview:
                OverviewContent(projections: $projections)
            case .marks:
                MarksContent(picked: Binding(get: { marksPick ?? start }, set: { marksPick = $0 }))
            case .exams:
                ExamsContent(picked: Binding(get: { examsPick ?? start }, set: { examsPick = $0 }))
            case .calculator:
                CalculatorContent()
            }
        }
        .task {
            await graph.refreshAcademics(force: false)
            repo.credits.refresh()
            repo.program.refresh()
        }
    }

    private func refresh(force: Bool) async {
        switch view {
        case .overview:
            async let a: Void = graph.refreshAcademics(force: force)
            async let b: Void = graph.repo.credits.refresh(force: force).value
            async let c: Void = graph.repo.program.refresh(force: force).value
            _ = await (a, b, c)
        case .marks: await MarksContent.refresh(graph, code: marksPick ?? graph.semesterSelection.selected?.code, force: force)
        case .exams: await ExamsContent.refresh(graph, code: examsPick ?? graph.semesterSelection.selected?.code, force: force)
        case .calculator: await graph.refreshAcademics(force: force)
        }
    }
}

// MARK: overview: the jportal grades page, headline numbers and the what-if chart

private struct OverviewContent: View {
    @Binding var projections: [Int: Double]
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        let repo = graph.repo!
        let data = graph.academics
        let results = data.results
        let credits = repo.credits.state.data
        StaleNotice(res: results) { Task { await graph.refreshAcademics(force: true) } }
        ResourceGate(res: results, retry: { Task { await graph.refreshAcademics(force: true) } }, empty: { $0.isEmpty },
                     emptyTitle: "No results yet, first semester?") { real in
            let maxSem = max(courseLength(repo.program.state.data), real.map(\.semester).max() ?? 0)
            let lastReal = real.map(\.semester).max() ?? 0
            // what-ifs only go on semesters whose credits the portal gives us, today that's the one you're in
            let known = data.whatIfCredits(credits, after: lastReal).filter { $0.key <= maxSem }
            let points = Gpa.points(real, projections: projections, credits: known, maxSemesters: maxSem)
            let future = known.keys.sorted()
            let hint: String? = !projections.isEmpty ? "Dashed lines are what-ifs, not results"
                : future.isEmpty ? nil
                : future.count == 1 ? "Tap S\(future[0]), then drag to see where your CGPA lands"
                : "Tap a future semester, then drag to see where your CGPA lands"
            let latest = real.max { $0.semester < $1.semester }
            Headline(cgpa: latest?.cgpa, sgpa: latest?.sgpa, projected: points.last.flatMap { $0.projected ? $0.cgpa : nil },
                     earned: credits?.earned, required: credits?.required)
            // the chart runs to the latest result, plus the semester you're in when it has a what-if slot
            let lastShown = max(lastReal, future.last ?? 0)
            VStack(alignment: .leading, spacing: 8) {
                GpaChart(points: points, future: future, maxSem: lastShown) { s, v in projections[s] = v }
                if let hint {
                    HStack {
                        Text(hint).font(.caption).foregroundStyle(p.onSurfaceVariant)
                        Spacer()
                        if !projections.isEmpty { Button("Reset") { withAnimation { projections = [:] } }.font(.subheadline.weight(.semibold)) }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .card(p.containerLow, radius: Radius.extraLarge, padding: 12)
            .gutter()
            .padding(.vertical, 8)
            // one row per semester opens its grade card
            let graded = data.semesters.filter { $0.result != nil }
            if !graded.isEmpty {
                SectionHeader("Semesters")
                CardGroup {
                    ForEach(graded) { s in
                        NavigationLink(value: Route.gradeCard(s.code)) { SemesterRowView(s: s) }
                            .buttonStyle(.plain)
                            .groupRow(p.containerLow)
                    }
                }
            }
        }
    }
}

private struct Headline: View {
    let cgpa: Double?
    let sgpa: Double?
    let projected: Double?
    let earned: Int?
    let required: Int?
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: projected == nil ? 28 : 20) {
                big("CGPA", cgpa, p.cgpa)
                big("SGPA", sgpa, p.sgpa)
                if let projected { big("Projected", projected, p.tertiary) }
            }
            .animation(.snappy, value: projected == nil)
            if let earned, let required, required > 0 {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    Text("\(earned)").font(.number(52)).foregroundStyle(p.cgpa)
                    Text(" / \(required) credits").font(.headline)
                }
                .padding(.top, 16)
                ProgressView(value: min(1, Double(earned) / Double(required)))
                    .tint(p.cgpa)
                    .scaleEffect(x: 1, y: 2.2, anchor: .center)
                    .padding(.top, 8)
                    .accessibilityLabel("\(earned) of \(required) credits")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func big(_ label: String, _ v: Double?, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
            Text(v.map { String(format: "%.2f", $0) } ?? "–")
                .font(.number(projected == nil ? 52 : 40))
                .foregroundStyle(c)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SemesterRowView: View {
    let s: SemesterInfo
    @Environment(\.palette) private var p

    var body: some View {
        if let r = s.result {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.number.map { "Semester \($0)" } ?? prettySemester(s.code)).font(.headline)
                    Text("\(prettySemester(s.code)) · \(fmt(r.earnedCredits)) credits").font(.caption).foregroundStyle(p.onSurfaceVariant)
                }
                Spacer()
                Figure(value: String(format: "%.1f", r.sgpa), label: "SGPA", color: p.sgpa)
                Figure(value: String(format: "%.2f", r.cgpa), label: "CGPA", color: p.cgpa)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(p.onSurfaceVariant)
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }
}

/// sgpa and cgpa over the semesters. tap or drag on a future semester with known credits to set a what-if sgpa
private struct GpaChart: View {
    let points: [GpaPoint]
    let future: [Int]
    let maxSem: Int
    let onProject: (Int, Double) -> Void
    @Environment(\.palette) private var p
    /// the future semester being dragged up and down
    @State private var dragging: Int?
    /// a drag that began on a real semester, it only reads values
    @State private var scrubbing = false
    /// the semester the marker sits on while a finger is down
    @State private var marked: Int?

    private struct Mark: Identifiable {
        let id: String
        let series: String
        let semester: Int
        let value: Double
    }

    var body: some View {
        let lastReal = points.last { !$0.projected } ?? points.first
        let firstProjected = points.firstIndex { $0.projected }
        // real lines, then what-if lines that start from the last real point so they join up
        var marks: [Mark] = []
        for (i, pt) in points.enumerated() {
            let real = firstProjected.map { i < $0 } ?? true
            if real {
                marks.append(Mark(id: "s\(i)", series: "SGPA", semester: pt.semester, value: pt.sgpa))
                marks.append(Mark(id: "c\(i)", series: "CGPA", semester: pt.semester, value: pt.cgpa))
            }
        }
        if let f = firstProjected {
            let from = f > 0 ? Array(points[(f - 1)...]) : Array(points[f...])
            for (j, pt) in from.enumerated() {
                marks.append(Mark(id: "ps\(j)", series: "SGPA what-if", semester: pt.semester, value: pt.sgpa))
                marks.append(Mark(id: "pc\(j)", series: "CGPA what-if", semester: pt.semester, value: pt.cgpa))
            }
        }
        let taken = Set(points.map(\.semester))
        let ghosts = future.filter { !taken.contains($0) }
        let low = max(0, min(5, floor((points.map { min($0.sgpa, $0.cgpa) }.min() ?? 5) - 0.5)))

        return Chart {
            ForEach(marks) { m in
                LineMark(x: .value("Semester", m.semester), y: .value("GPA", m.value), series: .value("Series", m.series))
                    .foregroundStyle(m.series.hasPrefix("SGPA") ? p.sgpa : p.cgpa)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, dash: m.series.hasSuffix("what-if") ? [5, 5] : []))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Semester", m.semester), y: .value("GPA", m.value))
                    .foregroundStyle(m.series.hasPrefix("SGPA") ? p.sgpa : p.cgpa)
                    .symbolSize(m.series.hasSuffix("what-if") && dragging == m.semester ? 140 : 50)
            }
            ForEach(ghosts, id: \.self) { s in
                PointMark(x: .value("Semester", s), y: .value("GPA", lastReal?.cgpa ?? 8))
                    .symbol { Circle().strokeBorder(p.onSurfaceVariant.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 14, height: 14) }
            }
            if let s = marked, let pt = points.first(where: { $0.semester == s }) {
                RuleMark(x: .value("Semester", s))
                    .foregroundStyle(p.onSurfaceVariant.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Semester", s), y: .value("GPA", pt.cgpa)).foregroundStyle(p.cgpa).symbolSize(170)
                PointMark(x: .value("Semester", s), y: .value("GPA", pt.sgpa)).foregroundStyle(p.sgpa).symbolSize(170)
                // the readout goes under both points when there's room, the space below 7 is nearly always empty
                let below = min(pt.sgpa, pt.cgpa) - low > 1.6
                PointMark(x: .value("Semester", s), y: .value("GPA", below ? min(pt.sgpa, pt.cgpa) : max(pt.sgpa, pt.cgpa)))
                    .symbolSize(0)
                    .annotation(position: below ? .bottom : .top, spacing: 12,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Readout(point: pt)
                    }
            }
        }
        .chartXScale(domain: 0.6...(Double(maxSem) + 0.4))
        .chartYScale(domain: low...10)
        // the semester labels are drawn in the overlay, right under each point
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: 1)) { v in
                AxisGridLine().foregroundStyle(p.outlineVariant.opacity(0.5))
                AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))").font(.caption.weight(.semibold)) } }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let frame = proxy.plotFrame {
                    let plot = geo[frame]
                    ForEach(1...max(1, maxSem), id: \.self) { s in
                        Text("S\(s)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(p.onSurfaceVariant)
                            .position(x: plot.minX + (proxy.position(forX: Double(s)) ?? 0), y: plot.maxY + 14)
                    }
                }
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard let frame = proxy.plotFrame, let xv = proxy.value(atX: g.location.x - geo[frame].origin.x, as: Double.self) else { return }
                            // the first touch decides: a future semester gets dragged up and down, anywhere else reads values
                            if dragging == nil && !scrubbing {
                                let s = Int(xv.rounded())
                                if future.contains(s) { dragging = s } else { scrubbing = true }
                            }
                            if let s = dragging {
                                if let v = proxy.value(atY: g.location.y - geo[frame].origin.y, as: Double.self) {
                                    onProject(s, (min(10, max(0, v)) * 10).rounded() / 10)
                                }
                                marked = s
                            } else {
                                // snap to the nearest semester that has a point
                                marked = points.min { abs(Double($0.semester) - xv) < abs(Double($1.semester) - xv) }?.semester
                            }
                        }
                        .onEnded { _ in
                            dragging = nil
                            scrubbing = false
                            marked = nil
                        })
            }
        }
        .sensoryFeedback(.selection, trigger: marked)
        .frame(height: 240)
        .padding(.top, 8)
        .padding(.bottom, 26)
        .accessibilityLabel("SGPA and CGPA by semester")
        .accessibilityValue(points.filter { !$0.projected }.map { "semester \($0.semester): SGPA \(String(format: "%.2f", $0.sgpa))" }.joined(separator: ", "))
    }

    /// the little card that follows the finger
    private struct Readout: View {
        let point: GpaPoint
        @Environment(\.palette) private var p

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(point.projected ? "Semester \(point.semester) · what-if" : "Semester \(point.semester)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(p.onSurfaceVariant)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    value("SGPA", point.sgpa, p.sgpa)
                    value("CGPA", point.cgpa, p.cgpa)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.outlineVariant))
            .shadow(color: .black.opacity(p.dark ? 0.4 : 0.12), radius: 8, y: 3)
        }

        private func value(_ label: String, _ v: Double, _ c: Color) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: "%.2f", v)).font(.number(20)).foregroundStyle(c)
                Text(label).font(.caption2.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
            }
        }
    }
}
