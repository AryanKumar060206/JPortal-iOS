import SwiftUI

@main
struct JPortalApp: App {
    @State private var graph = AppGraph()

    var body: some Scene {
        WindowGroup {
            Themed { RootView() }
                .environment(graph)
                .environment(graph.prefs)
        }
    }
}

/// applies the theme setting and hands every view its palette
private struct Themed<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(Prefs.self) private var prefs
    @Environment(\.colorScheme) private var system

    var body: some View {
        let scheme: ColorScheme? = prefs.themeMode == .system ? nil : (prefs.themeMode == .dark ? .dark : .light)
        Inner(amoled: prefs.amoled, content: content)
            .preferredColorScheme(scheme)
    }

    private struct Inner: View {
        let amoled: Bool
        @ViewBuilder let content: () -> Content
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            let palette = Palette.make(dark: scheme == .dark, amoled: amoled)
            content()
                .environment(\.palette, palette)
                .tint(palette.primary)
        }
    }
}

/// everything you can land on past a tab's root
enum Route: Hashable {
    /// codes, not portal ids, so any semester's subject opens the same way
    case subject(semesterCode: String, subjectCode: String)
    case gradeCard(String)
    case marks(String)
    case exams
    case choices
    case mooc
    case profile
    case fees
    case bank
    case hostel
    case feedback
    case settings
    case about
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .subject(let sem, let code): SubjectScreen(semesterCode: sem, subjectCode: code)
        case .gradeCard(let code): GradeCardScreen(code: code)
        case .marks(let code): MarksScreen(code: code)
        case .exams: ExamsScreen()
        case .choices: ChoicesScreen()
        case .mooc: MoocScreen()
        case .profile: ProfileScreen()
        case .fees: FeesScreen()
        case .bank: BankScreen()
        case .hostel: HostelScreen()
        case .feedback: FeedbackScreen()
        case .settings: SettingsScreen()
        case .about: AboutScreen()
        }
    }
}

struct RootView: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            p.surface.ignoresSafeArea()
            if graph.sessions.signedIn {
                MainTabs().transition(.opacity)
            } else {
                SignInScreen().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: graph.sessions.signedIn)
    }
}

enum Tab: Hashable { case attendance, academics, subjects, planner, me }

struct MainTabs: View {
    @Environment(AppGraph.self) private var graph
    @Environment(\.palette) private var p
    @State private var tab: Tab = .attendance

    var body: some View {
        @Bindable var sessions = graph.sessions
        TabView(selection: $tab) {
            stack { AttendanceScreen() }
                .tabItem { Label("Attendance", systemImage: "checklist") }
                .tag(Tab.attendance)
            stack { AcademicsScreen() }
                .tabItem { Label("Academics", systemImage: "graduationcap") }
                .tag(Tab.academics)
            stack { SubjectsScreen() }
                .tabItem { Label("Subjects", systemImage: "book") }
                .tag(Tab.subjects)
            stack { PlannerScreen() }
                .tabItem { Label("Planner", systemImage: "clock") }
                .tag(Tab.planner)
            stack { MeScreen() }
                .tabItem { Label("Me", systemImage: "person") }
                .tag(Tab.me)
        }
        .sensoryFeedback(.selection, trigger: tab)
        // under everything: it only needs to exist, the hidden web view tries a silent google sign-in
        .background { if graph.sessions.reauthWanted { ReauthHost() } }
        .sheet(isPresented: $sessions.needsSheet) { SignInSheet() }
        .task { if !graph.demo { _ = await graph.sessions.loadConfig() } }
    }

    private func stack<V: View>(@ViewBuilder _ root: () -> V) -> some View {
        NavigationStack {
            root().navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

// MARK: the semester every screen follows

struct SemesterSelection {
    let all: [Semester]
    /// the one going on now, which isn't always the head of the list
    let current: Semester?
    let selected: Semester?
    var isCurrent: Bool { selected?.id == current?.id }
}

extension AppGraph {
    /// the semester going on now unless the user pinned something else
    var semesterSelection: SemesterSelection {
        let all = repo.attendanceMeta.state.data?.semesters ?? []
        let current = currentSemester(all)
        return SemesterSelection(all: all, current: current, selected: all.first { $0.code == prefs.semester } ?? current)
    }

    var semesterNumber: String { repo.attendanceMeta.state.data?.header?.semesterNumber ?? "" }
}
