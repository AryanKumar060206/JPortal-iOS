import Observation
import SwiftUI

struct FeedbackForm: Identifiable, Hashable {
    let event: FeedbackEvent
    let row: FeedbackRow
    var id: String { "\(event.id)/\(row.key)" }
}

enum Sending: Equatable {
    case busy, sent
    case failed(String)
}

/// every open form with the rating it'll get: one for everyone, overridable per row
@MainActor
@Observable
final class FeedbackSession {
    let forms: [FeedbackForm]
    var everyone: Rating = .VERY_GOOD
    var custom: [String: Rating] = [:]
    var status: [String: Sending] = [:]
    var busy = false

    init(forms: [FeedbackForm]) { self.forms = forms }

    func rating(_ f: FeedbackForm) -> Rating { custom[f.id] ?? everyone }
    var left: [FeedbackForm] { forms.filter { status[$0.id] != .sent } }
    var sent: Int { forms.count - left.count }
    var failed: Bool { forms.contains { if case .failed = status[$0.id] { return true } else { return false } } }

    /// one at a time, the portal's write endpoint isn't one to hammer
    func submit(_ send: (FeedbackForm, Rating) async throws -> Void) async {
        busy = true
        for f in left {
            status[f.id] = .busy
            do {
                try await send(f, rating(f))
                status[f.id] = .sent
            } catch {
                DebugLog.record("feedback", error)
                status[f.id] = .failed(describe(error))
            }
        }
        busy = false
    }
}

struct FeedbackScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var session: FeedbackSession?
    @State private var gridError: Error?
    @State private var attempt = 0
    @State private var review = false

    var body: some View {
        let repo = graph.repo!
        let events = repo.feedback.state
        Screen("Feedback", subtitle: session.map { s in
            var seen = Set<String>()
            return s.forms.map(\.event).filter { seen.insert($0.id).inserted }.map { $0.description.ifBlank($0.code) }.joined(separator: " · ")
        }, refresh: {
            await repo.feedback.refresh(force: true).value
            attempt += 1
        }) {
            StaleNotice(res: events) { repo.feedback.refresh(force: true) }
            if let session {
                FormList(session: session)
            } else {
                ResourceGate(res: events, retry: { repo.feedback.refresh(force: true) }) { list in
                    if list.isEmpty {
                        MessageState(frog: .sleep, title: "No feedback window open")
                    } else if let gridError {
                        MessageState(frog: .plunger, title: describe(gridError), message: "Pull down or tap retry.", action: "Retry") { attempt += 1 }
                    } else {
                        CenteredLoading()
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            if let s = session, !s.left.isEmpty {
                Button { if s.failed { Task { await send(s) } } else { review = true } } label: {
                    Text(s.busy ? "Sending \(min(s.sent + 1, s.forms.count)) of \(s.forms.count)"
                         : s.failed ? "Retry the \(s.left.count) left" : "Review \(plural(s.left.count, "form"))")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(s.busy)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(p.surface.opacity(0.95))
            }
        }
        .sheet(isPresented: $review) {
            if let s = session { Review(session: s) { review = false; Task { await send(s) } } }
        }
        .task { repo.feedback.refresh() }
        .task(id: "\((events.data ?? []).map(\.id).joined(separator: ","))|\(attempt)") { await loadGrid(events.data) }
    }

    private func loadGrid(_ events: [FeedbackEvent]?) async {
        guard let events, !events.isEmpty else { return }
        gridError = nil
        do {
            let forms: [FeedbackForm]
            if graph.demo {
                forms = events.flatMap { e in Demo.feedbackRows().map { FeedbackForm(event: e, row: $0) } }
            } else {
                forms = try await graph.sessions.call { p in
                    var out: [FeedbackForm] = []
                    for e in events { out += try await p.feedbackGrid(e).map { FeedbackForm(event: e, row: $0) } }
                    return out
                }
            }
            if session?.forms.map(\.id) != forms.map(\.id) { session = FeedbackSession(forms: forms) }
        } catch {
            DebugLog.record("feedback", error)
            gridError = error
        }
    }

    private func send(_ s: FeedbackSession) async {
        let demo = graph.demo
        let sessions = graph.sessions
        await s.submit { f, r in
            if demo {
                try await Task.sleep(nanoseconds: 400_000_000)
            } else {
                _ = try await sessions.call { try await $0.submitFeedback(f.event, row: f.row, rating: r) }
            }
        }
        // once everything's in, the me tab's "open" count should catch up
        if s.left.isEmpty && !demo { graph.repo.feedback.refresh(force: true) }
    }
}

private struct FormList: View {
    @Bindable var session: FeedbackSession
    @Environment(\.palette) private var p

    var body: some View {
        if session.forms.isEmpty {
            MessageState(frog: .party, title: "Nothing left to fill")
        } else if session.left.isEmpty {
            MessageState(frog: .party, title: "Feedback sent", message: plural(session.forms.count, "form"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rate everyone").font(.subheadline.weight(.semibold))
                Text(session.everyone.label).font(.system(size: 30, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Slider(value: Binding(get: { Double(Rating.allCases.firstIndex(of: session.everyone) ?? 3) },
                                      set: { session.everyone = Rating.allCases[min(4, max(0, Int($0.rounded())))] }),
                       in: 0...4, step: 1)
                    .disabled(session.busy)
                    .sensoryFeedback(.selection, trigger: session.everyone)
                    .accessibilityValue(session.everyone.label)
                HStack {
                    Text(Rating.UNSATISFIED.label)
                    Spacer()
                    Text(Rating.EXCELLENT.label)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(p.onSurfaceVariant)
            }
            .foregroundStyle(p.onPrimaryContainer)
            .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
            .gutter()
            .padding(.vertical, 8)
            SectionHeader(plural(session.forms.count, "form"))
            CardGroup {
                ForEach(session.forms) { f in FormRow(session: session, form: f).groupRow(p.containerLow) }
            }
            .padding(.bottom, 16)
        }
    }
}

private struct FormRow: View {
    @Bindable var session: FeedbackSession
    let form: FeedbackForm
    @Environment(\.palette) private var p

    var body: some View {
        let st = session.status[form.id]
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(form.row.facultyName.nameCase).font(.headline).lineLimit(1)
                Text([form.row.subjectName.titleCase, componentName[form.row.component] ?? form.row.component].filter { !$0.isBlank }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(p.onSurfaceVariant).lineLimit(2)
                if case .failed(let why)? = st { Text(why).font(.caption).foregroundStyle(p.error) }
            }
            Spacer()
            switch st {
            case .busy?: ProgressView().frame(width: 48)
            case .sent?: Label("Sent", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(p.primary)
            case .failed?: Label("Failed", systemImage: "xmark.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(p.error)
            case nil:
                Menu {
                    ForEach(Rating.allCases.reversed(), id: \.self) { r in
                        Button { session.custom[form.id] = r } label: {
                            if session.rating(form) == r { Label(r.label, systemImage: "checkmark") } else { Text(r.label) }
                        }
                    }
                    Divider()
                    Button("Same as everyone") { session.custom.removeValue(forKey: form.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text(session.rating(form).label).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(session.custom[form.id] != nil ? p.onSecondaryContainer : p.onSurface)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(session.custom[form.id] != nil ? p.secondaryContainer : .clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(session.custom[form.id] != nil ? .clear : p.outlineVariant))
                }
                .disabled(session.busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// what's about to go, grouped by rating, before the only write this app ever makes
private struct Review: View {
    let session: FeedbackSession
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        let left = session.left
        let groups = Dictionary(grouping: left, by: session.rating).sorted { (Rating.allCases.firstIndex(of: $0.key) ?? 0) > (Rating.allCases.firstIndex(of: $1.key) ?? 0) }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Each teacher gets the rating shown for every question on their form. Comments stay empty.")
                        .font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                    ForEach(groups, id: \.key) { r, forms in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.label).font(.headline)
                                Spacer()
                                Text("\(forms.count)").font(.headline).foregroundStyle(p.primary)
                            }
                            Text(forms.map { $0.row.facultyName.nameCase + (componentName[$0.row.component].map { " (\($0))" } ?? "") }.joined(separator: ", "))
                                .font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                        }
                        .card(p.containerLow, radius: Radius.medium, padding: 14)
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Submit \(plural(left.count, "form"))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Submit") { onSubmit() }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(p.surface)
    }
}
