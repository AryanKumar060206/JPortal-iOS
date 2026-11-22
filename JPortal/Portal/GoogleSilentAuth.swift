import Foundation

/// silent google re-auth that works under webkit's tracking prevention.
///
/// one tap runs google in an iframe on the portal's page, where webkit hides
/// google's cookies (third party), so on ios it can never sign in silently.
/// this instead opens google's oauth endpoint as the top-level page of a hidden
/// web view: google's cookies are first party there, and prompt=none makes it
/// answer straight away, either with a fresh id token or with an error, never ui.
/// the portal's client id accepts its own origin as a redirect, and the id
/// token google sends there is what the portal's token exchange already takes.
enum GoogleSilentAuth {
    /// the redirect google sends us back to, exactly as registered: no trailing slash
    static let redirect = "https://webportal.jiit.ac.in:6011"

    enum Outcome: Equatable {
        case token(String)
        /// google wants the person (login_required, interaction_required, account_selection_required...)
        case refused(String)
    }

    static func url(clientId: String, nonce: String, loginHint: String?) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "id_token"),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "none"),
        ]
        if let hint = loginHint, !hint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: hint)) }
        c.queryItems = items
        return c.url!
    }

    static func nonce() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(rng.next() as UInt64, radix: 36) }.joined()
    }

    /// whether this navigation is google handing control back to the redirect
    static func isRedirect(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "webportal.jiit.ac.in" && url.port == 6011
            && (url.path.isEmpty || url.path == "/")
    }

    /// reads google's answer out of the redirect's fragment. a token only counts
    /// if it carries the nonce we asked with, so a stale or planted one is refused.
    static func outcome(_ url: URL, nonce: String) -> Outcome? {
        guard isRedirect(url), let fragment = url.fragment, !fragment.isEmpty else { return nil }
        var c = URLComponents()
        c.percentEncodedQuery = fragment
        let items = c.queryItems ?? []
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        if let token = value("id_token"), !token.isEmpty {
            guard jwtClaims(token)?["nonce"].string == nonce else { return .refused("nonce_mismatch") }
            return .token(token)
        }
        if let error = value("error") { return .refused(value("error_subtype").map { "\(error)/\($0)" } ?? error) }
        return .refused("no_token")
    }
}

/// the claims of a jwt, unverified. the server checks the signature, we only read
func jwtClaims(_ token: String) -> JSON? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return nil }
    return try? JSON(parsing: data)
}
