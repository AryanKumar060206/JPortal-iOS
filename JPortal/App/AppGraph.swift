import Foundation
import Observation

/// the app's few singletons, built once and handed down through the environment
@MainActor
@Observable
final class AppGraph {
    @ObservationIgnored let prefs = Prefs()
    @ObservationIgnored let transport = Transport()
    let sessions: SessionManager
    @ObservationIgnored let cache = Cache()
    @ObservationIgnored private(set) var repo: Repository!
    @ObservationIgnored private(set) var calendar: CalendarSync!
    @ObservationIgnored private(set) var timetable: TimetableSource!

    init() {
        sessions = SessionManager(store: SessionStore(), transport: transport)
        repo = Repository(cache: cache, sessions: sessions) { [unowned self] in !self.demo }
        calendar = CalendarSync(prefs: prefs) { [unowned self] in await self.repo.examSheet() }
        timetable = TimetableSource { [unowned self] in self.demo ? Demo.timetable : nil }
    }

    /// the made up student is signed in, nothing may touch the portal
    var demo: Bool { Demo.owns(sessions.session) }

    /// signs the made up student in, from the sign-in screen's button
    func startDemo() async {
        let cache = cache
        await Task.detached { Demo.seed(cache) }.value
        sessions.signedIn(Demo.session)
        timetable.repaint()
    }

    func signedIn(_ s: Session, googleCredential: String? = nil) {
        sessions.signedIn(s, googleCredential: googleCredential)
        timetable.repaint()
    }

    func signOut() {
        calendar.forget()
        sessions.signOut()
        repo.wipe()
        prefs.clearAccountBits()
        timetable.repaint()
    }
}
