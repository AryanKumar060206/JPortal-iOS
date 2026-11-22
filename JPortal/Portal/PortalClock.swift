import Foundation

/// the portal validates dateseq and token expiry against its own clock, which
/// drifts (measured ~8.5 min slow). every response's Date header nudges our view of it.
final class PortalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _skew: TimeInterval = 0
    private let system: @Sendable () -> Date

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    init(system: @escaping @Sendable () -> Date = { Date() }) {
        self.system = system
    }

    var skew: TimeInterval { lock.withLock { _skew } }

    func now() -> Date { system().addingTimeInterval(skew) }

    func observe(_ dateHeader: String?) {
        guard let header = dateHeader else { return }
        let server: Date? = lock.withLock { formatter.date(from: header) }
        guard let server else { return }
        let s = server.timeIntervalSince(system())
        lock.withLock { _skew = s }
    }

    func restore(_ skew: TimeInterval) {
        lock.withLock { _skew = skew }
    }
}
