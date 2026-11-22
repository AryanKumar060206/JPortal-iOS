import SwiftUI
import UIKit

struct MeScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        let repo = graph.repo!
        let info = repo.personal.state.data?.general
        let session = graph.sessions.session
        let name = (info?.name).flatMap { $0.isBlank ? nil : $0 } ?? session?.name ?? ""
        let fees = repo.fees.state.data
        let hostel = repo.hostel.state.data
        let open = repo.feedback.state.data?.count ?? 0
        Screen("Me", refresh: {
            async let a: Void = repo.personal.refresh(force: true).value
            async let b: Void = repo.fees.refresh(force: true).value
            async let c: Void = repo.hostel.refresh(force: true).value
            async let d: Void = repo.feedback.refresh(force: true).value
            _ = await (a, b, c, d)
        }) {
            NavigationLink(value: Route.profile) {
                HStack(spacing: 16) {
                    Avatar(photo: repo.personal.state.data?.photo, name: name, size: 64, revealOnly: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.nameCase).font(.title3.weight(.semibold))
                        Text(session?.enrollmentNo ?? "").font(.subheadline)
                        if let info {
                            Text([info.program, info.branch, info.semester > 0 ? "Sem \(info.semester)" : ""].filter { !$0.isBlank }.joined(separator: " · "))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .foregroundStyle(p.onPrimaryContainer)
                .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
            }
            .buttonStyle(.plain)
            .gutter()
            .padding(.vertical, 8)

            SectionHeader("Money and stay")
            CardGroup {
                link(.fees, Entry(icon: "banknote", title: "Fees",
                                  subtitle: fees.map { $0.totalDue > 0 ? "\(rupees($0.totalDue)) due" : "Nothing due" }, alert: (fees?.totalDue ?? 0) > 0))
                link(.bank, Entry(icon: "building.columns", title: "Bank details"))
                link(.hostel, Entry(icon: "bed.double", title: "Hostel", subtitle: hostel.map { h in
                    guard let i = h.info else { return "Not allotted" }
                    return [i.hostel.titleCase, i.room.isBlank ? nil : "Room \(i.room)"].compactMap { $0 }.joined(separator: " · ")
                }))
            }
            SectionHeader("College")
            CardGroup {
                link(.feedback, Entry(icon: "text.bubble", title: "Feedback", subtitle: open > 0 ? "\(open) open" : "No feedback window open", alert: open > 0))
            }
            SectionHeader("App")
            CardGroup {
                link(.settings, Entry(icon: "gearshape", title: "Settings", subtitle: "Theme, goal, calendar"))
                link(.about, Entry(icon: "info.circle", title: "About JPortal", subtitle: "Credits, licenses, debug report"))
            }
            BigEnergy()
        }
        .task {
            repo.personal.refresh()
            repo.fees.refresh()
            repo.hostel.refresh()
            repo.feedback.refresh()
        }
    }

    private func link(_ route: Route, _ entry: Entry) -> some View {
        NavigationLink(value: route) { entry }.buttonStyle(.plain).groupRow(p.containerLow)
    }
}

/// the portal photo behind a tap, people open this app around other people
struct Avatar: View {
    let photo: String?
    let name: String
    let size: CGFloat
    var revealOnly = false
    @Environment(Prefs.self) private var prefs
    @Environment(\.palette) private var p

    var body: some View {
        let image = photo.flatMap { s -> UIImage? in
            guard s.count > 32 else { return nil }
            let raw = s.split(separator: ",", maxSplits: 1).last.map(String.init) ?? s
            return Data(base64Encoded: raw, options: .ignoreUnknownCharacters).flatMap(UIImage.init(data:))
        }
        ZStack {
            if let image, prefs.showPhoto {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(p.onPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(p.primary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(.easeInOut, value: prefs.showPhoto)
        .onTapGesture { if image != nil && !(revealOnly && prefs.showPhoto) { prefs.showPhoto.toggle() } }
        .accessibilityLabel(image != nil ? (prefs.showPhoto ? "Photo, double tap to hide" : "Initials, double tap to show photo") : "Initials")
    }
}

/// a page backed by one store
struct Page<T: Codable & Sendable, Content: View>: View {
    let title: String
    let store: Store<T>
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        Screen(title, refresh: { await store.refresh(force: true).value }) {
            StaleNotice(res: store.state) { store.refresh(force: true) }
            ResourceGate(res: store.state, retry: { store.refresh(force: true) }) { content($0) }
        }
        .navigationBarTitleDisplayMode(.large)
        .task { store.refresh() }
    }
}

private struct InfoGroup: View {
    let rows: [(String, String)]
    @Environment(\.palette) private var p

    var body: some View {
        let shown = rows.filter { !$0.1.isBlank }
        if !shown.isEmpty {
            CardGroup {
                ForEach(shown, id: \.0) { k, v in InfoRow(k, v).groupRow(p.containerLow) }
            }
        }
    }
}

struct ProfileScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        Page(title: "Profile", store: graph.repo.personal) { info in
            let g = info.general
            VStack(spacing: 6) {
                Avatar(photo: info.photo, name: g.name, size: 112)
                Text(g.name.nameCase).font(.title2.weight(.semibold)).padding(.top, 10)
                Text(g.enrollmentNo).font(.body).foregroundStyle(p.onSurfaceVariant)
                Text("Tap any row to copy").font(.caption).foregroundStyle(p.onSurfaceVariant).padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            SectionHeader("Academics")
            InfoGroup(rows: [
                ("Program", [g.program, g.branch].filter { !$0.isBlank }.joined(separator: " · ")),
                ("Semester", g.semester > 0 ? "\(g.semester)" : ""),
                ("Batch", [g.batch, g.section].filter { !$0.isBlank }.joined(separator: " · ")),
                ("Admitted", g.admissionYear), ("APAAR ID", g.apaarId),
            ])
            SectionHeader("Contact")
            InfoGroup(rows: [
                ("College email", g.collegeEmail), ("Personal email", g.personalEmail), ("Phone", g.phone),
                ("Address", [g.currentAddress1, g.currentAddress3, g.currentCity, g.currentState, g.currentPin].filter { !$0.isBlank }.joined(separator: ", ")),
            ])
            SectionHeader("Family")
            InfoGroup(rows: [("Father", g.fatherName.nameCase), ("Mother", g.motherName.nameCase), ("Parent phone", g.parentPhone), ("Parent email", g.parentEmail)])
            SectionHeader("Personal")
            InfoGroup(rows: [("Date of birth", g.dateOfBirth), ("Blood group", g.bloodGroup), ("Gender", g.gender), ("Category", g.category), ("Nationality", g.nationality)])
            if !info.qualifications.isEmpty {
                SectionHeader("Before JIIT")
                InfoGroup(rows: info.qualifications.map { q in
                    ("\(q.code) · \(q.board) · \(q.year)", q.percent > 0 ? String(format: "%.1f%%", q.percent) : q.cgpa > 0 ? "CGPA \(fmt(q.cgpa))" : "")
                })
            }
        }
    }
}

struct FeesScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        Page(title: "Fees", store: graph.repo.fees) { f in
            if f.heads.isEmpty {
                MessageState(frog: .sleep, title: "No fee records")
            } else {
                CardGroup {
                    ForEach(f.heads.sorted { $0.semester > $1.semester }, id: \.self) { h in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Semester \(h.semester)").font(.headline)
                                let extra = [h.type.isBlank ? nil : h.type, h.waived > 0 ? "\(rupees(h.waived)) waived" : nil,
                                             h.refunded > 0 ? "\(rupees(h.refunded)) refunded" : nil].compactMap { $0 }.joined(separator: " · ")
                                if !extra.isEmpty { Text(extra).font(.caption).foregroundStyle(p.onSurfaceVariant) }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(rupees(h.paid)) paid").font(.subheadline.weight(.bold))
                                Text("of \(rupees(h.fee))").font(.caption).foregroundStyle(p.onSurfaceVariant)
                                if h.due > 0 { Text("\(rupees(h.due)) due").font(.caption.weight(.semibold)).foregroundStyle(p.error) }
                            }
                        }
                        .padding(16)
                        .groupRow(p.containerLow)
                    }
                }
                .padding(.top, 8)
                if let adv = f.advance.first, adv.amount > 0 {
                    Text("\(rupees(adv.amount)) held as advance").font(.subheadline).foregroundStyle(p.onSurfaceVariant).padding(20)
                }
            }
        }
    }
}

struct BankScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var shown = false

    /// "•••• 4821": enough to recognise it, not enough to read it off over a shoulder
    private func masked(_ a: String) -> String { a.count > 4 ? "•••• \(a.suffix(4))" : a }

    var body: some View {
        Page(title: "Bank details", store: graph.repo.bank) { b in
            CardGroup {
                InfoRow(label: "Account number", value: shown ? b.account : masked(b.account), copy: b.account) {
                    Button { shown.toggle() } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                        .accessibilityLabel(shown ? "Hide" : "Show")
                }
                .groupRow(p.containerLow)
                ForEach([("IFSC", b.ifsc), ("Bank", b.bank.titleCase), ("Account holder", b.holder.nameCase),
                         ("Branch", [b.address, b.city, b.state, b.pin].filter { !$0.isBlank }.joined(separator: ", ")),
                         ("Status", b.frozen == "Y" ? "Locked by the accounts office" : "Editable on the portal")].filter { !$0.1.isBlank }, id: \.0) { k, v in
                    InfoRow(k, v).groupRow(p.containerLow)
                }
            }
            .padding(.top, 8)
            Text("Tap to copy").font(.caption).foregroundStyle(p.onSurfaceVariant).padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

struct HostelScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        Page(title: "Hostel", store: graph.repo.hostel) { answer in
            if let h = answer.info {
                VStack(alignment: .leading, spacing: 6) {
                    Text(h.hostel.titleCase).font(.title3.weight(.semibold))
                    Text("Room").font(.subheadline.weight(.semibold)).padding(.top, 8)
                    Text(h.room.ifBlank("–")).font(.number(52))
                    FlowLayout {
                        ForEach([h.floor.isBlank ? nil : "Floor \(h.floor)", h.roomType.isBlank ? nil : h.roomType.titleCase,
                                 h.hostelType.isBlank ? nil : h.hostelType.titleCase].compactMap { $0 }, id: \.self) { c in
                            Text(c).font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(p.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        }
                    }
                    .padding(.top, 6)
                }
                .foregroundStyle(p.onPrimaryContainer)
                .card(p.primaryContainer, radius: Radius.extraLarge, padding: 20)
                .gutter()
                .padding(.vertical, 8)
                InfoGroup(rows: [("Allotted", [h.from, h.until].filter { !$0.isBlank }.joined(separator: " to ")), ("Bed", h.bed), ("Left on", h.leftOn ?? "")])
            } else {
                MessageState(frog: .sleep, title: "No hostel allotted", message: "Day scholar, or the allotment isn't in yet.")
            }
        }
    }
}

struct SettingsScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var editTarget = false
    @State private var confirmOut = false
    @State private var pickCalendar = false

    var body: some View {
        @Bindable var prefs = graph.prefs
        Screen("Settings") {
            SectionHeader("Look")
            CardGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Theme").font(.headline)
                    Picker("Theme", selection: $prefs.themeMode) {
                        ForEach(ThemeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(16)
                .groupRow(p.containerLow)
                if p.dark {
                    toggle("Pure black", "Fully black backgrounds", $prefs.amoled)
                }
            }
            SectionHeader("Attendance")
            CardGroup {
                Button { editTarget = true } label: { Entry(icon: "flag", title: "Attendance goal", subtitle: "\(prefs.target)%") }
                    .buttonStyle(.plain).groupRow(p.containerLow)
            }
            SectionHeader("Exams")
            CardGroup {
                toggle("Sync to calendar",
                       prefs.calendarSync ? "Upcoming papers, with reminders the evening before and an hour before"
                           : prefs.calendarDenied ? "Calendar access denied. Allow it in Settings"
                           : "Puts upcoming papers in a calendar you pick and keeps room and seat current",
                       Binding(get: { prefs.calendarSync }, set: { on in
                           if on { Task { await turnOnSync() } } else { graph.calendar.disable() }
                       }))
                if prefs.calendarSync {
                    Button { pickCalendar = true } label: {
                        Entry(icon: "calendar", title: "Calendar", subtitle: graph.calendar.calendar(prefs.calendarId)?.title ?? "Pick one")
                    }
                    .buttonStyle(.plain).groupRow(p.containerLow)
                }
                if prefs.calendarDenied || graph.calendar.denied {
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                        Entry(icon: "arrow.up.forward.app", title: "Open Settings", subtitle: "Allow calendar there, then turn sync on")
                    }
                    .buttonStyle(.plain).groupRow(p.containerLow)
                }
            }
            SectionHeader("Planner")
            CardGroup {
                toggle("Show timeline", "The rail through your day, with what's on now lit up", $prefs.timeline)
            }
            SectionHeader("Account")
            CardGroup {
                Button { confirmOut = true } label: {
                    Entry(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", subtitle: "Clears the session and everything cached on this phone", chevron: false)
                }
                .buttonStyle(.plain).groupRow(p.containerLow)
            }
        }
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $editTarget) {
            TargetSheet(current: prefs.target) { prefs.setTarget($0) }.presentationDetents([.medium])
        }
        .sheet(isPresented: $pickCalendar) { CalendarPicker() }
        .alert("Sign out?", isPresented: $confirmOut) {
            Button("Sign out", role: .destructive) { graph.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your cached attendance and marks go too.")
        }
    }

    private func turnOnSync() async {
        if !graph.calendar.hasAccess {
            let ok = await graph.calendar.requestAccess()
            if !ok {
                graph.prefs.calendarDenied = true
                return
            }
        }
        graph.prefs.calendarDenied = false
        if let id = graph.prefs.calendarId, graph.calendar.calendar(id) != nil {
            await graph.calendar.enable(id)
        } else {
            pickCalendar = true
        }
    }

    private func toggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(p.onSurfaceVariant)
            }
        }
        .padding(16)
        .groupRow(p.containerLow)
    }
}

private struct CalendarPicker: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var p

    var body: some View {
        NavigationStack {
            let cals = graph.calendar.calendars()
            List {
                if cals.isEmpty {
                    Text("No calendar on this phone takes new events. Add an account in the Calendar app first.")
                }
                ForEach(cals, id: \.calendarIdentifier) { c in
                    Button {
                        Task {
                            await graph.calendar.enable(c.calendarIdentifier)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Circle().fill(Color(cgColor: c.cgColor)).frame(width: 12, height: 12)
                            VStack(alignment: .leading) {
                                Text(c.title).foregroundStyle(p.onSurface)
                                Text(c.source.title).font(.caption).foregroundStyle(p.onSurfaceVariant)
                            }
                            Spacer()
                            if c.calendarIdentifier == graph.prefs.calendarId { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .navigationTitle("Sync exams to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct AboutScreen: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        Screen("About") {
            VStack(spacing: 6) {
                AppMark(size: 96)
                Text("JPortal").font(.title.weight(.semibold)).padding(.top, 8)
                Text("\(version) · iOS").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                Text("Unofficial. Not made, endorsed or checked by JIIT.").font(.subheadline).foregroundStyle(p.onSurfaceVariant)
                    .multilineTextAlignment(.center).padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            SectionHeader("Made possible by")
            CardGroup {
                link("heart", "JPortal for Android", "codelif, the app this is a port of", "https://github.com/codelif/jportal-android")
                link("heart", "JPortal", Text("Big \(BigEnergy.heart) Energy lives on in Yash Malik"), "https://github.com/codeblech/jportal")
                link("chevron.left.forwardslash.chevron.right", "ktjiit", "GPL-3.0, the portal client this one follows", "https://github.com/codelif/ktjiit")
                link("chevron.left.forwardslash.chevron.right", "jsjiit", "ISC, portal protocol groundwork", "https://github.com/codeblech/jsjiit")
                link("chevron.left.forwardslash.chevron.right", "pyjiit", "MIT, where it all started", "https://github.com/codelif/pyjiit")
                link("calendar", "jiit-planner-cdn", "The planner's timetables", "https://github.com/codelif/jiit-planner-cdn")
            }
            SectionHeader("Licenses")
            CardGroup {
                InfoRow("JPortal for iOS", "GNU General Public License v3.0").groupRow(p.containerLow)
                InfoRow("Frog artwork", "From JPortal for Android, GPL-3.0").groupRow(p.containerLow)
            }
            SectionHeader("Something broken?")
            CardGroup {
                Button {
                    UIPasteboard.general.string = DebugLog.report(extra: ["clock skew": String(format: "%.0fs", graph.transport.clock.skew)])
                    copied = true
                } label: {
                    Entry(icon: "doc.on.doc", title: copied ? "Copied, paste it into a GitHub issue" : "Copy debug report",
                          subtitle: "App, device and recent errors. No tokens, names or ids.", chevron: false)
                }
                .buttonStyle(.plain).groupRow(p.containerLow)
            }
            BigEnergy()
        }
        .navigationBarTitleDisplayMode(.large)
    }

    private func link(_ icon: String, _ title: String, _ sub: String, _ url: String) -> some View {
        Button { if let u = URL(string: url) { openURL(u) } } label: { Entry(icon: icon, title: title, subtitle: sub) }
            .buttonStyle(.plain).groupRow(p.containerLow)
    }

    private func link(_ icon: String, _ title: String, _ sub: Text, _ url: String) -> some View {
        Button { if let u = URL(string: url) { openURL(u) } } label: { Entry(icon: icon, title: title, subtitleText: sub) }
            .buttonStyle(.plain).groupRow(p.containerLow)
    }
}
