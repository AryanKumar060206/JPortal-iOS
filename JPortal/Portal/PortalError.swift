import Foundation

enum PortalError: Error, Sendable {
    /// 401, token is past its 2h life
    case sessionExpired
    /// 403, usually a bad Origin or a token the server refuses outright
    case forbidden
    /// 5xx, the portal falls over a lot during result season. shape is content type and size, never the body
    case serverUnavailable(code: Int, shape: String)
    /// 5xx with spring's error page instead of an envelope: the server is up, this request blew up in it
    case serverError(code: Int, shape: String, error: String?, detail: String?)
    /// 200 with nothing in it, what you get for a bad LocalName
    case emptyResponse
    /// the envelope said Failure
    case portal(errors: [String], code: Int)
    case malformed(String)
    /// tls failed: an expired or wrong certificate, or something in the middle. never worth a retry
    case untrusted(String)
    case network(String, timedOut: Bool)

    /// "NO ... FOUND" style answers, which really mean an empty list
    var isNoData: Bool {
        guard case .portal(let errors, _) = self else { return false }
        return errors.contains { e in
            e.range(of: "NO ", options: .caseInsensitive) != nil && e.range(of: "FOUND", options: .caseInsensitive) != nil
        }
    }

    /// how the hostel call says there's no allotment, "You are not a hosteller student"
    var meansNoHostel: Bool {
        guard case .portal(let errors, _) = self else { return false }
        return isNoData || errors.contains { $0.range(of: "not a hosteller", options: .caseInsensitive) != nil }
    }

    /// the portal's gateway drops the odd request under load and answers fine a second later.
    var timedOut: Bool {
        if case .network(_, true) = self { return true }
        return false
    }

    /// a timeout already cost us 45s, don't make it three
    var transient: Bool {
        switch self {
        case .serverUnavailable, .emptyResponse: return true
        case .network(_, let timedOut): return !timedOut
        default: return false
        }
    }
}

/// thrown when only a visible sign in can fix things, the ui answers with the sheet
struct SignInRequired: Error {}

/// what a person reads when something went wrong
func describe(_ error: Error?) -> String {
    guard let error else { return "" }
    if error is SignInRequired { return "Sign in again to refresh" }
    guard let e = error as? PortalError else {
        if error is MarksParseError { return "The marks sheet couldn't be read" }
        if let u = error as? URLError, u.code == .notConnectedToInternet { return "You're offline" }
        return "Something went wrong"
    }
    switch e {
    case .untrusted: return "The portal is having trouble on its end"
    case .network: return "You're offline"
    case .serverUnavailable: return "The portal is down right now"
    case .serverError: return "The portal couldn't handle this request"
    case .portal(let errors, _):
        guard let first = errors.first, !first.isEmpty else { return "The portal said no" }
        let lower = first.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    case .sessionExpired: return "Session expired"
    case .emptyResponse, .malformed: return "The portal sent something odd"
    case .forbidden: return "The portal refused this request"
    }
}

func isOffline(_ error: Error?) -> Bool {
    if case .network = error as? PortalError { return true }
    return false
}
