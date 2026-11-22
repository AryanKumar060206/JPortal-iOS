import Foundation
import UIKit

/// the last few errors, for the "copy debug report" button. never tokens, names or ids:
/// only error kinds and shapes are kept.
enum DebugLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    static func record(_ area: String, _ error: Error) {
        note(area, shape(error))
    }

    static func note(_ area: String, _ message: String) {
        lock.withLock {
            lines.append("\(stamp()) \(area): \(message)")
            if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        }
    }

    private static func shape(_ e: Error) -> String {
        guard let p = e as? PortalError else { return String(describing: type(of: e)) }
        switch p {
        case .sessionExpired: return "session expired"
        case .forbidden: return "forbidden"
        case .serverUnavailable(let code, let shape): return "server unavailable \(code) (\(shape))"
        case .serverError(let code, let shape, let err, _): return "server error \(code) (\(shape)) \(err ?? "")"
        case .emptyResponse: return "empty response"
        case .portal(let errors, let code): return "portal error \(code): \(errors.count) message(s)"
        case .malformed(let m): return "malformed: \(m)"
        case .untrusted: return "untrusted connection"
        case .network(_, let timedOut): return timedOut ? "network timeout" : "network"
        }
    }

    @MainActor
    static func report(extra: [String: String]) -> String {
        let info = Bundle.main.infoDictionary
        var out = [
            "JPortal for iOS \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(UIDevice.current.model)",
        ]
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { out.append("\(k): \(v)") }
        out.append("")
        out.append(contentsOf: lock.withLock { lines.isEmpty ? ["no errors recorded"] : lines })
        return out.joined(separator: "\n")
    }
}
