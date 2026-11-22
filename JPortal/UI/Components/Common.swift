import SwiftUI
import UIKit

// MARK: layout

extension View {
    /// a filled rounded surface, the cards every list is built from
    func card(_ color: Color, radius: CGFloat = Radius.large, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// the 16pt side gutter of every list
    func gutter() -> some View { padding(.horizontal, 16) }

    @ViewBuilder func `if`<V: View>(_ cond: Bool, _ transform: (Self) -> V) -> some View {
        if cond { transform(self) } else { self }
    }
}

/// every top level screen: large title, pull to refresh, a lazy column. an optional
/// pinned row stays under the bar while the rest scrolls
struct Screen<Content: View, Pinned: View>: View {
    let title: String
    var subtitle: String?
    var refresh: (() async -> Void)?
    let pinned: Pinned
    @ViewBuilder let content: () -> Content

    @Environment(\.palette) private var p

    init(_ title: String, subtitle: String? = nil, refresh: (() async -> Void)? = nil,
         @ViewBuilder pinned: () -> Pinned, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.refresh = refresh
        self.pinned = pinned()
        self.content = content
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(p.onSurfaceVariant)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
                Section {
                    content()
                } header: {
                    pinned.background(p.surface)
                }
            }
            .padding(.bottom, 24)
        }
        .background(p.surface.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .modifier(Refreshing(action: refresh))
    }
}

extension Screen where Pinned == EmptyView {
    init(_ title: String, subtitle: String? = nil, refresh: (() async -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, subtitle: subtitle, refresh: refresh, pinned: { EmptyView() }, content: content)
    }
}

private struct Refreshing: ViewModifier {
    let action: (() async -> Void)?
    func body(content: Content) -> some View {
        if let action { content.refreshable { await action() } } else { content }
    }
}

struct SectionHeader<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.palette) private var p

    var body: some View {
        HStack {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(p.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing()
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// rows that sit together on one card, separated by thin gaps
struct CardGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 2) { content() }
            .clipShape(RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .gutter()
    }
}

extension View {
    /// one row on a CardGroup
    func groupRow(_ color: Color) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).background(color)
    }
}

/// wrapping row of chips
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, s.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

// MARK: states

/// the frog's moods, one per kind of empty
enum Frog: String {
    case sleep = "FrogSleep", plunger = "FrogPlunger", party = "FrogParty", look = "FrogLook"
}

struct MessageState: View {
    let frog: Frog
    let title: String
    var message: String? = nil
    var action: String? = nil
    var onAction: (() -> Void)? = nil
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            Image(frog.rawValue)
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 128)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            if let action, let onAction {
                Button(action, action: onAction)
                    .buttonStyle(.bordered)
                    .tint(p.primary)
                    .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}

struct CenteredLoading: View {
    var body: some View {
        LoadingBlob().frame(maxWidth: .infinity).padding(.top, 96)
    }
}

/// thin strip above content when what you see is cached and the refresh failed
struct StaleNotice<T>: View {
    let res: Resource<T>
    let retry: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        if res.error != nil && res.data != nil {
            HStack(spacing: 12) {
                Image(systemName: isOffline(res.error) ? "wifi.slash" : (res.error as? PortalError).map { if case .untrusted = $0 { return "exclamationmark.triangle" } else { return "clock.arrow.circlepath" } } ?? "clock.arrow.circlepath")
                    .font(.footnote)
                Text("\(describe(res.error)) · updated \(ago(res.fetchedAt))")
                    .font(.footnote.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry", action: retry).font(.footnote.weight(.semibold))
            }
            .foregroundStyle(p.onSecondaryContainer)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .background(p.secondaryContainer, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .gutter()
            .padding(.vertical, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// the no-data-yet branches every screen shares. draws content only once there's something to draw
struct ResourceGate<T, Content: View>: View {
    let res: Resource<T>
    let retry: () -> Void
    var empty: (T) -> Bool = { _ in false }
    var emptyTitle = "Nothing here yet"
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        if let data = res.data {
            if empty(data) { MessageState(frog: .sleep, title: emptyTitle) } else { content(data) }
        } else if res.error == nil {
            if res.checked || res.refreshing { CenteredLoading() }
        } else {
            MessageState(frog: isOffline(res.error) ? .sleep : .plunger, title: describe(res.error),
                         message: "Pull down or tap retry.", action: "Retry", onAction: retry)
        }
    }
}

// MARK: little pieces

/// jportal's value-over-label column
struct Figure: View {
    let value: String
    let label: String
    let color: Color
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.number(21)).foregroundStyle(color)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
        }
        .accessibilityElement(children: .combine)
    }
}

/// the grade letter in its colour, sitting on a faint wash of the same colour
struct GradeLetter: View {
    let grade: String
    var size: CGFloat = 48
    @Environment(\.palette) private var p

    var body: some View {
        let c = p.grade(grade)
        Text(grade.isBlank ? "–" : grade)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(c)
            .frame(width: size, height: size)
            .background(c.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel("Grade \(grade.isBlank ? "not out" : grade)")
    }
}

/// one exam's marks: the event, then obtained over max in the marks band colour
struct ScoreChip: View {
    let score: EventScore
    let background: Color
    @Environment(\.palette) private var p

    var body: some View {
        let (main, sub, tint): (String, String, Color?) = {
            switch score.marks {
            case .value(let o, let m)?: return (fmt(o), "of \(fmt(m))", m > 0 ? p.marksInk(o / m) : nil)
            case .absent?: return ("A", "absent", p.error)
            default: return ("–", "", nil)
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            Text(shortExamName(score.event)).font(.caption.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(main).font(.number(24)).foregroundStyle(tint ?? p.onSurface)
                Text(sub).font(.caption.weight(.medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// a selectable chip, for filters and the planner's picker
struct Chip: View {
    let label: String
    let selected: Bool
    var check = false
    let action: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if check && selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? p.onSecondaryContainer : p.onSurface)
            .background(selected ? p.secondaryContainer : Color.clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(selected ? Color.clear : p.outlineVariant))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// a row that leads somewhere: tinted icon, title, optional subtitle, chevron
struct Entry: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    /// a subtitle with styled bits in it, used instead of subtitle when set
    var subtitleText: Text? = nil
    var alert = false
    var chevron = true
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(alert ? p.onTertiaryContainer : p.onSurfaceVariant)
                .frame(width: 44, height: 44)
                .background(alert ? p.tertiaryContainer : p.containerHighest, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(p.onSurface)
                if let line = subtitleText ?? subtitle.map({ Text($0) }) {
                    line.font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                }
            }
            Spacer(minLength: 0)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(p.onSurfaceVariant.opacity(0.6)) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// a label over a value, tap to copy
struct InfoRow<Trailing: View>: View {
    let label: String
    let value: String
    var copy: String?
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.palette) private var p
    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(copied ? "Copied" : label).font(.caption.weight(.medium)).foregroundStyle(copied ? p.primary : p.onSurfaceVariant)
                Text(value).font(.body).foregroundStyle(p.onSurface).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = copy ?? value
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        }
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to copy")
    }
}

extension InfoRow where Trailing == EmptyView {
    init(_ label: String, _ value: String, copy: String? = nil) {
        self.init(label: label, value: value, copy: copy, trailing: { EmptyView() })
    }
}

/// L, T and P, as little tags
struct ComponentTags: View {
    let subject: SubjectAttendance
    @Environment(\.palette) private var p

    var body: some View {
        let tags = [subject.lectureComponent.map { _ in "L" }, subject.tutorialComponent.map { _ in "T" }, subject.practicalComponent.map { _ in "P" }].compactMap { $0 }
        ForEach(tags, id: \.self) { k in
            Text(k)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(p.secondaryContainer, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityLabel(componentName[k] ?? k)
        }
    }
}

/// one mark per recent class, newest on the right: a dot for present, a cross for absent
struct RecentDots: View {
    let recent: [Bool]
    @Environment(\.palette) private var p

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            for (i, present) in recent.enumerated() {
                let x = CGFloat(i) * 11
                if present {
                    let r = h / 2 * 0.85
                    ctx.fill(Path(ellipseIn: CGRect(x: x + h / 2 - r, y: h / 2 - r, width: r * 2, height: r * 2)), with: .color(p.good))
                } else {
                    let m: CGFloat = 0.9
                    var path = Path()
                    path.move(to: CGPoint(x: x + m, y: m))
                    path.addLine(to: CGPoint(x: x + h - m, y: h - m))
                    path.move(to: CGPoint(x: x + h - m, y: m))
                    path.addLine(to: CGPoint(x: x + m, y: h - m))
                    ctx.stroke(path, with: .color(p.error), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
            }
        }
        .frame(width: CGFloat(max(recent.count, 1) * 11 - 3), height: 8)
        .accessibilityLabel("last \(recent.count) classes: \(recent.filter { $0 }.count) present, \(recent.filter { !$0 }.count) absent")
    }
}

/// a soft pulsing block that holds the exact space of text still on its way
struct Placeholder: View {
    let width: CGFloat
    let height: CGFloat
    @Environment(\.palette) private var p
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(p.containerHighest)
            .frame(width: width, height: height)
            .opacity(dim ? 0.45 : 0.9)
            .onAppear { withAnimation(.easeInOut(duration: 0.85).repeatForever()) { dim = true } }
    }
}

/// a chip that opens a list of semesters
struct SemesterMenu: View {
    let semesters: [Semester]
    let selected: Semester?
    /// marked "current" in the list, nil marks none
    var current: Semester? = nil
    var filled = false
    /// in a toolbar the system draws the capsule, the chip only brings its label
    var bare = false
    let pick: (Int, Semester) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        if let sel = selected {
            Menu {
                ForEach(Array(semesters.enumerated()), id: \.element.id) { i, s in
                    Button {
                        pick(i, s)
                    } label: {
                        if s.code == sel.code {
                            Label(prettySemester(s.code) + (s.id == current?.id ? "  ·  current" : ""), systemImage: "checkmark")
                        } else {
                            Text(prettySemester(s.code) + (s.id == current?.id ? "  ·  current" : ""))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(prettySemester(sel.code)).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(p.onSurface)
                .padding(.horizontal, bare ? 4 : 12)
                .padding(.vertical, bare ? 0 : 7)
                .background(filled ? p.secondaryContainer : Color.clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(filled || bare ? Color.clear : p.outlineVariant))
            }
            .accessibilityLabel("Semester, \(prettySemester(sel.code))")
        }
    }
}

/// a view's own semester row, for lists the portal keeps apart from attendance's (marks, exams)
struct SemesterRow: View {
    let semesters: [Semester]
    let selected: Semester?
    let fetchedAt: Date?
    let pick: (String) -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack {
            SemesterMenu(semesters: semesters, selected: selected, filled: true) { _, s in pick(s.code) }
            Spacer()
            if let fetchedAt {
                Text("Updated \(ago(fetchedAt))").font(.caption.weight(.medium)).foregroundStyle(p.onSurfaceVariant)
            }
        }
        .gutter()
        .padding(.vertical, 6)
    }
}

/// the app's mark: the frog on its dark green
struct AppMark: View {
    var size: CGFloat = 96

    var body: some View {
        Image("Mark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityLabel("JPortal")
    }
}

/// jportal signed off with "made with big energy by yash malik" (an eggplant, here a red heart), so do we
struct BigEnergy: View {
    @Environment(\.palette) private var p

    /// an outline heart in red, sitting in a line of text
    static var heart: Text { Text(Image(systemName: "heart")).foregroundStyle(Color.red) }

    var body: some View {
        (Text("Big \(BigEnergy.heart) Energy lives on in ") + Text("[Yash Malik](https://github.com/codeblech)"))
            .font(.footnote)
            .foregroundStyle(p.onSurfaceVariant)
            .tint(p.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
    }
}

/// now, to the minute, ticking on the minute. every countdown on screen reads this one clock
struct MinuteClock<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.everyMinute) { tl in content(tl.date) }
    }
}
